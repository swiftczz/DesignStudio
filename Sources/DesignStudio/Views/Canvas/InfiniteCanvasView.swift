import SwiftUI
import AppKit
import Observation

/// 无限画布：所有画板摊开在画布上，可平移、缩放，直接选中和编辑元素
struct InfiniteCanvasView: View {
    @Bindable var session: ProjectSession
    let loadsWebContent: Bool
    @FocusState private var focused: Bool
    @State private var mountedArtboardIDs: Set<UUID> = []
    /// 底部工具栏的实际宽度：全屏顶部控制条与它等宽
    @State private var toolbarWidth: CGFloat = 320

    /// 浮动工具栏距画布上下边缘的距离（顶部控制条与底部工具栏对称）
    static let edgeInset: CGFloat = 18
    @State private var artboardDrag = ArtboardDragPreview()
    @State private var textBarSize = CGSize(width: 460, height: 38)
    /// 在空白处拖出的框选范围（视图坐标）
    @State private var marquee: (start: CGPoint, end: CGPoint)?
    /// ⇧ 框选时，开始前已选中的画板（框选结果加在后面）
    @State private var marqueeBase: [UUID] = []

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

    /// 在画布空白处拖动：框选碰到的画板（⇧ 加选）
    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(CanvasCoordinateSpace.viewport))
            .onChanged { value in
                guard session.tool == .select, !session.interactivePreview else { return }
                if marquee == nil {
                    focused = true
                    let current = !session.selectedArtboardIDs.isEmpty ? session.selectedArtboardIDs
                        : session.selection.flatMap { $0.elementID == nil ? [$0.artboardID] : nil } ?? []
                    marqueeBase = NSEvent.modifierFlags.contains(.shift) ? current : []
                }
                marquee = (value.startLocation, value.location)
                let a = session.worldPoint(value.startLocation), b = session.worldPoint(value.location)
                let area = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                let hits = (session.currentPage?.artboards ?? []).filter { $0.frame.intersects(area) }.map(\.id)
                let ids = marqueeBase + hits.filter { !marqueeBase.contains($0) }
                if ids.isEmpty { session.clearSelection() } else { session.selectArtboards(ids) }
            }
            .onEnded { _ in
                marquee = nil
                marqueeBase = []
            }
    }

    var body: some View {
        GeometryReader { geo in
            let boards = session.currentPage?.artboards ?? []
            ZStack(alignment: .topLeading) {
                CanvasGrid(zoom: session.zoom, pan: session.pan)
                    .contentShape(.rect)
                    .onTapGesture {
                        session.clearSelection()
                        focused = true
                    }
                    .gesture(marqueeGesture)

                ForEach(boards) { board in
                    ArtboardFrame(artboard: board, session: session, drag: artboardDrag,
                                  mountsWebView: mountedArtboardIDs.contains(board.id))
                        .zIndex(Double(artboardDrag.isMoving(board.id) ? 1 : 0))
                }

                if !session.interactivePreview && session.tool != .pencil {
                    SelectionLayer(session: session, drag: artboardDrag)
                        .allowsHitTesting(false)
                        .zIndex(2)
                }

                ArtboardGuideLayer(session: session, drag: artboardDrag)
                    .allowsHitTesting(false)
                    .zIndex(3)

                if let m = marquee {
                    let r = CGRect(x: min(m.start.x, m.end.x), y: min(m.start.y, m.end.y),
                                   width: abs(m.end.x - m.start.x), height: abs(m.end.y - m.start.y))
                    Rectangle()
                        .fill(CanvasPalette.selection.opacity(0.08))
                        .strokeBorder(CanvasPalette.selection.opacity(0.9), lineWidth: 1)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                        .allowsHitTesting(false)
                        .zIndex(3)
                }

                if session.tool.capturesPointer && session.isEditable && !session.interactivePreview {
                    Group {
                        if session.tool == .pencil {
                            PencilCaptureLayer(session: session)
                        } else {
                            ToolCaptureLayer(session: session)
                        }
                    }
                    .zIndex(4)
                }

                // 选中文字时，元素上方出现格式工具栏
                if let placement = textBarPlacement(viewport: geo.size) {
                    TextFormatBar(session: session, props: placement.props)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { textBarSize = $0 }
                        .offset(x: placement.origin.x, y: placement.origin.y)
                        .transition(.opacity)
                        .zIndex(5)
                }

                if let pending = session.pendingComment {
                    CommentNoteEditor(session: session, artboardID: pending.artboardID, rect: pending.props.rect)
                        .zIndex(5)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .coordinateSpace(.named(CanvasCoordinateSpace.viewport))
            .background(CanvasEventMonitor(session: session))
            .onAppear { session.viewportDidChange(geo.size) }
            .onChange(of: geo.size) { _, size in session.viewportDidChange(size) }
            .task(id: loadsWebContent ? boards.map(\.id) : []) {
                guard loadsWebContent else { return }
                await mountArtboards(boards, viewport: geo.size)
            }
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
        .onChange(of: session.tool) { _, tool in
            if tool == .note || tool == .pencil { focused = true }
        }
        .onKeyPress(phases: .down) { press in
            guard !session.isEditingText else { return .ignored }
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

    private func mountArtboards(_ boards: [Artboard], viewport: CGSize) async {
        guard !Task.isCancelled else { return }
        mountedArtboardIDs.formIntersection(boards.map(\.id))
        let bounds = CGRect(origin: .zero, size: viewport)
        let remaining = boards.filter { !mountedArtboardIDs.contains($0.id) }
        let visible = remaining.filter { session.viewRect($0.frame).intersects(bounds) }
        let visibleIDs = Set(visible.map(\.id))
        let order = visible + remaining.filter { !visibleIDs.contains($0.id) }

        for index in stride(from: 0, to: order.count, by: 2) {
            if index > 0 {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            mountedArtboardIDs.formUnion(order[index..<min(index + 2, order.count)].map(\.id))
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

private enum CanvasCoordinateSpace: Hashable {
    case viewport
}

/// 拖动画板时的预览：一个或多个画板（框选后）作为整体移动，整体外框对齐到其他画板
@Observable
private final class ArtboardDragPreview {
    private(set) var movingIDs: Set<UUID> = []
    private(set) var result: ArtboardAlignment.Result?
    private var startFrames: [UUID: CGRect] = [:]
    private var groupFrame = CGRect.zero
    private var grabOffset = CGSize.zero
    private var neighbors: [CGRect] = []

    func isMoving(_ id: UUID) -> Bool { movingIDs.contains(id) }

    func frame(for artboard: Artboard) -> CGRect {
        guard let start = startFrames[artboard.id], let moved = result?.frame else { return artboard.frame }
        return start.offsetBy(dx: moved.minX - groupFrame.minX, dy: moved.minY - groupFrame.minY)
    }

    func begin(_ artboards: [Artboard], at pointer: CGPoint, neighbors: [CGRect]) {
        guard let first = artboards.first else { return }
        movingIDs = Set(artboards.map(\.id))
        startFrames = Dictionary(uniqueKeysWithValues: artboards.map { ($0.id, $0.frame) })
        groupFrame = artboards.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        grabOffset = CGSize(width: pointer.x - groupFrame.minX, height: pointer.y - groupFrame.minY)
        self.neighbors = neighbors
    }

    func update(at pointer: CGPoint, zoom: CGFloat) {
        let origin = CGPoint(x: pointer.x - grabOffset.width, y: pointer.y - grabOffset.height)
        result = ArtboardAlignment.snap(CGRect(origin: origin, size: groupFrame.size),
                                        to: neighbors, tolerance: 5 / zoom)
    }

    /// 松手后每个画板的新位置（没有移动时为空）
    var finalOrigins: [UUID: CGPoint] {
        guard let moved = result?.frame, moved.origin != groupFrame.origin else { return [:] }
        return startFrames.mapValues {
            CGPoint(x: $0.minX + moved.minX - groupFrame.minX, y: $0.minY + moved.minY - groupFrame.minY)
        }
    }

    func clear(_ id: UUID) {
        guard movingIDs.contains(id) else { return }
        movingIDs = []
        startFrames = [:]
        result = nil
        neighbors = []
    }
}

private struct ArtboardGuideLayer: View {
    let session: ProjectSession
    let drag: ArtboardDragPreview

    var body: some View {
        let guides = drag.result?.guides ?? []
        Canvas { context, _ in
            for guide in guides {
                let start = session.viewPoint(guide.start), end = session.viewPoint(guide.end)
                let vertical = start.x == end.x
                let line = Path {
                    $0.move(to: CGPoint(x: start.x - (vertical ? 0 : 10), y: start.y - (vertical ? 10 : 0)))
                    $0.addLine(to: CGPoint(x: end.x + (vertical ? 0 : 10), y: end.y + (vertical ? 10 : 0)))
                }
                context.stroke(line, with: .color(.pink), lineWidth: 1)
            }
        }
    }
}

// MARK: - 画板

private struct ArtboardFrame: View {
    let artboard: Artboard
    @Bindable var session: ProjectSession
    let drag: ArtboardDragPreview
    let mountsWebView: Bool
    @GestureState private var isDragging = false
    @State private var renaming = false
    @State private var newName = ""

    private let headerHeight: CGFloat = 26

    private var selectedElementIDs: [Int] {
        guard let selection = session.selection, selection.artboardID == artboard.id,
              let id = selection.elementID else { return [] }
        return session.multiSelection.count > 1 ? session.multiSelection.map(\.id) : [id]
    }

    var body: some View {
        let z = session.zoom
        let origin = session.viewPoint(drag.frame(for: artboard).origin)
        let isSelected = session.selectedArtboardIDs.contains(artboard.id)
            || session.selection?.artboardID == artboard.id && session.selection?.elementID == nil
        // 框选的画板：拖动画板内容也能整体移动，单击则单独选中这个画板（之后可以再点选里面的元素）
        let boxSelected = session.selectedArtboardIDs.contains(artboard.id) && session.tool == .select
            && !session.interactivePreview

        let width = max(artboard.width * z, 120)
        let height = headerHeight + artboard.height * z

        // 注意：必须用 position（布局）而不是 offset（只移动绘制）定位，
        // 否则 WKWebView 的真实 frame 仍叠在原点：WebKit 会当成被遮挡而不绘制，鼠标点击也会落到错误的画板上
        VStack(alignment: .leading, spacing: 6) {
            header(isSelected: isSelected)
                .frame(width: width, height: headerHeight - 6, alignment: .leading)

            Group {
                if mountsWebView {
                    ArtboardWebView(artboard: artboard, zoom: z, mode: session.editorMode(for: artboard.id),
                                    selectedElementIDs: selectedElementIDs, session: session)
                } else {
                    Color.clear
                }
            }
                .frame(width: artboard.width * z, height: artboard.height * z)
                .background(.white)
                .clipShape(.rect(cornerRadius: 2))
                .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
                .overlay {
                    if boxSelected {
                        Color.clear
                            .contentShape(.rect)
                            .onTapGesture { session.select(CanvasSelection(artboardID: artboard.id, elementID: nil)) }
                            .gesture(moveGesture)
                            .pointerStyle(drag.isMoving(artboard.id) ? .grabActive : .grabIdle)
                    }
                }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .position(x: origin.x + width / 2, y: origin.y - headerHeight + height / 2)
        .onChange(of: isDragging) { _, active in
            if !active { drag.clear(artboard.id) }
        }
        .onDisappear { drag.clear(artboard.id) }
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
                ArtboardExportMenu(artboard: artboard, session: session)
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
        .gesture(moveGesture)
        .pointerStyle(drag.isMoving(artboard.id) ? .grabActive : .grabIdle)
    }

    /// 拖动画板：属于框选的多个画板时整体移动，否则只移动这一个
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(CanvasCoordinateSpace.viewport))
            .updating($isDragging) { _, active, transaction in
                active = true
                transaction.animation = nil
            }
            .onChanged { value in
                guard session.isEditable, !renaming else { return }
                if !drag.isMoving(artboard.id) {
                    let all = session.currentPage?.artboards ?? []
                    let group = session.selectedArtboardIDs.count > 1 && session.selectedArtboardIDs.contains(artboard.id)
                        ? all.filter { session.selectedArtboardIDs.contains($0.id) } : [artboard]
                    let ids = Set(group.map(\.id))
                    drag.begin(group, at: session.worldPoint(value.startLocation),
                               neighbors: all.filter { !ids.contains($0.id) }.map(\.frame))
                    if group.count == 1 && !session.selectedArtboardIDs.contains(artboard.id) {
                        session.select(CanvasSelection(artboardID: artboard.id, elementID: nil))
                    }
                    session.userMovedViewport()
                }
                drag.update(at: session.worldPoint(value.location), zoom: session.zoom)
            }
            .onEnded { value in
                guard drag.isMoving(artboard.id) else { return }
                defer { drag.clear(artboard.id) }
                drag.update(at: session.worldPoint(value.location), zoom: session.zoom)
                let origins = drag.finalOrigins
                if origins.count == 1, let (id, origin) = origins.first {
                    session.moveArtboard(id, to: origin)
                } else {
                    session.moveArtboards(origins)
                }
            }
    }
}

// MARK: - 选中框 / 悬停框

private struct SelectionLayer: View {
    let session: ProjectSession
    let drag: ArtboardDragPreview

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let hover = session.hover, hover.elementID != session.selection?.elementID || hover.artboardID != session.selection?.artboardID,
               let rect = elementRect(hover.artboardID, hover.rect) {
                Rectangle()
                    .strokeBorder(CanvasPalette.selection.opacity(0.7), lineWidth: 1)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }

            if session.selectedArtboardIDs.count > 1 {
                // 框选了多个画板：每个画板一个细框，外面一个整体选中框
                let rects = (session.currentPage?.artboards ?? [])
                    .filter { session.selectedArtboardIDs.contains($0.id) }
                    .map { session.viewRect(drag.frame(for: $0)) }
                ForEach(Array(rects.enumerated()), id: \.offset) { _, r in
                    Rectangle()
                        .strokeBorder(CanvasPalette.selection, lineWidth: 1)
                        .frame(width: max(r.width, 1), height: max(r.height, 1))
                        .offset(x: r.minX, y: r.minY)
                }
                if let union = rects.dropFirst().reduce(rects.first, { $0?.union($1) }) {
                    SelectionBox(rect: union.insetBy(dx: -4, dy: -4), label: "已选 \(rects.count) 个画板")
                }
            } else if let sel = session.selection, let board = session.currentPage?.artboards.first(where: { $0.id == sel.artboardID }) {
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
                    SelectionBox(rect: session.viewRect(drag.frame(for: board)),
                                 label: "\(Int(board.width)) × \(Int(board.height))")
                }
            }
        }
    }

    private func elementRect(_ artboardID: UUID, _ r: ElementRect) -> CGRect? {
        guard let board = session.currentPage?.artboards.first(where: { $0.id == artboardID }) else { return nil }
        let frame = drag.frame(for: board)
        return session.viewRect(CGRect(x: frame.minX + r.x, y: frame.minY + r.y, width: r.w, height: r.h))
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
            DragGesture(minimumDistance: 0, coordinateSpace: .named(CanvasCoordinateSpace.viewport))
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
                    if let p = panStart {
                        session.pan = CGPoint(x: p.x + v.translation.width, y: p.y + v.translation.height)
                    } else if session.tool != .hand {
                        finish(start: v.startLocation, end: v.location)
                    }
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
        case .text, .note, .rectangle, .image:
            guard let board = session.currentPage?.artboards.last(where: { $0.frame.contains(ws) }) else {
                NSSound.beep()
                return
            }
            let local = CGPoint(x: ws.x - board.x, y: ws.y - board.y)
            switch session.tool {
            case .text: session.insertText(in: board.id, at: local)
            case .note: session.insertNote(in: board.id, at: local)
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

private struct PencilCaptureLayer: View {
    let session: ProjectSession
    @GestureState private var dragging = false
    @State private var stroke: Stroke?

    private struct Stroke {
        var board: Artboard
        var style: PencilStroke
        var points: [CGPoint]

        func localPoint(_ worldPoint: CGPoint) -> CGPoint {
            CGPoint(x: min(max(worldPoint.x - board.x, 0), board.width),
                    y: min(max(worldPoint.y - board.y, 0), board.height))
        }
    }

    var body: some View {
        ZStack {
            Color.clear
            if let stroke {
                let boardRect = session.viewRect(stroke.board.frame)
                let scale = session.zoom
                Canvas { context, _ in
                    context.clip(to: Path(boardRect))
                    let path = Path { path in
                        path.addLines(stroke.points.map {
                            CGPoint(x: boardRect.minX + $0.x * scale, y: boardRect.minY + $0.y * scale)
                        })
                    }
                    context.stroke(path, with: .color(Color(hex: PencilStroke.color)),
                                   style: StrokeStyle(lineWidth: stroke.style.width * scale, lineCap: .round,
                                                      lineJoin: .round, dash: stroke.style.dash.map { $0 * scale }))
                }
                .allowsHitTesting(false)
            }
        }
        .contentShape(.rect)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(CanvasCoordinateSpace.viewport))
            .updating($dragging) { _, active, _ in active = true }
            .onChanged { value in
                if stroke == nil {
                    let start = session.worldPoint(value.startLocation)
                    guard let board = session.currentPage?.artboards.last(where: { $0.frame.contains(start) }),
                          !session.streamingArtboardIDs.contains(board.id) else { return }
                    let point = CGPoint(x: start.x - board.x, y: start.y - board.y)
                    stroke = Stroke(board: board, style: session.pencilStroke, points: [point])
                    session.userMovedViewport()
                }
                appendPoint(at: value.location)
            }
            .onEnded { value in
                defer { stroke = nil }
                appendPoint(at: value.location)
                guard let stroke, session.currentPage?.artboards.contains(where: { $0.id == stroke.board.id }) == true else { return }
                session.insertPencilStroke(stroke.style, points: stroke.points, in: stroke.board.id)
            })
        .onChange(of: dragging) { _, active in if !active { stroke = nil } }
        .pointerStyle(.rectSelection)
    }

    private func appendPoint(at position: CGPoint) {
        guard let point = stroke?.localPoint(session.worldPoint(position)), stroke?.points.last != point else { return }
        stroke?.points.append(point)
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
            .accessibilityLabel(session.showChat ? "隐藏对话" : "显示对话")
            .help(session.showChat ? "隐藏对话" : "显示对话")

            Divider().frame(height: 16)

            PagePicker(session: session)
            ArtboardFinder(session: session)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
    }
}

private struct ArtboardFinder: View {
    let session: ProjectSession
    @State private var isOpen = false
    @State private var query = ""

    var body: some View {
        Button {
            query = ""
            isOpen.toggle()
        } label: {
            Image(systemName: "magnifyingglass")
        }
        .buttonStyle(.borderless)
        .tint(.primary)
        .accessibilityLabel("查找画板")
        .help("查找并定位画板")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            let boards = session.currentPage?.artboards ?? []
            let matches = boards.filter { query.trimmed.isEmpty || $0.name.localizedStandardContains(query.trimmed) }
            VStack(alignment: .leading, spacing: 8) {
                TextField("搜索当前画布", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if let board = matches.first { reveal(board) } }
                if matches.isEmpty {
                    Text("没有匹配的画板").foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(matches) { board in
                                Button { reveal(board) } label: {
                                    HStack {
                                        Text(board.name).lineLimit(1)
                                        Spacer()
                                        Text("\(Int(board.width)) × \(Int(board.height))").foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(height: min(CGFloat(matches.count) * 25, 240))
                }
            }
            .padding(12)
            .frame(width: 265)
        }
    }

    private func reveal(_ board: Artboard) {
        session.select(CanvasSelection(artboardID: board.id, elementID: nil))
        session.zoomToSelection()
        isOpen = false
    }
}

/// 画布切换与画板排列菜单
private struct PagePicker: View {
    @Bindable var session: ProjectSession
    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 5) {
                Text(session.currentPage?.displayName ?? "画布")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
        .tint(.primary)
        .help("切换画布（当前画布 \(session.currentPage?.artboards.count ?? 0) 个画板）")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            PageList(session: session) { isOpen = false }
        }
    }
}

private struct PageList: View {
    @Bindable var session: ProjectSession
    let dismiss: () -> Void
    @State private var hovered: UUID?
    @State private var hoveringArrange = false
    @State private var hoveringNew = false
    @State private var renamingID: UUID?
    @State private var newName = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("画布")
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
                session.rearrangeArtboards()
                dismiss()
            } label: {
                Label("重新排列画板", systemImage: "square.grid.2x2")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(hoveringArrange && session.canRearrangeArtboards ? Color.primary.opacity(0.06) : .clear,
                                in: .rect(cornerRadius: 8))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { hoveringArrange = $0 }
            .disabled(!session.canRearrangeArtboards)

            Button {
                session.addPage()
                dismiss()
            } label: {
                Label("新建画布", systemImage: "plus")
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
                TextField("画布名称", text: $newName)
                    .textFieldStyle(.plain)
                    .focused($renameFocused)
                    .onSubmit { commitRename(page.id) }
                    .onExitCommand { renamingID = nil }
            } else {
                Text(page.displayName)
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
            Button("重命名画布", systemImage: "pencil") { startRename(page) }
            if session.document.pages.count > 1 {
                Button("删除画布", systemImage: "trash", role: .destructive) { session.deletePage(page.id) }
            }
        }
    }

    private func startRename(_ page: DesignPage) {
        newName = page.displayName
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
