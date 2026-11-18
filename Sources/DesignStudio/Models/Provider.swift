import Foundation

nonisolated enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 通过官方 Claude Code CLI（claude auth login，支持 Pro/Max 订阅或 Console 账号）
    case claudeCode
    /// 通过官方 Codex CLI（codex login，支持 ChatGPT 账号登录）
    case codex
    /// 通过 Google Antigravity CLI（agy，使用 Google 账号与 Google AI 订阅额度）
    case antigravity
    /// Anthropic Messages API 及兼容接口（智谱、Kimi、DeepSeek 等提供的 /anthropic 端点）
    case anthropicAPI
    /// OpenAI Chat Completions 兼容接口（OpenAI、OpenRouter、DeepSeek、通义、Ollama…）
    case openAICompatible
    /// OpenAI Responses 接口（OpenAI 官方及兼容实现）
    case openAIResponses

    var id: String { rawValue }

    /// API 类来源可以互相切换的接口协议
    static let apiKinds: [ProviderKind] = [.openAICompatible, .openAIResponses, .anthropicAPI]

    var title: String {
        switch self {
        case .claudeCode: "Claude 账号登录"
        case .codex: "Codex / ChatGPT 登录"
        case .antigravity: "Antigravity / Google 登录"
        case .anthropicAPI: "Anthropic Messages"
        case .openAICompatible: "OpenAI Chat Completions"
        case .openAIResponses: "OpenAI Responses"
        }
    }

    var symbol: String {
        switch self {
        case .claudeCode: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .antigravity: "airplane"
        case .anthropicAPI: "key.horizontal"
        case .openAICompatible, .openAIResponses: "network"
        }
    }

    var isCLI: Bool { self == .claudeCode || self == .codex || self == .antigravity }

    /// 请求的接口路径（用于设置页说明）
    var endpointHint: String {
        switch self {
        case .anthropicAPI: "{Base URL}/v1/messages"
        case .openAICompatible: "{Base URL}/chat/completions"
        case .openAIResponses: "{Base URL}/responses"
        default: ""
        }
    }

    var defaultExecutable: String {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        case .antigravity: "agy"
        default: ""
        }
    }
}

/// 模型的上下文上限。nil 表示未知：输出不传上限，由服务商按模型最大值处理
nonisolated struct ModelLimits: Codable, Hashable, Sendable {
    /// 上下文窗口（输入 + 输出）
    var contextWindow: Int?
    /// 单次最大输出 tokens
    var maxOutput: Int?
}

/// 从服务商 /models 接口拉取到的模型
nonisolated struct RemoteModel: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var displayName: String?
    var limits = ModelLimits()
    var created: Int?
    /// 支持的思考强度（来自 /models，如 DeepSeek 的 effort.supported_levels），未知为 nil
    var efforts: [String]?
    /// 不传思考强度时服务商使用的强度
    var defaultEffort: String?

    var title: String { displayName.map { $0.isEmpty ? id : $0 } ?? id }
}

