import SwiftUI

/// 画布底部的浮动工具栏（Liquid Glass）
struct FloatingToolbar: View {
    @Bindable var session: ProjectSession
    @Namespace private var toolCoordinates
    @State private var toolFrames: [CanvasTool: CGRect] = [:]
    @GestureState private var dragX: CGFloat?

    private let groups: [[CanvasTool]] = [[.select, .hand], [.text, .frame, .note, .pencil, .rectangle, .image], [.comment]]
    private let toolWidth: CGFloat = 32
    private let toolHeight: CGFloat = 30
    private let toolSpacing: CGFloat = 3
    private let snapAnimation = Animation.spring(response: 0.32, dampingFraction: 0.78)

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: toolSpacing) {
                toolTray
                divider

                Button {
                    withAnimation(.snappy) { session.showAskAI.toggle() }
                } label: {
                    Label("询问 AI", systemImage: "sparkles")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(session.showAskAI ? Theme.accent.opacity(0.16) : Color.secondary.opacity(0.10),
                                    in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .foregroundStyle(session.showAskAI ? Theme.accent : .primary)
                .help("让 AI 修改选中的画板或元素")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
        }
        .disabled(!session.isEditable)
    }

    private var toolTray: some View {
        let coordinates = toolCoordinates
        let highlighted = dragX.flatMap(nearestTool(to:)) ?? session.tool
        return HStack(spacing: toolSpacing) {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { divider }
                ForEach(group) { tool in
                    toolButton(tool, highlighted: tool == highlighted)
                        .onGeometryChange(for: CGRect.self) { geo in
                            geo.frame(in: .named(coordinates))
                        } action: { frame in
                            toolFrames[tool] = frame
                        }
                }
            }
        }
        .background(alignment: .leading) {
            if let center = indicatorCenter {
                Capsule()
                    .fill(.clear)
                    .frame(width: toolWidth, height: toolHeight)
                    .glassEffect(.regular.tint(Theme.accent.opacity(0.24)).interactive(), in: .capsule)
                    .scaleEffect(dragX == nil ? 1 : 1.06)
                    .animation(.snappy(duration: 0.18), value: dragX != nil)
                    .offset(x: center - toolWidth / 2)
                    .animation(dragX == nil ? snapAnimation : nil, value: center)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(.rect)
        .highPriorityGesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named(coordinates))
                .updating($dragX) { value, position, _ in
                    guard isToolDrag(value) else { return }
                    position = value.location.x
                }
                .onEnded { value in
                    guard isToolDrag(value), let tool = nearestTool(to: value.location.x),
                          tool != session.tool else { return }
                    activate(tool)
                }
        )
        .coordinateSpace(.named(coordinates))
    }

    private var divider: some View {
        Divider().frame(height: 20).padding(.horizontal, 3)
    }

    private var indicatorCenter: CGFloat? {
        guard let dragX else { return toolFrames[session.tool]?.midX }
        guard let first = toolFrames[.select], let last = toolFrames[.comment] else { return nil }
        return min(max(dragX, first.midX), last.midX)
    }

    private func isToolDrag(_ value: DragGesture.Value) -> Bool {
        (0..<toolHeight).contains(value.startLocation.y)
            && (dragX != nil || abs(value.translation.width) >= abs(value.translation.height))
    }

    private func nearestTool(to x: CGFloat) -> CanvasTool? {
        groups.joined().min {
            abs((toolFrames[$0]?.midX ?? .infinity) - x) < abs((toolFrames[$1]?.midX ?? .infinity) - x)
        }
    }

    private func activate(_ tool: CanvasTool) {
        withAnimation(.snappy(duration: 0.2)) {
            session.showShapePicker = tool == .rectangle && (session.tool != tool || !session.showShapePicker)
            session.tool = tool
        }
    }

    private func toolButton(_ tool: CanvasTool, highlighted: Bool) -> some View {
        let selected = session.tool == tool
        let isShape = tool == .rectangle
        return Button {
            activate(tool)
        } label: {
            ToolGlyph(tool: tool, shape: session.shapeKind, selected: highlighted)
                .frame(width: toolWidth, height: toolHeight)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(highlighted ? Theme.accent : .primary)
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .modifier(HoverName(text: isShape ? "\(session.shapeKind.title)  R" : "\(tool.title)  \(String(tool.shortcut).uppercased())",
                            enabled: dragX == nil && !(isShape && session.showShapePicker) && !(selected && tool == .pencil)))
        .overlay(alignment: .top) {
            if dragX == nil && isShape && session.showShapePicker {
                ShapePicker(session: session)
                    .fixedSize()
                    .offset(y: -50)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
            }
        }
        .overlay(alignment: .top) {
            if dragX == nil && selected && tool == .pencil {
                PencilStylePicker(style: $session.pencilStroke)
                    .fixedSize()
                    .offset(y: -50)
            }
        }
    }
}

