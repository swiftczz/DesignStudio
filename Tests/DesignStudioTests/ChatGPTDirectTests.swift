import Foundation
import Security
import Testing
@testable import DesignStudio

@MainActor
struct ChatGPTDirectTests {
    @Test func loopbackIgnoresInvalidStateAndAcceptsBrowserCallback() async throws {
        let listener = try ChatGPTLoopback(state: "expected")
        defer { listener.close() }
        let redirect = try await listener.redirectURI()
        let invalid = try #require(URL(string: redirect + "?state=wrong&code=unsolicited"))
        let (_, rejected) = try await URLSession.shared.data(for: URLRequest(url: invalid, timeoutInterval: 5))
        #expect((rejected as? HTTPURLResponse)?.statusCode == 400)

        let valid = try #require(URL(string: redirect + "?state=expected&code=authorized&client_id=oaiapp_test"))
        let (body, response) = try await URLSession.shared.data(for: URLRequest(url: valid, timeoutInterval: 5))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(!String(decoding: body, as: UTF8.self).contains("code=authorized"))
        var callbacks = listener.callbacks.makeAsyncIterator()
        let received = try await callbacks.next()
        let callback = try #require(received)
        let result = try ChatGPTAuthService.authorizationCode(callback, existingClientID: nil)
        #expect(result.code == "authorized")
        #expect(result.clientID == "oaiapp_test")
    }