nonisolated struct ProviderProfile: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var kind: ProviderKind
    var baseURL: String = ""
    /// 默认模型
    var model: String = ""
    /// API 来源：已选用的模型（可多个，在输入框里切换）
    var models: [String] = []
    /// API 来源：最近一次从 /models 拉取到的全部模型
    var availableModels: [RemoteModel] = []
    /// API 来源：已选模型的上下文上限（来自拉取结果，可手动修改）
    var modelLimits: [String: ModelLimits] = [:]
    var executablePath: String = ""
    var extraArguments: String = ""
    var useBearerAuth: Bool = false
    /// 每行一个 `Header: Value`
    var extraHeaders: String = ""
    /// 本次请求的思考强度（项目里选择的，不保存在来源配置里）；空字符串表示不指定，由 CLI / 服务商决定
    var effort: String = ""

    init(id: UUID = UUID(), name: String, kind: ProviderKind, baseURL: String = "", model: String = "",
         models: [String] = [], useBearerAuth: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.models = models.isEmpty && !model.isEmpty ? [model] : models
        self.useBearerAuth = useBearerAuth
    }

    // 新增字段都按「可缺省」解码，旧版本保存的 providers.json 仍能读取
    private enum CodingKeys: String, CodingKey {
        case id, name, kind, baseURL, model, models, availableModels, modelLimits
        case executablePath, extraArguments, useBearerAuth, extraHeaders
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(ProviderKind.self, forKey: .kind)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        models = try c.decodeIfPresent([String].self, forKey: .models) ?? []
        availableModels = try c.decodeIfPresent([RemoteModel].self, forKey: .availableModels) ?? []
        modelLimits = try c.decodeIfPresent([String: ModelLimits].self, forKey: .modelLimits) ?? [:]
        executablePath = try c.decodeIfPresent(String.self, forKey: .executablePath) ?? ""
        extraArguments = try c.decodeIfPresent(String.self, forKey: .extraArguments) ?? ""
        useBearerAuth = try c.decodeIfPresent(Bool.self, forKey: .useBearerAuth) ?? false
        extraHeaders = try c.decodeIfPresent(String.self, forKey: .extraHeaders) ?? ""
        if !kind.isCLI, models.isEmpty, !model.trimmed.isEmpty { models = [model.trimmed] }
    }

    var secretAccount: String { id.uuidString }

    var displayModel: String {
        let m = model.trimmed
        if m.isEmpty {
            // CLI 留空时显示 CLI 实际会用的模型（读它自己的配置，或上次运行时报告的模型）
            if kind.isCLI, let id = ModelCatalog.cliDefaultModel(kind) { return ModelCatalog.title(for: id, kind: kind) }
            return "默认模型"
        }
        return kind.isCLI ? ModelCatalog.title(for: m, kind: kind) : title(forModel: m)
    }

    /// API 模型的显示名（拉取结果里有 display_name 时用它）
    func title(forModel id: String) -> String {
        availableModels.first { $0.id == id }?.title ?? id
    }

    /// 菜单里「交给 CLI 决定」那一项：知道 CLI 实际用哪个模型时直接写出来
    var cliDefaultTitle: String {
        if let m = ModelCatalog.cliDefaultModel(kind) {
            return "默认（\(ModelCatalog.title(for: m, kind: kind))）"
        }
        return "默认模型"
    }
    var cliExecutable: String { executablePath.trimmed.isEmpty ? kind.defaultExecutable : executablePath.trimmed }

    /// 输入框模型菜单里可切换的模型
    var modelOptions: [ModelOption] {
        let configured = model.trimmed
        var list: [ModelOption]
        if kind.isCLI {
            list = ModelCatalog.known(for: kind)
            if !configured.isEmpty, !list.contains(where: { $0.id == configured }) {
                list.insert(ModelOption(id: configured, title: configured), at: 0)
            }
        } else {
            var ids = models
            if !configured.isEmpty, !ids.contains(configured) { ids.insert(configured, at: 0) }
            list = ids.map { id in
                let remote = availableModels.first { $0.id == id }
                return ModelOption(id: id, title: title(forModel: id),
                                   efforts: remote?.efforts ?? [], defaultEffort: remote?.defaultEffort)
            }
        }
        var seen = Set<String>()
        return list.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
    }

    /// 当前默认模型的上下文上限
    var limits: ModelLimits { limits(for: model.trimmed) }

    func limits(for modelID: String) -> ModelLimits {
        if kind.isCLI { return ModelCatalog.limits(for: modelID, kind: kind) }
        if let l = modelLimits[modelID] { return l }
        return availableModels.first { $0.id == modelID }?.limits ?? ModelLimits()
    }

    /// 应用单个项目选择的模型和思考强度；`nil` / 空字符串表示沿用设置里的配置
    func resolved(model override: String?, effort: String? = nil) -> ProviderProfile {
        var copy = self
        if let override = override?.trimmed, !override.isEmpty { copy.model = override }
        copy.effort = effort?.trimmed ?? ""
        return copy
    }

    /// 当前模型的思考强度选项（Antigravity 的强度写在模型 ID 里，不走这里）
    var currentModelOption: ModelOption? {
        modelOptions.first { $0.id == model.trimmed }
    }

    var parsedHeaders: [String: String] {
        var result: [String: String] = [:]
        for line in extraHeaders.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].isEmpty { result[parts[0]] = parts[1] }
        }
        return result
    }

    static func claudeCode() -> ProviderProfile {
        ProviderProfile(name: "Claude", kind: .claudeCode)
    }

    static func codex() -> ProviderProfile {
        ProviderProfile(name: "Codex", kind: .codex)
    }

    static func antigravity() -> ProviderProfile {
        ProviderProfile(name: "Antigravity", kind: .antigravity)
    }

    static func anthropic() -> ProviderProfile {
        ProviderProfile(name: "Anthropic API", kind: .anthropicAPI,
                        baseURL: "https://api.anthropic.com")
    }
}

