import SwiftUI

/// 选中对象的属性面板：画板（名称 / 尺寸 / 位置）或元素（尺寸、布局、文字、外观…）
struct PropertiesView: View {
    @Bindable var session: ProjectSession

    var body: some View {
        if let sel = session.selection, let board = session.displayedDocument.artboard(sel.artboardID) {
            if sel.elementID == nil {
                ArtboardProperties(session: session, board: board)
            } else if let p = session.selectedProps, p.id == sel.elementID {
                ElementProperties(session: session, props: p)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ContentUnavailableView("未选中任何内容", systemImage: "cursorarrow.click.2",
                                   description: Text("点击画布中的任意元素，在这里查看和修改它的属性。"))
        }
    }
}

// MARK: - 画板属性

private struct ArtboardProperties: View {
    @Bindable var session: ProjectSession
    let board: Artboard

    var body: some View {
        Form {
            Section("画板") {
                CommitField("名称", value: board.name) { session.renameArtboard(board.id, to: $0) }
                PairRow {
                    NumberField("W", value: board.width) { v in session.resizeArtboard(board.id, width: max(v, 20)) }
                    NumberField("H", value: board.height) { v in session.resizeArtboard(board.id, height: max(v, 20)) }
                }
                PairRow {
                    NumberField("X", value: board.x) { v in session.updateArtboard(board.id) { $0.x = v } }
                    NumberField("Y", value: board.y) { v in session.updateArtboard(board.id) { $0.y = v } }
                }
                Menu("常用尺寸") {
                    ForEach(Self.presets, id: \.0) { name, size in
                        Button("\(name)  \(Int(size.width))×\(Int(size.height))") {
                            session.resizeArtboard(board.id, width: size.width, height: size.height)
                        }
                    }
                }
            }
            Section {
                Button("全屏查看（可交互）", systemImage: "arrow.up.left.and.arrow.down.right") { session.showFullScreen(board.id) }
                Button("让 AI 修改这个画板", systemImage: "sparkles") { session.showAskAI = true }
                Button("复制画板", systemImage: "plus.square.on.square") { session.duplicateArtboard(board.id) }
                Button("删除画板", systemImage: "trash", role: .destructive) { session.deleteArtboard(board.id) }
            }
            .buttonStyle(.borderless)
        }
        .formStyle(.grouped)
        .disabled(!session.isEditable)
    }

    static let presets: [(String, CGSize)] = [
        ("iPhone", CGSize(width: 390, height: 844)),
        ("iPhone Pro Max", CGSize(width: 430, height: 932)),
        ("iPad", CGSize(width: 834, height: 1194)),
        ("桌面", CGSize(width: 1440, height: 900)),
        ("幻灯片 16:9", CGSize(width: 1920, height: 1080)),
        ("海报 4:5", CGSize(width: 1080, height: 1350))
    ]
}

// MARK: - 元素属性

private struct ElementProperties: View {
    @Bindable var session: ProjectSession
    let props: ElementProps

    var body: some View {
        Form {
            header
            sizeSection
            layoutSection
            spacingSection
            if props.hasText { textSection }
            appearanceSection
            if props.tag == "img" { imageSection }
            if props.tag == "a" { linkSection }
            actionsSection
        }
        .formStyle(.grouped)
        .disabled(!session.isEditable)
    }

