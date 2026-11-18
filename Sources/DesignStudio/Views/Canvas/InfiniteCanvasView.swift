import SwiftUI
import AppKit

/// 无限画布：所有画板摊开在画布上，可平移、缩放，直接选中和编辑元素
struct InfiniteCanvasView: View {
    @Bindable var session: ProjectSession
    @FocusState private var focused: Bool
    /// 底部工具栏的实际宽度：全屏顶部控制条与它等宽
    @State private var toolbarWidth: CGFloat = 320

    /// 浮动工具栏距画布上下边缘的距离（顶部控制条与底部工具栏对称）
    static let edgeInset: CGFloat = 18
    @State private var textBarSize = CGSize(width: 460, height: 38)

    /// 格式工具栏的位置：选中元素上方居中；上方放不下（被顶部控制条挡住）时放到下方尺寸标签之下，左右不超出画布
    private func textBarPlacement(viewport: CGSize) -> (props: ElementProps, origin: CGPoint)? {
        guard !session.interactivePreview, !session.isEditingText, session.tool == .select,
              session.multiSelection.count < 2,
              let sel = session.selection, sel.elementID != nil,
              let props = session.selectedProps, props.id == sel.elementID, props.hasText,
              !session.streamingArtboardIDs.contains(sel.artboardID),
              let board = session.currentPage?.artboards.first(where: { $0.id == sel.artboardID }) else { return nil }
        let r = props.rect
        let rect = session.viewRect(CGRect(x: board.x + r.x, y: board.y + r.y, width: r.w, height: r.h))
        let w = textBarSize.width, h = textBarSize.height
        var y = rect.minY - h - 12
        if y < 64 { y = rect.maxY + 34 }
        let x = min(max(rect.midX - w / 2, 12), max(viewport.width - w - 12, 12))
        return (props, CGPoint(x: x, y: y))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                CanvasGrid(zoom: session.zoom, pan: session.pan)
                    .contentShape(.rect)
                    .onTapGesture {
                        session.clearSelection()
                        focused = true
                    }

                ForEach(session.currentPage?.artboards ?? []) { board in
                    ArtboardFrame(artboard: board, session: session)
                }

                if !session.interactivePreview {
                    SelectionLayer(session: session)
                        .allowsHitTesting(false)
                }

                if session.tool.capturesPointer && session.isEditable && !session.interactivePreview {
                    ToolCaptureLayer(session: session)
                }

                // 选中文字时，元素上方出现格式工具栏
                if let placement = textBarPlacement(viewport: geo.size) {
                    TextFormatBar(session: session, props: placement.props)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { textBarSize = $0 }
                        .offset(x: placement.origin.x, y: placement.origin.y)
                        .transition(.opacity)
                }

                if let pending = session.pendingComment {
                    CommentNoteEditor(session: session, artboardID: pending.artboardID, rect: pending.props.rect)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .background(CanvasEventMonitor(session: session))
            .onAppear { session.viewportDidChange(geo.size) }
            .onChange(of: geo.size) { _, size in session.viewportDidChange(size) }
        }
        .background(CanvasPalette.background)
        // 顶部控制条与底部工具栏对称：距窗口顶端 edgeInset（与工具栏距底部一致）。
        // 放在 ignoresSafeArea 之前，坐标从窗口最顶端算起
        .overlay(alignment: .top) {
            if session.isFullScreen {
                FullScreenBar(session: session, width: toolbarWidth).padding(.top, Self.edgeInset)
            }
        }
        // 画布延伸到标题栏下方（标题栏背景已隐藏），顶部颜色与画布一致
        .ignoresSafeArea(.container, edges: .top)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onChange(of: focused) { _, now in session.canvasFocused = now }
        .onKeyPress(phases: .down) { press in
            let key: String = switch press.key {
            case .delete: "backspace"
            case .deleteForward: "delete"
            case .escape: "escape"
            case .leftArrow: "arrowleft"
            case .rightArrow: "arrowright"
            default: press.characters
            }
            return session.handleKey(key: key, command: press.modifiers.contains(.command),
                                     shift: press.modifiers.contains(.shift)) ? .handled : .ignored
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if session.showAskAI { AskAIBar(session: session) }
                FloatingToolbar(session: session)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { toolbarWidth = $0 }
            }
            .padding(.bottom, Self.edgeInset)
        }
        // 非全屏：顶部两组工具栏放在标题栏下方（标题栏里的点击会被系统工具栏拦截，用于拖动窗口）
        .overlay(alignment: .top) {
            if !session.isFullScreen {
                HStack(alignment: .top) {
                    CanvasTopLeftBar(session: session)
                    Spacer(minLength: 12)
                    CanvasTopRightBar(session: session)
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
            }
        }
        .overlay(alignment: .top) {
            CanvasStatusBanner(session: session)
                .padding(.top, 64)   // 位于顶部控制条下方
        }
        .overlay {
            if session.currentPage?.artboards.isEmpty ?? true, !session.isGenerating {
                ContentUnavailableView {
                    Label("画布还是空的", systemImage: "square.dashed")
                } description: {
                    Text("在左侧对话里描述想要的设计，或用底部工具栏的「画板」工具（F）手动创建。")
                }
                .allowsHitTesting(false)
            }
        }
    }
}

