import Foundation

/// 通过 Google Antigravity CLI 调用：
/// `agy --input-format stream-json --output-format stream-json -p=`，提示词以 NDJSON 从 stdin 传入
/// （`{"event":"user","message":{"content":"…"}}`；大段画板源码不适合放在命令行参数里）。
/// 登录由 `agy` 首次运行时的 Google 账号登录完成，使用 Google AI 订阅（Antigravity）的额度。
nonisolated struct AntigravityProvider: LLMProvider {
    let profile: ProviderProfile

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        let profile = profile
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let workdir = try TempWorkspace.make(prefix: "antigravity")
                    defer { try? FileManager.default.removeItem(at: workdir) }
                    let images = try TempWorkspace.writeImages(request.latestImages, to: workdir)

                    // agy 没有替换系统提示词的参数，设计规范放在提示词开头
                    var prompt = request.flattenedPrompt(includeSystem: true)
                    prompt += try TempWorkspace.prepareReferenceFiles(request.files, in: workdir)
                    if !images.isEmpty {
                        let names = images.map { "./" + $0.lastPathComponent }.joined(separator: "、")
                        prompt += "\n\n用户附带了参考图片，已保存在当前目录：\(names)。请先用 view_file 查看这些图片再开始设计。"
                    }
                    // 与 Codex 一样：只要文字回复，不要动文件或执行命令（输出格式必须与 instructions 里的约定一致）
                    prompt += "\n\nIMPORTANT: Do not run commands and do not create or edit files. "
                        + "Reply directly in this message, following the output contract in <instructions>: "
                    prompt += request.replyFormatReminder

                    var args = ["--input-format", "stream-json", "--output-format", "stream-json"]
                    if !profile.model.trimmed.isEmpty { args += ["--model", profile.model.trimmed] }
                    args += ArgumentSplitter.split(profile.extraArguments)
                    args.append("-p=")

                    var emitted = false
                    var lastTextStep: Int?
                    var lastThinkingStep: Int?
                    var stderr = ""
                    var failure: String?
                    continuation.yield(.status("正在启动 Antigravity…"))

                    for try await line in CLIRunner.stream(profile.cliExecutable, args,
                                                           stdin: Self.inputLine(prompt), cwd: workdir) {
                        switch line {
                        case .stderr(let s):
                            stderr += s + "\n"
                        case .exit(let code):
                            if code == 127 { throw LLMError.notInstalled(profile.cliExecutable) }
                            if code != 0 && !emitted {
                                let msg = failure ?? (stderr.trimmed.isEmpty ? "agy 退出码 \(code)" : stderr.trimmed)
                                throw Self.classify(msg)
                            }
                        case .stdout(let s):
                            guard let obj = JSONHelpers.object(s) else { continue }
                            switch obj["event"] as? String {
                            case "init":
                                let model = (obj["init"] as? [String: Any])?["model"] as? String ?? ""
                                if profile.model.trimmed.isEmpty, !model.isEmpty {
                                    ModelCatalog.recordReportedModel(model, kind: .antigravity)
                                }
                                continuation.yield(.status("Antigravity 已连接"))
                            case "step_update":
                                guard let step = obj["step_update"] as? [String: Any] else { break }
                                let index = step["step_index"] as? Int ?? 0
                                let type = step["step_type"] as? String ?? ""
                                if let t = step["thinking_delta"] as? String, !t.isEmpty {
                                    // 不同步骤的思考之间空一行
                                    if let last = lastThinkingStep, last != index { continuation.yield(.thinking("\n\n")) }
                                    lastThinkingStep = index
                                    continuation.yield(.thinking(t))
                                }
                                if type == "agent_response", let t = step["text_delta"] as? String, !t.isEmpty {
                                    if let last = lastTextStep, last != index { continuation.yield(.text("\n\n")) }
                                    lastTextStep = index
                                    emitted = true
                                    continuation.yield(.text(t))
                                } else if !type.isEmpty, type != "user_input", type != "agent_response",
                                          step["state"] as? String == "ACTIVE" {
                                    continuation.yield(.status("Antigravity 正在使用 \(type)…"))
                                }
                                if let err = step["error_message"] as? String, !err.trimmed.isEmpty { failure = err }
                            case "result":
                                guard let result = obj["result"] as? [String: Any] else { break }
                                if result["status"] as? String != "SUCCESS" {
                                    let msg = result["error"] as? String ?? failure ?? (result["status"] as? String ?? "未知错误")
                                    throw Self.classify(msg)
                                }
                                if !emitted, let t = result["response"] as? String, !t.isEmpty {
                                    emitted = true
                                    continuation.yield(.text(t))
                                }
                                if let usage = result["usage"] as? [String: Any] {
                                    continuation.yield(.usage(input: usage["input_tokens"] as? Int ?? 0,
                                                              output: usage["output_tokens"] as? Int ?? 0))
                                }
                            default:
                                break
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

    /// stdin 的一行 NDJSON 用户消息
    static func inputLine(_ prompt: String) -> String {
        let message: [String: Any] = ["event": "user", "message": ["content": prompt]]
        let data = (try? JSONSerialization.data(withJSONObject: message)) ?? Data()
        return (String(data: data, encoding: .utf8) ?? "") + "\n"
    }

    static func classify(_ message: String) -> LLMError {
        if let hint = CLIDiagnosis.brokenInstallMessage(message, kind: .antigravity, name: "Antigravity") { return .cli(hint) }
        let lower = message.lowercased()
        let signInRequired = ["not authenticated", "not logged in", "not signed in", "sign in",
                              "login required", "please login", "please log in", "authentication required", "unauthenticated"]
        if signInRequired.contains(where: lower.contains) {
            return .notLoggedIn("Antigravity")
        }
        if lower.contains("command not found") { return .notInstalled("agy") }
        return .cli(message)
    }
}