    // 基本
    private var header: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: ElementKind.symbol(props.kind))
                    .foregroundStyle(.secondary)
                Text(ElementKind.title(props.kind))
                    .font(.headline)
                Text("<\(props.tag)>")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            CommitField("图层名称", value: props.name, prompt: "未命名") { session.setAttribute("data-name", $0) }
            if let text = props.text {
                CommitField("文字内容", value: text, multiline: true) { session.setText($0) }
            }
        }
    }

    // 尺寸与定位
    private var sizeSection: some View {
        Section("尺寸") {
            SizeRow(label: "宽度", measured: props.rect.w, inline: props.inlineCSS("width")) { session.setStyle("width", $0) }
            SizeRow(label: "高度", measured: props.rect.h, inline: props.inlineCSS("height")) { session.setStyle("height", $0) }
            Picker("定位", selection: Binding(
                get: { props.css("position") },
                set: { session.setStyle("position", $0 == "static" ? "" : $0) }
            )) {
                Text("常规").tag("static")
                Text("相对").tag("relative")
                Text("绝对").tag("absolute")
                Text("固定").tag("fixed")
                Text("粘性").tag("sticky")
            }
            if props.isAbsolute {
                PairRow {
                    NumberField("X", value: CSSValue.number(props.css("left")) ?? props.rect.x) { session.setStyle("left", CSSValue.px($0)) }
                    NumberField("Y", value: CSSValue.number(props.css("top")) ?? props.rect.y) { session.setStyle("top", CSSValue.px($0)) }
                }
            }
            NumberField("伸展", value: Double(props.css("flex-grow")) ?? 0, unit: "") {
                session.setStyle("flex-grow", $0 == 0 ? "" : CSSValue.format($0))
            }
        }
    }

    // 自动布局
    @ViewBuilder
    private var layoutSection: some View {
        Section("布局") {
            if props.isLayout {
                Picker("布局", selection: Binding(
                    get: { props.css("display").contains("grid") ? "grid" : "flex" },
                    set: { session.setStyle("display", $0) }
                )) {
                    Text("堆叠").tag("flex")
                    Text("网格").tag("grid")
                }
                if !props.css("display").contains("grid") {
                    Picker("方向", selection: Binding(
                        get: { props.css("flex-direction").hasPrefix("column") ? "column" : "row" },
                        set: { session.setStyle("flex-direction", $0) }
                    )) {
                        Image(systemName: "arrow.right").tag("row")
                        Image(systemName: "arrow.down").tag("column")
                    }
                    .pickerStyle(.segmented)
                    Picker("主轴对齐", selection: Binding(
                        get: { CSSValue.normalizeAlign(props.css("justify-content")) },
                        set: { session.setStyle("justify-content", $0) }
                    )) {
                        Text("起点").tag("flex-start")
                        Text("居中").tag("center")
                        Text("终点").tag("flex-end")
                        Text("两端").tag("space-between")
                    }
                    Picker("交叉轴对齐", selection: Binding(
                        get: { CSSValue.normalizeAlign(props.css("align-items")) },
                        set: { session.setStyle("align-items", $0) }
                    )) {
                        Text("起点").tag("flex-start")
                        Text("居中").tag("center")
                        Text("终点").tag("flex-end")
                        Text("拉伸").tag("stretch")
                    }
                    Toggle("自动换行", isOn: Binding(
                        get: { props.css("flex-wrap") == "wrap" },
                        set: { session.setStyle("flex-wrap", $0 ? "wrap" : "") }
                    ))
                }
                NumberField("间距", value: CSSValue.number(props.css("gap")) ?? 0) { session.setStyle("gap", CSSValue.px($0)) }
                Button("移除自动布局") { session.setStyle(["display": "block"]) }
                    .buttonStyle(.borderless)
            } else {
                Button("添加自动布局", systemImage: "plus") {
                    session.setStyle(["display": "flex", "flex-direction": "column", "gap": "8px"])
                }
                .buttonStyle(.borderless)
            }
        }
    }

    // 内外边距
    private var spacingSection: some View {
        Section("边距") {
            BoxRow(label: "内边距", prefix: "padding", props: props, session: session)
            BoxRow(label: "外边距", prefix: "margin", props: props, session: session)
        }
    }

    // 文字
    private var textSection: some View {
        Section("文字") {
            Picker("字体", selection: Binding(
                get: { CSSValue.firstFamily(props.css("font-family")) },
                set: { session.setStyle("font-family", CSSValue.familyStack($0)) }
            )) {
                ForEach(CSSValue.fontChoices(including: CSSValue.firstFamily(props.css("font-family"))), id: \.self) {
                    Text($0).tag($0)
                }
            }
            Picker("字重", selection: Binding(
                get: { props.css("font-weight") },
                set: { session.setStyle("font-weight", $0) }
            )) {
                ForEach(CSSValue.weights, id: \.0) { value, name in Text(name).tag(value) }
                if !CSSValue.weights.contains(where: { $0.0 == props.css("font-weight") }) {
                    Text(props.css("font-weight")).tag(props.css("font-weight"))
                }
            }
            PairRow {
                NumberField("字号", value: CSSValue.number(props.css("font-size")) ?? 16) { session.setStyle("font-size", CSSValue.px($0)) }
                NumberField("行高", value: CSSValue.lineHeight(props.css("line-height"), fontSize: props.css("font-size")),
                            unit: "") { session.setStyle("line-height", CSSValue.format($0)) }
            }
            NumberField("字间距", value: CSSValue.number(props.css("letter-spacing")) ?? 0) {
                session.setStyle("letter-spacing", $0 == 0 ? "" : CSSValue.px($0))
            }
            ColorRow(label: "颜色", css: props.css("color")) { session.setStyle("color", $0) }
            Picker("对齐", selection: Binding(
                get: { CSSValue.textAlign(props.css("text-align")) },
                set: { session.setStyle("text-align", $0) }
            )) {
                Image(systemName: "text.alignleft").tag("left")
                Image(systemName: "text.aligncenter").tag("center")
                Image(systemName: "text.alignright").tag("right")
                Image(systemName: "text.justify").tag("justify")
            }
            .pickerStyle(.segmented)
        }
    }

    // 外观
    private var appearanceSection: some View {
        Section("外观") {
            ColorRow(label: "填充", css: props.css("background-color"), allowsNone: true) {
                session.setStyle("background-color", $0)
            }
            if props.css("background-image") != "none", !props.css("background-image").isEmpty {
                LabeledContent("背景图") {
                    Button("移除") { session.setStyle("background-image", "none") }
                        .buttonStyle(.borderless)
                }
            }
            OpacityRow(value: Double(props.css("opacity")) ?? 1) { session.setStyle("opacity", $0 >= 1 ? "" : CSSValue.format($0)) }
            NumberField("圆角", value: CSSValue.number(props.css("border-top-left-radius")) ?? 0) {
                session.setStyle("border-radius", $0 == 0 ? "" : CSSValue.px($0))
            }
            Picker("描边", selection: Binding(
                get: { (CSSValue.number(props.css("border-top-width")) ?? 0) == 0 ? "none" : props.css("border-top-style") },
                set: { style in
                    if style == "none" { session.setStyle("border", "none") }
                    else {
                        let w = max(CSSValue.number(props.css("border-top-width")) ?? 1, 1)
                        let c = CSSValue.hex(props.css("border-top-color"))?.hex ?? "#D0D5DD"
                        session.setStyle("border", "\(CSSValue.format(w))px \(style) \(c)")
                    }
                }
            )) {
                Text("无").tag("none")
                Text("实线").tag("solid")
                Text("虚线").tag("dashed")
                Text("点线").tag("dotted")
            }
            if (CSSValue.number(props.css("border-top-width")) ?? 0) > 0 {
                NumberField("描边粗细", value: CSSValue.number(props.css("border-top-width")) ?? 1) {
                    session.setStyle("border-width", CSSValue.px($0))
                }
                ColorRow(label: "描边颜色", css: props.css("border-top-color")) { session.setStyle("border-color", $0) }
            }
            Picker("阴影", selection: Binding(
                get: { CSSValue.shadowPreset(props.css("box-shadow")) },
                set: { key in session.setStyle("box-shadow", CSSValue.shadows.first { $0.0 == key }.map(\.2) ?? "") }
            )) {
                ForEach(CSSValue.shadows, id: \.0) { key, name, _ in Text(name).tag(key) }
                if CSSValue.shadowPreset(props.css("box-shadow")) == "custom" { Text("自定义").tag("custom") }
            }
        }
    }

    private var imageSection: some View {
        Section("图片") {
            Button("替换图片…", systemImage: "photo") {
                if let a = ImageUtil.pickImages().first {
                    session.setAttribute("src", "data:\(a.mimeType);base64,\(a.data.base64EncodedString())")
                }
            }
            .buttonStyle(.borderless)
            Picker("填充方式", selection: Binding(
                get: { props.css("object-fit") },
                set: { session.setStyle("object-fit", $0) }
            )) {
                Text("填满").tag("fill")
                Text("覆盖").tag("cover")
                Text("包含").tag("contain")
                Text("原尺寸").tag("none")
                Text("缩小适应").tag("scale-down")
            }
        }
    }

    private var linkSection: some View {
        Section("链接") {
            CommitField("地址", value: props.href, prompt: "https://") { session.setAttribute("href", $0) }
        }
    }

    private var actionsSection: some View {
        Section {
            Button("让 AI 修改这个元素", systemImage: "sparkles") { session.showAskAI = true }
            Button("复制（⌘D）", systemImage: "plus.square.on.square") { session.duplicateSelection() }
            Button("删除（⌫）", systemImage: "trash", role: .destructive) { session.deleteSelection() }
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - 输入控件

/// 两个控件并排
private struct PairRow<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 12) { content }
    }
}

