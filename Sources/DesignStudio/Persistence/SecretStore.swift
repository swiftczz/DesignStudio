import Foundation

/// API Key 存放在应用数据目录下的 `secrets.json`（权限 0600，仅当前用户可读写），
/// 不使用系统钥匙串，避免重新打包后反复弹出钥匙串授权。
@MainActor
enum SecretStore {
    private static var cache: [String: String]?

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "DesignStudio", directoryHint: .isDirectory)
            .appending(path: "secrets.json")
    }

    static func get(_ account: String) -> String? {
        let value = load()[account]
        return (value?.isEmpty ?? true) ? nil : value
    }

    static func set(_ value: String, for account: String) {
        var all = load()
        guard all[account] != value else { return }
        if value.isEmpty { all.removeValue(forKey: account) } else { all[account] = value }
        save(all)
    }

    static func remove(_ account: String) {
        set("", for: account)
    }

    private static func load() -> [String: String] {
        if let cache { return cache }
        let loaded = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        cache = loaded
        return loaded
    }

    private static func save(_ all: [String: String]) {
        cache = all
        let url = fileURL
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? data.write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
    }
}
