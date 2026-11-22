import SwiftUI
import AppKit

enum Theme {
    /// 当前主题色：在视图 body 里读取会自动跟随设置里的切换刷新
    static var accent: Color { ThemeStore.shared.choice.color }
    /// 对话正文：比系统默认正文（13pt）大一号
}

enum WorkspaceMotion {
    static let hover = Animation.easeOut(duration: 0.12)
    static let panel = Animation.easeOut(duration: 0.18)
}

// MARK: - 非玻璃按钮样式

/// 选择类按钮（主页的设计类型）：选中为主色实心，未选中为浅底细边
struct ChipButtonStyle: ButtonStyle {
    var isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration, isSelected: isSelected)
    }

    private struct ChipBody: View {
        let configuration: Configuration
        let isSelected: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.body.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background {
                    Capsule().fill(isSelected
                                   ? AnyShapeStyle(Theme.accent)
                                   : AnyShapeStyle(hovering ? .quaternary : .quinary))
                }
                .overlay {
                    if !isSelected {
                        Capsule().strokeBorder(.separator, lineWidth: 0.5)
                    }
                }
                .opacity(configuration.isPressed ? 0.75 : 1)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(.snappy(duration: 0.15), value: hovering)
        }
    }
}

/// 图标按钮：默认浅主色底 + 主色图标（附件、停止），与旁边的设计系统 / 模型菜单视觉一致；
/// `prominent` 为主色实心 + 白色图标（发送），禁用时变浅
struct SoftIconButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        SoftIconBody(configuration: configuration, prominent: prominent)
    }

    private struct SoftIconBody: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.controlSize) private var controlSize
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let small = controlSize == .small || controlSize == .mini
            let fill = prominent
                ? Theme.accent.opacity(hovering && isEnabled ? 0.9 : 1)
                : Theme.accent.opacity(hovering ? 0.14 : 0.08)
            configuration.label
                .font(small ? .callout : .body)
                .foregroundStyle(prominent ? Color.white : Theme.accent)
                .frame(width: small ? 26 : 30, height: small ? 22 : 26)
                .background(fill, in: .rect(cornerRadius: 7))
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
                .contentShape(.rect(cornerRadius: 7))
                .onHover { hovering = $0 }
                .animation(.snappy(duration: 0.15), value: hovering)
        }
    }
}

/// 输入框里的次要图标按钮（附件）：无底色的灰色图标，悬停时出现浅灰圆底
struct ComposerIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ComposerIconBody(configuration: configuration)
    }

    private struct ComposerIconBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.07 : 0)))
                .contentShape(Circle())
                .onHover { hovering = $0 }
                .animation(.snappy(duration: 0.15), value: hovering)
        }
    }
}

/// 发送 / 停止按钮：圆形。可发送时深色实心 + 白色箭头；不可发送时浅灰底 + 灰色箭头；
/// `stop` 为深色实心圆 + 方块（深色模式下自动反色）
struct SendButtonStyle: ButtonStyle {
    var stop = false
    /// 带文字的胶囊（主页「开始设计」），颜色规则与圆形发送按钮相同
    var wide = false

    func makeBody(configuration: Configuration) -> some View {
        SendBody(configuration: configuration, stop: stop, wide: wide)
    }

    private struct SendBody: View {
        let configuration: Configuration
        let stop: Bool
        let wide: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            // 不用主题色：可发送 / 停止都是深色实心（深色模式下反色），不可发送时浅灰
            let active = stop || isEnabled
            let fill: Color = active ? .primary : Color.primary.opacity(0.08)
            let ink: Color = active ? Color(nsColor: .textBackgroundColor) : Color.secondary.opacity(0.7)
            configuration.label
                .font(.system(size: stop ? 10 : 13, weight: wide ? .semibold : .bold))
                .foregroundStyle(ink)
                .padding(.horizontal, wide ? 14 : 0)
                .frame(width: wide ? nil : 28, height: wide ? 32 : 28)
                .background(Capsule().fill(fill))
                .opacity(configuration.isPressed ? 0.75 : (hovering && isEnabled ? 0.9 : 1))
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(.snappy(duration: 0.15), value: isEnabled)
        }
    }
}

