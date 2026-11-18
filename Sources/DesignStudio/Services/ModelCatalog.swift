import Foundation

/// 输入框模型菜单里的一个可选模型
nonisolated struct ModelOption: Hashable, Sendable {
    /// 传给 CLI / API 的模型名
    var id: String
    /// 菜单里显示的名称（带版本号）
    var title: String
    /// 已知的上下文上限（用于决定能带多少历史对话）
    var limits = ModelLimits()
    /// 可选的思考强度（以参数传给 CLI / 接口）；为空表示不能调
    var efforts: [String] = []
    /// 不指定时的默认强度；nil 表示未知（菜单里显示「默认」）
    var defaultEffort: String?
}

/// 思考强度的显示名
nonisolated enum Effort {
    static func title(_ raw: String) -> String {
        switch raw.lowercased() {
        case "xhigh": "XHigh"
        case "": "默认"
        default: raw.prefix(1).uppercased() + raw.dropFirst().lowercased()
        }
    }
}

/// 菜单里的一个模型及其思考强度。两种来源：
/// - 强度写在模型 ID 里（Antigravity 的「Gemini 4 Carbon (Low / Medium / High)」是三个模型）：合并成一项；
/// - 强度是单独的参数（Claude `--effort`、Codex `model_reasoning_effort`、DeepSeek 等接口的 effort）：同一个模型展开强度。
nonisolated struct ModelFamily: Hashable, Sendable {
    /// 去掉思考强度后的名称（「Gemini 4 Carbon」）
    var name: String
    /// 按强度从低到高排列
    var variants: [Variant]
    /// 强度以参数传递（而不是不同的模型 ID）
    var usesEffortParam = false
    /// 以参数传递时，不指定强度时的默认强度；nil 表示未知（有一个「默认」项）
    var defaultEffort: String?

    nonisolated struct Variant: Hashable, Sendable {
        /// 显示名：Low / Medium / High…，参数模式下默认项为「默认」
        var title: String
        var option: ModelOption
        /// 参数模式下传递的强度；nil 表示不传
        var effort: String?
    }

    /// 只有一个版本时直接作为普通菜单项
    var isSingle: Bool { variants.count == 1 }

    /// 未选中时显示的默认强度
    var defaultVariant: Variant {
        if usesEffortParam { return variants.first { $0.effort == defaultEffort } ?? variants[0] }
        return variants.first { $0.title.lowercased() == "medium" } ?? variants[0]
    }

    static let effortOrder = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    /// 「Gemini 4 Carbon (High)」→（「Gemini 4 Carbon」,「High」）；括号里不是思考强度时不拆分
    static func split(_ title: String) -> (name: String, effort: String?) {
        guard let m = title.wholeMatch(of: /(.+?)\s*\((\w+)\)/),
              effortOrder.contains(String(m.2).lowercased()) else { return (title, nil) }
        return (String(m.1), String(m.2))
    }

    private static func rank(_ effort: String) -> Int {
        effortOrder.firstIndex(of: effort.lowercased()) ?? 99
    }

    /// 按名称合并模型，保持首次出现的顺序；同一名称只有一个强度时保留原标题
    static func group(_ options: [ModelOption]) -> [ModelFamily] {
        var order: [String] = []
        var buckets: [String: [Variant]] = [:]
        var families: [String: ModelFamily] = [:]
        for option in options {
            if !option.efforts.isEmpty {
                // 强度是参数：同一模型展开，默认强度未知时加一个「默认」
                let key = "param:" + option.id
                guard families[key] == nil else { continue }
                var variants = option.efforts.sorted { rank($0) < rank($1) }
                    .map { Variant(title: Effort.title($0), option: option, effort: $0) }
                if option.defaultEffort == nil || !option.efforts.contains(option.defaultEffort!) {
                    variants.insert(Variant(title: "默认", option: option, effort: nil), at: 0)
                }
                families[key] = ModelFamily(name: option.title, variants: variants, usesEffortParam: true,
                                            defaultEffort: option.efforts.contains(option.defaultEffort ?? "")
                                                ? option.defaultEffort : nil)
                order.append(key)
                continue
            }
            let (name, effort) = split(option.title)
            let key = effort == nil ? option.title : name
            if buckets[key] == nil && families[key] == nil { order.append(key) }
            buckets[key, default: []].append(Variant(title: effort ?? option.title, option: option, effort: nil))
        }
        return order.map { key in
            if let family = families[key] { return family }
            let variants = buckets[key]!.sorted { rank($0.title) < rank($1.title) }
            if variants.count == 1 {
                // 单个模型保留原标题（例如「GPT-OSS 120B (Medium)」）
                var only = variants[0]
                only.title = only.option.title
                return ModelFamily(name: only.option.title, variants: [only])
            }
            return ModelFamily(name: key, variants: variants)
        }
    }
}