/// 失焦或回车时提交的文本框
private struct CommitField: View {
    let label: String
    let value: String
    var prompt: String = ""
    var multiline = false
    let onCommit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    init(_ label: String, value: String, prompt: String = "", multiline: Bool = false, onCommit: @escaping (String) -> Void) {
        self.label = label; self.value = value; self.prompt = prompt; self.multiline = multiline; self.onCommit = onCommit
    }

    var body: some View {
        TextField(label, text: $text, prompt: Text(prompt), axis: multiline ? .vertical : .horizontal)
            .lineLimit(multiline ? 1...6 : 1...1)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, f in if !f { commit() } }
            .onChange(of: value, initial: true) { _, v in if !focused { text = v } }
    }

    private func commit() {
        if text != value { onCommit(text) }
    }
}

/// 数字输入（px 等），失焦或回车时提交
private struct NumberField: View {
    let label: String
    let value: Double
    var unit: String = "px"
    let onCommit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    init(_ label: String, value: Double, unit: String = "px", onCommit: @escaping (Double) -> Void) {
        self.label = label; self.value = value; self.unit = unit; self.onCommit = onCommit
    }

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                TextField(label, text: $text)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: focused) { _, f in if !f { commit() } }
                if !unit.isEmpty {
                    Text(unit).font(.caption).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: 110)
        }
        .onChange(of: value, initial: true) { _, v in if !focused { text = CSSValue.format(v) } }
    }

    private func commit() {
        guard let v = Double(text.trimmed), abs(v - value) > 0.0001 else {
            text = CSSValue.format(value)
            return
        }
        onCommit(v)
    }
}