/// 第三方 API 预设（模型可在添加后点「拉取模型列表」更新）
/// 添加模型来源时的服务商预设。接口类型在详细设置里切换，每个服务商记录各类型对应的地址
nonisolated struct ProviderPreset: Identifiable, Sendable {
    var name: String
    /// 默认接口类型
    var kind: ProviderKind
    /// OpenAI 兼容地址（Chat Completions / Responses 共用）
    var openAIBase: String? = nil
    /// Anthropic Messages 兼容地址
    var anthropicBase: String? = nil
    /// Anthropic 端点是否用 Authorization: Bearer（国内兼容端点大多如此）
    var anthropicBearer = false

    var id: String { name }

    func baseURL(for kind: ProviderKind) -> String? {
        kind == .anthropicAPI ? anthropicBase : openAIBase
    }

    func makeProfile() -> ProviderProfile {
        ProviderProfile(name: name, kind: kind, baseURL: baseURL(for: kind) ?? "https://",
                        useBearerAuth: kind == .anthropicAPI && anthropicBearer)
    }

    static let all: [ProviderPreset] = [
        ProviderPreset(name: "Anthropic", kind: .anthropicAPI,
                       anthropicBase: "https://api.anthropic.com"),
        ProviderPreset(name: "OpenAI", kind: .openAIResponses,
                       openAIBase: "https://api.openai.com/v1"),
        ProviderPreset(name: "OpenRouter", kind: .openAICompatible,
                       openAIBase: "https://openrouter.ai/api/v1"),
        ProviderPreset(name: "DeepSeek", kind: .openAICompatible,
                       openAIBase: "https://api.deepseek.com/v1", anthropicBase: "https://api.deepseek.com/anthropic", anthropicBearer: true),
        ProviderPreset(name: "智谱 GLM", kind: .anthropicAPI,
                       openAIBase: "https://open.bigmodel.cn/api/paas/v4", anthropicBase: "https://open.bigmodel.cn/api/anthropic", anthropicBearer: true),
        ProviderPreset(name: "Kimi（Moonshot）", kind: .openAICompatible,
                       openAIBase: "https://api.moonshot.cn/v1", anthropicBase: "https://api.moonshot.cn/anthropic", anthropicBearer: true),
        ProviderPreset(name: "阿里云百炼（通义）", kind: .openAICompatible,
                       openAIBase: "https://dashscope.aliyuncs.com/compatible-mode/v1"),
        ProviderPreset(name: "硅基流动", kind: .openAICompatible,
                       openAIBase: "https://api.siliconflow.cn/v1"),
        ProviderPreset(name: "Ollama（本地）", kind: .openAICompatible,
                       openAIBase: "http://localhost:11434/v1")
    ]

    /// 自定义服务商：默认 OpenAI Chat Completions，类型和地址在详细设置里改
    static let custom = ProviderPreset(name: "自定义", kind: .openAICompatible, openAIBase: "https://")

    /// 切换接口类型时：如果 Base URL 是某个服务商的已知地址，换成该服务商在新类型下的地址
    static func switching(baseURL: String, to kind: ProviderKind) -> (url: String, bearer: Bool)? {
        func norm(_ s: String) -> String {
            var t = s.trimmed
            while t.hasSuffix("/") { t.removeLast() }
            return t.lowercased()
        }
        let current = norm(baseURL)
        guard let preset = all.first(where: { p in
            [p.openAIBase, p.anthropicBase].compactMap { $0 }.contains { norm($0) == current }
        }), let url = preset.baseURL(for: kind) else { return nil }
        return (url, kind == .anthropicAPI && preset.anthropicBearer)
    }
}

/// 输入框里的模型选择：模型来源 + 可选的模型覆盖（nil 表示用来源里配置的模型）
nonisolated struct ModelChoice: Equatable, Sendable {
    var providerID: UUID?
    var model: String?
    /// 思考强度；nil 表示用模型 / CLI 的默认强度
    var effort: String? = nil
}

nonisolated struct AppSettings: Codable, Sendable {
    var defaultProviderID: UUID?
    var defaultDesignSystemID: UUID?
    /// 主题色（ThemeColor.rawValue），为空时用默认的陶土橙
    var accentTheme: String?
    /// 旧版本的自动检查偏好，首次启动 Sparkle 时迁移。
    var automaticallyChecksForUpdates: Bool?
}
