import Foundation

/// 从服务商的 /models 接口拉取可用模型及其上下文上限
nonisolated enum ModelFetcher {
    static func fetch(_ profile: ProviderProfile, apiKey: String) async throws -> [RemoteModel] {
        switch profile.kind {
        case .anthropicAPI:
            return try await fetchAnthropic(profile, apiKey: apiKey)
        case .openAICompatible, .openAIResponses:
            return try await fetchOpenAI(profile, apiKey: apiKey)
        case .chatGPT:
            return try await ChatGPTAuthService.shared.models()
        case .claudeCode, .codex, .antigravity:
            return []
        }
    }

    // MARK: - Anthropic：GET /v1/models（分页，带 max_input_tokens / max_tokens）

    private static func fetchAnthropic(_ profile: ProviderProfile, apiKey: String) async throws -> [RemoteModel] {
        let base = try Endpoint.anthropicModels(profile.baseURL)
        var all: [RemoteModel] = []
        var afterID: String?
        for _ in 0..<20 {
            var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
            comps.queryItems = [URLQueryItem(name: "limit", value: "1000")]
                + (afterID.map { [URLQueryItem(name: "after_id", value: $0)] } ?? [])
            var req = URLRequest(url: comps.url!, timeoutInterval: 30)
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            if profile.useBearerAuth {
                req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
            } else {
                req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            }
            for (k, v) in profile.parsedHeaders { req.setValue(v, forHTTPHeaderField: k) }
            let obj = try await getJSON(req)
            let page = parseAnthropic(obj)
            all += page
            guard obj["has_more"] as? Bool == true, let last = obj["last_id"] as? String ?? page.last?.id else { break }
            afterID = last
        }
        return all
    }

    static func parseAnthropic(_ obj: [String: Any]) -> [RemoteModel] {
        let data = obj["data"] as? [[String: Any]] ?? []
        return data.compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            return RemoteModel(
                id: id,
                displayName: m["display_name"] as? String,
                limits: ModelLimits(contextWindow: int(m["max_input_tokens"]) ?? int(m["context_window"]),
                                    maxOutput: int(m["max_tokens"]) ?? int(m["max_output_tokens"]))
            )
        }
    }

    // MARK: - OpenAI 风格：GET {Base URL}/models

    private static func fetchOpenAI(_ profile: ProviderProfile, apiKey: String) async throws -> [RemoteModel] {
        var req = URLRequest(url: try Endpoint.openAIModels(profile.baseURL), timeoutInterval: 30)
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization") }
        for (k, v) in profile.parsedHeaders { req.setValue(v, forHTTPHeaderField: k) }
        let obj = try await getJSON(req)
        return parseOpenAI(obj)
    }

    /// OpenAI 官方只返回 id；OpenRouter、Kimi、硅基流动等会额外带上下文 / 输出上限，字段名各不相同
    static func parseOpenAI(_ obj: [String: Any]) -> [RemoteModel] {
        let data = obj["data"] as? [[String: Any]] ?? obj["models"] as? [[String: Any]] ?? []
        let models: [RemoteModel] = data.compactMap { m in
            guard let id = (m["id"] as? String) ?? (m["name"] as? String), !id.isEmpty else { return nil }
            guard !isNonChatModel(id) else { return nil }
            let top = m["top_provider"] as? [String: Any]
            let context = int(m["context_length"]) ?? int(m["context_window"]) ?? int(m["max_context_length"])
                ?? int(m["max_input_tokens"]) ?? int(top?["context_length"])
            let output = int(top?["max_completion_tokens"]) ?? int(m["max_output_tokens"])
                ?? int(m["max_completion_tokens"]) ?? int(m["max_tokens"])
            let name = (m["display_name"] as? String) ?? (m["name"] as? String).flatMap { $0 == id ? nil : $0 }
            let effort = efforts(m)
            return RemoteModel(id: id, displayName: name,
                               limits: ModelLimits(contextWindow: context, maxOutput: output),
                               created: int(m["created"]), efforts: effort.levels, defaultEffort: effort.default)
        }
        // 有创建时间就按新到旧排，便于找到最新模型
        if models.contains(where: { $0.created != nil }) {
            return models.sorted { ($0.created ?? 0) > ($1.created ?? 0) }
        }
        return models
    }

    /// 模型支持的思考强度：DeepSeek 的 `effort: {supported_levels, default_level}`，
    /// 或 OpenAI 风格的 `supported_reasoning_levels` / `default_reasoning_level`
    static func efforts(_ m: [String: Any]) -> (levels: [String]?, default: String?) {
        if let e = m["effort"] as? [String: Any] {
            let levels = (e["supported_levels"] as? [String]) ?? (e["levels"] as? [String])
            return (levels.flatMap { $0.isEmpty ? nil : $0 }, (e["default_level"] as? String) ?? (e["default"] as? String))
        }
        if let raw = m["supported_reasoning_levels"] as? [Any] {
            let levels = raw.compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["effort"] as? String) }
            return (levels.isEmpty ? nil : levels, m["default_reasoning_level"] as? String)
        }
        return (nil, nil)
    }

    /// 过滤掉明显不能用于对话生成的模型（向量、语音、图像、审核等）
    static func isNonChatModel(_ id: String) -> Bool {
        let lower = id.lowercased()
        let markers = ["embedding", "embed-", "tts", "whisper", "transcribe", "dall-e", "gpt-image",
                       "moderation", "rerank", "davinci", "babbage", "text-similarity", "sora"]
        return markers.contains { lower.contains($0) }
    }

    // MARK: - 工具

    private static func getJSON(_ req: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw LLMError.http(-1, "无效响应") }
        let body = String(decoding: data, as: UTF8.self)
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.http(http.statusCode, LLMError.extractMessage(body))
        }
        guard let obj = JSONHelpers.object(body) else { throw LLMError.http(http.statusCode, "模型列表格式无法识别") }
        return obj
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let i as Int: return i > 0 ? i : nil
        case let d as Double: return d > 0 ? Int(d) : nil
        case let s as String: return Int(s).flatMap { $0 > 0 ? $0 : nil }
        default: return nil
        }
    }
}
