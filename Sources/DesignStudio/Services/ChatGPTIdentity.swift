import Foundation
import Security

nonisolated enum ChatGPTIdentity {
    struct Claims: Decodable {
        let iss: String
        let aud: Audience
        let exp: TimeInterval
        let nonce: String
        let sub: String
        let email: String?

        enum Audience: Decodable {
            case one(String)
            case many([String])

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let value = try? container.decode(String.self) { self = .one(value) }
                else { self = .many(try container.decode([String].self)) }
            }

            func matches(_ clientID: String) -> Bool {
                switch self {
                case .one(let audience): audience == clientID
                case .many(let audiences): audiences == [clientID]
                }
            }
        }
    }

    private struct Header: Decodable { let alg: String; let kid: String }
    private struct JWKS: Decodable { let keys: [JWK] }
    private struct JWK: Decodable { let kty: String; let kid: String; let n: String?; let e: String? }

    static func verify(_ token: String, clientID: String, nonce: String) async throws -> Claims {
        let data = try await ChatGPTAPI.data(for: URLRequest(url: ChatGPTAPI.issuer.appending(path: ".well-known/jwks.json")))
        return try verify(token, clientID: clientID, nonce: nonce, jwks: data)
    }

    static func verify(_ token: String, clientID: String, nonce: String, jwks: Data, now: Date = .now) throws -> Claims {
        let failure = LLMError.invalidResponse("无法验证 ChatGPT 账号身份，请重新登录。")
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        let decoder = JSONDecoder()
        guard parts.count == 3, let headerData = decodeBase64URL(parts[0]),
              let header = try? decoder.decode(Header.self, from: headerData), header.alg == "RS256",
              let signature = decodeBase64URL(parts[2]),
              let keys = try? decoder.decode(JWKS.self, from: jwks),
              let key = keys.keys.first(where: { $0.kid == header.kid && $0.kty == "RSA" }),
              let n = key.n.flatMap({ decodeBase64URL($0) }), let e = key.e.flatMap({ decodeBase64URL($0) }),
              !n.isEmpty, !e.isEmpty else { throw failure }
        // Security 接受 DER 格式的 RSAPublicKey（模数和指数）。
        let der = derValue(0x30, derInteger(n) + derInteger(e))
        let attributes = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        guard let publicKey = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil),
              SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                    Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, nil),
              let payload = decodeBase64URL(parts[1]),
              let claims = try? decoder.decode(Claims.self, from: payload),
              claims.iss == ChatGPTAPI.issuer.absoluteString, claims.aud.matches(clientID),
              claims.nonce == nonce, claims.exp > now.timeIntervalSince1970,
              !claims.sub.isEmpty else { throw failure }
        return claims
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(_ value: some StringProtocol) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    private static func derInteger(_ bytes: Data) -> Data {
        let magnitude = Data(bytes.drop(while: { $0 == 0 }))
        let value = ((magnitude.first ?? 0) >= 128 || magnitude.isEmpty) ? Data([0]) + magnitude : magnitude
        return derValue(0x02, value)
    }

    private static func derValue(_ tag: UInt8, _ bytes: Data) -> Data {
        if bytes.count < 128 { return Data([tag, UInt8(bytes.count)]) + bytes }
        var length = bytes.count
        var encoded: [UInt8] = []
        while length > 0 {
            encoded.append(UInt8(length & 0xff))
            length >>= 8
        }
        return Data([tag, 0x80 | UInt8(encoded.count)] + encoded.reversed()) + bytes
    }
}