enum CanvasPalette {
    static let background = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.955, alpha: 1)
    })
    static let selection = Color(hex: "#3B82F6")
}

// MARK: - 背景点阵

private struct CanvasGrid: View {
    let zoom: Double
    let pan: CGPoint

    var body: some View {
        Canvas { ctx, size in
            // 缩放后间距保持在 16–40pt 之间
            var step = 24.0 * zoom
            while step < 16 { step *= 2 }
            while step > 40 { step /= 2 }
            let dot = max(1.0, min(1.6, zoom * 1.6))
            let startX = pan.x.truncatingRemainder(dividingBy: step)
            let startY = pan.y.truncatingRemainder(dividingBy: step)
            var path = Path()
            var y = startY
            while y < size.height {
                var x = startX
                while x < size.width {
                    path.addEllipse(in: CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot))
                    x += step
                }
                y += step
            }
            ctx.fill(path, with: .color(.secondary.opacity(0.28)))
        }
    }
}

// MARK: - 画板

private struct ArtboardFrame: View {
    let artboard: Artboard
    @Bindable var session: ProjectSession
    @State private var dragOffset: CGSize = .zero
    @State private var renaming = false
    @State private var newName = ""

    private let headerHeight: CGFloat = 26

    var body: some View {
        let z = session.zoom
        let origin = session.viewPoint(CGPoint(x: artboard.x, y: artboard.y))
        let isSelected = session.selection?.artboardID == artboard.id && session.selection?.elementID == nil

        let width = max(artboard.width * z, 120)
        let height = headerHeight + artboard.height * z

        // 注意：必须用 position（布局）而不是 offset（只移动绘制）定位，
        // 否则 WKWebView 的真实 frame 仍叠在原点：WebKit 会当成被遮挡而不绘制，鼠标点击也会落到错误的画板上
        VStack(alignment: .leading, spacing: 6) {
            header(isSelected: isSelected)
                .frame(width: width, height: headerHeight - 6, alignment: .leading)

            ArtboardWebView(artboard: artboard, zoom: z, mode: session.editorMode(for: artboard.id), session: session)
                .frame(width: artboard.width * z, height: artboard.height * z)
                .background(.white)
                .clipShape(.rect(cornerRadius: 2))
                .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .position(x: origin.x + dragOffset.width + width / 2,
                  y: origin.y - headerHeight + dragOffset.height + height / 2)
    }

    @ViewBuilder
    private func header(isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            if renaming {
                TextField("画板名称", text: $newName)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .onSubmit {
                        session.renameArtboard(artboard.id, to: newName)
                        renaming = false
                    }
                    .onExitCommand { renaming = false }
            } else {
                Text(artboard.name)
                    .font(.callout)
                    .foregroundStyle(isSelected ? CanvasPalette.selection : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if session.zoom * artboard.width > 220 {
                Menu {
                    Button("全屏查看此画板", systemImage: "arrow.up.left.and.arrow.down.right") {
                        session.select(CanvasSelection(artboardID: artboard.id, elementID: nil))
                        session.showFullScreen(artboard.id)
                    }
                    Divider()
                    Button("复制画板", systemImage: "plus.square.on.square") { session.duplicateArtboard(artboard.id) }
                    Button("重命名", systemImage: "pencil") { newName = artboard.name; renaming = true }
                    Button("缩放到此画板", systemImage: "plus.magnifyingglass") {
                        session.select(CanvasSelection(artboardID: artboard.id, elementID: nil))
                        session.zoomToSelection()
                    }
                    Divider()
                    Button("删除画板", systemImage: "trash", role: .destructive) { session.deleteArtboard(artboard.id) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .foregroundStyle(.secondary)
        .contentShape(.rect)
        .onTapGesture(count: 2) { newName = artboard.name; renaming = true }
        .onTapGesture { session.select(CanvasSelection(artboardID: artboard.id, elementID: nil)) }
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { v in
                    guard session.isEditable else { return }
                    dragOffset = v.translation
                }
                .onEnded { v in
                    guard session.isEditable else { return }
                    let z = session.zoom
                    session.moveArtboard(artboard.id, by: CGSize(width: v.translation.width / z, height: v.translation.height / z))
                    dragOffset = .zero
                }
        )
        .pointerStyle(.grabIdle)
    }
}

// MARK: - 选中框 / 悬停框

private struct SelectionLayer: View {
    let session: ProjectSession

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let hover = session.hover, hover.elementID != session.selection?.elementID || hover.artboardID != session.selection?.artboardID,
               let rect = elementRect(hover.artboardID, hover.rect) {
                Rectangle()
                    .strokeBorder(CanvasPalette.selection.opacity(0.7), lineWidth: 1)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }

            if let sel = session.selection, let board = session.currentPage?.artboards.first(where: { $0.id == sel.artboardID }) {
                if session.multiSelection.count > 1 {
                    // 多选：每个元素一个细框，外面一个整体的选中框，标签显示数量
                    let rects = session.multiSelection.compactMap { elementRect(board.id, $0.rect) }
                    ForEach(Array(rects.enumerated()), id: \.offset) { _, r in
                        Rectangle()
                            .strokeBorder(CanvasPalette.selection, lineWidth: 1)
                            .frame(width: max(r.width, 1), height: max(r.height, 1))
                            .offset(x: r.minX, y: r.minY)
                    }
                    if let union = rects.dropFirst().reduce(rects.first, { $0?.union($1) }) {
                        SelectionBox(rect: union.insetBy(dx: -3, dy: -3), label: "已选 \(rects.count) 个")
                    }
                } else if sel.elementID != nil, let props = session.selectedProps, let rect = elementRect(board.id, props.rect) {
                    SelectionBox(rect: rect, label: "\(Int(props.rect.w.rounded())) × \(Int(props.rect.h.rounded()))")
                } else if sel.elementID == nil {
                    SelectionBox(rect: session.viewRect(board.frame),
                                 label: "\(Int(board.width)) × \(Int(board.height))")
                }
            }
        }
    }

    private func elementRect(_ artboardID: UUID, _ r: ElementRect) -> CGRect? {
        guard let board = session.currentPage?.artboards.first(where: { $0.id == artboardID }) else { return nil }
        return session.viewRect(CGRect(x: board.x + r.x, y: board.y + r.y, width: r.w, height: r.h))
    }
}

private struct SelectionBox: View {
    let rect: CGRect
    let label: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(CanvasPalette.selection, lineWidth: 1.5)
                .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                .offset(x: rect.minX, y: rect.minY)
            ForEach(0..<4, id: \.self) { i in
                let x = i % 2 == 0 ? rect.minX : rect.maxX
                let y = i < 2 ? rect.minY : rect.maxY
                Rectangle()
                    .fill(.white)
                    .overlay(Rectangle().strokeBorder(CanvasPalette.selection, lineWidth: 1.2))
                    .frame(width: 7, height: 7)
                    .offset(x: x - 3.5, y: y - 3.5)
            }
            Text(label)
                .font(.caption2.monospacedDigit().weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(CanvasPalette.selection, in: .rect(cornerRadius: 3))
                .fixedSize()
                .frame(width: max(rect.width, 60))
                .offset(x: rect.minX + rect.width / 2 - max(rect.width, 60) / 2, y: rect.maxY + 6)
        }
    }
}

// MARK: - 工具覆盖层（抓手 / 画板 / 文本 / 矩形 / 图片）

private struct ToolCaptureLayer: View {
    @Bindable var session: ProjectSession
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var panStart: CGPoint?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(.rect)
            if let s = dragStart, let c = dragCurrent, session.tool == .frame || session.tool == .rectangle {
                let r = CGRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(c.x - s.x), height: abs(c.y - s.y))
                if session.tool == .rectangle && session.shapeKind.isStroke {
                    // 直线 / 箭头：预览从起点到当前位置的线
                    Path { p in p.move(to: s); p.addLine(to: c) }
                        .stroke(CanvasPalette.selection, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                } else if session.tool == .rectangle && session.shapeKind == .ellipse {
                    Ellipse()
                        .fill(CanvasPalette.selection.opacity(0.08))
                        .strokeBorder(CanvasPalette.selection, lineWidth: 1)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                } else {
                    Rectangle()
                        .fill(CanvasPalette.selection.opacity(0.08))
                        .strokeBorder(CanvasPalette.selection, lineWidth: 1)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if session.tool == .hand {
                        if panStart == nil { panStart = session.pan; session.userMovedViewport() }
                        if let p = panStart {
                            session.pan = CGPoint(x: p.x + v.translation.width, y: p.y + v.translation.height)
                        }
                    } else {
                        if dragStart == nil {
                            dragStart = v.startLocation
                            session.showShapePicker = false
                        }
                        dragCurrent = v.location
                    }
                }
                .onEnded { v in
                    defer { dragStart = nil; dragCurrent = nil; panStart = nil }
                    guard session.tool != .hand else { return }
                    finish(start: v.startLocation, end: v.location)
                }
        )
        .pointerStyle(pointer)
    }

    private var pointer: PointerStyle {
        switch session.tool {
        case .hand: panStart == nil ? .grabIdle : .grabActive
        case .text: .horizontalText
        default: .rectSelection
        }
    }

    private func finish(start: CGPoint, end: CGPoint) {
        let ws = session.worldPoint(start), we = session.worldPoint(end)
        let dragged = hypot(end.x - start.x, end.y - start.y) > 6
        let worldRect = CGRect(x: min(ws.x, we.x), y: min(ws.y, we.y), width: abs(we.x - ws.x), height: abs(we.y - ws.y))

        switch session.tool {
        case .frame:
            if dragged { session.addArtboard(frame: worldRect) } else { session.addArtboard(at: ws) }
        case .text, .rectangle, .image:
            guard let board = session.currentPage?.artboards.last(where: { $0.frame.contains(ws) }) else {
                NSSound.beep()
                return
            }
            let local = CGPoint(x: ws.x - board.x, y: ws.y - board.y)
            switch session.tool {
            case .text: session.insertText(in: board.id, at: local)
            case .image: session.insertImage(in: board.id, at: local)
            default:
                let kind = session.shapeKind
                let r = dragged
                    ? CGRect(x: worldRect.minX - board.x, y: worldRect.minY - board.y, width: worldRect.width, height: worldRect.height)
                    : CGRect(x: local.x, y: local.y, width: 120, height: 120)
                // 直线 / 箭头：没拖动时默认向右 160px
                let end = dragged ? CGPoint(x: we.x - board.x, y: we.y - board.y) : CGPoint(x: local.x + 160, y: local.y)
                session.insertShape(kind, in: board.id, rect: r, start: local, end: end)
            }
        default:
            break
        }
    }
}

// MARK: - 批注输入

private struct CommentNoteEditor: View {
    @Bindable var session: ProjectSession
    let artboardID: UUID
    let rect: ElementRect
    @State private var note = ""
    @FocusState private var focused: Bool