/// 宽 / 高：数值 + 固定 / 自适应 / 填充
private struct SizeRow: View {
    let label: String
    let measured: Double
    let inline: String
    let onCommit: (String) -> Void

    private var mode: String {
        if inline.isEmpty || inline == "auto" || inline == "fit-content" { return "hug" }
        if inline == "100%" { return "fill" }
        return "fixed"
    }

    var body: some View {
        HStack(spacing: 8) {
            NumberField(label, value: measured.rounded()) { onCommit(CSSValue.px($0)) }
            Picker(label, selection: Binding(
                get: { mode },
                set: { m in
                    switch m {
                    case "hug": onCommit("")
                    case "fill": onCommit("100%")
                    default: onCommit(CSSValue.px(measured.rounded()))
                    }
                }
            )) {
                Text("固定").tag("fixed")
                Text("自适应").tag("hug")
                Text("填充").tag("fill")
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// 四个方向的内 / 外边距
private struct BoxRow: View {
    let label: String
    let prefix: String
    let props: ElementProps
    let session: ProjectSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.callout)
            Grid(horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    side("上", "top")
                    side("右", "right")
                }
                GridRow {
                    side("下", "bottom")
                    side("左", "left")
                }
            }
        }
    }

    private func side(_ name: String, _ key: String) -> some View {
        let prop = "\(prefix)-\(key)"
        return NumberField(name, value: CSSValue.number(props.css(prop)) ?? 0) { session.setStyle(prop, CSSValue.px($0)) }
    }
}

/// 颜色：取色器 + 十六进制；连续拖动取色器时延迟提交
private struct ColorRow: View {
    let label: String
    let css: String
    var allowsNone = false
    let onCommit: (String) -> Void
    @State private var pending: Task<Void, Never>?
    @State private var hexText = ""

    init(label: String, css: String, allowsNone: Bool = false, onCommit: @escaping (String) -> Void) {
        self.label = label; self.css = css; self.allowsNone = allowsNone; self.onCommit = onCommit
    }

    private var parsed: (hex: String, alpha: Double)? { CSSValue.hex(css) }
    private var isNone: Bool { (parsed?.alpha ?? 0) == 0 }

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                if allowsNone && isNone {
                    Text("无").foregroundStyle(.secondary)
                    Button("添加") { onCommit("#FFFFFF") }
                        .buttonStyle(.borderless)
                } else {
                    ColorPicker(label, selection: Binding(
                        get: { Color(hex: parsed?.hex ?? "#000000") },
                        set: { c in
                            let hex = c.hexString
                            hexText = hex
                            pending?.cancel()
                            pending = Task {
                                try? await Task.sleep(for: .milliseconds(280))
                                if !Task.isCancelled { onCommit(hex) }
                            }
                        }
                    ), supportsOpacity: false)
                    .labelsHidden()
                    TextField("HEX", text: $hexText)
                        .labelsHidden()
                        .font(.callout.monospaced())
                        .frame(width: 76)
                        .onSubmit {
                            let h = hexText.trimmed
                            if h.range(of: #"^#?[0-9A-Fa-f]{3,8}$"#, options: .regularExpression) != nil {
                                onCommit(h.hasPrefix("#") ? h : "#" + h)
                            }
                        }
                    if allowsNone {
                        Button {
                            onCommit("transparent")
                        } label: {
                            Image(systemName: "minus")
                        }
                        .buttonStyle(.borderless)
                        .help("移除填充")
                    }
                }
            }
        }
        .onChange(of: css, initial: true) { _, _ in hexText = parsed?.hex ?? "" }
    }
}

private struct OpacityRow: View {
    let value: Double
    let onCommit: (Double) -> Void
    @State private var current = 1.0

