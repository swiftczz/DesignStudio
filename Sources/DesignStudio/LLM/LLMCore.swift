import Foundation

// MARK: - 请求与事件

nonisolated struct LLMMessage: Sendable {
    var role: ChatRole
    var text: String
    var images: [ChatAttachment] = []
}

nonisolated struct LLMRequest: Sendable {
    var system: String
    var messages: [LLMMessage]
    /// 最大输出 tokens；nil 表示不传，由服务商按模型上限处理（Anthropic Messages 必填，届时用兜底值）
    var maxTokens: Int?
    /// 元素级修改：模型返回元素修改代码块（CLI 提供方据此调整末尾提醒）
    var elementEdit = false
    var files: [ChatAttachment] = []
    var titleOnly = false

    var replyFormatReminder: String {
        if titleOnly { return "Output only the short project title on one line." }
        if elementEdit {
            return "Output one block: ```html element patch for text/style JSON, or ```html element for replacement HTML."
        }
        return "Output one ```html artboard=\"<name>\" width=<px> height=<px> block per artboard."
    }

    var latestImages: [ChatAttachment] { messages.last?.images ?? [] }

    /// CLI 类提供方（claude -p / codex exec）只接受单条提示词，把多轮对话压平
    func flattenedPrompt(includeSystem: Bool) -> String {
        var out = ""
        if includeSystem {
            out += "<instructions>\n\(system)\n</instructions>\n\n"
        }
        let history = messages.dropLast()
        if !history.isEmpty {
            out += "<conversation_history>\n"
            for m in history {
                out += "[\(m.role == .user ? "User" : "Assistant")]\n\(m.text)\n\n"
            }
            out += "</conversation_history>\n\n"
        }
        out += messages.last?.text ?? ""
        return out
    }
}

nonisolated enum LLMEvent: Sendable {
    case text(String)
    /// 模型的思考过程（思维链摘要），增量追加
    case thinking(String)
    case status(String)
    case usage(input: Int, output: Int)
}

nonisolated protocol LLMProvider: Sendable {
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error>
}

// MARK: - 错误

nonisolated enum LLMError: LocalizedError {
    case missingAPIKey
    case missingModel
    case invalidBaseURL(String)
    case http(Int, String)
    case cli(String)
    case notInstalled(String)
    case notLoggedIn(String)
    case invalidResponse(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "尚未填写 API Key，请在 设置 → 模型与账号 中配置。"
        case .missingModel: "尚未选择模型，请在 设置 → 模型与账号 中拉取模型列表并选择。"
        case .invalidBaseURL(let s): "Base URL 无效：\(s)"
        case .http(let code, let msg): code > 0 ? "接口返回 \(code)：\(msg)" : "接口错误：\(msg)"
        case .cli(let msg): "命令行工具出错：\(msg)"
        case .notInstalled(let name): "没有找到 `\(name)` 命令行工具，请先安装，或在设置里指定可执行文件路径。"
        case .notLoggedIn(let name): "\(name) 尚未登录，请在 设置 → 模型与账号 中登录。"
        case .invalidResponse(let message): message
        case .emptyResponse: "模型没有返回内容。"
        }
    }

    /// 从错误响应体中提取可读信息
    static func extractMessage(_ body: String) -> String {
        if let obj = JSONHelpers.object(body) {
            if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String { return msg }
            if let msg = obj["error"] as? String { return msg }
            if let msg = obj["message"] as? String { return msg }
        }
        let t = body.trimmed
        return t.count > 500 ? String(t.prefix(500)) + "…" : t
    }
}

// MARK: - 工具

nonisolated enum JSONHelpers {
    static func object(_ text: some StringProtocol) -> [String: Any]? {
        guard let data = String(text).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    /// 生成 JS 字符串字面量
    static func jsString(_ s: String) -> String {
        if let data = try? JSONEncoder().encode(s), let str = String(data: data, encoding: .utf8) { return str }
        return "\"\""
    }
}

nonisolated enum Endpoint {
    static func anthropicMessages(_ base: String) throws -> URL {
        var b = base.trimmed
        if b.isEmpty { b = "https://api.anthropic.com" }
        while b.hasSuffix("/") { b.removeLast() }
        let full: String
        if b.hasSuffix("/v1/messages") { full = b }
        else if b.hasSuffix("/v1") { full = b + "/messages" }
        else { full = b + "/v1/messages" }
        guard let url = URL(string: full), url.scheme?.hasPrefix("http") == true, url.host != nil else {
            throw LLMError.invalidBaseURL(base)
        }
        return url
    }

    static func chatCompletions(_ base: String) throws -> URL {
        try openAI(base, path: "/chat/completions")
    }

    static func responses(_ base: String) throws -> URL {
        try openAI(base, path: "/responses")
    }

    /// OpenAI 风格的模型列表：{Base URL}/models
    static func openAIModels(_ base: String) throws -> URL {
        try openAI(base, path: "/models")
    }

    /// Anthropic 模型列表：与 Messages 同一前缀下的 /v1/models
    static func anthropicModels(_ base: String) throws -> URL {
        let messages = try anthropicMessages(base).absoluteString
        guard let url = URL(string: String(messages.dropLast("/messages".count)) + "/models") else {
            throw LLMError.invalidBaseURL(base)
        }
        return url
    }

    private static func openAI(_ base: String, path: String) throws -> URL {
        var b = base.trimmed
        while b.hasSuffix("/") { b.removeLast() }
        // 允许用户直接填完整接口地址
        for suffix in ["/chat/completions", "/responses", "/models"] where b.hasSuffix(suffix) {
            b.removeLast(suffix.count)
        }
        guard let url = URL(string: b + path), url.scheme?.hasPrefix("http") == true, url.host != nil else {
            throw LLMError.invalidBaseURL(base)
        }
        return url
    }
}

nonisolated enum HTTPCheck {
    static func ensureOK(_ response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse else { throw LLMError.http(-1, "无效响应") }
        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines {
                body += line + "\n"
                if body.count > 4000 { break }
            }
            throw LLMError.http(http.statusCode, LLMError.extractMessage(body))
        }
    }
}

