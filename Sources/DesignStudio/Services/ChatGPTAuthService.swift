import AppKit
import CryptoKit
import Darwin
import Foundation
import Observation
import Security

/// 独立于 CLI 的 OAuth 注册。注册 ID 和账号身份在退出后保留，令牌单独清除。
nonisolated private struct ChatGPTAccount: Codable {
    let clientID: String
    let subject: String
    let email: String?
    var tokens: ChatGPTTokens?
}

nonisolated private struct ChatGPTTokens: Codable {
    let access: String
    let refresh: String?
    let identity: String?
    let expiry: Date
    let scopes: Set<String>

    var canUsePlan: Bool { scopes.contains("chatgpt.tokens.use.direct") }
}

nonisolated private struct ChatGPTTokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let id_token: String?
    let token_type: String
    let expires_in: Double
    let scope: String?

    func credentials(previous: ChatGPTTokens? = nil) throws -> ChatGPTTokens {
        guard token_type.caseInsensitiveCompare("Bearer") == .orderedSame,
              !access_token.isEmpty, expires_in.isFinite, expires_in > 0 else {
            throw LLMError.invalidResponse("ChatGPT 返回了无效的授权凭据。")
        }
        return ChatGPTTokens(access: access_token, refresh: refresh_token ?? previous?.refresh,
                             identity: previous?.identity ?? id_token,
                             expiry: Date().addingTimeInterval(expires_in),
                             scopes: scope.map { Set($0.split(separator: " ").map(String.init)) } ?? previous?.scopes ?? [])
    }
}

@MainActor
@Observable
final class ChatGPTAuthService {
    static let shared = ChatGPTAuthService()

    private static let requestedScopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    nonisolated private static let initialClientID = "dynamic_agent_client"

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var login: Task<Bool, Never>?
    @ObservationIgnored private var renewal: Task<String, Error>?
    private var account: ChatGPTAccount?
    @ObservationIgnored private var sessionRevision = UUID()
    private(set) var busy = false
    private(set) var signingIn = false
    private(set) var error: String?

    var isSignedIn: Bool { account?.tokens != nil }
    var canUsePlan: Bool { account?.tokens?.canUsePlan == true }
    var hasRegistration: Bool { account != nil }
    var status: String {
        guard isSignedIn else { return "未登录" }
        let identity = account?.email ?? "ChatGPT 账号"
        return canUsePlan ? "已登录 · \(identity)" : "已登录 · 未授权订阅用量"
    }

    private init() {
        let directory = SecretStore.fileURL.deletingLastPathComponent().appending(path: "ChatGPT", directoryHint: .isDirectory)
        self.directory = directory
        account = (try? Data(contentsOf: directory.appending(path: "account.json")))
            .flatMap { try? JSONDecoder().decode(ChatGPTAccount.self, from: $0) }
    }

    func signIn(newAccount: Bool = false) async -> Bool {
        guard !busy, !newAccount || !isSignedIn else { return false }
        busy = true
        signingIn = true
        error = nil
        let task = Task {
            do {
                try await authorize(existing: newAccount ? nil : account)
                return true
            } catch is CancellationError {
                // 取消浏览器登录时继续使用当前账号。
            } catch {
                self.error = error.localizedDescription
            }
            return false
        }
        login = task
        let result = await task.value
        login = nil
        signingIn = false
        busy = false
        return result
    }

    func cancelSignIn() { login?.cancel() }