private struct PencilStylePicker: View {
    @Binding var style: PencilStroke

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PencilStroke.Weight.allCases) { weight in
                option(title: "线条粗细：\(weight.title)", selected: style.weight == weight,
                       width: weight.rawValue, dash: []) { style.weight = weight }
            }
            Divider().frame(height: 18).padding(.horizontal, 4)
            ForEach(PencilStroke.Pattern.allCases) { pattern in
                option(title: pattern.title, selected: style.pattern == pattern,
                       width: 2, dash: pattern.dash(for: 2)) { style.pattern = pattern }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
    }

    private func option(title: String, selected: Bool, width: CGFloat, dash: [CGFloat],
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Path { path in
                path.move(to: CGPoint(x: 6, y: 14))
                path.addLine(to: CGPoint(x: 23, y: 14))
            }
            .stroke(selected ? Theme.accent : Color.secondary,
                    style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
            .frame(width: 29, height: 28)
            .background(selected ? Theme.accent.opacity(0.16) : .clear, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 工具图标：文本用一个「T」（SF Symbol textformat 在中文系统下会显示成「格式」），形状跟随当前图形
private struct ToolGlyph: View {
    let tool: CanvasTool
    let shape: ShapeKind
    let selected: Bool

    var body: some View {
        switch tool {
        case .text:
            Text("T")
                .font(.system(size: 17, weight: selected ? .semibold : .regular))
        case .rectangle:
            Image(systemName: shape.symbol)
                .font(.system(size: 15, weight: selected ? .semibold : .regular))
        case .frame:
            // SF Symbol 的 number 是斜的，画板用方正的井号
            HashGlyph()
                .stroke(style: StrokeStyle(lineWidth: selected ? 1.8 : 1.4, lineCap: .round))
                .frame(width: 16, height: 16)
        case .note:
            StickyNoteGlyph()
                .stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                .frame(width: 16, height: 16)
        case .image:
            // SF Symbol 的 photo 是横长方形，这里用方形
            // 外框直接用系统的 square 符号，与「形状」按钮完全一致；里面只画太阳和山
            Image(systemName: "square")
                .font(.system(size: 15, weight: selected ? .semibold : .regular))
                .overlay {
                    // square 在 15pt 下的笔画范围是 14 × 15pt，居中；线宽 regular 1.25 / semibold 1.75
                    ImageInterior(lineWidth: selected ? 1.75 : 1.25)
                        .frame(width: 14, height: 15)
                }
        default:
            Image(systemName: tool.symbol)
                .font(.system(size: 15, weight: selected ? .semibold : .regular))
        }
    }
}

/// 圆角便签，右下角的折边和外轮廓共用端点。
nonisolated private struct StickyNoteGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        return Path { path in
            path.move(to: point(0.27, 0.10))
            path.addLine(to: point(0.73, 0.10))
            path.addQuadCurve(to: point(0.90, 0.27), control: point(0.90, 0.10))
            path.addLine(to: point(0.90, 0.43))
            path.addCurve(to: point(0.43, 0.90), control1: point(0.90, 0.69), control2: point(0.69, 0.90))
            path.addLine(to: point(0.27, 0.90))
            path.addQuadCurve(to: point(0.10, 0.73), control: point(0.10, 0.90))
            path.addLine(to: point(0.10, 0.27))
            path.addQuadCurve(to: point(0.27, 0.10), control: point(0.10, 0.10))
            path.closeSubpath()

            path.move(to: point(0.49, 0.89))
            path.addLine(to: point(0.49, 0.63))
            path.addQuadCurve(to: point(0.63, 0.49), control: point(0.49, 0.49))
            path.addLine(to: point(0.89, 0.49))
        }
    }
}

/// 方正的井号（两横两竖）
nonisolated struct HashGlyph: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height
        for x in [0.34, 0.66] {
            p.move(to: CGPoint(x: r.minX + w * x, y: r.minY + h * 0.1))
            p.addLine(to: CGPoint(x: r.minX + w * x, y: r.minY + h * 0.9))
        }
        for y in [0.34, 0.66] {
            p.move(to: CGPoint(x: r.minX + w * 0.1, y: r.minY + h * y))
            p.addLine(to: CGPoint(x: r.minX + w * 0.9, y: r.minY + h * y))
        }
        return p
    }
}

