import Foundation

/// 通过官方 Claude Code CLI 调用 Claude：
/// `claude -p --output-format stream-json --verbose --include-partial-messages --system-prompt …`
/// 登录由 `claude auth login` 完成（Pro/Max 订阅或 Console 账号），凭据由 CLI 自己保存在钥匙串中。
nonisolated struct ClaudeCodeProvider: LLMProvider {
    let profile: ProviderProfile

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        let profile = profile
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let workdir = try TempWorkspace.make(prefix: "claude")
                    let images = try TempWorkspace.writeImages(request.latestImages, to: workdir)

                    var prompt = request.flattenedPrompt(includeSystem: false)
                    if !images.isEmpty {
                        let names = images.map { "./" + $0.lastPathComponent }.joined(separator: "、")
                        prompt += "\n\n用户附带了参考图片，已保存在当前目录：\(names)。请先用 Read 工具查看这些图片再开始设计。"
                    }

                    var args = [
                        "-p",
                        "--output-format", "stream-json",
                        "--verbose",
                        "--include-partial-messages",
                        "--system-prompt", request.system
                    ]
                    if !profile.model.trimmed.isEmpty { args += ["--model", profile.model.trimmed] }
                    let extra = ArgumentSplitter.split(profile.extraArguments)
                    // 新模型默认不返回思考内容，显式要求返回摘要，才能在对话里展示思维链
                    if !extra.contains(where: { $0.hasPrefix("--thinking-display") }) {
                        args += ["--thinking-display", "summarized"]
                    }
                    if !profile.effort.isEmpty, !extra.contains("--effort") {
                        args += ["--effort", profile.effort]
                    }
                    args += extra

                    var gotPartial = false
                    var gotPartialThinking = false
                    var thinkingBlocks = 0
                    var emitted = false
                    var stderr = ""
                    continuation.yield(.status("正在启动 Claude…"))

                    for try await line in CLIRunner.stream(profile.cliExecutable, args, stdin: prompt, cwd: workdir) {
                        switch line {
                        case .stderr(let s):
                            stderr += s + "\n"
                        case .exit(let code):
                            if code == 127 { throw LLMError.notInstalled(profile.cliExecutable) }
                            if code != 0 && !emitted {
                                let msg = stderr.trimmed.isEmpty ? "claude 退出码 \(code)" : stderr.trimmed
                                throw Self.classify(msg)
                            }
                        case .stdout(let s):
                            guard let obj = JSONHelpers.object(s) else { continue }
                            switch obj["type"] as? String {
                            case "system":
                                if obj["subtype"] as? String == "init" {
                                    let model = obj["model"] as? String ?? ""
                                    continuation.yield(.status(model.isEmpty ? "Claude 已连接" : "Claude 已连接 · \(model)"))
                                }
                            case "stream_event":
                                guard let event = obj["event"] as? [String: Any] else { break }
                                if event["type"] as? String == "content_block_start",
                                   (event["content_block"] as? [String: Any])?["type"] as? String == "thinking" {
                                    // 多段思考之间空一行
                                    if thinkingBlocks > 0 { continuation.yield(.thinking("\n\n")) }
                                    thinkingBlocks += 1
                                }
                                if event["type"] as? String == "content_block_delta",
                                   let delta = event["delta"] as? [String: Any] {
                                    if delta["type"] as? String == "text_delta", let t = delta["text"] as? String {
                                        gotPartial = true
                                        emitted = true
                                        continuation.yield(.text(t))
                                    } else if delta["type"] as? String == "thinking_delta" {
                                        if let t = delta["thinking"] as? String, !t.isEmpty {
                                            gotPartialThinking = true
                                            continuation.yield(.thinking(t))
                                        } else {
                                            continuation.yield(.status("思考中…"))
                                        }
                                    }
                                }
                            case "assistant":
                                guard let message = obj["message"] as? [String: Any],
                                      let content = message["content"] as? [[String: Any]] else { break }
                                for block in content {
                                    switch block["type"] as? String {
                                    case "thinking":
                                        if !gotPartialThinking, let t = block["thinking"] as? String, !t.trimmed.isEmpty {
                                            continuation.yield(.thinking(t + "\n\n"))
                                        }
                                    case "text":
                                        // 老版本 CLI 没有 partial 事件时，直接使用整段消息
                                        if !gotPartial, let t = block["text"] as? String {
                                            emitted = true
                                            continuation.yield(.text(t))
                                        }
                                    case "tool_use":
                                        let name = block["name"] as? String ?? "工具"
                                        continuation.yield(.status("Claude 正在使用 \(name)…"))
                                        if gotPartial { continuation.yield(.text("\n\n")) }
                                    default: break
                                    }
                                }
                            case "result":
                                let isError = obj["is_error"] as? Bool ?? false
                                if isError || (obj["subtype"] as? String).map({ $0 != "success" }) == true {
                                    let msg = obj["result"] as? String ?? (obj["subtype"] as? String ?? "未知错误")
                                    throw Self.classify(msg)
                                }
                                if !emitted, let t = obj["result"] as? String, !t.isEmpty {
                                    emitted = true
                                    continuation.yield(.text(t))
                                }
                                if let usage = obj["usage"] as? [String: Any] {
                                    continuation.yield(.usage(input: usage["input_tokens"] as? Int ?? 0,
                                                              output: usage["output_tokens"] as? Int ?? 0))
                                }
                            default:
                                break
                            }
                        }
                    }
                    try? FileManager.default.removeItem(at: workdir)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func classify(_ message: String) -> LLMError {
        let lower = message.lowercased()
        if lower.contains("/login") || lower.contains("not logged in") || lower.contains("invalid api key")
            || lower.contains("authentication") || lower.contains("oauth") {
            return .notLoggedIn("Claude")
        }
        if lower.contains("command not found") { return .notInstalled("claude") }
        return .cli(message)
    }
}