    var body: some View {
        if let board = session.currentPage?.artboards.first(where: { $0.id == artboardID }) {
            let r = session.viewRect(CGRect(x: board.x + rect.x, y: board.y + rect.y, width: rect.w, height: rect.h))
            VStack(alignment: .leading, spacing: 8) {
                Label("给这个元素留下修改意见", systemImage: "bubble.left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("例如：标题再大一点，改成深绿色", text: $note, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit { session.addComment(note: note) }
                HStack {
                    Button("取消") { session.pendingComment = nil }
                    Spacer()
                    Button("添加批注") { session.addComment(note: note) }
                        .buttonStyle(PrimaryActionButtonStyle())
                        .disabled(note.trimmed.isEmpty)
                }
                .controlSize(.small)
            }
            .padding(12)
            .frame(width: 280)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
            // 用 padding 布局定位（含文本框，不能用 offset，否则点击位置不对）
            .padding(.leading, min(r.maxX + 10, max(session.viewportSize.width - 300, 0)))
            .padding(.top, max(r.minY, 60))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear { focused = true }
        }
    }
}

// MARK: - 顶部浮动栏

private struct CanvasTopLeftBar: View {
    @Bindable var session: ProjectSession

    var body: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.snappy) { session.showChat.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.borderless)
            .tint(.primary)
            .help(session.showChat ? "隐藏对话" : "显示对话")

