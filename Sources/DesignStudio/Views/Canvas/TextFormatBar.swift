import SwiftUI

/// 选中文字时浮在元素上方的格式工具栏：字体、字号、字重、颜色、粗体 / 斜体 / 下划线、对齐，以及询问 AI、批注
struct TextFormatBar: View {
    @Bindable var session: ProjectSession
    let props: ElementProps

    private var family: String { CSSValue.firstFamily(props.css("font-family")) }
    private var size: Double { CSSValue.number(props.css("font-size")) ?? 16 }
    private var weight: String { props.css("font-weight") }
    private var color: String { CSSValue.hex(props.css("color"))?.hex ?? "#000000" }
    private var align: String { CSSValue.textAlign(props.css("text-align")) }
    private var isBold: Bool { (Int(weight) ?? 400) >= 600 }
    private var isItalic: Bool { props.css("font-style") == "italic" }
    private var isUnderline: Bool { props.css("text-decoration-line").contains("underline") }
    private var isNote: Bool { props.kind == "note" }

    static let sizes: [Double] = [10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24, 28, 32, 36, 40, 48, 56, 64, 72, 96]
    static let aligns: [(String, String, String)] = [("left", "左对齐", "text.alignleft"), ("center", "居中", "text.aligncenter"),
                                                     ("right", "右对齐", "text.alignright"), ("justify", "两端对齐", "text.justify")]

    var body: some View {
        HStack(spacing: 2) {
            if isNote {
                sizeMenu

                ColorSwatchButton(hex: color, title: "文字颜色") { session.setStyle("color", $0) }
                toggle("bold", on: isBold, help: "粗体") { session.setStyle("font-weight", isBold ? "400" : "700") }
                toggle("italic", on: isItalic, help: "斜体") { session.setStyle("font-style", isItalic ? "" : "italic") }
                divider
                ColorSwatchButton(hex: CSSValue.hex(props.css("background-color"))?.hex ?? "#FFF2A6", title: "便签底色") {
                    session.setStyle("background-color", $0)
                }
                divider
                commentButton
            } else {
                textControls
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
        .fixedSize()
    }

    @ViewBuilder private var textControls: some View {
        // 字体
        Menu {
            ForEach(CSSValue.fontChoices(including: family), id: \.self) { name in
                Toggle(name, isOn: Binding(get: { name == family },
                                           set: { _ in session.setStyle("font-family", CSSValue.familyStack(name)) }))
            }
        } label: {
            chip {
                Image(systemName: "textformat.size").font(.system(size: 11, weight: .medium))
                Text(family).lineLimit(1).frame(maxWidth: 110, alignment: .leading)
            }
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("字体")

        sizeMenu

        // 字重
        Menu {
            ForEach(CSSValue.weights, id: \.0) { w in
                Toggle(w.1, isOn: Binding(get: { w.0 == weight }, set: { _ in session.setStyle("font-weight", w.0) }))
            }
        } label: {
            chip { Text(CSSValue.weights.first { $0.0 == weight }.map { String($0.1.prefix(2)) } ?? weight) }
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("字重")

        divider

        ColorSwatchButton(hex: color) { session.setStyle("color", $0) }

        divider

        toggle("bold", on: isBold, help: "粗体") { session.setStyle("font-weight", isBold ? "400" : "700") }
        toggle("italic", on: isItalic, help: "斜体") { session.setStyle("font-style", isItalic ? "" : "italic") }
        toggle("underline", on: isUnderline, help: "下划线") {
            session.setStyle("text-decoration", isUnderline ? "none" : "underline")
        }

        // 对齐
        Menu {
            ForEach(Self.aligns, id: \.0) { a in
                Toggle(isOn: Binding(get: { a.0 == align }, set: { _ in session.setStyle("text-align", a.0) })) {
                    Label(a.1, systemImage: a.2)
                }
            }
        } label: {
            icon(Self.aligns.first { $0.0 == align }?.2 ?? "text.alignleft")
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("对齐")

        divider

        Button { session.showAskAI = true } label: { icon("sparkle") }
            .buttonStyle(.plain)
            .disabled(!session.canAskAboutSelection)
            .help("询问 AI（⌘J）")
        commentButton

        Menu {
            Button("复制一份") { session.duplicateSelection() }
            Button("拷贝为 PNG") { session.copySelectionAsPNG() }
            Button("拷贝属性") { session.copyProperties() }
            Button("粘贴属性") { session.pasteProperties() }.disabled(session.copiedStyle == nil)
            Divider()
            Button("删除", role: .destructive) { session.deleteSelection() }
        } label: { icon("ellipsis") }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("更多")
    }

    private var commentButton: some View {
        Button {
            if let sel = session.selection { session.pendingComment = (sel.artboardID, props) }
        } label: { icon("bubble.left") }
            .buttonStyle(.plain)
            .help("添加批注")
    }

    private var sizeMenu: some View {
        Menu {
            ForEach(sizeChoices, id: \.self) { v in
                Toggle(CSSValue.px(v), isOn: Binding(get: { abs(v - size) < 0.01 },
                                                    set: { _ in session.setStyle("font-size", CSSValue.px(v)) }))
            }
        } label: {
            chip {
                if isNote { Image(systemName: "textformat.size") }
                Text(CSSValue.format(size)).monospacedDigit()
            }
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("字号")
    }

    private var sizeChoices: [Double] {
        Self.sizes.contains(where: { abs($0 - size) < 0.01 }) ? Self.sizes : (Self.sizes + [size]).sorted()
    }

    private var divider: some View {
        Rectangle().fill(.separator).frame(width: 1, height: 18).padding(.horizontal, 3)
    }

    private func chip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HoverChip { HStack(spacing: 5) { content(); Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary) } }
    }

    private func icon(_ symbol: String) -> some View {
        HoverChip(square: true) { Image(systemName: symbol).font(.system(size: 13, weight: .medium)) }
    }

    private func toggle(_ symbol: String, on: Bool, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HoverChip(square: true, selected: on) { Image(systemName: symbol).font(.system(size: 13, weight: .semibold)) }
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// 工具栏里的按钮外观：悬停时浅灰底，选中时深一点
private struct HoverChip<Content: View>: View {
    var square = false
    var selected = false
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        content
            .font(.callout)
            .foregroundStyle(.primary)
            .padding(.horizontal, square ? 0 : 8)
            .frame(width: square ? 28 : nil, height: 28)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(selected ? 0.12 : hovering ? 0.07 : 0)))
            .contentShape(.rect)
            .onHover { hovering = $0 }
    }
}

/// 颜色按钮：当前颜色的色块，点开选常用色或打开系统取色器
private struct ColorSwatchButton: View {
    let hex: String
    var title = "颜色"
    let apply: (String) -> Void
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            HoverChip(square: true) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(hex: hex))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.15)))
                    .frame(width: 18, height: 18)
            }
        }
        .buttonStyle(.plain)
        .help("\(title) \(hex)")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 8), count: 7), spacing: 8) {
                    ForEach(TextMenu.palette, id: \.hex) { c in
                        Button { apply(c.hex); showing = false } label: {
                            Circle()
                                .fill(Color(hex: c.hex))
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
                                .overlay(Circle().strokeBorder(Color.accentColor,
                                                               lineWidth: c.hex.caseInsensitiveCompare(hex) == .orderedSame ? 2 : 0)
                                    .padding(-3))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .help("\(c.name) \(c.hex)")
                    }
                }
                Button("其他颜色…") {
                    showing = false
                    ColorPanelBridge.shared.open(current: hex, apply: apply)
                }
                .buttonStyle(.link)
            }
            .padding(12)
        }
    }
}