/// 输入框卡片：白底 + 细灰线描边 + 淡阴影；聚焦时描边略微加深（不用主题色）
struct ComposerCard: ViewModifier {
    var focused = false
    var cornerRadius: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(Color(nsColor: .textBackgroundColor)))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.primary.opacity(focused ? 0.18 : 0.1), lineWidth: 1)
            }
            .shadow(color: .black.opacity(focused ? 0.07 : 0.045), radius: 10, y: 3)
            .animation(.snappy(duration: 0.15), value: focused)
    }
}

extension View {
    func composerCard(focused: Bool = false, cornerRadius: CGFloat = 18) -> some View {
        modifier(ComposerCard(focused: focused, cornerRadius: cornerRadius))
    }
}

/// 输入框里菜单的标签：灰色文字 + 小箭头，悬停时出现浅灰胶囊底
struct ComposerChipLabel<Content: View>: View {
    var idleTint: Color? = nil
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            content
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
        }
        .font(.callout)
        .lineLimit(1)
        .foregroundStyle(hovering ? Color.primary : idleTint ?? Color.secondary)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Capsule().fill(Color.primary.opacity(hovering ? 0.07 : 0)))
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.15), value: hovering)
    }
}

extension View {
    /// 用于标签是 ComposerChipLabel 的菜单：去掉系统按钮外观和自带箭头
    func composerMenuStyle(fitsContent: Bool = true) -> some View {
        self.menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: fitsContent, vertical: true)
    }
}

/// 主操作按钮（开始设计）：主色实心胶囊，禁用时变浅
struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryBody(configuration: configuration)
    }

    private struct PrimaryBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(Capsule().fill(Theme.accent))
                .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
                .contentShape(Capsule())
        }
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmed.replacingOccurrences(of: "#", with: "")
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt64(s.prefix(6), radix: 16) ?? 0
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255,
                  opacity: 1)
    }

    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X",
                      Int((ns.redComponent * 255).rounded()),
                      Int((ns.greenComponent * 255).rounded()),
                      Int((ns.blueComponent * 255).rounded()))
    }
}

/// 点阵画布背景
struct CanvasBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { ctx, size in
            let spacing: CGFloat = 22
            let dot = Path(ellipseIn: CGRect(x: 0, y: 0, width: 1.6, height: 1.6))
            var y: CGFloat = spacing / 2
            while y < size.height {
                var x: CGFloat = spacing / 2
                while x < size.width {
                    ctx.fill(dot.offsetBy(dx: x, dy: y), with: .color(.secondary.opacity(0.3)))
                    x += spacing
                }
                y += spacing
            }
        }
        // 对齐 macOS 27 的底色，避免系统背景色随版本变化而改变卡片对比度。
        .background(colorScheme == .dark ? Color(hex: "#282828") : Color(hex: "#F6F6F6"))
        .ignoresSafeArea()
    }
}

/// 附件缩略图条
struct AttachmentStrip: View {
    @Binding var attachments: [ChatAttachment]
    var provider: ProviderKind?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { a in
                    VStack(alignment: .leading, spacing: 2) {
                        ZStack(alignment: .topTrailing) {
                            AttachmentThumbnail(attachment: a, size: 56, removable: true)
                            Button {
                                attachments.removeAll { $0.id == a.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .padding(3)
                            .accessibilityLabel("移除 \(a.filename)")
                        }
                        if let provider {
                            let readable = a.isImage || a.documentText != nil || provider.isCLI
                            Text(a.documentText != nil ? "已读取" : readable ? "已添加" : "模型只收到文件名")
                                .font(.caption2)
                                .foregroundStyle(readable ? Color.secondary : .orange)
                        }
                    }
                }
            }
        }
    }
}

private struct AttachmentThumbnail: View {
    let attachment: ChatAttachment
    let size: CGFloat
    var removable = false

    var body: some View {
        if attachment.isImage, let img = NSImage(data: attachment.data) {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .background(.quaternary)
                .clipShape(.rect(cornerRadius: 10))
                .accessibilityLabel(attachment.filename)
                .help(attachment.filename)
        } else {
            Label(attachment.filename, systemImage: attachment.documentText == nil ? "doc" : "doc.text")
                .font(.caption)
                .lineLimit(1)
                .padding(.leading, 9)
                .padding(.trailing, removable ? 22 : 9)
                .padding(.vertical, 10)
                .frame(maxWidth: 154, alignment: .leading)
                .background(.quaternary, in: .rect(cornerRadius: 10))
                .help(attachment.filename)
        }
    }
}