// MARK: - 工厂

enum ProviderFactory {
    @MainActor
    static func make(_ profile: ProviderProfile) throws -> any LLMProvider {
        switch profile.kind {
        case .claudeCode:
            return ClaudeCodeProvider(profile: profile)
        case .codex:
            return CodexProvider(profile: profile)
        case .antigravity:
            return AntigravityProvider(profile: profile)
        case .anthropicAPI:
            guard let key = SecretStore.get(profile.secretAccount) else { throw LLMError.missingAPIKey }
            guard !profile.model.trimmed.isEmpty else { throw LLMError.missingModel }
            return AnthropicProvider(profile: profile, apiKey: key)
        case .openAICompatible:
            // 本地 Ollama 等可以不需要 Key
            guard !profile.model.trimmed.isEmpty else { throw LLMError.missingModel }
            return OpenAICompatibleProvider(profile: profile, apiKey: SecretStore.get(profile.secretAccount) ?? "")
        case .openAIResponses:
            guard !profile.model.trimmed.isEmpty else { throw LLMError.missingModel }
            return OpenAIResponsesProvider(profile: profile, apiKey: SecretStore.get(profile.secretAccount) ?? "")
        }
    }

    /// 发送一个极小的请求用于测试连接
    @MainActor
    static func test(_ profile: ProviderProfile) async -> Result<String, Error> {
        do {
            let provider = try make(profile)
            let request = LLMRequest(
                system: "You are a connectivity test. Follow the instruction exactly.",
                messages: [LLMMessage(role: .user, text: "Reply with exactly: OK")],
                // 推理模型会先消耗思考 tokens，给足余量
                maxTokens: 2048
            )
            var text = ""
            for try await event in provider.stream(request) {
                if case .text(let t) = event { text += t }
            }
            let trimmed = text.trimmed
            if trimmed.isEmpty { throw LLMError.emptyResponse }
            return .success(trimmed.count > 120 ? String(trimmed.prefix(120)) + "…" : trimmed)
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - <think> 标签拆分

/// 把正文开头的 `<think>…</think>` 拆成思考内容（Ollama 旧版、vLLM、SGLang 等常见做法）。
/// 只在输出开头（允许前导空白）出现 `<think>` 时生效，标签被拆在多个流式片段里也能识别。
nonisolated struct ThinkTagSplitter: Sendable {
    struct Part: Equatable, Sendable {
        var isThinking: Bool
        var text: String
    }

    private enum State { case start, thinking, body }
    private var state: State = .start
    private var buffer = ""

    private static let open = "<think>"
    private static let close = "</think>"

    mutating func feed(_ chunk: String) -> [Part] {
        buffer += chunk
        var out: [Part] = []
        while true {
            switch state {
            case .start:
                let trimmed = buffer.drop(while: \.isWhitespace)
                if trimmed.hasPrefix(Self.open) {
                    buffer = String(trimmed.dropFirst(Self.open.count))
                    state = .thinking
                } else if Self.open.hasPrefix(String(trimmed)) {
                    return out          // 可能是被拆开的 <think，等下一段
                } else {
                    state = .body
                }
            case .thinking:
                if let r = buffer.range(of: Self.close) {
                    let thought = String(buffer[..<r.lowerBound])
                    if !thought.isEmpty { out.append(Part(isThinking: true, text: thought)) }
                    buffer = String(buffer[r.upperBound...]).replacingOccurrences(of: #"^\s+"#, with: "", options: .regularExpression)
                    state = .body
                } else {
                    // 末尾可能是被拆开的 </think，先保留
                    let keep = Self.partialSuffix(of: buffer, matching: Self.close)
                    let emit = String(buffer.dropLast(keep))
                    if !emit.isEmpty { out.append(Part(isThinking: true, text: emit)) }
                    buffer = String(buffer.suffix(keep))
                    return out
                }
            case .body:
                if !buffer.isEmpty { out.append(Part(isThinking: false, text: buffer)) }
                buffer = ""
                return out
            }
        }
    }

    /// 流结束时把剩余内容吐出来
    mutating func finish() -> [Part] {
        defer { buffer = "" }
        guard !buffer.isEmpty else { return [] }
        return [Part(isThinking: state == .thinking, text: buffer)]
    }

    /// buffer 末尾与 marker 开头重合的最长长度
    private static func partialSuffix(of buffer: String, matching marker: String) -> Int {
        for n in stride(from: min(marker.count - 1, buffer.count), through: 1, by: -1)
            where marker.hasPrefix(String(buffer.suffix(n))) {
            return n
        }
        return 0
    }
}