    func signOut() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        error = nil
        if let renewal { _ = await renewal.result }
        guard account != nil else { return }
        let revocation: (String?, String)
        do {
            let lock = try await lockAccount()
            defer { close(lock) }
            guard let current = try readAccount(), current.clientID == account?.clientID else {
                account = nil
                return
            }
            guard let tokens = current.tokens else { account = current; return }
            try clearTokens(current)
            revocation = (tokens.refresh, current.clientID)
        } catch {
            self.error = "无法清除本机登录凭据，请重试。"
            return
        }
        guard let refresh = revocation.0 else { return }
        for attempt in 0..<3 {
            do {
                let config = try await ChatGPTAPI.data(for: URLRequest(
                    url: ChatGPTAPI.issuer.appending(path: ".well-known/openid-configuration"), timeoutInterval: 10))
                struct Discovery: Decodable { let revocation_endpoint: URL }
                let endpoint = try JSONDecoder().decode(Discovery.self, from: config).revocation_endpoint
                guard endpoint.scheme == "https", endpoint.host == ChatGPTAPI.issuer.host else {
                    throw LLMError.invalidResponse("无法验证 ChatGPT 的退出端点。")
                }
                _ = try await ChatGPTAPI.post(endpoint, [
                    "token": refresh, "token_type_hint": "refresh_token", "client_id": revocation.1
                ])
                return
            } catch let failure as ChatGPTAPI.Failure where failure.status < 500 {
                break
            } catch {
                if attempt < 2 { try? await Task.sleep(for: .seconds(attempt + 1)) }
            }
        }
        error = "本机已退出，远程撤销未确认。你可以在 ChatGPT 设置中断开 DesignStudio。"
    }

    func models() async throws -> [RemoteModel] {
        let revision = sessionRevision
        let token = try await accessToken()
        let models: [RemoteModel]
        do {
            models = try await ChatGPTAPI.models(token)
        } catch let failure as ChatGPTAPI.Failure where failure.status == 401 {
            guard sessionRevision == revision else { throw CancellationError() }
            let replacement = try await accessToken(replacing: token)
            models = try await ChatGPTAPI.models(replacement)
        }
        guard sessionRevision == revision, canUsePlan else { throw CancellationError() }
        return models
    }

    func inferenceAuthorization(replacing rejected: ChatGPTAPI.Authorization? = nil) async throws -> ChatGPTAPI.Authorization {
        let revision = sessionRevision
        guard rejected == nil || rejected?.revision == revision else {
            throw LLMError.invalidResponse("ChatGPT 账号已切换，请重新发送。")
        }
        let token = try await accessToken(replacing: rejected?.token)
        guard sessionRevision == revision else {
            throw LLMError.invalidResponse("ChatGPT 账号已切换，请重新发送。")
        }
        return .init(token: token, revision: revision)
    }

    private func accessToken(replacing rejected: String? = nil) async throws -> String {
        guard !busy || signingIn, let current = account, let tokens = current.tokens else {
            throw LLMError.notLoggedIn("ChatGPT")
        }
        guard tokens.canUsePlan else { throw LLMError.invalidResponse("请在设置中授权 DesignStudio 使用 ChatGPT 订阅额度。") }
        if let renewal {
            let value = try await renewal.value
            guard !busy || signingIn else { throw LLMError.notLoggedIn("ChatGPT") }
            return value
        }
        if rejected != tokens.access, tokens.expiry.timeIntervalSinceNow > 60 {
            return tokens.access
        }
        let task = Task {
            defer { renewal = nil }
            // 重新打开应用的其他进程可能已轮换了 refresh token。
            let lock = try await lockAccount()
            defer { close(lock) }
            guard let saved = try readAccount(), saved.clientID == current.clientID,
                  let tokens = saved.tokens else {
                account = nil
                sessionRevision = UUID()
                throw LLMError.notLoggedIn("ChatGPT")
            }
            account = saved
            guard tokens.canUsePlan else { throw LLMError.invalidResponse("ChatGPT 订阅授权已失效，请重新授权。") }
            if rejected != tokens.access, tokens.expiry.timeIntervalSinceNow > 60 { return tokens.access }
            guard let refresh = tokens.refresh else {
                try clearTokens(saved)
                throw LLMError.notLoggedIn("ChatGPT")
            }
            do {
                let response = try await requestTokens([
                    "grant_type": "refresh_token", "client_id": saved.clientID, "refresh_token": refresh
                ])
                var updated = saved
                let replacement = try response.credentials(previous: tokens)
                updated.tokens = replacement
                try save(updated)
                guard replacement.canUsePlan else {
                    throw LLMError.invalidResponse("ChatGPT 订阅授权已失效，请重新授权。")
                }
                return replacement.access
            } catch let failure as ChatGPTAPI.Failure where failure.invalidRefresh {
                try clearTokens(saved)
                throw LLMError.notLoggedIn("ChatGPT")
            }
        }
        renewal = task
        let value = try await task.value
        guard !busy || signingIn else { throw LLMError.notLoggedIn("ChatGPT") }
        return value
    }

    private func authorize(existing: ChatGPTAccount?) async throws {
        let state = try Self.randomString()
        let nonce = try Self.randomString()
        let verifier = try Self.randomString()
        let listener = try ChatGPTLoopback(state: state)
        defer { listener.close() }
        let redirect = try await listener.redirectURI()
        let hostID = try await hostIdentifier()
        var url = URLComponents(url: ChatGPTAPI.issuer.appending(path: "api/accounts/authorize"), resolvingAgainstBaseURL: false)!
        var parameters = [
            "client_id": existing?.clientID ?? Self.initialClientID,
            "ext_agent_host_id": hostID,
            "response_type": "code",
            "redirect_uri": redirect,
            "scope": Self.requestedScopes,
            "resource": ChatGPTAPI.resource.absoluteString,
            "state": state,
            "nonce": nonce,
            "code_challenge_method": "S256",
            "code_challenge": ChatGPTIdentity.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        ]
        if let existing {
            parameters["login_hint"] = existing.email
            parameters["id_token_hint"] = existing.tokens?.identity
            if existing.tokens?.canUsePlan == false { parameters["prompt"] = "consent" }
        } else {
            parameters["agent_name_hint"] = "DesignStudio"
        }
        url.percentEncodedQuery = ChatGPTAPI.formEncode(parameters)
        try Task.checkCancellation()
        guard let authorizeURL = url.url, NSWorkspace.shared.open(authorizeURL) else {
            throw LLMError.invalidResponse("无法打开浏览器，请检查默认浏览器设置。")
        }

        for try await callback in listener.callbacks {
            let value = try Self.authorizationCode(callback, existingClientID: existing?.clientID)
            listener.close()
            let response = try await requestTokens([
                "grant_type": "authorization_code", "client_id": value.clientID,
                "code": value.code, "code_verifier": verifier, "redirect_uri": redirect
            ])
            let tokens = try response.credentials()
            guard let idToken = tokens.identity else { throw LLMError.invalidResponse("ChatGPT 未返回账号身份。") }
            let claims = try await ChatGPTIdentity.verify(idToken, clientID: value.clientID, nonce: nonce)
            guard existing == nil || claims.sub == existing?.subject else {
                throw LLMError.invalidResponse("浏览器选择的 ChatGPT 账号与当前连接不同。请退出后选择「使用其他账号」。")
            }
            if let renewal { _ = await renewal.result }
            try Task.checkCancellation()
            let lock = try await lockAccount()
            defer { close(lock) }
            try save(ChatGPTAccount(clientID: value.clientID, subject: claims.sub, email: claims.email, tokens: tokens))
            sessionRevision = UUID()
            return
        }
        try Task.checkCancellation()
        throw LLMError.invalidResponse("ChatGPT 登录回调已结束，请重试。")
    }

    nonisolated static func authorizationCode(_ callback: URL, existingClientID: String?) throws -> (code: String, clientID: String) {
        let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = query.first(where: { $0.name == "error" })?.value {
            let message = error == "access_denied" ? "ChatGPT 授权已取消或被拒绝。" : "ChatGPT 未能完成授权。"
            throw LLMError.invalidResponse(message)
        }
        let clientIDs = query.filter { $0.name == "client_id" }
        let issued = clientIDs.first?.value
        let codes = query.filter { $0.name == "code" }
        guard clientIDs.count <= 1, codes.count == 1, let code = codes.first?.value, !code.isEmpty,
              let clientID = existingClientID ?? issued, !clientID.isEmpty, clientID != initialClientID,
              clientIDs.isEmpty || issued == clientID else {
            throw LLMError.invalidResponse("ChatGPT 返回的登录回调无效，请重试。")
        }
        return (code, clientID)
    }

    private func requestTokens(_ parameters: [String: String]) async throws -> ChatGPTTokenResponse {
        var form = parameters
        form["resource"] = ChatGPTAPI.resource.absoluteString
        let data = try await ChatGPTAPI.post(ChatGPTAPI.issuer.appending(path: "api/accounts/oauth/token"), form)
        return try JSONDecoder().decode(ChatGPTTokenResponse.self, from: data)
    }

    private func clearTokens(_ previous: ChatGPTAccount) throws {
        var updated = previous
        updated.tokens = nil
        try save(updated)
        sessionRevision = UUID()
    }

    private func save(_ value: ChatGPTAccount) throws {
        try writeProtected(JSONEncoder().encode(value), name: "account.json")
        account = value
    }

    private func hostIdentifier() async throws -> String {
        let lock = try await lockAccount()
        defer { close(lock) }
        if let saved = try? String(contentsOf: directory.appending(path: "host-id"), encoding: .utf8), !saved.isEmpty {
            return saved
        }
        let identifier = "urn:uuid:" + UUID().uuidString.lowercased()
        try writeProtected(Data(identifier.utf8), name: "host-id")
        return identifier
    }

    private func readAccount() throws -> ChatGPTAccount? {
        do {
            let data = try Data(contentsOf: directory.appending(path: "account.json"))
            return try JSONDecoder().decode(ChatGPTAccount.self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    private func lockAccount() async throws -> Int32 {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let fd = open(directory.appending(path: "account.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        let failure = LLMError.invalidResponse("ChatGPT 本机账号存储正在使用或无法访问，请重试。")
        guard fd >= 0 else { throw failure }
        do {
            for _ in 0..<100 {
                try Task.checkCancellation()
                if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
                guard errno == EWOULDBLOCK || errno == EINTR else { throw failure }
                try await Task.sleep(for: .milliseconds(200))
            }
            throw failure
        } catch {
            close(fd)
            throw error
        }
    }

    private func writeProtected(_ data: Data, name: String) throws {
        // 在专用目录内写入并设好权限后，一次性替换旧文件。
        let fm = FileManager.default
        let temporary = directory.appending(path: UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        let destination = directory.appending(path: name)
        guard rename(temporary.path, destination.path) == 0 else {
            throw LLMError.invalidResponse("无法保存 ChatGPT 登录状态，请重试。")
        }
    }

    private static func randomString() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw LLMError.invalidResponse("无法生成安全的 ChatGPT 登录参数。")
        }
        return ChatGPTIdentity.base64URL(Data(bytes))
    }
}

nonisolated enum ChatGPTAPI {
    static let issuer = URL(string: "https://auth.openai.com")!
    static let resource = URL(string: "https://api.openai.com/v1")!
    static let session = URLSession(configuration: .ephemeral, delegate: RejectRedirects(), delegateQueue: nil)

    struct Authorization: Sendable {
        let token: String
        let revision: UUID
    }

    struct Failure: LocalizedError {
        let status: Int
        let code: String?
        let message: String
        let requestID: String?

        var invalidRefresh: Bool {
            ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
             "refresh_token_invalidated", "refresh_token_reused"].contains(code ?? "")
        }

        var errorDescription: String? {
            let details = [message, code, requestID.map { "请求 \($0)" }].compactMap { $0 }.joined(separator: " · ")
            return LLMError.http(status, details).localizedDescription
        }
    }

    private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static func post(_ url: URL, _ form: [String: String]) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formEncode(form).utf8)
        return try await data(for: request)
    }

    static func formEncode(_ values: [String: String]) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return values.map { key, value in
            key + "=" + (value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")
        }.joined(separator: "&")
    }

    static func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse("ChatGPT 返回了无效的 HTTP 响应。") }
        guard (200..<300).contains(http.statusCode) else {
            throw failure(response: http, body: String(decoding: data.prefix(4000), as: UTF8.self))
        }
        return data
    }

    static func failure(response: HTTPURLResponse, body: String) -> Failure {
        let json = JSONHelpers.object(body)
        let error = json?["error"] as? [String: Any]
        let code = error?["code"] as? String ?? json?["error"] as? String
        let message = error?["message"] as? String ?? json?["detail"] as? String
            ?? json?["error_description"] as? String ?? "ChatGPT 请求失败"
        return Failure(status: response.statusCode, code: code, message: message,
                       requestID: response.value(forHTTPHeaderField: "x-request-id"))
    }

    static func models(_ token: String) async throws -> [RemoteModel] {
        var request = URLRequest(url: resource.appending(path: "models"), timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try parseModels(await data(for: request))
    }

    static func parseModels(_ data: Data) throws -> [RemoteModel] {
        guard let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = catalog["models"] as? [[String: Any]] else {
            throw LLMError.invalidResponse("ChatGPT 模型列表格式无法识别。")
        }
        // 订阅目录还包含 Codex 的 Ultra 自动委派档位。直连 Responses 不支持该档位。
        let directEfforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
        var seen = Set<String>()
        return models.compactMap { model in
            guard model["visibility"] as? String == "list", let id = model["slug"] as? String,
                  !id.isEmpty, seen.insert(id).inserted else { return nil }
            let effort = ModelFetcher.efforts(model)
            let supported = directEfforts.filter { effort.levels?.contains($0) == true }
            let defaultEffort = effort.default.flatMap { supported.contains($0) ? $0 : nil }
            return RemoteModel(id: id, displayName: model["display_name"] as? String,
                               efforts: supported, defaultEffort: defaultEffort)
        }
    }
}
