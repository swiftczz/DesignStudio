import Foundation

/// 使用 Codex 的 stdio JSON-RPC 接收正文增量。每次生成使用一个隔离的临时会话。
nonisolated enum CodexAppServer {
    enum Unavailable: Error { case startup }

    static func stream(profile: ProviderProfile, workdir: URL, images: [URL], prompt: String,
                       into output: AsyncThrowingStream<LLMEvent, Error>.Continuation) async throws {
        let arguments = ["app-server", "--listen", "stdio://", "-c", "service_tier=\"default\""]
        let process = CLIRunner.makeProcess(executable: profile.cliExecutable, arguments: arguments, cwd: workdir)
        let input = Pipe()
        let writer = input.fileHandleForWriting
        defer {
            try? writer.close()
            if process.isRunning { process.terminate() }
        }
        let lines = CLIRunner.stream(process, inputPipe: input, name: profile.cliExecutable)
        // CLI 版本不支持握手时回到 exec；请求模型以后不自动重发。
        let startupTimer = Task {
            try await Task.sleep(for: .seconds(8))
            if process.isRunning { process.terminate() }
        }
        defer { startupTimer.cancel() }

        func send(_ method: String, id: Int? = nil, params: [String: Any]? = nil) throws {
            var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
            message["id"] = id
            message["params"] = params
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            try writer.write(contentsOf: data)
        }

        var requestedTurn = false
        var stderr = ""
        var lastItem: String?
        var itemText = ""
        var pendingText = ""
        let clock = ContinuousClock()
        var lastFlush = clock.now - .seconds(1)

        func flushText() {
            guard !pendingText.isEmpty else { return }
            output.yield(.text(pendingText))
            pendingText = ""
            lastFlush = clock.now
        }

        func receiveText(_ delta: String, item: String) {
            guard !delta.isEmpty else { return }
            if lastItem != item {
                if lastItem != nil { pendingText += "\n\n" }
                lastItem = item
                itemText = ""
            }
            itemText += delta
            pendingText += delta
            if pendingText.utf8.count >= 192 || clock.now - lastFlush >= .milliseconds(80) {
                flushText()
            }
        }

        do {
            try send("initialize", id: 1, params: [
                "clientInfo": ["name": "designstudio", "title": "DesignStudio", "version": "1"]
            ])
            for try await line in lines {
                try Task.checkCancellation()
                if case .stderr(let text) = line {
                    if stderr.utf8.count < 4_000 { stderr += text + "\n" }
                }
                guard case .stdout(let json) = line, let event = JSONHelpers.object(json) else { continue }
                if let id = event["id"] as? Int, event["method"] == nil {
                    if let error = event["error"] as? [String: Any] {
                        throw CodexProvider.classify(error["message"] as? String ?? "Codex 请求失败")
                    }
                    let result = event["result"] as? [String: Any]
                    switch id {
                    case 1:
                        guard result != nil else { throw Unavailable.startup }
                        try send("initialized")
                        var params: [String: Any] = [
                            "cwd": workdir.path, "sandbox": "read-only", "approvalPolicy": "never",
                            "ephemeral": true, "serviceTier": "default"
                        ]
                        if !profile.model.trimmed.isEmpty { params["model"] = profile.model.trimmed }
                        try send("thread/start", id: 2, params: params)
                    case 2:
                        guard let thread = result?["thread"] as? [String: Any],
                              let threadID = thread["id"] as? String else { throw Unavailable.startup }
                        let inputs = [["type": "text", "text": prompt]]
                            + images.map { ["type": "localImage", "path": $0.path] }
                        var params: [String: Any] = ["threadId": threadID, "input": inputs, "summary": "concise"]
                        if !profile.effort.isEmpty { params["effort"] = profile.effort }
                        startupTimer.cancel()
                        requestedTurn = true
                        output.yield(.status("Codex 正在生成…"))
                        try send("turn/start", id: 3, params: params)
                    default: break
                    }
                    continue
                }

                guard let method = event["method"] as? String, let params = event["params"] as? [String: Any] else { continue }
                switch method {
                case "item/agentMessage/delta":
                    if let id = params["itemId"] as? String, let delta = params["delta"] as? String {
                        receiveText(delta, item: id)
                    }
                case "item/completed":
                    if let item = params["item"] as? [String: Any], item["type"] as? String == "agentMessage",
                       let id = item["id"] as? String, let text = item["text"] as? String {
                        if lastItem != id {
                            receiveText(text, item: id)
                        } else if text.hasPrefix(itemText) {
                            receiveText(String(text.dropFirst(itemText.count)), item: id)
                        } else {
                            throw LLMError.cli("Codex 返回的正文与流式预览不一致，请重试。")
                        }
                        flushText()
                    }
                case "item/reasoning/summaryTextDelta":
                    if let delta = params["delta"] as? String { output.yield(.thinking(delta)) }
                case "item/reasoning/summaryPartAdded":
                    if let index = params["summaryIndex"] as? Int, index > 0 { output.yield(.thinking("\n\n")) }
                case "thread/tokenUsage/updated":
                    if let usage = params["tokenUsage"] as? [String: Any], let total = usage["total"] as? [String: Any] {
                        output.yield(.usage(input: total["inputTokens"] as? Int ?? 0,
                                            output: total["outputTokens"] as? Int ?? 0))
                    }
                case "turn/completed":
                    flushText()
                    let turn = params["turn"] as? [String: Any]
                    guard turn?["status"] as? String == "completed" else {
                        let error = turn?["error"] as? [String: Any]
                        throw CodexProvider.classify(error?["message"] as? String ?? "Codex 生成未完成")
                    }
                    guard lastItem != nil else { throw LLMError.emptyResponse }
                    return
                default: break
                }
            }
            try Task.checkCancellation()
            throw CodexProvider.classify(stderr.trimmed.isEmpty ? "Codex 连接意外结束" : stderr.trimmed)
        } catch {
            try Task.checkCancellation()
            if !requestedTurn { throw Unavailable.startup }
            throw error
        }
    }
}