/// 只读附件网格（消息中）
struct AttachmentThumbs: View {
    let attachments: [ChatAttachment]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(attachments) { a in
                AttachmentThumbnail(attachment: a, size: 72)
            }
        }
    }
}

struct AttachButton: View {
    var onPick: ([ChatAttachment]) -> Void
    var body: some View {
        Button {
            let picked = AttachmentImporter.pick()
            if !picked.isEmpty { onPick(picked) }
        } label: {
            Image(systemName: "paperclip")
        }
        .buttonStyle(ComposerIconButtonStyle())
        .help("添加附件，也可在输入框按 ⌘V 粘贴文件或图片")
        .accessibilityLabel("添加参考附件")
    }
}

/// 模型选择菜单：每个模型来源一个子菜单，可直接切换具体模型
struct ProviderMenu: View {
    @Environment(AppModel.self) private var app
    @Binding var selection: ModelChoice
    var showsLogo = true
    var showsProviderName = true
    var maximumTitleWidth: CGFloat? = nil

    var body: some View {
        menu {
            ComposerChipLabel {
                if showsLogo {
                    ProviderLogo(current, size: 14)
                        .accessibilityHidden(true)
                }
                Text(showsProviderName ? currentTitle : modelTitle)
                    .lineLimit(1)
                    .frame(maxWidth: maximumTitleWidth, alignment: .leading)
            }
        }
        .composerMenuStyle()
        .help(current == nil ? "选择用于生成设计的模型" : currentTitle)
    }

    private var currentTitle: String {
        current.map { "\($0.name) · \(modelTitle)" } ?? modelTitle
    }

    private var modelTitle: String {
        guard let current else { return "选择模型" }
        let effort = activeEffort.map { " · " + Effort.title($0) } ?? ""
        return "\(current.resolved(model: activeModel).displayModel)\(effort)"
    }

    private func menu<L: View>(@ViewBuilder label: () -> L) -> some View {
        Menu {
            ForEach(app.providers) { p in
                Menu {
                    // CLI 来源未配置模型时，「默认模型」表示交给 CLI 决定
                    if p.model.trimmed.isEmpty {
                        option(p, model: nil, title: p.cliDefaultTitle)
                    }
                    // 同一模型的不同思考强度合并成一项，强度在子菜单里选（参考 Antigravity 的模型菜单）
                    ForEach(ModelFamily.group(p.modelOptions), id: \.self) { family in
                        if family.isSingle && !family.usesEffortParam {
                            option(p, model: family.variants[0].option.id, title: family.variants[0].option.title)
                        } else {
                            familyMenu(p, family)
                        }
                    }
                    if !p.kind.isCLI && p.modelOptions.isEmpty {
                        Text("尚未选择模型，请在设置中拉取")
                    }
                } label: {
                    // macOS 菜单不显示 Label 图标，用文字标出当前来源
                    if let image = ProviderBrand.detect(p).flatMap({ $0.menuImage() }) {
                        Label { Text(p.id == current?.id ? "\(p.name)（当前）" : p.name) } icon: { Image(nsImage: image) }
                    } else {
                        Text(p.id == current?.id ? "\(p.name)（当前）" : p.name)
                    }
                }
            }
            Divider()
            OpenSettingsButton {
                Label("管理模型与账号…", systemImage: "gearshape")
            }
        } label: {
            label()
        }
    }

    /// 一个模型的思考强度子菜单。标签显示当前（或默认）强度；菜单的勾选列只给 Toggle 用，
    /// 子菜单标签放不进去，所以与 Antigravity 一样把勾放在强度后面
    private func familyMenu(_ p: ProviderProfile, _ family: ModelFamily) -> some View {
        let selected = family.variants.first { isSelected(p, family, $0) }
        let shown = selected ?? family.defaultVariant
        return Menu {
            ForEach(family.variants, id: \.self) { v in
                Toggle(v.title, isOn: Binding(
                    get: { isSelected(p, family, v) },
                    set: { _ in choose(p, family, v) }
                ))
            }
        } label: {
            Text("\(family.name)  \(Text(shown.title).foregroundStyle(.secondary))\(selected != nil ? "  ✓" : "")")
        }
    }

    /// 选中设置里已配置的那个模型时不记录覆盖，之后改设置也能跟着变
    private func storedModel(_ p: ProviderProfile, _ model: String?) -> String? {
        (model == nil || model == p.model.trimmed) ? nil : model
    }