            Divider().frame(height: 16)

            PagePicker(session: session)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
    }
}

/// 页面切换：点开是与画布风格一致的弹出面板（页面列表 + 新建页面）
private struct PagePicker: View {
    @Bindable var session: ProjectSession
    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 5) {
                Text(session.currentPage?.name ?? "页面")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
        .tint(.primary)
        .help("切换页面（当前页面 \(session.currentPage?.artboards.count ?? 0) 个画板）")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            PageList(session: session) { isOpen = false }
        }
    }
}

private struct PageList: View {
    @Bindable var session: ProjectSession
    let dismiss: () -> Void
    @State private var hovered: UUID?
    @State private var hoveringNew = false
    @State private var renamingID: UUID?
    @State private var newName = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("页面")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 2)

            ForEach(session.document.pages) { page in
                row(page)
            }

            Divider().padding(.vertical, 4).padding(.horizontal, 6)

            Button {
                session.addPage()
                dismiss()
            } label: {
                Label("新建页面", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(hoveringNew ? Color.primary.opacity(0.06) : .clear, in: .rect(cornerRadius: 8))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .onHover { hoveringNew = $0 }
            .disabled(!session.isEditable)
        }
        .font(.callout)
        .padding(6)
        .frame(width: 220)
    }

    @ViewBuilder
    private func row(_ page: DesignPage) -> some View {
        let isCurrent = page.id == session.currentPage?.id
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.accent)
                .opacity(isCurrent ? 1 : 0)
                .frame(width: 12)
            if renamingID == page.id {
                TextField("页面名称", text: $newName)
                    .textFieldStyle(.plain)
                    .focused($renameFocused)
                    .onSubmit { commitRename(page.id) }
                    .onExitCommand { renamingID = nil }
            } else {
                Text(page.name)
                    .lineLimit(1)
                    .fontWeight(isCurrent ? .medium : .regular)
            }
            Spacer(minLength: 8)
            Text("\(page.artboards.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("\(page.artboards.count) 个画板")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            hovered == page.id ? Color.primary.opacity(0.06) : (isCurrent ? Theme.accent.opacity(0.10) : .clear),
            in: .rect(cornerRadius: 8)
        )
        .contentShape(.rect)
        .onHover { hovered = $0 ? page.id : (hovered == page.id ? nil : hovered) }
        .onTapGesture(count: 2) { startRename(page) }
        .onTapGesture {
            guard renamingID != page.id else { return }
            if !isCurrent { session.switchPage(page.id) }
            dismiss()
        }
        .contextMenu {
            Button("重命名", systemImage: "pencil") { startRename(page) }
            if session.document.pages.count > 1 {
                Button("删除页面", systemImage: "trash", role: .destructive) { session.deletePage(page.id) }
            }
        }
    }

    private func startRename(_ page: DesignPage) {
        newName = page.name
        renamingID = page.id
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename(_ id: UUID) {
        session.renamePage(id, to: newName)
        renamingID = nil
    }
}

