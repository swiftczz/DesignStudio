import Foundation
import CoreGraphics

// MARK: - 项目类型

nonisolated enum ProjectKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case prototype, slides, landing, wireframe, poster, component

    var id: String { rawValue }

    var title: String {
        switch self {
        case .prototype: "交互设计"
        case .slides: "幻灯片"
        case .landing: "落地页"
        case .wireframe: "线框图"
        case .poster: "海报 / 社媒图"
        case .component: "组件设计"
        }
    }

    var symbol: String {
        switch self {
        case .prototype: "cursorarrow.rays"
        case .slides: "rectangle.on.rectangle.angled"
        case .landing: "globe"
        case .wireframe: "square.dashed"
        case .poster: "photo.artframe"
        case .component: "square.grid.3x3.square"
        }
    }

    var placeholder: String {
        switch self {
        case .prototype: "描述你想设计的东西，例如：独立开发者工具的官网首页、记账 App 的三个页面、季度业务汇报幻灯片…"
        case .slides: "例如：10 页的产品发布会演示，主题是 AI 笔记应用的年度更新"
        case .landing: "例如：一款面向独立开发者的文档协作工具的官网首页"
        case .wireframe: "例如：电商 App 下单流程的低保真线框图"
        case .poster: "例如：周末咖啡市集的竖版海报，复古印刷风格"
        case .component: "例如：一套按钮、输入框和卡片的组件规范页"
        }
    }

    /// 主页上提供的类型（其余类型仅为兼容旧项目保留）
    static let homeKinds: [ProjectKind] = [.prototype, .slides]

    /// 新画板的默认尺寸（CSS 像素）
    var artboardSize: CGSize {
        switch self {
        case .prototype, .wireframe: CGSize(width: 390, height: 844)
        case .slides: CGSize(width: 1920, height: 1080)
        case .landing: CGSize(width: 1440, height: 900)
        case .poster: CGSize(width: 1080, height: 1350)
        case .component: CGSize(width: 1200, height: 800)
        }
    }

    /// 交给模型的类型说明（英文对模型更稳定）
    var guidance: String {
        switch self {
        case .prototype:
            """
            First work out WHAT the user wants to design, then choose the artboard size for that medium. Do not \
            assume a phone app — read the request carefully:
            - Mobile app (App, iOS, Android, 小程序, "手机上"): one artboard per screen, 390×844. Tablet app: 1180×820.
            - Website (官网, landing page, 落地页, 网站, 博客, 作品集, marketing / product page): desktop web, width 1440. \
            A scrolling page is ONE artboard per page whose height fits the whole page (typically 2400–5000) so the \
            full page is visible on the canvas; add a 390-wide mobile version only if the user asks for responsive.
            - Web app / SaaS / dashboard / admin / 后台 / 管理系统 / 控制台 / CRM / internal tool: one artboard per \
            screen at 1440×900 (app shell with sidebar or top bar; panels scroll inside).
            - Desktop app (macOS / Windows software, 桌面客户端): 1280×800 window content.
            - Slides / presentation / PPT / 演示 / 汇报 / 路演 / deck: every slide is its OWN artboard of exactly \
            1920×1080, 6–12 slides by default, names like "01 封面", "02 问题"; no navigation code or slide counters.
            - Poster / social graphic / 海报 / 封面 / 朋友圈 / 小红书: one artboard, 1080×1350 (or 1080×1920 for \
            stories, 1080×1080 square) unless a size is given. Email: 600 wide. Other formats: pick the real-world size.
            - If the user gives sizes, devices or a platform, follow them exactly.
            - If the medium is genuinely unclear, pick the most plausible one from the wording and say which medium \
            and size you chose in your opening sentence.
            - When modifying an existing design, keep the medium and artboard sizes already on the canvas unless the \
            user asks to change them; new screens match the existing artboards.

            Design each key screen, page, state or slide as its OWN artboard — typically 2–5 for products. Each \
            artboard shows exactly one screen filling the whole artboard. Never put several screens or slides side by \
            side inside one wide artboard — e.g. "three pages" means three separate artboards. In-screen interactions \
            (tabs, toggles, inputs, menus) may use vanilla JS. Use realistic data and keep design tokens identical \
            across artboards.
            """
        case .slides:
            """
            Presentation deck. Every slide is its OWN artboard of exactly 1920×1080: the <body> IS the slide \
            (width:1920px;height:1080px;margin:0;overflow:hidden). No scaling wrappers, no slide navigation code, \
            no slide counters. Default to 6–12 slides, one idea per slide, strong typographic hierarchy, charts as \
            inline SVG, consistent theme across slides. Name artboards like "01 封面", "02 问题", …. Never put several \
            slides inside one artboard.
            """
        case .landing:
            """
            Marketing landing page: hero, social proof, features, pricing or CTA, FAQ and footer. Fully responsive, \
            tasteful scroll-reveal animations, compelling realistic copy.
            """
        case .wireframe:
            """
            Low-fidelity wireframe: grayscale only, simple boxes, placeholder labels and short annotations explaining \
            intent. Prioritise layout and information hierarchy over styling. Multiple screens may be laid out side by \
            side with labels.
            """
        case .poster:
            """
            Single-artboard visual (poster / social graphic). Use a fixed artboard (default 1080×1350 unless the user \
            specifies a size) centered and scaled to fit the viewport. Bold composition, expressive typography, \
            CSS/SVG artwork — do not depend on external photos.
            """
        case .component:
            """
            Component specification sheet: show the requested component(s) with all variants and states (default, \
            hover, active, focus, disabled, sizes) on a neat, labelled spec layout.
            """
        }
    }
}