/// 图片图标的内部：太阳 + 山（外框由 square 符号绘制）
struct ImageInterior: View {
    var lineWidth: CGFloat = 1.25

    var body: some View {
        GeometryReader { geo in
            // 在外框笔画以内作画
            let box = CGRect(origin: .zero, size: geo.size).insetBy(dx: lineWidth + 0.6, dy: lineWidth + 0.6)
            ZStack {
                Circle()
                    .frame(width: box.width * 0.24, height: box.width * 0.24)
                    .position(x: box.minX + box.width * 0.7, y: box.minY + box.height * 0.27)
                Path { p in
                    p.move(to: CGPoint(x: box.minX, y: box.minY + box.height * 0.9))
                    p.addLine(to: CGPoint(x: box.minX + box.width * 0.36, y: box.minY + box.height * 0.52))
                    p.addLine(to: CGPoint(x: box.minX + box.width * 0.63, y: box.minY + box.height * 0.8))
                    p.addLine(to: CGPoint(x: box.minX + box.width * 0.78, y: box.minY + box.height * 0.65))
                    p.addLine(to: CGPoint(x: box.maxX, y: box.minY + box.height * 0.84))
                }
                .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

/// 形状选择条：矩形 / 圆形 | 箭头 / 直线
private struct ShapePicker: View {
    @Bindable var session: ProjectSession

    var body: some View {
        HStack(spacing: 2) {
            button(.rectangle)
            button(.ellipse)
            Divider().frame(height: 18).padding(.horizontal, 4)
            button(.arrow)
            button(.line)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
    }

    private func button(_ kind: ShapeKind) -> some View {
        let selected = session.shapeKind == kind
        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                session.shapeKind = kind
                session.tool = .rectangle
                session.showShapePicker = false
            }
        } label: {
            Image(systemName: kind.symbol)
                .font(.system(size: 15, weight: selected ? .semibold : .regular))
                .frame(width: 34, height: 30)
                .background(selected ? Theme.accent.opacity(0.16) : .clear, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Theme.accent : .primary)
        .modifier(HoverName(text: kind.title, enabled: true))
        .accessibilityLabel(kind.title)
    }
}

/// 鼠标停在按钮上时，在按钮上方立即显示名称（系统 help 提示要等约 1 秒）
struct HoverName: ViewModifier {
    let text: String
    var enabled = true
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
            }
            .overlay(alignment: .top) {
                if hovering && enabled {
                    Text(text)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.78), in: .capsule)
                        .fixedSize()
                        .offset(y: -36)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
    }
}

/// 「询问 AI」输入条：针对选中的画板 / 元素提出修改
struct AskAIBar: View {
    @Bindable var session: ProjectSession
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "scope")
                Text(targetDescription)
                    .lineLimit(1)
                Spacer()
                Button {
                    withAnimation(.snappy) { session.showAskAI = false }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $session.askDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit(send)
                ProviderMenu(selection: providerBinding, showsLogo: false, maximumTitleWidth: 225)
                Button(action: send) {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(SendButtonStyle())
                .disabled(!session.canAsk)
                .help("发送（Return；⌥Return 换行）")
            }
        }
        .padding(12)
        .frame(width: 520)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .onAppear { focused = true }
        .onExitCommand { session.showAskAI = false }
    }

    private var targetDescription: String {
        guard let sel = session.selection, let board = session.document.artboard(sel.artboardID) else {
            return "未选中内容：AI 会根据描述修改当前画布"
        }
        if sel.elementID != nil, let p = session.selectedProps {
            return "修改「\(board.name)」中的\(ElementKind.title(p.kind)) \(ProjectSession.displayName(p))"
        }
        return "修改画板「\(board.name)」"
    }

    private var placeholder: String {
        session.selection == nil ? "描述想要的修改…" : "让 AI 怎么改它？"
    }

    private func send() {
        guard session.canAsk else { return }
        session.send(useSelection: true)
    }

    private var providerBinding: Binding<ModelChoice> {
        Binding(
            get: {
                guard let project = session.project, let id = project.providerID,
                      session.app.provider(for: id) != nil else {
                    return ModelChoice(providerID: session.app.defaultProvider?.id)
                }
                return ModelChoice(providerID: id, model: project.model, effort: project.effort)
            },
            set: { newValue in
                session.app.updateProject(session.projectID, touch: false) {
                    $0.providerID = newValue.providerID
                    $0.model = newValue.model
                    $0.effort = newValue.effort
                }
            }
        )
    }
}
