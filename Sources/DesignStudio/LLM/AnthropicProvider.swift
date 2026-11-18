import Foundation

/// Anthropic Messages API（含各家兼容端点），SSE 流式
nonisolated struct AnthropicProvider: LLMProvider {
    let profile: ProviderProfile
    let apiKey: String

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        let profile = profile
        let apiKey = apiKey
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = try Endpoint.anthropicMessages(profile.baseURL)
                    var req = URLRequest(url: url, timeoutInterval: 600)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "content-type")
                    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    if profile.useBearerAuth {
                        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
                    } else {
                        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    }
                    for (k, v) in profile.parsedHeaders { req.setValue(v, forHTTPHeaderField: k) }

                    var body: [String: Any] = [
                        "model": profile.model.trimmed,
                        // Messages 接口必须传 max_tokens：优先用模型上限，未知时用兜底值
                        "max_tokens": request.maxTokens ?? Self.fallbackMaxTokens,
                        "system": request.system,
                        "stream": true,
                        "messages": request.messages.map(Self.encode)
                    ]
                    // 官方端点上的新一代 Claude 默认不返回思考内容，显式要求摘要以便展示思维链。
                    // 兼容端点（智谱、Kimi 等）的 thinking 参数各不相同，不主动传。
                    if Self.supportsThinkingSummary(model: profile.model.trimmed, url: url) {
                        body["thinking"] = ["type": "adaptive", "display": "summarized"]
                    }
                    if !profile.effort.isEmpty { body["output_config"] = ["effort": profile.effort] }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    try await HTTPCheck.ensureOK(response, bytes: bytes)

                    continuation.yield(.status("已连接，等待模型响应…"))
                    var inputTokens = 0
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let obj = JSONHelpers.object(payload) else { continue }
                        switch obj["type"] as? String {
                        case "message_start":
                            if let msg = obj["message"] as? [String: Any],
                               let usage = msg["usage"] as? [String: Any] {
                                inputTokens = usage["input_tokens"] as? Int ?? 0
                            }
                        case "content_block_delta":
                            guard let delta = obj["delta"] as? [String: Any] else { break }
                            switch delta["type"] as? String {
                            case "text_delta":
                                if let t = delta["text"] as? String { continuation.yield(.text(t)) }
                            case "thinking_delta":
                                if let t = delta["thinking"] as? String, !t.isEmpty {
                                    continuation.yield(.thinking(t))
                                } else {
                                    continuation.yield(.status("思考中…"))
                                }
                            default: break
                            }
                        case "message_delta":
                            if let usage = obj["usage"] as? [String: Any], let out = usage["output_tokens"] as? Int {
                                continuation.yield(.usage(input: inputTokens, output: out))
                            }
                        case "error":
                            let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? payload
                            throw LLMError.http(0, msg)
                        default:
                            break
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

    /// 模型输出上限未知时使用（兼容端点的模型列表通常不带上限）
    static let fallbackMaxTokens = 32000

    /// 只对 Anthropic 官方端点上支持自适应思考的模型开启：按模型 ID 里的版本号判断（4.6 及以后），
    /// 不列具体模型，新模型发布后不用改代码。旧格式（claude-3-5-sonnet）和 4.5 及以前不开启
    static func supportsThinkingSummary(model: String, url: URL) -> Bool {
        guard url.host == "api.anthropic.com" else { return false }
        return claudeVersion(model).map { $0.major >= 5 || ($0.major == 4 && $0.minor >= 6) } ?? false
    }

    /// claude-<系列>-<主版本>[-<次版本>][-<日期>] → (主版本, 次版本)；日期（8 位数字）不算次版本
    static func claudeVersion(_ model: String) -> (major: Int, minor: Int)? {
        guard let m = model.lowercased().firstMatch(of: /^claude-[a-z]+-(\d{1,2})(?:-(\d{1,2}))?(?:-|$|\[)/),
              let major = Int(m.1) else { return nil }
        return (major, m.2.flatMap { Int($0) } ?? 0)
    }

    static func encode(_ m: LLMMessage) -> [String: Any] {
        var content: [[String: Any]] = m.images.map { img in
            [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": img.mimeType,
                    "data": img.data.base64EncodedString()
                ]
            ]
        }
        content.append(["type": "text", "text": m.text.isEmpty ? "(empty)" : m.text])
        return ["role": m.role.rawValue, "content": content]
    }
}
