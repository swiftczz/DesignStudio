import Foundation

nonisolated enum UpdateService {
    private static let repository = "swiftczz/DesignStudio"
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    static let installedVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    struct Update {
        let version: String
        let notes: String
        let downloadURL: URL
    }

    enum CheckError: LocalizedError, Equatable {
        case unknownInstalledVersion
        case invalidRelease
        case missingInstaller
        case httpStatus(Int)

        var errorDescription: String? {
            switch self {
            case .unknownInstalledVersion:
                "无法读取当前版本。请在打包后的 DesignStudio.app 中检查更新。"
            case .invalidRelease:
                "GitHub 返回的版本信息无效，请稍后重试。"
            case .missingInstaller:
                "新版的 DMG 安装包暂不可用，请稍后重试。"
            case .httpStatus(let code):
                "GitHub 返回 HTTP \(code)，请稍后重试。"
            }
        }
    }

    static func check(installedVersion: String) async throws -> Update? {
        var request = URLRequest(url: latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CheckError.invalidRelease }
        guard response.statusCode == 200 else { throw CheckError.httpStatus(response.statusCode) }
        return try availableUpdate(in: data, installedVersion: installedVersion)
    }

    static func availableUpdate(in data: Data, installedVersion: String) throws -> Update? {
        guard let current = versionComponents(installedVersion) else { throw CheckError.unknownInstalledVersion }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let release = try? decoder.decode(Release.self, from: data) else { throw CheckError.invalidRelease }
        guard !release.draft, !release.prerelease else { return nil }

        let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        guard let latest = versionComponents(version) else { throw CheckError.invalidRelease }
        guard current.lexicographicallyPrecedes(latest) else { return nil }

        let installerName = "DesignStudio-\(version).dmg"
        let downloadURL = URL(string: "https://github.com/\(repository)/releases/download/\(release.tagName)/\(installerName)")!
        guard release.assets.contains(where: {
            $0.name == installerName && $0.state == "uploaded" && $0.browserDownloadUrl == downloadURL
        }) else { throw CheckError.missingInstaller }

        return Update(version: version, notes: release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                      downloadURL: downloadURL)
    }

    private static func versionComponents(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part in
            part.allSatisfy { $0.isASCII && $0.isNumber } ? Int(part) : nil
        }
        return numbers.count == parts.count ? numbers : nil
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let state: String
            let browserDownloadUrl: URL
        }

        let tagName: String
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }
}