    @Test func returningAuthorizationCannotReplaceRegisteredClient() throws {
        let redirect = try #require(URL(string: "http://127.0.0.1/auth/callback?code=one&client_id=oaiapp_other"))
        #expect(throws: LLMError.self) {
            try ChatGPTAuthService.authorizationCode(redirect, existingClientID: "oaiapp_saved")
        }
        let returning = try #require(URL(string: "http://127.0.0.1/auth/callback?code=one"))
        #expect(try ChatGPTAuthService.authorizationCode(returning, existingClientID: "oaiapp_saved").clientID == "oaiapp_saved")
    }

    @Test func validatesSignedIDTokenAndRejectsCrossAccountClaims() throws {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        let privateKey = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        let der = try #require(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        // Security exports a PKCS#1 public key as SEQUENCE(INTEGER n, INTEGER e).
        var iterator = der.makeIterator()
        func nextByte() throws -> UInt8 {
            let value = iterator.next()
            return try #require(value)
        }
        func read(_ tag: UInt8) throws -> Data {
            let actualTag = try nextByte()
            #expect(actualTag == tag)
            let first = Int(try nextByte())
            var length = first
            if first >= 128 {
                length = 0
                for _ in 0..<(first & 0x7f) {
                    length = (length << 8) | Int(try nextByte())
                }
            }
            // The sequence header leaves its two child fields in the iterator.
            if tag == 0x30 { return Data() }
            return Data(try (0..<length).map { _ in try nextByte() })
        }
        _ = try read(0x30)
        let modulus = try read(0x02)
        let exponent = try read(0x02)
        let jwks = try JSONSerialization.data(withJSONObject: ["keys": [[
            "kty": "RSA", "kid": "test", "n": ChatGPTIdentity.base64URL(Data(modulus.drop(while: { $0 == 0 }))),
            "e": ChatGPTIdentity.base64URL(exponent)
        ]]])
        let header = ChatGPTIdentity.base64URL(Data(#"{"alg":"RS256","kid":"test"}"#.utf8))
        let payload = ChatGPTIdentity.base64URL(Data(#"{"iss":"https://auth.openai.com","aud":"oaiapp_test","exp":12345678,"nonce":"expected","sub":"account"}"#.utf8))
        let input = header + "." + payload
        let signature = try #require(SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256,
                                                            Data(input.utf8) as CFData, nil)) as Data
        let jwt = input + "." + ChatGPTIdentity.base64URL(signature)
        let now = Date(timeIntervalSince1970: 12345000)
        let claims = try ChatGPTIdentity.verify(jwt, clientID: "oaiapp_test", nonce: "expected", jwks: jwks, now: now)
        #expect(claims.sub == "account")
        #expect(throws: LLMError.self) {
            try ChatGPTIdentity.verify(jwt, clientID: "different-client", nonce: "expected", jwks: jwks, now: now)
        }
        #expect(throws: LLMError.self) {
            try ChatGPTIdentity.verify(jwt, clientID: "oaiapp_test", nonce: "replayed", jwks: jwks, now: now)
        }
        #expect(throws: LLMError.self) {
            try ChatGPTIdentity.verify(input + ".AAAA", clientID: "oaiapp_test", nonce: "expected", jwks: jwks, now: now)
        }
    }

    @Test func catalogAndRequestFollowChatGPTPlanContract() throws {
        let data = Data("""
            {"models":[
                {"slug":"gpt-6.2-sol","display_name":"GPT-6.2","visibility":"list",
                 "supported_reasoning_levels":[{"effort":"low"},{"effort":"high"},{"effort":"max"},{"effort":"ultra"}],
                 "default_reasoning_level":"low"},
                {"slug":"without-effort","visibility":"list"},
                {"slug":"hidden","visibility":"hidden"}
            ]}
            """.utf8)
        let models = try ChatGPTAPI.parseModels(data)
        #expect(models.map(\.id) == ["gpt-6.2-sol", "without-effort"])
        #expect(models.map(\.title) == ["GPT-6.2", "without-effort"])
        #expect(models.map(\.efforts) == [["low", "high", "max"], []])

        let request = LLMRequest(system: "Design", messages: [LLMMessage(role: .user, text: "Make a screen")], maxTokens: 2048)
        var direct = ProviderProfile(name: "ChatGPT", kind: .chatGPT, model: "gpt-6.2-sol")
        direct.availableModels = models
        let picker = try #require(ModelFamily.group(direct.modelOptions).first)
        #expect(picker.variants.map(\.title) == ["Low", "High", "Max"])
        #expect(picker.defaultEffort == "low")
        let body = OpenAIResponsesProvider.requestBody(profile: direct, request: request, withReasoning: false)
        #expect(body["model"] as? String == direct.model)
        #expect(body["stream"] as? Bool == true)
        #expect(body["store"] as? Bool == false)
        #expect(body["max_output_tokens"] == nil)
        #expect(body["service_tier"] == nil)
        #expect(body["reasoning"] == nil)

        let high = direct.resolved(model: nil, effort: "high")
        let highBody = OpenAIResponsesProvider.requestBody(profile: high, request: request, withReasoning: false)
        #expect((highBody["reasoning"] as? [String: String]) == ["effort": "high"])
        #expect(highBody["service_tier"] == nil)

        var apiKeyProfile = direct
        apiKeyProfile.kind = .openAIResponses
        let apiBody = OpenAIResponsesProvider.requestBody(profile: apiKeyProfile, request: request, withReasoning: false)
        #expect(apiBody["max_output_tokens"] as? Int == 2048)
    }

    @Test(arguments: [true, false])
    func directStreamRequiresCompletedEvent(completed: Bool) async throws {
        let lines = AsyncStream<String> { emitter in
            emitter.yield(#"data: {"type":"response.output_text.delta","delta":"screen"}"#)
            if completed { emitter.yield(#"data: {"type":"response.completed"}"#) }
            emitter.yield("data: [DONE]")
            emitter.finish()
        }
        let (events, continuation) = AsyncThrowingStream<LLMEvent, Error>.makeStream()
        let response = URLResponse(url: ChatGPTAPI.resource, mimeType: "text/event-stream", expectedContentLength: -1, textEncodingName: nil)
        do {
            try await OpenAIResponsesProvider.readEvents(lines, response: response, direct: true, continuation: continuation)
            #expect(completed)
        } catch let error as LLMError {
            #expect(!completed)
            #expect(error.localizedDescription.contains("未收到生成完成事件"))
        }
        continuation.finish()
        var text = ""
        for try await event in events {
            if case .text(let delta) = event { text += delta }
        }
        #expect(text == "screen")
    }

    @Test func addsDirectLoginWithoutMovingExistingCodexProjectsOrParameters() throws {
        let folder = try TempWorkspace.make(prefix: "chatgpt-provider-migration")
        defer { try? FileManager.default.removeItem(at: folder) }
        let persistence = PersistenceController(root: folder)
        var cli = ProviderProfile(name: "Codex", kind: .codex, model: "custom")
        cli.executablePath = "/custom/codex"
        cli.extraArguments = "-c model_provider=custom"
        persistence.store([cli], file: "providers.json")

        let app = AppModel(persistence: persistence)
        #expect(app.providers.map(\.kind) == [.chatGPT, .codex])
        #expect(app.defaultProvider?.id == cli.id)
        #expect(app.defaultProvider?.name == "Codex CLI")
        #expect(app.defaultProvider?.executablePath == cli.executablePath)
        #expect(app.defaultProvider?.extraArguments == cli.extraArguments)
        #expect(app.defaultProvider?.model == cli.model)
        #expect(AppModel(persistence: persistence).providers.map(\.id) == app.providers.map(\.id))
    }
}