// MARK: - 聊天

nonisolated enum ChatRole: String, Codable, Sendable {
    case user, assistant
}

nonisolated struct ChatAttachment: Codable, Identifiable, Sendable, Equatable {
    var id = UUID()
    var filename: String
    var mimeType: String
    var data: Data

    var fileExtension: String {
        switch mimeType {
        case "image/png": "png"
        case "image/gif": "gif"
        case "image/webp": "webp"
        default: "jpg"
        }
    }
}

nonisolated struct ChatMessage: Codable, Identifiable, Sendable {
    var id = UUID()
    var role: ChatRole
    var text: String
    var attachments: [ChatAttachment] = []
    var comments: [CanvasComment] = []
    var createdAt = Date()
    var versionID: UUID?
    var providerName: String?
    /// 模型的思考过程（思维链摘要），只用于展示，不会回传给模型
    var thinking: String?
    var errorText: String?
    var wasStopped = false
    /// 通过画布上的「询问 AI」发送时，针对的画板 / 元素
    var target: MessageTarget?
}

/// 用户消息针对的修改对象：显示在消息上方，点击可在画布上重新选中
nonisolated struct MessageTarget: Codable, Sendable, Equatable {
    var artboardID: UUID
    var artboardName: String
    /// 元素种类（ElementKind），为空表示针对整个画板
    var elementKind: String?
    /// 元素的显示名（图层名 / 文字 / 标签名）
    var elementName: String?
    /// 用于重新定位元素的 CSS 选择器
    var selector: String?

    var isElement: Bool { elementKind != nil }

    /// 写进历史对话的说明，例如：画板「冥想计时」中的按钮「开始或暂停」
    var promptDescription: String {
        guard let kind = elementKind else { return "画板「\(artboardName)」" }
        return "画板「\(artboardName)」中的\(ElementKind.title(kind))\(elementName ?? "")"
    }
}

// MARK: - 版本 & 批注

nonisolated struct DesignVersion: Codable, Identifiable, Sendable {
    var id = UUID()
    var number: Int
    /// 旧版本：单个 HTML；新版本为空字符串，内容在 document 中
    var html: String = ""
    /// 整个设计文档（所有页面 / 画板）的快照
    var document: DesignDocument?
    var summary: String
    var createdAt = Date()
    var truncated = false
}

nonisolated struct CanvasComment: Codable, Identifiable, Sendable, Equatable {
    var id = UUID()
    var selector: String
    var tag: String
    var snippet: String
    var note: String
    /// 所在画板名称
    var artboardName: String?
    var resolved = false
    var createdAt = Date()

    /// 发给模型的描述
    var promptLine: String {
        let text = snippet.isEmpty ? "" : "，当前文字：“\(snippet)”"
        let board = artboardName.map { "画板「\($0)」中的" } ?? ""
        return "\(board)元素 `\(selector)`（<\(tag)>\(text)）：\(note)"
    }
}