    var body: some View {
        LabeledContent("不透明度") {
            HStack {
                Slider(value: $current, in: 0...1) { editing in
                    if !editing { onCommit((current * 100).rounded() / 100) }
                }
                Text("\(Int((current * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
            .frame(maxWidth: 180)
        }
        .onChange(of: value, initial: true) { _, v in current = v }
    }
}

// MARK: - CSS 值处理

nonisolated enum CSSValue {
    /// "16px" → 16；"normal" / "auto" → nil
    static func number(_ css: String) -> Double? {
        let t = css.trimmed
        guard let r = t.range(of: #"^-?\d+(\.\d+)?"#, options: .regularExpression) else { return nil }
        return Double(t[r])
    }

    static func format(_ v: Double) -> String {
        let r = (v * 100).rounded() / 100
        return r == r.rounded() ? String(Int(r)) : String(r)
    }

    static func px(_ v: Double) -> String { format(v) + "px" }

    /// 行高统一显示为倍数
    static func lineHeight(_ css: String, fontSize: String) -> Double {
        guard let lh = number(css) else { return 1.2 }
        if css.hasSuffix("px"), let fs = number(fontSize), fs > 0 { return (lh / fs * 100).rounded() / 100 }
        return lh
    }

    static func normalizeAlign(_ css: String) -> String {
        switch css {
        case "start", "flex-start", "normal", "left": "flex-start"
        case "end", "flex-end", "right": "flex-end"
        case "center": "center"
        case "space-between", "space-around", "space-evenly": "space-between"
        case "stretch": "stretch"
        default: css
        }
    }

    static func textAlign(_ css: String) -> String {
        switch css {
        case "start", "-webkit-auto", "auto": "left"
        case "end": "right"
        default: css
        }
    }

    /// rgb()/rgba()/#hex → (#RRGGBB, alpha)
    static func hex(_ css: String) -> (hex: String, alpha: Double)? {
        let t = css.trimmed.lowercased()
        if t == "transparent" { return ("#000000", 0) }
        if t.hasPrefix("#") { return (t.uppercased(), 1) }
        guard let open = t.firstIndex(of: "("), let close = t.lastIndex(of: ")") else { return nil }
        let parts = t[t.index(after: open)..<close]
            .replacingOccurrences(of: "/", with: ",")
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .compactMap { Double($0) }
        guard parts.count >= 3 else { return nil }
        let hex = String(format: "#%02X%02X%02X", Int(parts[0].rounded()), Int(parts[1].rounded()), Int(parts[2].rounded()))
        return (hex, parts.count >= 4 ? parts[3] : 1)
    }

    static func firstFamily(_ css: String) -> String {
        let first = css.split(separator: ",").first.map(String.init) ?? css
        return first.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    static func familyStack(_ name: String) -> String {
        let generic = ["serif", "sans-serif", "monospace", "system-ui"]
        if generic.contains(name) { return name }
        let fallback = name.lowercased().contains("serif") && !name.lowercased().contains("sans") ? "serif" : "sans-serif"
        return "\"\(name)\", \(fallback)"
    }

    static let commonFonts = ["-apple-system", "PingFang SC", "Noto Sans SC", "Noto Serif SC", "Inter", "SF Pro Display",
                              "Helvetica Neue", "Georgia", "Menlo", "system-ui", "serif", "sans-serif", "monospace"]

    static func fontChoices(including current: String) -> [String] {
        var list = commonFonts
        if !current.isEmpty, !list.contains(current) { list.insert(current, at: 0) }
        return list
    }

    static let weights: [(String, String)] = [
        ("100", "极细 100"), ("200", "纤细 200"), ("300", "细体 300"), ("400", "常规 400"), ("500", "中等 500"),
        ("600", "半粗 600"), ("700", "粗体 700"), ("800", "特粗 800"), ("900", "黑体 900")
    ]

    static let shadows: [(String, String, String)] = [
        ("none", "无", "none"),
        ("sm", "小", "0 1px 3px rgba(16,24,40,.10), 0 1px 2px rgba(16,24,40,.06)"),
        ("md", "中", "0 8px 24px rgba(16,24,40,.10)"),
        ("lg", "大", "0 20px 48px rgba(16,24,40,.16)")
    ]

    static func shadowPreset(_ css: String) -> String {
        let t = css.trimmed
        if t.isEmpty || t == "none" { return "none" }
        let compact = t.replacingOccurrences(of: " ", with: "")
        for (key, _, value) in shadows where value.replacingOccurrences(of: " ", with: "") == compact { return key }
        return "custom"
    }
}
