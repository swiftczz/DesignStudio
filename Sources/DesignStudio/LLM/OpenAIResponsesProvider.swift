import Foundation

/// OpenAI Responses 接口（POST {Base URL}/responses），SSE 流式
nonisolated struct OpenAIResponsesProvider: LLMProvider {
    let profile: ProviderProfile
    let apiKey: String

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        let profile = profile
        let apiKey = apiKey
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if profile.kind == .chatGPT {
                        try await Self.runChatGPT(profile: profile, request: request, continuation: continuation)
                    } else {
                        let url = try Endpoint.responses(profile.baseURL)
                        // 先要求返回推理摘要；非推理模型不支持 reasoning 参数时去掉重试一次
                        do {
                            try await Self.run(url: url, profile: profile, apiKey: apiKey, request: request,
                                               withReasoning: true, continuation: continuation)
                        } catch LLMError.http(let code, let message)
                                    where code == 400 && message.lowercased().contains("reasoning") {
                            try await Self.run(url: url, profile: profile, apiKey: apiKey, request: request,
                                               withReasoning: false, continuation: continuation)
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

    private static func runChatGPT(profile: ProviderProfile, request: LLMRequest,
                                   continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation) async throws {
        let auth = await ChatGPTAuthService.shared
        let authorization = try await auth.inferenceAuthorization()
        guard !profile.model.trimmed.isEmpty else { throw LLMError.missingModel }
        let url = ChatGPTAPI.resource.appending(path: "responses")
        do {
            try await run(url: url, profile: profile, apiKey: authorization.token, request: request,
                          withReasoning: false, continuation: continuation)
        } catch let failure as ChatGPTAPI.Failure where failure.status == 401 {
            let replacement = try await auth.inferenceAuthorization(replacing: authorization)
            try await run(url: url, profile: profile, apiKey: replacement.token, request: request,
                          withReasoning: false, continuation: continuation)
        }
    }

    private static func run(url: URL, profile: ProviderProfile, apiKey: String, request: LLMRequest,
                            withReasoning: Bool,
                            continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation) async throws {
        var req = URLRequest(url: url, timeoutInterval: 600)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization") }
        let direct = profile.kind == .chatGPT
        if !direct {
            for (k, v) in profile.parsedHeaders { req.setValue(v, forHTTPHeaderField: k) }
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: requestBody(profile: profile, request: request,
                                                                              withReasoning: withReasoning))

        let session = direct ? ChatGPTAPI.session : URLSession.shared
        let (bytes, response) = try await session.bytes(for: req)
        if direct, let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var body = ""
            for try await line in bytes.lines {
                body += line + "\n"
                if body.count > 4000 { break }
            }
            throw ChatGPTAPI.failure(response: http, body: body)
        }
        try await HTTPCheck.ensureOK(response, bytes: bytes)

        try await readEvents(bytes.lines, response: response, direct: direct, continuation: continuation)
    }

    static func readEvents<Lines: AsyncSequence>(_ lines: Lines, response: URLResponse, direct: Bool,
                                                continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation) async throws
    where Lines.Element == String {
        continuation.yield(.status("已连接，等待模型响应…"))
        var summaryParts = 0
        var reasoningItems = 0
        for try await line in lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let obj = JSONHelpers.object(payload) else { continue }
            switch obj["type"] as? String {
            case "response.output_text.delta":
                if let d = obj["delta"] as? String { continuation.yield(.text(d)) }
            case "response.created", "response.in_progress":
                continuation.yield(.status("模型已开始处理…"))
            case "response.output_item.added":
                // 新的思考段落（DeepSeek 等直接输出原始思考文字）之间空一行
                if (obj["item"] as? [String: Any])?["type"] as? String == "reasoning" {
                    if reasoningItems > 0 { continuation.yield(.thinking("\n\n")) }
                    reasoningItems += 1
                    continuation.yield(.status("思考中…"))
                }
            case "response.reasoning_summary_part.added":
                if summaryParts > 0 { continuation.yield(.thinking("\n\n")) }
                summaryParts += 1
            case let type? where type.contains("reasoning") && type.hasSuffix(".delta"):
                // 各家思考事件名不统一：OpenAI 官方为 reasoning_summary_text（摘要），
                // DeepSeek 为 reasoning_text（原始思考），也有实现用 reasoning.delta —— 统一当作思考内容
                if let d = obj["delta"] as? String { continuation.yield(.thinking(d)) }
            case "response.completed", "response.incomplete":
                if let resp = obj["response"] as? [String: Any],
                   let usage = resp["usage"] as? [String: Any] {
                    continuation.yield(.usage(input: usage["input_tokens"] as? Int ?? 0,
                                              output: usage["output_tokens"] as? Int ?? 0))
                }
                if direct {
                    if obj["type"] as? String == "response.completed" { return }
                    let response = obj["response"] as? [String: Any]
                    let details = response?["incomplete_details"] as? [String: Any]
                    let reason = details?["reason"] as? String
                    throw LLMError.invalidResponse(reason.map { "ChatGPT 未完成生成（\($0)）。" } ?? "ChatGPT 未完成生成。")
                }
            case "response.failed":
                let err = (obj["response"] as? [String: Any])?["error"] as? [String: Any]
                if direct { throw streamFailure(err, response: response) }
                throw LLMError.http(0, err?["message"] as? String ?? "生成失败")
            case "error":
                if direct { throw streamFailure(obj["error"] as? [String: Any] ?? obj, response: response) }
                let msg = obj["message"] as? String
                    ?? (obj["error"] as? [String: Any])?["message"] as? String
                    ?? payload
                throw LLMError.http(0, msg)
            default:
                break
            }
        }
        if direct {
            try Task.checkCancellation()
            throw LLMError.invalidResponse("ChatGPT 响应中断，未收到生成完成事件。")
        }
    }

    private static func streamFailure(_ error: [String: Any]?, response: URLResponse) -> ChatGPTAPI.Failure {
        ChatGPTAPI.Failure(status: 0, code: error?["code"] as? String,
                           message: error?["message"] as? String ?? "ChatGPT 生成失败",
                           requestID: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "x-request-id"))
    }

    static func requestBody(profile: ProviderProfile, request: LLMRequest, withReasoning: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "model": profile.model.trimmed,
            "instructions": request.system,
            "input": request.messages.map(encode),
            "stream": true,
            "store": false
        ]
        if profile.kind != .chatGPT, let max = request.maxTokens, max > 0 { body["max_output_tokens"] = max }
        var reasoning: [String: Any] = withReasoning ? ["summary": "auto"] : [:]
        if !profile.effort.isEmpty { reasoning["effort"] = profile.effort }
        if !reasoning.isEmpty { body["reasoning"] = reasoning }
        return body
    }

    static func encode(_ m: LLMMessage) -> [String: Any] {
        if m.role == .assistant {
            return ["role": "assistant", "content": [["type": "output_text", "text": m.text]]]
        }
        var parts: [[String: Any]] = [["type": "input_text", "text": m.text.isEmpty ? "(empty)" : m.text]]
        for img in m.images {
            parts.append(["type": "input_image",
                          "image_url": "data:\(img.mimeType);base64,\(img.data.base64EncodedString())"])
        }
        return ["role": "user", "content": parts]
    }
}