// MARK: - 项目

nonisolated struct Project: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var kind: ProjectKind
    var createdAt = Date()
    var updatedAt = Date()
    var messages: [ChatMessage] = []
    var versions: [DesignVersion] = []
    var currentVersionID: UUID?
    var comments: [CanvasComment] = []
    var designSystemID: UUID?
    var providerID: UUID?
    /// 本项目选择的模型，覆盖模型来源里配置的模型；nil 表示沿用来源配置
    var model: String?
    /// 本项目选择的思考强度；nil 表示用默认强度
    var effort: String?
    /// 当前的设计文档（画布上看到并可直接编辑的内容）；旧项目为 nil，读取时从当前版本迁移
    var document: DesignDocument?

    /// 当前设计文档：优先用已保存的文档，其次由当前版本迁移
    var workingDocument: DesignDocument {
        if let document { return document }
        if let v = currentVersion { return v.document ?? DesignDocument.migrated(html: v.html, kind: kind) }
        return DesignDocument()
    }

    var hasDesign: Bool { !workingDocument.isEmpty }

    var currentVersion: DesignVersion? {
        if let currentVersionID, let v = versions.first(where: { $0.id == currentVersionID }) {
            return v
        }
        return versions.last
    }

    static func suggestedName(from prompt: String) -> String {
        let line = prompt
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if line.isEmpty { return "未命名设计" }
        return line.count > 24 ? String(line.prefix(24)) + "…" : line
    }
}

// MARK: - 可调参数（Tweaks）

/// 由模型在 HTML 中通过 <script type="application/json" id="ds-tweaks"> 暴露的可调参数
nonisolated struct TweakControl: Codable, Identifiable, Hashable, Sendable {
    var variable: String
    var label: String
    var type: String          // color | range | select | text
    var value: String
    var min: Double?
    var max: Double?
    var step: Double?
    var unit: String?
    var options: [String]?

    var id: String { variable }

    enum CodingKeys: String, CodingKey {
        case variable = "var", label, type, value, min, max, step, unit, options
    }

    init(variable: String, label: String, type: String, value: String,
         min: Double? = nil, max: Double? = nil, step: Double? = nil,
         unit: String? = nil, options: [String]? = nil) {
        self.variable = variable; self.label = label; self.type = type; self.value = value
        self.min = min; self.max = max; self.step = step; self.unit = unit; self.options = options
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        variable = try c.decode(String.self, forKey: .variable)
        label = (try? c.decode(String.self, forKey: .label)) ?? variable
        type = (try? c.decode(String.self, forKey: .type)) ?? "text"
        if let s = try? c.decode(String.self, forKey: .value) {
            value = s
        } else if let d = try? c.decode(Double.self, forKey: .value) {
            value = TweakControl.format(d)
        } else {
            value = ""
        }
        min = try? c.decode(Double.self, forKey: .min)
        max = try? c.decode(Double.self, forKey: .max)
        step = try? c.decode(Double.self, forKey: .step)
        unit = try? c.decode(String.self, forKey: .unit)
        options = try? c.decode([String].self, forKey: .options)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(variable, forKey: .variable)
        try c.encode(label, forKey: .label)
        try c.encode(type, forKey: .type)
        if type == "range", let d = Double(value) {
            try c.encode(d, forKey: .value)
        } else {
            try c.encode(value, forKey: .value)
        }
        try c.encodeIfPresent(min, forKey: .min)
        try c.encodeIfPresent(max, forKey: .max)
        try c.encodeIfPresent(step, forKey: .step)
        try c.encodeIfPresent(unit, forKey: .unit)
        try c.encodeIfPresent(options, forKey: .options)
    }

    /// 原始值 → CSS 值（range 自动加单位）
    func cssValue(_ raw: String) -> String {
        type == "range" ? raw + (unit ?? "") : raw
    }

    static func format(_ d: Double) -> String {
        d.rounded() == d ? String(Int(d)) : String(format: "%.2f", d)
    }
}

nonisolated extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
