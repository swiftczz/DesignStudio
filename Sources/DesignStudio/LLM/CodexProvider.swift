import Foundation

/// 使用官方 Codex CLI 的 app-server，旧版 CLI 或自定义参数走 codex exec。
/// 登录由 `codex login`（ChatGPT 账号）完成。
nonisolated struct CodexProvider: LLMProvider {
    let profile: ProviderProfile

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        let profile = profile
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let workdir = try TempWorkspace.make(prefix: "codex")
                    defer { try? FileManager.default.removeItem(at: workdir) }
                    let images = try TempWorkspace.writeImages(request.latestImages, to: workdir)

                    var prompt = request.flattenedPrompt(includeSystem: true)
                    // 注意：不要在这里另立输出格式，必须与 instructions 里的画板协议一致（每个画板一个代码块）
                    prompt += "\n\nIMPORTANT: Do not run shell commands and do not create or edit files. "
                        + "Reply directly in this message, following the output contract in <instructions>: "
                    prompt += request.replyFormatReminder
                    let extra = ArgumentSplitter.split(profile.extraArguments)
                    continuation.yield(.status("正在启动 Codex…"))
                    // 自定义 exec 参数可能只适用于旧入口，按原方式传递。
                    if extra.isEmpty {
                        do {
                            try await CodexAppServer.stream(profile: profile, workdir: workdir, images: images,
                                                            prompt: prompt, into: continuation)
                            continuation.finish()
                            return
                        } catch CodexAppServer.Unavailable.startup {
                            try Task.checkCancellation()
                        }
                    }

                    var args = [
                        "exec",
                        "--json",
                        "--skip-git-repo-check",
                        "--sandbox", "read-only",
                        "-C", workdir.path
                    ]
                    if !profile.model.trimmed.isEmpty { args += ["-m", profile.model.trimmed] }
                    // 要求返回推理摘要，才能在对话里展示思维链
                    if !extra.contains(where: { $0.contains("model_reasoning_summary") }) {
                        args += ["-c", "model_reasoning_summary=\"detailed\""]
                    }
                    if !profile.effort.isEmpty, !extra.contains(where: { $0.contains("model_reasoning_effort") }) {
                        args += ["-c", "model_reasoning_effort=\"\(profile.effort)\""]
                    }
                    args += extra
                    args += ["-c", "service_tier=\"default\""]
                    if !images.isEmpty {
                        args += ["--image", images.map(\.path).joined(separator: ",")]
                    }

                    var emittedByItem: [String: Int] = [:]
                    var emittedAny = false
                    var stderr = ""
                    var lastItemID: String?

                    func emitAgentText(id: String, text: String) {
                        let already = emittedByItem[id] ?? 0
                        if already == 0 {
                            if emittedAny && lastItemID != id { continuation.yield(.text("\n\n")) }
                            continuation.yield(.text(text))
                        } else if text.count > already {
                            continuation.yield(.text(String(text.dropFirst(already))))
                        }
                        emittedByItem[id] = max(already, text.count)
                        emittedAny = true
                        lastItemID = id
                    }

                    var thoughtByItem: [String: Int] = [:]
                    func emitReasoning(id: String, text: String) {
                        let already = thoughtByItem[id] ?? 0
                        if already == 0 {
                            if !thoughtByItem.isEmpty { continuation.yield(.thinking("\n\n")) }
                            continuation.yield(.thinking(text))
                        } else if text.count > already {
                            continuation.yield(.thinking(String(text.dropFirst(already))))
                        }
                        thoughtByItem[id] = max(already, text.count)
                    }

                    for try await line in CLIRunner.stream(profile.cliExecutable, args, stdin: prompt, cwd: workdir) {
                        switch line {
                        case .stderr(let s):
                            stderr += s + "\n"
                        case .exit(let code):
                            if code == 127 { throw LLMError.notInstalled(profile.cliExecutable) }
                            if code != 0 && !emittedAny {
                                throw Self.classify(stderr.trimmed.isEmpty ? "codex 退出码 \(code)" : stderr.trimmed)
                            }
                        case .stdout(let s):
                            guard let obj = JSONHelpers.object(s) else { continue }
                            let type = obj["type"] as? String

                            // 新版事件格式（thread.* / turn.* / item.*）
                            if let type, type.hasPrefix("item.") {
                                guard let item = obj["item"] as? [String: Any] else { continue }
                                let itemType = (item["type"] as? String) ?? (item["item_type"] as? String) ?? ""
                                let id = item["id"] as? String ?? UUID().uuidString
                                switch itemType {
                                case "agent_message", "assistant_message":
                                    if let text = item["text"] as? String, !text.isEmpty {
                                        emitAgentText(id: id, text: text)
                                    }
                                case "reasoning":
                                    if let text = item["text"] as? String, !text.trimmed.isEmpty {
                                        emitReasoning(id: id, text: text)
                                    } else {
                                        continuation.yield(.status("Codex 思考中…"))
                                    }
                                case "command_execution":
                                    continuation.yield(.status("Codex 正在执行命令…"))
                                case "error":
                                    if let msg = item["message"] as? String { continuation.yield(.status(msg)) }
                                default:
                                    break
                                }
                                continue
                            }

                            switch type {
                            case "thread.started":
                                continuation.yield(.status("Codex 已连接"))
                            case "turn.started":
                                continuation.yield(.status("Codex 正在生成…"))
                            case "turn.completed":
                                if let usage = obj["usage"] as? [String: Any] {
                                    continuation.yield(.usage(input: usage["input_tokens"] as? Int ?? 0,
                                                              output: usage["output_tokens"] as? Int ?? 0))
                                }
                            case "turn.failed":
                                let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "Codex 生成失败"
                                throw Self.classify(msg)
                            case "error":
                                let msg = obj["message"] as? String ?? s
                                throw Self.classify(msg)
                            default:
                                // 旧版格式：{"msg": {"type": "agent_message_delta", "delta": "..."}}
                                if let msg = obj["msg"] as? [String: Any] {
                                    switch msg["type"] as? String {
                                    case "agent_message_delta":
                                        if let d = msg["delta"] as? String {
                                            emittedByItem["legacy", default: 0] += d.count
                                            emittedAny = true
                                            continuation.yield(.text(d))
                                        }
                                    case "agent_message":
                                        if let t = msg["message"] as? String, (emittedByItem["legacy"] ?? 0) == 0 {
                                            emitAgentText(id: "legacy-final", text: t)
                                        }
                                    case "error":
                                        throw Self.classify(msg["message"] as? String ?? s)
                                    default: break
                                    }
                                }
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func classify(_ message: String) -> LLMError {
        if let hint = CLIDiagnosis.brokenInstallMessage(message, kind: .codex, name: "Codex") { return .cli(hint) }
        let lower = message.lowercased()
        if lower.contains("login") || lower.contains("unauthorized") || lower.contains("401")
            || lower.contains("not authenticated") || lower.contains("re-authenticate") {
            return .notLoggedIn("Codex")
        }
        if lower.contains("command not found") { return .notInstalled("codex") }
        return .cli(message)
    }
}
