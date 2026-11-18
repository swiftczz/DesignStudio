import Foundation

/// OpenAI Chat Completions 兼容接口，SSE 流式
nonisolated struct OpenAICompatibleProvider: LLMProvider {
    let profile: ProviderProfile
    let apiKey: String

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        let profile = profile
        let apiKey = apiKey
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = try Endpoint.chatCompletions(profile.baseURL)
                    var req = URLRequest(url: url, timeoutInterval: 600)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "content-type")
                    if !apiKey.isEmpty {
                        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
                    }
                    // OpenRouter 推荐的来源标识
                    req.setValue("DesignStudio", forHTTPHeaderField: "X-Title")
                    for (k, v) in profile.parsedHeaders { req.setValue(v, forHTTPHeaderField: k) }

                    var messages: [[String: Any]] = [["role": "system", "content": request.system]]
                    messages += request.messages.map(Self.encode)
                    var body: [String: Any] = [
                        "model": profile.model.trimmed,
                        "stream": true,
                        "messages": messages
                    ]
                    // 上限未知时不传，由服务商按模型最大值处理；OpenAI 官方的新模型只接受 max_completion_tokens
                    if let max = request.maxTokens, max > 0 {
                        body[url.host == "api.openai.com" ? "max_completion_tokens" : "max_tokens"] = max
                    }
                    // 只在用户选了思考强度时传（来自服务商 /models 声明支持的强度）
                    if !profile.effort.isEmpty { body["reasoning_effort"] = profile.effort }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    try await HTTPCheck.ensureOK(response, bytes: bytes)

                    continuation.yield(.status("已连接，等待模型响应…"))
                    var splitter = ThinkTagSplitter()
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let obj = JSONHelpers.object(payload) else { continue }
                        if let err = obj["error"] as? [String: Any] {
                            throw LLMError.http(0, err["message"] as? String ?? payload)
                        }
                        if let choices = obj["choices"] as? [[String: Any]],
                           let delta = choices.first?["delta"] as? [String: Any] {
                            // 思考内容的字段名各家不同：DeepSeek / Kimi / 通义 / 硅基流动用 reasoning_content，
                            // OpenRouter / Groq / 新版 Ollama 用 reasoning，也有实现用 thinking
                            let reasoning = (delta["reasoning_content"] as? String)
                                ?? (delta["reasoning"] as? String)
                                ?? (delta["thinking"] as? String)
                            if let r = reasoning, !r.isEmpty {
                                continuation.yield(.thinking(r))
                            }
                            // Ollama 旧版、vLLM 等把思考用 <think>…</think> 写在正文开头，拆出来
                            if let t = delta["content"] as? String, !t.isEmpty {
                                for part in splitter.feed(t) {
                                    continuation.yield(part.isThinking ? .thinking(part.text) : .text(part.text))
                                }
                            }
                        }
                        if let usage = obj["usage"] as? [String: Any] {
                            continuation.yield(.usage(input: usage["prompt_tokens"] as? Int ?? 0,
                                                      output: usage["completion_tokens"] as? Int ?? 0))
                        }
                    }
                    for part in splitter.finish() {
                        continuation.yield(part.isThinking ? .thinking(part.text) : .text(part.text))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func encode(_ m: LLMMessage) -> [String: Any] {
        if m.images.isEmpty {
            return ["role": m.role.rawValue, "content": m.text]
        }
        var parts: [[String: Any]] = [["type": "text", "text": m.text]]
        for img in m.images {
            parts.append([
                "type": "image_url",
                "image_url": ["url": "data:\(img.mimeType);base64,\(img.data.base64EncodedString())"]
            ])
        }
        return ["role": m.role.rawValue, "content": parts]
    }
}
