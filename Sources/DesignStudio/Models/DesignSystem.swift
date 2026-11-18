import Foundation

nonisolated struct ColorToken: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var hex: String
}

nonisolated struct DesignSystem: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var summary: String
    var colors: [ColorToken]
    var headingFont: String
    var bodyFont: String
    var monoFont: String
    var cornerRadius: Double
    var spacingUnit: Double
    var guidelines: String

    /// 注入到系统提示词中的描述
    var promptDescription: String {
        var lines: [String] = []
        lines.append("Design system \"\(name)\" — \(summary)")
        lines.append("Color tokens (expose each as a CSS custom property on :root):")
        for c in colors {
            let varName = "--" + c.name.lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .filter { $0.isLetter || $0.isNumber || $0 == "-" }
            lines.append("  - \(c.name): \(c.hex)  (\(varName))")
        }
        lines.append("Typography: headings \"\(headingFont)\", body \"\(bodyFont)\", mono \"\(monoFont)\". "
                     + "Load them from Google Fonts when available; for Chinese text fall back to \"Noto Sans SC\", \"PingFang SC\".")
        lines.append("Corner radius: \(Int(cornerRadius))px. Spacing unit: \(Int(spacingUnit))px (use multiples).")
        if !guidelines.trimmed.isEmpty {
            lines.append("Brand guidelines:\n\(guidelines.trimmed)")
        }
        lines.append("Follow this design system strictly unless the user explicitly overrides it.")
        return lines.joined(separator: "\n")
    }

    static func blank() -> DesignSystem {
        DesignSystem(
            name: "新设计系统",
            summary: "描述品牌气质",
            colors: [
                ColorToken(name: "Primary", hex: "#3B82F6"),
                ColorToken(name: "Background", hex: "#FFFFFF"),
                ColorToken(name: "Surface", hex: "#F4F4F5"),
                ColorToken(name: "Text", hex: "#18181B")
            ],
            headingFont: "Inter", bodyFont: "Inter", monoFont: "JetBrains Mono",
            cornerRadius: 10, spacingUnit: 8, guidelines: ""
        )
    }

    static let builtIns: [DesignSystem] = [
        DesignSystem(
            name: "暖陶 Warm Clay",
            summary: "温暖、克制、有人文气质的编辑风格",
            colors: [
                ColorToken(name: "Primary", hex: "#D97757"),
                ColorToken(name: "Background", hex: "#FAF9F5"),
                ColorToken(name: "Surface", hex: "#F0EEE6"),
                ColorToken(name: "Text", hex: "#141413"),
                ColorToken(name: "Muted", hex: "#73726C"),
                ColorToken(name: "Accent", hex: "#6A9BCC"),
                ColorToken(name: "Success", hex: "#788C5D")
            ],
            headingFont: "Fraunces", bodyFont: "Inter", monoFont: "JetBrains Mono",
            cornerRadius: 12, spacingUnit: 8,
            guidelines: """
            - 大量留白，版面呼吸感强；衬线标题搭配无衬线正文
            - 避免高饱和渐变与霓虹色；阴影轻柔
            - 插画使用简洁线条与有机形状
            """
        ),
        DesignSystem(
            name: "极简黑白 Mono",
            summary: "高对比度、精确、功能优先的现代界面",
            colors: [
                ColorToken(name: "Primary", hex: "#111111"),
                ColorToken(name: "Background", hex: "#FFFFFF"),
                ColorToken(name: "Surface", hex: "#F4F4F5"),
                ColorToken(name: "Text", hex: "#09090B"),
                ColorToken(name: "Muted", hex: "#71717A"),
                ColorToken(name: "Accent", hex: "#2563EB")
            ],
            headingFont: "Inter", bodyFont: "Inter", monoFont: "IBM Plex Mono",
            cornerRadius: 8, spacingUnit: 4,
            guidelines: """
            - 1px 细边框与网格对齐；仅在关键操作上使用强调色
            - 字重层级清晰：标题 600–700，正文 400
            """
        ),
        DesignSystem(
            name: "暗夜科技 Midnight",
            summary: "深色、发光、面向开发者与 AI 产品",
            colors: [
                ColorToken(name: "Primary", hex: "#7C5CFF"),
                ColorToken(name: "Background", hex: "#0B0F19"),
                ColorToken(name: "Surface", hex: "#141A2A"),
                ColorToken(name: "Text", hex: "#E6E8EE"),
                ColorToken(name: "Muted", hex: "#8B93A7"),
                ColorToken(name: "Accent", hex: "#22D3EE")
            ],
            headingFont: "Space Grotesk", bodyFont: "Inter", monoFont: "JetBrains Mono",
            cornerRadius: 14, spacingUnit: 8,
            guidelines: """
            - 深色背景上用细微的径向光晕和玻璃质感卡片
            - 代码片段、终端等开发者元素可作为视觉母题
            """
        ),
        DesignSystem(
            name: "清新自然 Fresh",
            summary: "明亮、友好、生活方式类品牌",
            colors: [
                ColorToken(name: "Primary", hex: "#3E8E5E"),
                ColorToken(name: "Background", hex: "#F7FAF5"),
                ColorToken(name: "Surface", hex: "#FFFFFF"),
                ColorToken(name: "Text", hex: "#1F3A2E"),
                ColorToken(name: "Muted", hex: "#6B7F72"),
                ColorToken(name: "Accent", hex: "#F2C94C")
            ],
            headingFont: "DM Serif Display", bodyFont: "DM Sans", monoFont: "DM Mono",
            cornerRadius: 18, spacingUnit: 8,
            guidelines: """
            - 圆润的形状与柔和的投影；可使用叶片、阳光等有机图形
            - 语气亲切，按钮使用胶囊形
            """
        )
    ]
}