    private func isModelSelected(_ p: ProviderProfile, _ model: String?) -> Bool {
        let effective = (storedModel(p, model) ?? p.model).trimmed
        return p.id == current?.id && (activeModel ?? p.model).trimmed == effective
    }

    private func isSelected(_ p: ProviderProfile, _ family: ModelFamily, _ v: ModelFamily.Variant) -> Bool {
        guard isModelSelected(p, v.option.id) else { return false }
        guard family.usesEffortParam else { return true }
        return (activeEffort ?? family.defaultEffort) == v.effort
    }

    /// 选默认强度时不记录，之后 CLI / 服务商的默认变了也跟着变
    private func choose(_ p: ProviderProfile, _ family: ModelFamily, _ v: ModelFamily.Variant) {
        let effort = family.usesEffortParam && v.effort != family.defaultEffort ? v.effort : nil
        selection = ModelChoice(providerID: p.id, model: storedModel(p, v.option.id), effort: effort)
    }

    private func option(_ p: ProviderProfile, model: String?, title: String) -> some View {
        // 菜单里的 Toggle 会渲染成系统原生的勾选项
        Toggle(title, isOn: Binding(
            get: { isModelSelected(p, model) },
            set: { _ in selection = ModelChoice(providerID: p.id, model: storedModel(p, model)) }
        ))
    }

    private var current: ProviderProfile? { app.provider(for: selection.providerID) ?? app.defaultProvider }

    /// 当前生效的模型覆盖；选择的来源已不存在而回退到默认来源时不沿用覆盖
    private var activeModel: String? {
        app.provider(for: selection.providerID) == nil ? nil : selection.model
    }

    private var activeEffort: String? {
        app.provider(for: selection.providerID) == nil ? nil : selection.effort
    }
}

/// 设计系统选择菜单
struct DesignSystemMenu: View {
    @Environment(AppModel.self) private var app
    @Binding var selection: UUID?
    /// 紧凑样式（输入框里）：灰色文字 + 小箭头
    var compact = false

    var body: some View {
        if compact {
            menu { ComposerChipLabel { current } }
                .composerMenuStyle()
                .help("生成时遵循的设计系统")
        } else {
            menu { current }
                .menuIndicator(.visible)
                .fixedSize()
        }
    }

    @ViewBuilder private var current: some View {
        HStack(spacing: 6) {
            if let ds = app.designSystem(for: selection) {
                HStack(spacing: -4) {
                    ForEach(ds.colors.prefix(3)) { c in
                        Circle().fill(Color(hex: c.hex)).frame(width: 12, height: 12)
                            .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1))
                    }
                }
                Text(ds.name).lineLimit(1)
            } else {
                Image(systemName: "paintpalette")
                Text("设计系统")
            }
        }
    }

    private func menu<L: View>(@ViewBuilder label: () -> L) -> some View {
        Menu {
            Button {
                selection = nil
            } label: {
                Label("不使用设计系统", systemImage: selection == nil ? "checkmark" : "circle.dashed")
            }
            Divider()
            ForEach(app.designSystems) { ds in
                Button {
                    selection = ds.id
                } label: {
                    Label(ds.name, systemImage: ds.id == selection ? "checkmark" : "paintpalette")
                }
            }
        } label: {
            label()
        }
    }
}

struct AuthStateBadge: View {
    let state: CLIAuthService.State

    var body: some View {
        HStack(spacing: 6) {
            switch state {
            case .checking:
                ProgressView().controlSize(.mini)
            default:
                Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(state.label).font(.callout).lineLimit(1)
        }
    }

    private var color: Color {
        switch state {
        case .loggedIn: .green
        case .loggedOut: .orange
        case .notInstalled, .failed, .broken: .red
        default: .gray
        }
    }
}

/// 项目卡片缩略图
struct ProjectThumbnail: View {
    @Environment(AppModel.self) private var app
    let project: Project

    var body: some View {
        Color.clear
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay(alignment: .top) {
                if let img = app.thumbnail(for: project.id) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        LinearGradient(colors: [Theme.accent.opacity(0.25), Theme.accent.opacity(0.06)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: project.kind.symbol)
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
            .clipped()
    }
}

// MARK: - 打开设置窗口

/// 替代 `SettingsLink`：设置改为普通 Window 场景后，用 openWindow 打开
struct OpenSettingsButton<Label: View>: View {
    @Environment(\.openWindow) private var openWindow
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button { openWindow(id: SettingsWindow.id) } label: { label() }
    }
}
