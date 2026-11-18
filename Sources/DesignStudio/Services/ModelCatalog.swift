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

/// 各模型来源可选的模型列表
///
/// - Claude：Claude Code CLI 没有可读取的模型清单，这里内置当前一代模型的完整 ID，
///   这样菜单能显示具体版本，且不会因为别名指向变化而悄悄换模型。
/// - Codex：读取 Codex CLI 按账号拉取并缓存的 `~/.codex/models_cache.json`，
///   与 `codex` 自带的模型选择器保持一致；文件缺失时退回内置列表。
nonisolated enum ModelCatalog {
    private static let claudeLimits = ModelLimits(contextWindow: 1_000_000, maxOutput: 128_000)
    /// `claude --effort` 接受的强度；默认强度由 Claude Code 决定，菜单里显示「默认」
    private static let claudeEfforts = ["low", "medium", "high", "xhigh", "max"]

    static let claude: [ModelOption] = [
        ModelOption(id: "claude-fable-5-2", title: "Fable 5.2", limits: claudeLimits, efforts: claudeEfforts),
        ModelOption(id: "claude-opus-5-5", title: "Opus 5.5", limits: claudeLimits, efforts: claudeEfforts),
        ModelOption(id: "claude-sonnet-5-5", title: "Sonnet 5.5", limits: claudeLimits, efforts: claudeEfforts),
        ModelOption(id: "claude-haiku-5-5", title: "Haiku 5.5", limits: claudeLimits, efforts: claudeEfforts)
    ]

    private static let codexEfforts = ["low", "medium", "high", "xhigh", "max"]

    static let codexFallback: [ModelOption] = [
        ModelOption(id: "gpt-6.1-sol", title: "GPT-6.1-Sol", efforts: codexEfforts),
        ModelOption(id: "gpt-6-astra", title: "GPT-6-Astra", efforts: codexEfforts),
        ModelOption(id: "gpt-6.1-terra", title: "GPT-6.1 Terra", efforts: codexEfforts),
        ModelOption(id: "gpt-6-luna", title: "GPT-6-Luna", efforts: codexEfforts)
    ]

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
        if modelID.isEmpty, kind == .codex { modelID = codexConfiguredDefault() ?? "" }
        if let hit = known(for: kind).first(where: { $0.id == modelID }) { return hit.limits }
        // Claude CLI 的别名（opus / sonnet / fable…）与默认模型都是当前一代，上下文同为 1M
        if kind == .claudeCode, modelID.isEmpty || !modelID.contains("-4-") { return claudeLimits }
        return ModelLimits()
    }

    /// 把模型 ID 映射为可读名称，未知 ID 原样返回
    static func title(for id: String, kind: ProviderKind) -> String {
        known(for: kind).first { $0.id == id }?.title ?? id
    }

    // MARK: - Antigravity

    /// 内置列表：`agy models` 的结果（检测登录状态时会刷新缓存，缓存缺失时用这里）
    static let antigravityFallback: [ModelOption] = [
        ModelOption(id: "gemini-4-carbon-medium", title: "Gemini 4 Carbon (Medium)"),
        ModelOption(id: "gemini-4-carbon-high", title: "Gemini 4 Carbon (High)"),
        ModelOption(id: "gemini-4-argon-medium", title: "Gemini 4 Argon (Medium)"),
        ModelOption(id: "gemini-4-hydrogen-high", title: "Gemini 4 Hydrogen (High)"),
        ModelOption(id: "gemini-3.8-flash-medium", title: "Gemini 3.8 Flash (Medium)"),
        ModelOption(id: "claude-opus-4-6-thinking", title: "Claude Opus 4.6 (Thinking)"),
        ModelOption(id: "claude-sonnet-4-6", title: "Claude Sonnet 4.6 (Thinking)")
    ]

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
              let pairs = try? JSONDecoder().decode([[String]].self, from: data) else { return antigravityFallback }
        let list = pairs.compactMap { $0.count == 2 ? ModelOption(id: $0[0], title: $0[1]) : nil }
        return list.isEmpty ? antigravityFallback : list
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
        else { return codexFallback }

        lock.lock(); defer { lock.unlock() }
        if let cached, cached.stamp == stamp { return cached.options }

        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(CodexCache.self, from: data) else { return codexFallback }
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
        let result = options.isEmpty ? codexFallback : options
        cached = (stamp, result)
        return result
    }
}
