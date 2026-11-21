import Foundation
import Network

/// 浏览器只回调本机，使用系统分配的端口，以免与 Codex CLI 登录冲突。
nonisolated final class ChatGPTLoopback: Sendable {
    static let path = "/auth/callback"
    private let listener: NWListener
    private let ready: AsyncThrowingStream<UInt16, Error>
    let callbacks: AsyncThrowingStream<URL, Error>

    init(state: String) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let (ready, port) = AsyncThrowingStream<UInt16, Error>.makeStream()
        let (callbacks, callback) = AsyncThrowingStream<URL, Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        self.ready = ready
        self.callbacks = callbacks
        listener.stateUpdateHandler = { [weak listener] status in
            switch status {
            case .ready:
                if let value = listener?.port { port.yield(value.rawValue) }
                port.finish()
            case .failed(let error):
                port.finish(throwing: error)
                callback.finish(throwing: error)
            case .cancelled:
                port.finish()
                callback.finish()
            default:
                break
            }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { connection.cancel() }
            Self.read(connection, state: state, callback: callback)
        }
        listener.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak listener] in
            let error = LLMError.invalidResponse("ChatGPT 登录已超时，请重新登录。")
            port.finish(throwing: error)
            callback.finish(throwing: error)
            listener?.cancel()
        }
    }

    func redirectURI() async throws -> String {
        for try await port in ready { return "http://127.0.0.1:\(port)\(Self.path)" }
        try Task.checkCancellation()
        throw LLMError.invalidResponse("无法启动 ChatGPT 登录回调。")
    }

    func close() { listener.cancel() }

    private static func read(_ connection: NWConnection, state: String,
                             callback: AsyncThrowingStream<URL, Error>.Continuation, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, complete, error in
            guard error == nil, let data else { connection.cancel(); return }
            let request = buffer + data
            guard request.count <= 16_384 else { connection.cancel(); return }
            guard let end = request.range(of: Data([13, 10, 13, 10])) else {
                if complete { connection.cancel() }
                else { read(connection, state: state, callback: callback, buffer: request) }
                return
            }
            let header = String(decoding: request[..<end.lowerBound], as: UTF8.self)
            let url = callbackURL(in: header, state: state)
            let accepted = url != nil
            let status = accepted ? "200 OK" : "400 Bad Request"
            let message = accepted ? "You can close this tab and return to DesignStudio." : "Invalid callback."
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\n"
                + "Content-Length: \(message.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
                + "Referrer-Policy: no-referrer\r\n\r\n" + message
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            if let url { callback.yield(url); callback.finish() }
        }
    }

    static func callbackURL(in header: String, state: String) -> URL? {
        let parts = header.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
        guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix(path + "?"),
              let url = URL(string: "http://127.0.0.1" + parts[1]),
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let states = query.filter { $0.name == "state" }
        guard states.count == 1, states.first?.value == state else { return nil }
        let codes = query.filter { $0.name == "code" }
        let errors = query.filter { $0.name == "error" }
        guard (codes.count == 1 && errors.isEmpty) || (codes.isEmpty && errors.count == 1) else { return nil }
        return url
    }
}