/// 缩放比例菜单：显示当前缩放，点开可放大 / 缩小 / 适应
private struct ZoomMenu: View {
    let session: ProjectSession

    var body: some View {
        Menu {
            Button("放大", systemImage: "plus.magnifyingglass") { session.zoomIn() }
            Button("缩小", systemImage: "minus.magnifyingglass") { session.zoomOut() }
            Divider()
            Button("缩放到 50%") { session.setZoom(0.5) }
            Button("缩放到 100%") { session.zoomTo100() }
            Button("缩放到 200%") { session.setZoom(2) }
            Divider()
            Button(session.isFullScreen ? "适应窗口（⌘1）" : "适应画布（⌘1）") {
                session.isFullScreen ? session.fitFullScreen() : session.zoomToFit()
            }
            Button("缩放到选中（⌘2）") { session.zoomToSelection() }
        } label: {
            Text("\(Int((session.zoom * 100).rounded()))%")
                .monospacedDigit()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("缩放：⌘ + 滚轮或双指捏合")
    }
}

private struct CanvasTopRightBar: View {
    @Bindable var session: ProjectSession

    var body: some View {
        HStack(spacing: 10) {
            ZoomMenu(session: session)
                .tint(.primary)

            Button {
                session.toggleArtboardFullScreen()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .tint(.primary)
            .disabled(session.exportArtboard == nil)
            .help("全屏查看选中的画板（⇧⌘F），可交互，←/→ 切换")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
    }
}

private struct CanvasStatusBanner: View {
    @Bindable var session: ProjectSession

    var body: some View {
        if session.isGenerating {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(session.status ?? "生成中…")
                Button("停止") { session.stop() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.accent)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
        } else if let (id, err) = session.artboardErrors.first,
                  let board = session.document.artboard(id) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("「\(board.name)」运行出错：\(err)")
                    .lineLimit(1)
                    .frame(maxWidth: 420)
                Button("让 AI 修复") { session.fixError(in: id) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.accent)
                Button {
                    session.artboardErrors[id] = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
        }
    }
}

// MARK: - 滚轮 / 捏合缩放

/// 在画布区域拦截滚轮与捏合事件（否则会被画板网页吞掉）：
/// 双指滑动 / 滚轮平移，⌘ + 滚轮或双指捏合缩放
private struct CanvasEventMonitor: NSViewRepresentable {
    let session: ProjectSession

    func makeNSView(context: Context) -> MonitorView {
        let v = MonitorView()
        v.session = session
        return v
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.session = session
    }

    final class MonitorView: NSView {
        weak var session: ProjectSession?
        private var monitor: Any?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                // 本地事件监视器总在主线程回调
                nonisolated(unsafe) let e = event
                let consumed = MainActor.assumeIsolated { self?.consume(e) ?? false }
                return consumed ? nil : event
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            super.removeFromSuperview()
        }

        /// 返回 true 表示事件已被画布处理
        private func consume(_ event: NSEvent) -> Bool {
            guard let session, let window, event.window === window else { return false }
            let p = convert(event.locationInWindow, from: nil)
            guard bounds.contains(p) else { return false }
            // 文本输入等浮层在画布上方时不拦截
            if let hit = window.contentView?.hitTest(event.locationInWindow), hit is NSTextView { return false }

            switch event.type {
            case .magnify:
                session.setZoom(session.zoom * (1 + event.magnification), anchor: p)
                return true
            case .scrollWheel:
                if event.modifierFlags.contains(.command) {
                    let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
                    session.setZoom(session.zoom * exp(dy * 0.01), anchor: p)
                } else {
                    let k = event.hasPreciseScrollingDeltas ? 1.0 : 12.0
                    session.panBy(dx: event.scrollingDeltaX * k, dy: event.scrollingDeltaY * k)
                }
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - 全屏控制条

/// 全屏（专注模式）顶部控制条：全部 / 单个、切换画板、交互预览、检查器、退出
private struct FullScreenBar: View {
    @Bindable var session: ProjectSession
    /// 与底部工具栏相同的宽度
    let width: CGFloat

    private var boards: [Artboard] { session.currentPage?.artboards ?? [] }
    private var index: Int { boards.firstIndex { $0.id == session.previewArtboardID } ?? 0 }

    /// 全部 / 单个
    enum Scope: String, CaseIterable, Identifiable {
        case all = "全部"
        case single = "单个"
        var id: String { rawValue }
    }

    var body: some View {
        HStack(spacing: 8) {
            // Liquid Glass 标签：可点击或按住左右滑动切换
            GlassTabBar(items: Scope.allCases, title: \.rawValue, selection: Binding(
                get: { session.previewShowsAll ? .all : .single },
                set: { session.setFullScreenShowsAll($0 == .all) }
            ))
            .frame(width: 104)

            // 中间区域占满剩余宽度：切换全部 / 单个时整条宽度不变
            Group {
                if session.previewShowsAll {
                    Text("\(boards.count) 个画板")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    HStack(spacing: 4) {
                        Button { session.stepFullScreen(-1) } label: { Image(systemName: "chevron.left") }
                            .disabled(index == 0)
                            .help("上一个画板（←）")
                        Text("\(index + 1)/\(boards.count)")
                            .font(.callout.monospacedDigit())
                            .lineLimit(1)
                            .help(boards.indices.contains(index) ? boards[index].name : "")
                        Button { session.stepFullScreen(1) } label: { Image(systemName: "chevron.right") }
                            .disabled(index >= boards.count - 1)
                            .help("下一个画板（→）")
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .tint(.primary)

            ZoomMenu(session: session)
                .tint(.primary)

            // 未开启时与「全部」同为黑色，开启后用强调色
            Button {
                session.interactivePreview.toggle()
            } label: {
                Image(systemName: session.interactivePreview ? "hand.tap.fill" : "hand.tap")
                    .foregroundStyle(session.interactivePreview ? Theme.accent : Color.primary)
            }
            .help(session.interactivePreview ? "交互中：可以像真机一样点击页面；关闭后回到选中编辑" : "交互预览：直接点击页面里的按钮、切换等")

            Button {
                session.showInspector.toggle()
            } label: {
                Image(systemName: "sidebar.trailing")
            }
            .tint(session.showInspector ? Theme.accent : .primary)
            .help(session.showInspector ? "隐藏检查器" : "显示检查器（图层 / 属性 / 代码）")

            Button {
                session.exitFullScreen()
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
            }
            .tint(.primary)
            .help("退出全屏（Esc / ⇧⌘F）")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .frame(width: width)
        .glassEffect(.regular, in: .capsule)
    }
}