/// 各模型来源可选的模型列表。不内置任何模型名（新模型发布后内置列表很快就会过时），都从 CLI 自己的数据里读：
///
/// - Claude：Claude Code 按账号缓存的模型目录（`~/.claude/cache/model-catalog/*-cc.json`），
///   只列出它自己的模型选择器里显示的那些（section = main），带上下文上限和思考强度。
/// - Codex：Codex CLI 按账号缓存的 `~/.codex/models_cache.json`。
/// - Antigravity：`agy models` 的结果（检测登录状态时刷新缓存）。
/// 读不到时列表为空，菜单里只有「默认模型」（交给 CLI 决定），也可以在设置里手动填写模型 ID。
nonisolated enum ModelCatalog {
    /// Claude 模型，带上每个模型实际生效的默认思考强度（菜单里直接显示，不写「默认」）
    static var claude: [ModelOption] {
        guard let catalog = claudeCatalog() else { return [] }
        let settings = claudeSettings()
        return catalog.pickerModels.map { option in
            var o = option
            o.defaultEffort = claudeEffectiveEffort(model: o.id, catalog: catalog, settings: settings)
            return o
        }
    }

    /// 缓存里没有给出模型支持的强度时，Codex `model_reasoning_effort` 可用的强度
    private static let codexEfforts = ["low", "medium", "high", "xhigh", "max"]

    /// 某个来源的内置 / 缓存模型（不含用户在设置里填写的自定义模型）
    static func known(for kind: ProviderKind) -> [ModelOption] {
        switch kind {
        case .claudeCode: claude
        case .codex: codexModels()
        case .antigravity: antigravityModels()
        default: []
        }
    }

    /// CLI 模型的上下文上限；留空（CLI 默认模型）时尽量推断，推断不出返回未知
    static func limits(for id: String, kind: ProviderKind) -> ModelLimits {
        var modelID = id
        if modelID.isEmpty { modelID = cliDefaultModel(kind) ?? "" }
        if let hit = known(for: kind).first(where: { $0.id == modelID }) { return hit.limits }
        // Claude：选择器之外的模型（设置里手动填写的）也可能在 Claude Code 的模型目录里
        if kind == .claudeCode, let hit = claudeCatalog()?.allModels.first(where: { $0.id == modelID }) { return hit.limits }
        return ModelLimits()
    }

    /// 把模型 ID 映射为可读名称，未知 ID 原样返回
    static func title(for id: String, kind: ProviderKind) -> String {
        if let hit = known(for: kind).first(where: { $0.id == id }) { return hit.title }
        if kind == .claudeCode, let hit = claudeCatalog()?.allModels.first(where: { $0.id == id }) { return hit.title }
        return id
    }

    // MARK: - Antigravity

    /// `agy models` 输出（每行「模型 ID<Tab>显示名」）的缓存文件
    static var antigravityCacheURL: URL {
        URL.applicationSupportDirectory.appending(path: "DesignStudio/antigravity-models.json")
    }

    /// 解析 `agy models` 的输出
    static func parseAntigravityModels(_ output: String) -> [ModelOption] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[0].contains(" ") else { return nil }
            return ModelOption(id: parts[0], title: parts[1])
        }
    }

    static func saveAntigravityModels(_ models: [ModelOption]) {
        let pairs = models.map { [$0.id, $0.title] }
        guard !pairs.isEmpty, let data = try? JSONEncoder().encode(pairs) else { return }
        try? FileManager.default.createDirectory(at: antigravityCacheURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: antigravityCacheURL)
    }

    static func antigravityModels() -> [ModelOption] {
        guard let data = try? Data(contentsOf: antigravityCacheURL),
              let pairs = try? JSONDecoder().decode([[String]].self, from: data) else { return [] }
        return pairs.compactMap { $0.count == 2 ? ModelOption(id: $0[0], title: $0[1]) : nil }
    }

    // MARK: - CLI 默认模型

    /// 模型留空时 CLI 实际使用的模型 ID：
    /// Codex 读 `~/.codex/config.toml`，Antigravity 读 `~/.gemini/antigravity-cli/settings.json`，
    /// Claude Code 读 `~/.claude/settings.json` 的 `model`；都没有时用上次运行时 CLI 报告的模型
    static func cliDefaultModel(_ kind: ProviderKind) -> String? {
        let configured: String? = switch kind {
        case .codex: codexConfiguredDefault()
        case .antigravity: antigravityConfiguredDefault()
        case .claudeCode: claudeConfiguredDefault()
        default: nil
        }
        return configured ?? lastReportedModel(kind)
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    private static func jsonString(_ url: URL, key: String) -> String? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = (obj[key] as? String)?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }

    /// agy 的设置里记的是显示名（「Gemini 4 Argon (Medium)」），换成模型 ID
    static func antigravityConfiguredDefault() -> String? {
        guard let value = jsonString(home.appending(path: ".gemini/antigravity-cli/settings.json"), key: "model") else { return nil }
        return antigravityModels().first { $0.title == value || $0.id == value }?.id ?? value
    }

    /// Claude Code 的默认模型：环境变量 / settings.json 的 `model`（可能是别名 opus / sonnet…），
    /// 都没有时用 Claude Code 缓存的模型目录里记录的当前模型
    static func claudeConfiguredDefault() -> String? {
        let value = ProcessInfo.processInfo.environment["ANTHROPIC_MODEL"]
            ?? jsonString(home.appending(path: ".claude/settings.json"), key: "model")
        if let value, !value.isEmpty, value.lowercased() != "default" {
            let alias = value.lowercased().replacingOccurrences(of: "[1m]", with: "")
            return claudeCatalog()?.aliases[alias] ?? value
        }
        return claudeCatalog()?.currentModel
    }

    // MARK: - Claude Code 模型目录

    /// Claude Code 按账号缓存的模型目录（`~/.claude/cache/model-catalog/*-cc.json`，cc = 命令行）：
    /// 每个模型支持的强度、内置默认强度，以及这个账号当前的模型和各模型的强度
    nonisolated struct ClaudeCatalog: Sendable {
        /// Claude Code 模型选择器里显示的模型（section = main），按目录顺序
        var pickerModels: [ModelOption] = []
        /// 目录里的全部模型（含旧模型），用于显示名和上下文上限
        var allModels: [ModelOption] = []
        /// 别名（opus / sonnet / haiku / fable）对应的模型
        var aliases: [String: String] = [:]
        var currentModel: String?
        var levels: [String: [String]] = [:]
        var builtinDefault: [String: String] = [:]
        var stateEffort: [String: String] = [:]
    }

    nonisolated(unsafe) private static var claudeCatalogCache: (stamp: Date, catalog: ClaudeCatalog?)?

    static func claudeCatalog() -> ClaudeCatalog? {
        let dir = home.appending(path: ".claude/cache/model-catalog")
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasSuffix("-cc.json") }
        let dated = files.compactMap { url -> (URL, Date)? in
            guard let d = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
            return (url, d)
        }
        guard let newest = dated.max(by: { $0.1 < $1.1 }) else { return nil }

        lock.lock(); defer { lock.unlock() }
        if let cache = claudeCatalogCache, cache.stamp == newest.1 { return cache.catalog }
        let catalog = parseClaudeCatalog((try? Data(contentsOf: newest.0)) ?? Data())
        claudeCatalogCache = (newest.1, catalog)
        return catalog
    }

    static func parseClaudeCatalog(_ data: Data) -> ClaudeCatalog? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let catalog = root["catalog"] as? [String: Any] else { return nil }
        var result = ClaudeCatalog()
        let config = catalog["config"] as? [String: Any]
        for m in config?["models"] as? [[String: Any]] ?? [] {
            guard let id = m["id"] as? String else { continue }
            let runtime = m["runtime"] as? [String: Any] ?? [:]
            let levels = runtime["effort_levels"] as? [String] ?? []
            if !levels.isEmpty { result.levels[id] = levels }
            if let d = runtime["default_effort"] as? String { result.builtinDefault[id] = d }
            let option = ModelOption(id: id, title: (m["name"] as? String) ?? id,
                                     limits: ModelLimits(contextWindow: runtime["max_input_tokens"] as? Int,
                                                         maxOutput: runtime["max_output_tokens"] as? Int),
                                     efforts: levels)
            result.allModels.append(option)
            if m["section"] as? String == "main" { result.pickerModels.append(option) }
        }
        for (alias, target) in config?["provider_alias_targets"] as? [String: Any] ?? [:] {
            if let id = (target as? [String: Any])?["default"] as? String { result.aliases[alias] = id }
        }
        let state = catalog["state"] as? [String: Any]
        result.currentModel = state?["model"] as? String
        for t in state?["thinking_by_model"] as? [[String: Any]] ?? [] {
            if let id = t["id"] as? String, let e = (t["thinking"] as? [String: Any])?["effort"] as? String {
                result.stateEffort[id] = e
            }
        }
        return result
    }

    private static func claudeSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: home.appending(path: ".claude/settings.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    /// 不传 --effort 时 Claude Code 实际用的强度，优先级与 Claude Code 一致：
    /// 环境变量 CLAUDE_CODE_EFFORT_LEVEL → settings.json 里该模型的 effortLevel → 顶层 effortLevel
    /// → 模型目录里这个账号的强度 → 模型的内置默认强度
    static func claudeEffectiveEffort(model: String, catalog: ClaudeCatalog?, settings: [String: Any]) -> String? {
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CODE_EFFORT_LEVEL"], !env.isEmpty { return env.lowercased() }
        if let perModel = ((settings["modelSettings"] as? [String: Any])?[model] as? [String: Any])?["effortLevel"] as? String {
            return perModel
        }
        if let top = settings["effortLevel"] as? String { return top }
        return catalog?.stateEffort[model] ?? catalog?.builtinDefault[model]
    }

    /// CLI 每次运行开始时会报告实际使用的模型，记下来作为最后的依据
    static func recordReportedModel(_ model: String, kind: ProviderKind) {
        var id = model.trimmingCharacters(in: .whitespaces)
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }   // claude-opus-5-5[1m]
        guard !id.isEmpty else { return }
        UserDefaults.standard.set(id, forKey: "cliReportedModel." + kind.rawValue)
    }

    static func lastReportedModel(_ kind: ProviderKind) -> String? {
        UserDefaults.standard.string(forKey: "cliReportedModel." + kind.rawValue)
    }

    /// Codex CLI 配置里的默认模型（`~/.codex/config.toml` 顶层的 `model = "…"`）
    static func codexConfiguredDefault() -> String? { codexConfiguredValue("model") }

    /// `~/.codex/config.toml` 顶层的某个字符串键
    static func codexConfiguredValue(_ key: String) -> String? {
        guard let text = try? String(contentsOf: codexHome.appending(path: "config.toml"), encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("[") { break } // 只看顶层键，不进入 [profiles.*] 等表
            guard l.hasPrefix(key), let eq = l.firstIndex(of: "=") else { continue }
            guard l[..<eq].trimmingCharacters(in: .whitespaces) == key else { continue }
            let value = l[l.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: - Codex 缓存

    private static var codexHome: URL {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            return URL(filePath: env)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
    }

    private struct CodexCache: Decodable {
        struct Model: Decodable {
            var slug: String
            var display_name: String?
            var visibility: String?
            var priority: Int?
            var context_window: Int?
            var max_output_tokens: Int?
            var supported_reasoning_levels: [Level]?
            var default_reasoning_level: String?
        }
        struct Level: Decodable { var effort: String }
        var models: [Model]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (stamp: Date, options: [ModelOption])?

    private static func codexModels() -> [ModelOption] {
        let url = codexHome.appending(path: "models_cache.json")
        guard let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.modificationDate] as? Date
        else { return [] }

        lock.lock(); defer { lock.unlock() }
        if let cached, cached.stamp == stamp { return cached.options }

        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(CodexCache.self, from: data) else { return [] }
        let options = cache.models
            .filter { ($0.visibility ?? "list") == "list" }
            .sorted { ($0.priority ?? .max) < ($1.priority ?? .max) }
            .map { m in
                // config.toml 里的 model_reasoning_effort 覆盖每个模型自己的默认强度
                let configured = codexConfiguredValue("model_reasoning_effort")
                return ModelOption(id: m.slug, title: m.display_name ?? m.slug,
                                   limits: ModelLimits(contextWindow: m.context_window, maxOutput: m.max_output_tokens),
                                   efforts: m.supported_reasoning_levels?.map(\.effort) ?? codexEfforts,
                                   defaultEffort: configured ?? m.default_reasoning_level)
            }
        let result = options
        cached = (stamp, result)
        return result
    }
}
