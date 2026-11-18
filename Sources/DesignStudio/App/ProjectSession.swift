import SwiftUI
import AppKit
import Observation

/// 单个项目的运行时状态：设计文档、无限画布视口、选中与编辑、AI 生成、批注、可调参数
@MainActor
@Observable
final class ProjectSession {
    @ObservationIgnored unowned let app: AppModel
    let projectID: UUID

    // MARK: 文档
    /// 当前设计文档（所有页面与画板）；编辑后立即写回项目
    private(set) var document: DesignDocument
    /// 生成过程中的实时预览文档
    private(set) var liveDocument: DesignDocument?
    var currentPageID: UUID?

    // MARK: 视口
    var zoom: Double = 0.5 {
        didSet { if zoom != oldValue { scheduleSelectionRefresh() } }
    }
    @ObservationIgnored private var selectionRefreshTask: Task<Void, Never>?

    /// 缩放停下后重新读取选中元素的位置：画板排版与缩放无关，但网页字体等资源晚到也可能让元素移动
    private func scheduleSelectionRefresh() {
        selectionRefreshTask?.cancel()
        guard let target = selection, target.elementID != nil else { return }
        selectionRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            await self.refreshProps(target)
        }
    }
    var pan: CGPoint = CGPoint(x: 80, y: 120)
    var viewportSize: CGSize = .zero
    @ObservationIgnored private var didInitialFit = false

    // MARK: 选中与编辑
    var tool: CanvasTool = .select
    var selection: CanvasSelection?
    var selectedProps: ElementProps?
    /// ⇧ 点击多选的元素（同一个画板里，2 个及以上时才有值）
    var multiSelection: [SelectedElement] = []
    var hover: CanvasHover?
    /// 正在画板里行内编辑文字（这时 ⌘C / ⌘V 交给网页处理文字）
    var isEditingText = false
    /// 画布本身（而不是对话框等文字输入框）拥有键盘焦点
    var canvasFocused = false
    /// 应用内的元素剪贴板：同一个画板里粘贴用源码（保留 class），跨画板用样式展开后的代码
    private(set) var elementClipboard: ElementClipboard?
    /// 拷贝的属性（元素最终生效的样式）
    private(set) var copiedStyle: [String: String]?
    var trees: [UUID: [ElementNode]] = [:]
    var expandedLayers: Set<String> = []
    var pendingComment: (artboardID: UUID, props: ElementProps)?
    var artboardErrors: [UUID: String] = [:]

    // MARK: 面板
    var showChat = true
    /// 进入项目时只显示对话栏和画布，检查器按需打开
    var showInspector = false
    var showAskAI = false
    /// 全屏（专注模式）：当前聚焦的画板；非 nil 即处于全屏
    private(set) var previewArtboardID: UUID?
    /// 全屏时展示当前页全部画板（false 为聚焦单个画板）
    private(set) var previewShowsAll = true
    /// 交互预览：画板网页正常响应点击（不再选中元素）
    var interactivePreview = false
    var isFullScreen: Bool { previewArtboardID != nil }
    @ObservationIgnored private var savedLayout: (chat: Bool, sidebar: NavigationSplitViewVisibility)?
    /// 在此时间之前，画布尺寸变化时自动重新适应（进出全屏、面板收起的动画期间）
    @ObservationIgnored private var refitUntil = Date.distantPast

    // MARK: 生成
    var draft = ""
    /// 画布上「询问 AI」浮条的输入，与左侧对话框分开
    var askDraft = ""
    /// 形状工具当前画的图形，以及形状选择条是否展开
    var shapeKind: ShapeKind = .rectangle
    var showShapePicker = false
    var draftAttachments: [ChatAttachment] = []
    var isGenerating = false
    var streamingText = ""
    var streamingThinking = ""
    var streamingMessageID: UUID?
    var status: String?
    var tweakValues: [String: String] = [:]
    var lastUsage: (input: Int, output: Int)?

    @ObservationIgnored private var handles: [UUID: ArtboardHandle] = [:]
    @ObservationIgnored private var undoStack: [DesignDocument] = []
    @ObservationIgnored private var redoStack: [DesignDocument] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var wasCancelled = false
    @ObservationIgnored private var lastLiveUpdate = Date.distantPast
    @ObservationIgnored private var streamingArtifactStarted = false
    @ObservationIgnored private var generationPageID: UUID?
    @ObservationIgnored private var generationTarget: UUID?
    /// 从空白页面开始生成：新画板出现时自动缩放到能看全
    @ObservationIgnored private var generationStartedEmpty = false
    /// 元素级修改的目标（生成结束后用模型返回的元素替换它）
    @ObservationIgnored private var generationElement: (selection: CanvasSelection, source: String)?
    @ObservationIgnored private var needsThumbnail = false

    init(app: AppModel, projectID: UUID) {
        self.app = app
        self.projectID = projectID
        let project = app.project(projectID)
        document = project?.workingDocument ?? DesignDocument()
        currentPageID = document.pages.first?.id
        needsThumbnail = !(document.isEmpty) && app.thumbnailStamps[projectID] == nil
    }

    // MARK: - 派生

    var project: Project? { app.project(projectID) }
    var kind: ProjectKind { project?.kind ?? .prototype }
    var hasDesign: Bool { !document.isEmpty }

    /// 画布上显示的文档（生成中显示实时预览）
    var displayedDocument: DesignDocument { liveDocument ?? document }
    var currentPage: DesignPage? { displayedDocument.page(currentPageID) }

    var selectedArtboard: Artboard? {
        guard let id = selection?.artboardID else { return nil }
        return displayedDocument.artboard(id)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    /// 生成过程中也可以平移画布、查看和修改元素；只有正在被模型重写的画板不能编辑（见 streamingArtboardIDs）
    var isEditable: Bool { true }

    /// 生成中正在被模型输出覆盖的画板：每隔一会儿就会重新加载，期间不能选中或编辑
    private(set) var streamingArtboardIDs: Set<UUID> = []
    /// 生成过程中用户自己移动 / 缩放过画布：之后不再自动「适应画布」，免得把视图拽走
    private var viewportAdjustedDuringGeneration = false

    /// 用户手动平移 / 缩放画布
    func userMovedViewport() {
        if isGenerating { viewportAdjustedDuringGeneration = true }
    }

    var pendingComments: [CanvasComment] { project?.comments.filter { !$0.resolved } ?? [] }

    var canSend: Bool {
        !isGenerating && (!draft.trimmed.isEmpty || !pendingComments.isEmpty || !draftAttachments.isEmpty)
    }

    var canAsk: Bool { !isGenerating && !askDraft.trimmed.isEmpty }
    /// 右键菜单「询问 AI」：有选中对象且没有在生成
    var canAskAboutSelection: Bool { selection != nil && !isGenerating }

    var provider: ProviderProfile? {
        if let chosen = app.provider(for: project?.providerID) {
            return chosen.resolved(model: project?.model, effort: project?.effort)
        }
        return app.defaultProvider
    }

    func editorMode(for artboardID: UUID) -> EditorMode {
        guard isEditable, !interactivePreview, !tool.capturesPointer,
              !streamingArtboardIDs.contains(artboardID) else { return .off }
        return tool == .comment ? .comment : .select
    }

    func handle(for artboardID: UUID) -> ArtboardHandle {
        if let h = handles[artboardID] { return h }
        let h = ArtboardHandle(artboardID: artboardID)
        handles[artboardID] = h
        return h
    }

    // MARK: - 视口

    /// 世界坐标（CSS 像素）→ 画布视图坐标
    func viewPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * zoom + pan.x, y: p.y * zoom + pan.y)
    }

    func worldPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - pan.x) / zoom, y: (p.y - pan.y) / zoom)
    }

    func viewRect(_ r: CGRect) -> CGRect {
        CGRect(origin: viewPoint(r.origin), size: CGSize(width: r.width * zoom, height: r.height * zoom))
    }

    func setZoom(_ newZoom: Double, anchor: CGPoint? = nil) {
        let z = min(max(newZoom, 0.05), 4)
        let a = anchor ?? CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        userMovedViewport()
        let ratio = z / zoom
        pan = CGPoint(x: a.x - (a.x - pan.x) * ratio, y: a.y - (a.y - pan.y) * ratio)
        zoom = z
    }

    func zoomIn() { setZoom(zoom * 1.25) }
    func zoomOut() { setZoom(zoom / 1.25) }
    func zoomTo100() { setZoom(1) }

    func panBy(dx: Double, dy: Double) {
        userMovedViewport()
        pan = CGPoint(x: pan.x + dx, y: pan.y + dy)
    }

    /// 缩放到能看到整个页面（或指定区域）
    func zoomToFit(_ rect: CGRect? = nil, padding: Double = 48) {
        guard viewportSize.width > 0, let r = rect ?? currentPage?.bounds, r.width > 0, r.height > 0 else { return }
        // 顶部留出浮动控制条 + 画板标题，底部留出浮动工具栏
        // 画布从窗口顶端算起（标题栏透明），两种状态下顶部都留出控制条的位置
        let top: Double = 104
        let bottom: Double = 84
        let w = max(viewportSize.width - padding * 2, 100)
        let h = max(viewportSize.height - top - bottom, 100)
        let z = min(max(min(w / r.width, h / r.height), 0.05), isFullScreen ? 2 : 1)
        zoom = z
        pan = CGPoint(x: (viewportSize.width - r.width * z) / 2 - r.minX * z,
                      y: top + (h - r.height * z) / 2 - r.minY * z)
    }

    func zoomToSelection() {
        guard let a = selectedArtboard else { zoomToFit(); return }
        zoomToFit(a.frame)
    }

    func viewportDidChange(_ size: CGSize) {
        viewportSize = size
        if Date() < refitUntil { isFullScreen ? fitFullScreen() : zoomToFit() }
        if !didInitialFit, size.width > 0, currentPage?.bounds != nil {
            didInitialFit = true
            zoomToFit()
        }
    }

    /// 全屏（专注模式）：收起左侧项目栏与对话、隐藏标题，画布铺满窗口；右侧检查器可随时打开
    func toggleArtboardFullScreen() {
        if isFullScreen { exitFullScreen() } else { enterFullScreen(artboardID: nil, showAll: true) }
    }

    /// 全屏聚焦指定画板
    func showFullScreen(_ artboardID: UUID) {
        if isFullScreen {
            previewArtboardID = artboardID
            setFullScreenShowsAll(false)
        } else {
            enterFullScreen(artboardID: artboardID, showAll: false)
        }
    }

    private func enterFullScreen(artboardID: UUID?, showAll: Bool) {
        guard let id = artboardID ?? exportArtboard?.id else { return }
        savedLayout = (showChat, app.sidebarVisibility)
        previewShowsAll = showAll
        previewArtboardID = id
        withAnimation(.snappy) {
            showChat = false
            app.sidebarVisibility = .detailOnly
        }
        scheduleRefit()
    }

    func exitFullScreen() {
        guard isFullScreen else { return }
        previewArtboardID = nil
        interactivePreview = false
        if let saved = savedLayout {
            withAnimation(.snappy) {
                showChat = saved.chat
                app.sidebarVisibility = saved.sidebar
            }
        }
        savedLayout = nil
        scheduleRefit()
    }

    func setFullScreenShowsAll(_ all: Bool) {
        previewShowsAll = all
        if !all, let sel = selection?.artboardID { previewArtboardID = sel }
        fitFullScreen()
    }

    /// 单个模式下切换到上 / 下一个画板
    func stepFullScreen(_ delta: Int) {
        let boards = currentPage?.artboards ?? []
        guard let i = boards.firstIndex(where: { $0.id == previewArtboardID }) else { return }
        let next = min(max(i + delta, 0), boards.count - 1)
        previewArtboardID = boards[next].id
        previewShowsAll = false
        select(CanvasSelection(artboardID: boards[next].id, elementID: nil))
        fitFullScreen()
    }

    func fitFullScreen() {
        if previewShowsAll {
            zoomToFit()
        } else if let id = previewArtboardID, let a = document.artboard(id) {
            zoomToFit(a.frame)
        }
    }

    private func scheduleRefit() {
        refitUntil = Date().addingTimeInterval(1.0)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isFullScreen ? self.fitFullScreen() : self.zoomToFit()
        }
    }

    // MARK: - 选中

    func select(_ target: CanvasSelection?) {
        selection = target
        selectedProps = nil
        multiSelection = []
        guard let target else { return }
        if let id = target.elementID {
            expandAncestors(of: id, in: target.artboardID)
            Task { await refreshProps(target) }
        } else {
            expandedLayers.insert(LayerID.artboard(target.artboardID))
        }
    }

    func clearSelection() {
        selection = nil
        selectedProps = nil
        multiSelection = []
        pendingComment = nil
    }

    private func refreshProps(_ target: CanvasSelection) async {
        guard let id = target.elementID else { return }
        let props = await handle(for: target.artboardID).decode(ElementProps.self, "return window.__ds.props(id)", ["id": id])
        if selection == target { selectedProps = props }
    }

    private func expandAncestors(of elementID: Int, in artboardID: UUID) {
        expandedLayers.insert(LayerID.artboard(artboardID))
        if let path = ElementNode.path(to: elementID, in: trees[artboardID] ?? []) {
            for id in path.dropLast() { expandedLayers.insert(LayerID.element(artboardID, id)) }
        }
    }

    func setHover(artboardID: UUID, elementID: Int?) {
        guard let elementID else { hover = nil; return }
        Task {
            let rect = await handle(for: artboardID).decode(ElementRect.self, "return window.__ds.rect(id)", ["id": elementID])
            if let rect { hover = CanvasHover(artboardID: artboardID, elementID: elementID, rect: rect) }
        }
    }

    // MARK: - 编辑脚本消息

    func artboardDidLoad(_ id: UUID, tree: [ElementNode]) {
        trees[id] = tree
        artboardErrors[id] = nil
        if expandedLayers.isEmpty || !expandedLayers.contains(LayerID.artboard(id)) {
            expandedLayers.insert(LayerID.artboard(id))
        }
        if !tweakValues.isEmpty {
            for (name, raw) in tweakValues {
                let css = tweakControls.first { $0.variable == name }?.cssValue(raw) ?? raw
                handle(for: id).run("window.__ds.setVar(n, v)", ["n": name, "v": css])
            }
        }
        if let sel = selection, sel.artboardID == id, sel.elementID != nil {
            Task { await refreshProps(sel) }
        }
        if needsThumbnail, !isGenerating, id == document.pages.first?.artboards.first?.id {
            needsThumbnail = false
            let pid = projectID
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                if let image = await handle(for: id).snapshot(width: 480) { app.saveThumbnail(image, for: pid) }
            }
        }
    }

    func handleEditorMessage(_ msg: EditorMessage, from artboardID: UUID) {
        switch msg.type {
        case "hover":
            if let id = msg.id, let rect = msg.rect {
                hover = CanvasHover(artboardID: artboardID, elementID: id, rect: rect)
            } else if hover?.artboardID == artboardID {
                hover = nil
            }
        case "editing":
            isEditingText = true
        case "select":
            isEditingText = false
            multiSelection = msg.multi ?? []
            if let p = msg.props {
                selection = CanvasSelection(artboardID: artboardID, elementID: p.id)
                selectedProps = p
                expandAncestors(of: p.id, in: artboardID)
            } else {
                selection = CanvasSelection(artboardID: artboardID, elementID: nil)
                selectedProps = nil
            }
        case "dragging":
            if let rect = msg.rect, var p = selectedProps, p.id == msg.id {
                p.rect = rect
                selectedProps = p
            }
        case "changed":
            isEditingText = false
            if let r = msg.result { apply(r, artboardID: artboardID) }
        case "commentPick":
            if let p = msg.props {
                selection = CanvasSelection(artboardID: artboardID, elementID: p.id)
                selectedProps = p
                pendingComment = (artboardID, p)
            }
        case "key":
            handleKey(key: msg.key ?? "", command: msg.meta ?? false, shift: msg.shift ?? false)
        case "error":
            if let m = msg.message, !m.isEmpty { artboardErrors[artboardID] = m }
        default:
            break
        }
    }

    // MARK: - 元素编辑

    private func apply(_ r: EditResult, artboardID: UUID) {
        if let tree = r.tree { trees[artboardID] = tree }
        multiSelection = r.multi ?? []
        if let source = r.source {
            let clean = HTMLAnnotator.strip(source)
            handle(for: artboardID).loadedSource = clean   // 网页已是最新状态，不必重新加载
            commit { $0.updateArtboard(artboardID) { $0.html = clean } }
        }
        if let id = r.id {
            selection = CanvasSelection(artboardID: artboardID, elementID: id)
            selectedProps = r.props
            expandAncestors(of: id, in: artboardID)
        } else if r.props == nil, r.source != nil, selection?.artboardID == artboardID {
            selection = CanvasSelection(artboardID: artboardID, elementID: nil)
            selectedProps = nil
        }
    }

    private func edit(_ body: String, _ args: [String: Any], artboardID: UUID) async {
        guard isEditable else { return }
        guard let r = await handle(for: artboardID).decode(EditResult.self, body, args) else { return }
        apply(r, artboardID: artboardID)
    }

    /// 设置选中元素的 CSS 属性（空字符串表示移除）
    func setStyle(_ values: [String: String]) {
        guard let sel = selection, let id = sel.elementID else { return }
        Task { await edit("return window.__ds.setStyle(id, m)", ["id": id, "m": values], artboardID: sel.artboardID) }
    }

    func setStyle(_ property: String, _ value: String) { setStyle([property: value]) }

    func setText(_ text: String) {
        guard let sel = selection, let id = sel.elementID else { return }
        Task { await edit("return window.__ds.setText(id, t)", ["id": id, "t": text], artboardID: sel.artboardID) }
    }

    func setAttribute(_ name: String, _ value: String) {
        guard let sel = selection, let id = sel.elementID else { return }
        Task { await edit("return window.__ds.setAttr(id, n, v)", ["id": id, "n": name, "v": value], artboardID: sel.artboardID) }
    }

    func deleteSelection() {
        guard isEditable, let sel = selection else { return }
        if multiSelection.count > 1 {
            let ids = multiSelection.map(\.id)
            Task { await edit("return window.__ds.removeMany(ids)", ["ids": ids], artboardID: sel.artboardID) }
        } else if let id = sel.elementID {
            Task { await edit("return window.__ds.remove(id)", ["id": id], artboardID: sel.artboardID) }
        } else {
            deleteArtboard(sel.artboardID)
        }
    }

    func duplicateSelection() {
        guard isEditable, let sel = selection else { return }
        if let id = sel.elementID {
            Task { await edit("return window.__ds.duplicate(id)", ["id": id], artboardID: sel.artboardID) }
        } else {
            duplicateArtboard(sel.artboardID)
        }
    }

    // MARK: - 右键菜单 / 剪贴板操作

    private var selectedElement: (artboardID: UUID, id: Int)? {
        guard let sel = selection, let id = sel.elementID else { return nil }
        return (sel.artboardID, id)
    }

    func copySelection() {
        guard let (board, id) = selectedElement else { return }
        Task {
            let h = handle(for: board)
            guard let source = await h.call("return window.__ds.outer(id)", ["id": id]) else { return }
            let inlined = await h.call("return window.__ds.inlined(id)", ["id": id]) ?? source
            let clip = ElementClipboard(artboardID: board, source: source, inlined: inlined)
            elementClipboard = clip
            clip.write(to: .general)
        }
    }

    func cutSelection() {
        guard selectedElement != nil else { return }
        copySelection()
        Task {
            try? await Task.sleep(for: .milliseconds(80))   // 先完成拷贝再删除
            deleteSelection()
        }
    }

    /// 粘贴：选中元素时放在它后面，选中画板时放进画板；支持应用内元素、图片、HTML 和纯文本
    func paste() {
        guard let sel = selection else { return }
        let html: String
        if let clip = ElementClipboard.read(from: .general) ?? elementClipboard {
            html = clip.artboardID == sel.artboardID ? clip.source : clip.inlined
        } else if let image = NSImage(pasteboard: .general), let png = ImageUtil.pngData(image, maxWidth: 1600) {
            html = #"<img data-name="图片" alt="" src="data:image/png;base64,\#(png.base64EncodedString())" style="width:\#(Int(min(image.size.width, 320)))px;height:auto;display:block">"#
        } else if let text = NSPasteboard.general.string(forType: .string)?.trimmed, !text.isEmpty {
            html = text.hasPrefix("<") ? text
                : "<p data-name=\"文本\" style=\"margin:0\">\(text.htmlEscaped)</p>"
        } else {
            return
        }
        if let id = sel.elementID {
            Task { await edit("return window.__ds.insertAfter(id, h)", ["id": id, "h": html], artboardID: sel.artboardID) }
        } else {
            Task { await edit("return window.__ds.insert(h, null, null)", ["h": html], artboardID: sel.artboardID) }
        }
    }

    var canPaste: Bool {
        elementClipboard != nil || ElementClipboard.read(from: .general) != nil
            || NSImage.canInit(with: .general) || NSPasteboard.general.string(forType: .string) != nil
    }

    /// 拷贝为 PNG：选中元素（或整个画板）的截图，2 倍分辨率
    func copySelectionAsPNG() {
        guard let sel = selection else { return }
        Task {
            let h = handle(for: sel.artboardID)
            var rect: CGRect?
            if let id = sel.elementID {
                rect = await h.decode(ElementRect.self, "return window.__ds.rect(id)", ["id": id])?.cgRect
            }
            guard let image = await h.snapshot(cssRect: rect, scale: 2) else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([image])
        }
    }

    /// 拷贝为 SVG：样式展开后的元素放进 foreignObject，可以粘贴到 Figma 等工具
    func copySelectionAsSVG() {
        guard let (board, id) = selectedElement else { return }
        Task {
            let h = handle(for: board)
            guard let html = await h.call("return window.__ds.inlined(id)", ["id": id]),
                  let rect = await h.decode(ElementRect.self, "return window.__ds.rect(id)", ["id": id]) else { return }
            let w = Int(rect.w.rounded(.up)), hgt = Int(rect.h.rounded(.up))
            let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" width="\(w)" height="\(hgt)" viewBox="0 0 \(w) \(hgt)">
              <foreignObject x="0" y="0" width="\(w)" height="\(hgt)">
                <div xmlns="http://www.w3.org/1999/xhtml">
            \(html)
                </div>
              </foreignObject>
            </svg>
            """
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(svg, forType: .string)
            pb.setData(Data(svg.utf8), forType: NSPasteboard.PasteboardType("public.svg-image"))
        }
    }

    /// 拷贝为 HTML：样式展开后的代码，可以单独使用
    func copySelectionAsHTML() {
        guard let sel = selection else { return }
        Task {
            let text: String?
            if let id = sel.elementID {
                text = await handle(for: sel.artboardID).call("return window.__ds.inlined(id)", ["id": id])
            } else {
                text = document.artboard(sel.artboardID)?.html
            }
            guard let text else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            pb.setString(text, forType: .html)
        }
    }

    func copyProperties() {
        guard let (board, id) = selectedElement else { return }
        Task {
            guard let json = await handle(for: board).call("return window.__ds.styleOf(id)", ["id": id]),
                  let map = try? JSONDecoder().decode([String: String].self, from: Data(json.utf8)) else { return }
            copiedStyle = map
        }
    }

    func pasteProperties() {
        guard let copiedStyle, selectedElement != nil else { return }
        setStyle(copiedStyle)
    }

    func moveSelection(toLast: Bool) {
        guard let (board, id) = selectedElement else { return }
        Task { await edit("return window.__ds.moveToEdge(id, l)", ["id": id, "l": toLast], artboardID: board) }
    }

    /// 编组和取消编组同时只有一个可用：选中的是编组时只能取消编组，否则只能编组（多选时总是编组）
    var canGroup: Bool {
        multiSelection.count > 1 || (selectedElement != nil && selectedProps?.isGroup != true)
    }
    var canUngroup: Bool {
        multiSelection.count <= 1 && selectedElement != nil && selectedProps?.isGroup == true
    }

    func groupSelection() {
        guard canGroup, let (board, id) = selectedElement else { return }
        let ids = multiSelection.count > 1 ? multiSelection.map(\.id) : [id]
        Task { await edit("return window.__ds.groupMany(ids)", ["ids": ids], artboardID: board) }
    }

    func ungroupSelection() {
        guard canUngroup, let (board, id) = selectedElement else { return }
        Task { await edit("return window.__ds.ungroup(id)", ["id": id], artboardID: board) }
    }

    func wrapSelection(grid: Bool) {
        wrapSelection(grid
            ? #"<div data-name="Grid" style="display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px"></div>"#
            : #"<div data-name="Flex" style="display:flex;align-items:center;gap:12px"></div>"#)
    }

    private func wrapSelection(_ wrapper: String) {
        guard let (board, id) = selectedElement else { return }
        Task { await edit("return window.__ds.wrap(id, h)", ["id": id, "h": wrapper], artboardID: board) }
    }

    func flipSelection(horizontal: Bool) {
        guard let (board, id) = selectedElement else { return }
        Task { await edit("return window.__ds.flip(id, a)", ["id": id, "a": horizontal ? "x" : "y"], artboardID: board) }
    }

    func replaceSelectedElementHTML(_ html: String) {
        guard let sel = selection, let id = sel.elementID else { return }
        Task { await edit("return window.__ds.replaceOuter(id, h)", ["id": id, "h": html], artboardID: sel.artboardID) }
    }

    func selectedElementHTML() async -> String? {
        guard let sel = selection, let id = sel.elementID else { return nil }
        return await handle(for: sel.artboardID).call("return window.__ds.outer(id)", ["id": id])
    }

    /// 选中元素的代码，样式展开：命中的 CSS 规则（含变量）合并成每个元素的行内样式，去掉 class
    func selectedElementInlinedHTML() async -> String? {
        guard let sel = selection, let id = sel.elementID else { return nil }
        return await handle(for: sel.artboardID).call("return window.__ds.inlined(id)", ["id": id])
    }

    /// 在画板中插入元素；point 为画板内的 CSS 坐标
    func insertElement(_ html: String, in artboardID: UUID, at point: CGPoint?) {
        let args: [String: Any] = ["h": html, "x": point.map { Double($0.x) } ?? NSNull(), "y": point.map { Double($0.y) } ?? NSNull()]
        Task {
            await edit("return window.__ds.insert(h, x, y)", args, artboardID: artboardID)
            tool = .select
        }
    }

    func insertText(in artboardID: UUID, at point: CGPoint) {
        let html = #"<p data-name="文本" style="margin:0;font-size:24px;line-height:1.4;color:#1f2328;white-space:nowrap">双击编辑文字</p>"#
        insertElement(html, in: artboardID, at: point)
    }

    func insertRectangle(in artboardID: UUID, rect: CGRect) {
        let w = max(Int(rect.width.rounded()), 8), h = max(Int(rect.height.rounded()), 8)
        let html = #"<div data-name="矩形" style="width:\#(w)px;height:\#(h)px;background:#E9E4DF;border-radius:12px"></div>"#
        insertElement(html, in: artboardID, at: rect.origin)
    }

    /// 插入形状。矩形 / 圆形用 rect；直线 / 箭头从 start 画到 end（画板内坐标）
    func insertShape(_ kind: ShapeKind, in artboardID: UUID, rect: CGRect, start: CGPoint, end: CGPoint) {
        switch kind {
        case .rectangle:
            insertRectangle(in: artboardID, rect: rect)
        case .ellipse:
            let w = max(Int(rect.width.rounded()), 8), h = max(Int(rect.height.rounded()), 8)
            let html = #"<div data-name="圆形" style="width:\#(w)px;height:\#(h)px;background:#E9E4DF;border-radius:50%"></div>"#
            insertElement(html, in: artboardID, at: rect.origin)
        case .arrow, .line:
            let (html, origin) = Self.strokeShapeHTML(kind, from: start, to: end)
            insertElement(html, in: artboardID, at: origin)
        }
    }

    /// 直线 / 箭头的 SVG：外框留出线宽和箭头的余量，返回 SVG 与它在画板内的左上角
    nonisolated static func strokeShapeHTML(_ kind: ShapeKind, from a: CGPoint, to b: CGPoint) -> (String, CGPoint) {
        let pad: CGFloat = 10
        let minX = min(a.x, b.x) - pad, minY = min(a.y, b.y) - pad
        let w = Int((abs(b.x - a.x) + pad * 2).rounded()), h = Int((abs(b.y - a.y) + pad * 2).rounded())
        func f(_ v: CGFloat) -> String { String(format: "%.1f", v) }
        let x1 = a.x - minX, y1 = a.y - minY, x2 = b.x - minX, y2 = b.y - minY
        var d = "M\(f(x1)) \(f(y1)) L\(f(x2)) \(f(y2))"
        if kind == .arrow {
            let angle = atan2(y2 - y1, x2 - x1), len: CGFloat = 12, spread: CGFloat = .pi / 7
            let l = CGPoint(x: x2 - len * cos(angle - spread), y: y2 - len * sin(angle - spread))
            let r = CGPoint(x: x2 - len * cos(angle + spread), y: y2 - len * sin(angle + spread))
            d += " M\(f(l.x)) \(f(l.y)) L\(f(x2)) \(f(y2)) L\(f(r.x)) \(f(r.y))"
        }
        let name = kind == .arrow ? "箭头" : "直线"
        let html = ##"<svg data-name="\##(name)" width="\##(w)" height="\##(h)" viewBox="0 0 \##(w) \##(h)" style="display:block;overflow:visible"><path d="\##(d)" fill="none" stroke="#1f2328" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>"##
        return (html, CGPoint(x: minX, y: minY))
    }

    func insertImage(in artboardID: UUID, at point: CGPoint) {
        guard let attachment = ImageUtil.pickImages().first else { tool = .select; return }
        let dataURL = "data:\(attachment.mimeType);base64,\(attachment.data.base64EncodedString())"
        let html = #"<img data-name="图片" alt="" src="\#(dataURL)" style="width:240px;height:auto;border-radius:12px;display:block">"#
        insertElement(html, in: artboardID, at: point)
    }

    // MARK: - 画板

    func addArtboard(frame: CGRect? = nil, at center: CGPoint? = nil) {
        guard isEditable else { return }
        // 新画板沿用选中画板或页面上最后一个画板的尺寸（网页设计就加网页尺寸，幻灯片就加幻灯片尺寸）
        let reference = selection.flatMap { document.artboard($0.artboardID) } ?? currentPage?.artboards.last
        let size = frame?.size ?? reference.map { CGSize(width: $0.width, height: $0.height) } ?? kind.artboardSize
        var origin = frame?.origin ?? CGPoint.zero
        if frame == nil {
            if let center { origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2) }
            else { origin = currentPage?.nextArtboardOrigin() ?? .zero }
        }
        let index = (currentPage?.artboards.count ?? 0) + 1
        let board = Artboard(name: DesignDocument.defaultName(kind: kind, index: index),
                             html: Self.blankHTML(width: size.width, height: size.height),
                             x: origin.x.rounded(), y: origin.y.rounded(),
                             width: size.width.rounded(), height: size.height.rounded())
        let pageID = currentPageID ?? document.pages.first?.id
        commit { doc in
            if let i = doc.pages.firstIndex(where: { $0.id == pageID }) { doc.pages[i].artboards.append(board) }
        }
        tool = .select
        select(CanvasSelection(artboardID: board.id, elementID: nil))
    }

    static func blankHTML(width: Double, height: Double) -> String {
        """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=\(Int(width))">
        <style>
          html, body { margin: 0; width: \(Int(width))px; height: \(Int(height))px; }
          body { position: relative; overflow: hidden; background: #FFFFFF; font-family: -apple-system, "PingFang SC", "Noto Sans SC", sans-serif; }
        </style>
        </head>
        <body>
        </body>
        </html>
        """
    }

    func updateArtboard(_ id: UUID, _ mutate: @escaping (inout Artboard) -> Void) {
        guard isEditable else { return }
        commit { $0.updateArtboard(id, mutate) }
    }

    func moveArtboard(_ id: UUID, by delta: CGSize) {
        updateArtboard(id) { a in
            a.x = (a.x + delta.width).rounded()
            a.y = (a.y + delta.height).rounded()
        }
    }

    func renameArtboard(_ id: UUID, to name: String) {
        let n = name.trimmed
        guard !n.isEmpty else { return }
        updateArtboard(id) { $0.name = n }
    }

    func deleteArtboard(_ id: UUID) {
        guard isEditable else { return }
        commit { $0.removeArtboard(id) }
        handles[id] = nil
        trees[id] = nil
        if selection?.artboardID == id { clearSelection() }
    }

    func duplicateArtboard(_ id: UUID) {
        guard isEditable, let a = document.artboard(id) else { return }
        var copy = a
        copy.id = UUID()
        copy.name = a.name + " 副本"
        copy.x = a.x + a.width + 80
        commit { doc in
            for p in doc.pages.indices where doc.pages[p].artboards.contains(where: { $0.id == id }) {
                doc.pages[p].artboards.append(copy)
            }
        }
        select(CanvasSelection(artboardID: copy.id, elementID: nil))
    }

    func setArtboardHTML(_ id: UUID, _ html: String) {
        updateArtboard(id) { $0.html = html }
    }

    // MARK: - 页面

    func addPage() {
        guard isEditable else { return }
        let page = DesignPage(name: "页面 \(document.pages.count + 1)")
        commit { $0.pages.append(page) }
        currentPageID = page.id
        clearSelection()
    }

    func renamePage(_ id: UUID, to name: String) {
        let n = name.trimmed
        guard !n.isEmpty else { return }
        commit { doc in
            if let i = doc.pages.firstIndex(where: { $0.id == id }) { doc.pages[i].name = n }
        }
    }

    func deletePage(_ id: UUID) {
        guard isEditable, document.pages.count > 1 else { return }
        commit { $0.pages.removeAll { $0.id == id } }
        if currentPageID == id { currentPageID = document.pages.first?.id }
        clearSelection()
    }

    func switchPage(_ id: UUID) {
        currentPageID = id
        clearSelection()
        DispatchQueue.main.async { [weak self] in self?.zoomToFit() }
    }

    // MARK: - 提交 / 撤销

    /// 修改文档：记录撤销点并保存到项目
    private func commit(_ mutate: (inout DesignDocument) -> Void) {
        // 生成中画布显示的是实时预览文档：同样的修改也作用到它上面，生成结束合并时不会丢掉
        // （正在生成的新画板只存在于预览文档里，例如拖动它的位置）
        if var live = liveDocument {
            mutate(&live)
            if live != liveDocument { liveDocument = live }
        }
        var next = document
        mutate(&next)
        guard next != document else { return }
        undoStack.append(document)
        if undoStack.count > 80 { undoStack.removeFirst() }
        redoStack.removeAll()
        document = next
        persist()
    }

    /// 撤销 / 重做时文档整体替换：按已收到的模型输出重新生成实时预览
    private func rebuildLivePreview() {
        guard isGenerating, liveDocument != nil else { return }
        liveDocument = nil
        updateLivePreview()
    }

    private func persist() {
        let doc = document
        app.updateProject(projectID) { $0.document = doc }
    }

    func undo() {
        guard isEditable, let prev = undoStack.popLast() else { return }
        redoStack.append(document)
        document = prev
        persist()
        rebuildLivePreview()
        reconcileSelection()
    }

    func redo() {
        guard isEditable, let next = redoStack.popLast() else { return }
        undoStack.append(document)
        document = next
        persist()
        rebuildLivePreview()
        reconcileSelection()
    }

    private func reconcileSelection() {
        if let sel = selection, document.artboard(sel.artboardID) == nil { clearSelection() }
        if let id = currentPageID, document.page(id)?.id != id { currentPageID = document.pages.first?.id }
    }

    // MARK: - 键盘

    @discardableResult
    func handleKey(key: String, command: Bool, shift: Bool) -> Bool {
        let k = key.lowercased()
        if command {
            switch k {
            case "z": shift ? redo() : undo(); return true
            case "d": duplicateSelection(); return true
            case "=", "+": zoomIn(); return true
            case "-": zoomOut(); return true
            case "0": zoomTo100(); return true
            case "1": isFullScreen ? fitFullScreen() : zoomToFit(); return true
            case "2": zoomToSelection(); return true
            default: return false
            }
        }
        if shift, selectedElement != nil {
            switch k {
            case "h": flipSelection(horizontal: true); return true
            case "v": flipSelection(horizontal: false); return true
            case "a": wrapSelection(grid: false); return true
            default: break
            }
        }
        switch k {
        case "]" where selectedElement != nil: moveSelection(toLast: true); return true
        case "[" where selectedElement != nil: moveSelection(toLast: false); return true
        case "backspace", "delete": deleteSelection(); return true
        case "arrowleft" where isFullScreen && !previewShowsAll && selection?.elementID == nil:
            stepFullScreen(-1); return true
        case "arrowright" where isFullScreen && !previewShowsAll && selection?.elementID == nil:
            stepFullScreen(1); return true
        case "escape":
            if pendingComment != nil { pendingComment = nil }
            else if tool != .select { tool = .select; showShapePicker = false }
            else if showShapePicker { showShapePicker = false }
            else if let sel = selection, sel.elementID != nil { select(CanvasSelection(artboardID: sel.artboardID, elementID: nil)) }
            else if selection != nil { clearSelection() }
            else if isFullScreen { exitFullScreen() }
            return true
        default:
            if k.count == 1, let c = k.first, let t = CanvasTool.allCases.first(where: { $0.shortcut == c }) {
                tool = t
                showShapePicker = false
                return true
            }
            return false
        }
    }

    // MARK: - 版本

    func restore(_ version: DesignVersion) {
        guard isEditable else { return }
        let doc = version.document ?? DesignDocument.migrated(html: version.html, kind: kind)
        commit { $0 = doc }
        app.updateProject(projectID) { $0.currentVersionID = version.id }
        currentPageID = document.pages.first?.id
        clearSelection()
        DispatchQueue.main.async { [weak self] in self?.zoomToFit() }
    }

    /// 把当前画布保存为一个版本
    func saveVersion(summary: String) {
        let next = (project?.versions.map(\.number).max() ?? 0) + 1
        let version = DesignVersion(number: next, document: document, summary: summary)
        app.updateProject(projectID) { p in
            p.versions.append(version)
            p.currentVersionID = version.id
        }
    }

    func deleteVersion(_ version: DesignVersion) {
        app.updateProject(projectID) { p in
            p.versions.removeAll { $0.id == version.id }
            if p.currentVersionID == version.id { p.currentVersionID = p.versions.last?.id }
            for i in p.messages.indices where p.messages[i].versionID == version.id {
                p.messages[i].versionID = nil
            }
        }
    }

    // MARK: - AI 生成

    /// - Parameter useSelection: 来自画布上的「询问 AI」：把选中的画板 / 元素作为修改目标；
    ///   选中的是元素时，AI 只返回这个元素，生成后直接替换
    func send(useSelection: Bool = false) {
        guard useSelection ? canAsk : canSend, let project else { return }
        guard let profile = provider else {
            status = "请先在设置中添加模型来源"
            return
        }

        let text = (useSelection ? askDraft : draft).trimmed
        let comments = useSelection ? [] : pendingComments
        let attachments: [ChatAttachment]
        do {
            attachments = useSelection ? [] : try AttachmentImporter.includingPastedDocuments(in: text, attachments: draftAttachments)
        } catch {
            ExportService.presentError("无法读取参考文件", error)
            return
        }
        let pageID = currentPageID
        let target = useSelection ? selection : nil
        let props = target?.elementID != nil && selectedProps?.id == target?.elementID ? selectedProps : nil
        var userMessage = ChatMessage(
            role: .user,
            text: text.isEmpty ? (comments.isEmpty ? "请参考附件设计。" : "请根据画布批注修改设计。") : text,
            attachments: attachments,
            comments: comments
        )
        if let target, let board = document.artboard(target.artboardID) {
            userMessage.target = MessageTarget(artboardID: board.id, artboardName: board.name,
                                               elementKind: props?.kind, elementName: props.map(Self.displayName),
                                               selector: props?.selector)
        }
        let assistant = ChatMessage(role: .assistant, text: "", providerName: "\(profile.name) · \(profile.displayModel)")

        Task {
            var context: DesignPrompt.SelectionContext?
            var elementTarget: (selection: CanvasSelection, source: String)?
            if let target, let board = document.artboard(target.artboardID) {
                var desc: String?
                var html: String?
                if target.elementID != nil, let p = props {
                    desc = "<\(p.tag)> 元素（\(ElementKind.title(p.kind))\(p.name.isEmpty ? "" : "「\(p.name)」")，选择器 `\(p.selector)`）"
                    html = await handle(for: target.artboardID).call("return window.__ds.outer(id)", ["id": target.elementID!])
                }
                // <html>/<body>/<head> 不能整体替换；过大的元素也退回整画板修改
                let replaceable = props.map { !["html", "body", "head"].contains($0.tag.lowercased()) } ?? false
                let elementEdit = replaceable && (html.map { !$0.isEmpty && $0.count <= 60_000 } ?? false)
                if elementEdit { elementTarget = (target, board.html) }
                context = DesignPrompt.SelectionContext(artboardName: board.name, artboardID: board.id,
                                                        elementDescription: desc, elementHTML: html,
                                                        elementEdit: elementEdit, computedStyle: props?.style ?? [:])
            }
            guard !isGenerating else { return }
            var snapshot = project
            snapshot.document = document
            let request = DesignPrompt.makeRequest(
                project: snapshot,
                designSystem: app.designSystem(for: project.designSystemID),
                newMessage: userMessage,
                profile: profile,
                pageID: pageID,
                selection: context,
                commentsOnly: text.isEmpty && attachments.isEmpty
            )
            startGeneration(request: request, user: userMessage, assistant: assistant, profile: profile,
                            pageID: pageID, target: target?.artboardID, element: request.elementEdit ? elementTarget : nil,
                            fromAskBar: useSelection)
        }
    }

    private func startGeneration(request: LLMRequest, user: ChatMessage, assistant: ChatMessage,
                                 profile: ProviderProfile, pageID: UUID?, target: UUID?,
                                 element: (selection: CanvasSelection, source: String)? = nil, fromAskBar: Bool = false) {
        let resolved = Set(user.comments.map(\.id))
        app.updateProject(projectID) { p in
            p.messages.append(user)
            p.messages.append(assistant)
            for i in p.comments.indices where resolved.contains(p.comments[i].id) {
                p.comments[i].resolved = true
            }
            if p.providerID == nil { p.providerID = profile.id }
        }

        if fromAskBar {
            askDraft = ""
        } else {
            draft = ""
            draftAttachments = []
        }
        pendingComment = nil
        showAskAI = false
        if tool == .comment { tool = .select }
        isGenerating = true
        wasCancelled = false
        streamingText = ""
        streamingThinking = ""
        streamingMessageID = assistant.id
        liveDocument = nil
        streamingArtboardIDs = []
        viewportAdjustedDuringGeneration = false
        lastLiveUpdate = .distantPast
        streamingArtifactStarted = false
        lastUsage = nil
        generationPageID = pageID ?? document.pages.first?.id
        generationTarget = target
        generationElement = element
        app.persistence.setGenerating(projectID, true)
        generationStartedEmpty = document.page(generationPageID)?.artboards.isEmpty ?? true
        status = "正在连接 \(profile.name)…"

        let llm: any LLMProvider
        do {
            llm = try ProviderFactory.make(profile)
        } catch {
            task = Task { await finish(messageID: assistant.id, error: error) }
            return
        }

        task = Task { [weak self] in
            do {
                for try await event in llm.stream(request) {
                    guard let self else { return }
                    self.handle(event)
                }
                await self?.finish(messageID: assistant.id, error: nil)
            } catch {
                await self?.finish(messageID: assistant.id, error: error is CancellationError ? nil : error)
            }
        }
    }

    func stop() {
        guard isGenerating else { return }
        wasCancelled = true
        task?.cancel()
    }

    private func handle(_ event: LLMEvent) {
        switch event {
        case .text(let delta):
            streamingText += delta
            if !streamingArtifactStarted {
                streamingArtifactStarted = HTMLExtractor.fenceStarted(streamingText)
            }
            if streamingArtifactStarted {
                status = generationElement == nil ? "正在绘制画板…" : "正在修改元素…"
                let now = Date()
                if now.timeIntervalSince(lastLiveUpdate) > 1.2 {
                    lastLiveUpdate = now
                    updateLivePreview()
                }
            } else {
                status = "正在构思…"
            }
        case .thinking(let delta):
            streamingThinking += delta
            if !streamingArtifactStarted { status = "思考中…" }
        case .status(let s):
            status = s
        case .usage(let input, let output):
            lastUsage = (input, output)
        }
    }

    private var generatedPreviewIDs: Set<UUID> {
        let savedIDs = document.page(generationPageID)?.artboards.map(\.id) ?? []
        return streamingArtboardIDs.subtracting(savedIDs)
    }

    private func updateLivePreview() {
        guard generationElement == nil else { return }
        let parsed = ArtboardParser.previewable(streamingText)
        guard !parsed.isEmpty else { return }
        var live = liveDocument ?? document
        let before = live.page(generationPageID)?.artboards.count ?? 0
        let changed = live.merge(parsed, into: generationPageID, kind: kind, fallbackTarget: generationTarget,
                                 previewArtboardIDs: generatedPreviewIDs)
        guard !changed.isEmpty else { return }
        liveDocument = live
        streamingArtboardIDs.formUnion(changed)
        if let sel = selection, streamingArtboardIDs.contains(sel.artboardID), sel.elementID != nil {
            clearSelection()   // 选中的元素所在画板正在被重写
        }
        if generationStartedEmpty, !viewportAdjustedDuringGeneration,
           (live.page(generationPageID)?.artboards.count ?? 0) > before {
            DispatchQueue.main.async { [weak self] in self?.zoomToFit() }
        }
    }

    private func finish(messageID: UUID, error generationError: Error?) async {
        let text = streamingText
        let thinking = streamingThinking.trimmed
        let cancelled = wasCancelled

        var error = generationError
        let parsed = ArtboardParser.parse(text)
        var outputs = generationElement == nil ? parsed.filter(\.complete) : []
        var truncated = false
        if generationElement == nil, error == nil, !cancelled,
           let last = parsed.last, !last.complete, last.html.count > 400 {
            outputs.append(last)
            truncated = true
        }

        var elementEdit: (target: CanvasSelection, source: String, content: String, isPatch: Bool)?
        if error == nil, !cancelled, let target = generationElement {
            if !parsed.isEmpty {
                error = LLMError.invalidResponse("模型返回了整张画板。请选中画板重新尝试，或在主对话中发出修改。")
            } else if let block = ArtboardParser.element(text) {
                if block.complete, !block.html.isEmpty {
                    elementEdit = (target.selection, target.source, block.html, block.isPatch)
                } else {
                    error = LLMError.invalidResponse("模型返回的元素修改不完整，请重试。")
                }
            }
        }

        var newVersion: DesignVersion?
        if error == nil, !outputs.isEmpty {
            // 保留已预览画板的 ID。中途取消时，从原文档合并完整结果，避免提交半张画板。
            var merged = outputs.count == parsed.count ? (liveDocument ?? document) : document
            merged.merge(outputs, into: generationPageID, kind: kind, fallbackTarget: generationTarget,
                         previewArtboardIDs: generatedPreviewIDs)
            commit { $0 = merged }
            let next = (project?.versions.map(\.number).max() ?? 0) + 1
            newVersion = DesignVersion(number: next, document: document,
                                       summary: DesignPrompt.summary(from: text), truncated: truncated)
            if generationStartedEmpty, !viewportAdjustedDuringGeneration {
                DispatchQueue.main.async { [weak self] in self?.zoomToFit() }
            }
        }

        app.updateProject(projectID) { p in
            guard let i = p.messages.firstIndex(where: { $0.id == messageID }) else { return }
            p.messages[i].text = text
            p.messages[i].thinking = thinking.isEmpty ? nil : thinking
            if let error { p.messages[i].errorText = error.localizedDescription }
            if cancelled { p.messages[i].wasStopped = true }
            if let v = newVersion {
                p.versions.append(v)
                p.currentVersionID = v.id
                p.messages[i].versionID = v.id
            }
        }

        if let elementEdit {
            await applyElementEdit(elementEdit.content, isPatch: elementEdit.isPatch, to: elementEdit.target,
                                   source: elementEdit.source, messageID: messageID, reply: text)
        }
        isGenerating = false
        app.persistence.setGenerating(projectID, false)
        streamingMessageID = nil
        streamingText = ""
        streamingThinking = ""
        status = nil
        liveDocument = nil
        streamingArtboardIDs = []
        task = nil
        wasCancelled = false
        generationElement = nil
        if newVersion != nil {
            needsThumbnail = true
            tweakValues = [:]
        }
    }

    /// 把模型返回的补丁或替换 HTML 写入选中元素，并记为一个新版本
    private func applyElementEdit(_ content: String, isPatch: Bool, to target: CanvasSelection,
                                  source: String, messageID: UUID, reply: String) async {
        let handle = handle(for: target.artboardID)
        let r: EditResult?
        if let id = target.elementID, document.artboard(target.artboardID)?.html == source,
           handle.loadedSource == source {
            if isPatch {
                if let patch = ElementPatch.parse(content) {
                    let text: Any = patch.text.map { $0 as Any } ?? NSNull()
                    let style: Any = patch.style.map { $0 as Any } ?? NSNull()
                    r = await handle.decode(EditResult.self, "return window.__ds.patchElement(id, t, s)",
                                            ["id": id, "t": text, "s": style])
                } else {
                    r = nil
                }
            } else {
                r = await handle.decode(EditResult.self, "return window.__ds.replaceOuter(id, h)",
                                        ["id": id, "h": content])
            }
        } else {
            r = nil
        }
        // 替换成功时脚本会返回新的图层树；失败（元素已不存在 / HTML 无法解析）时没有
        guard let r, r.tree != nil, r.source != nil else {
            app.updateProject(projectID) { p in
                guard let i = p.messages.firstIndex(where: { $0.id == messageID }) else { return }
                p.messages[i].errorText = "没能把修改应用到选中元素：画板可能已更改，或返回的修改无法解析。"
            }
            return
        }
        apply(r, artboardID: target.artboardID)
        let next = (project?.versions.map(\.number).max() ?? 0) + 1
        let version = DesignVersion(number: next, document: document, summary: DesignPrompt.summary(from: reply))
        app.updateProject(projectID) { p in
            p.versions.append(version)
            p.currentVersionID = version.id
            if let i = p.messages.firstIndex(where: { $0.id == messageID }) { p.messages[i].versionID = version.id }
        }
        needsThumbnail = true
    }

    /// 重新发送失败的那一轮
    func retry(assistantMessageID: UUID) {
        guard !isGenerating, let project,
              let ai = project.messages.firstIndex(where: { $0.id == assistantMessageID }),
              ai > 0, project.messages[ai - 1].role == .user else { return }
        let user = project.messages[ai - 1]
        app.updateProject(projectID) { p in
            p.messages.removeSubrange((ai - 1)...ai)
            for c in user.comments {
                if let idx = p.comments.firstIndex(where: { $0.id == c.id }) { p.comments[idx].resolved = false }
            }
        }
        // 通过「询问 AI」发出的消息：重新选中原来的目标，仍按元素 / 画板修改
        if let target = user.target {
            askDraft = user.text
            Task {
                if let sel = await resolve(target) {
                    select(sel)
                    await refreshProps(sel)   // 发送时需要元素属性来判断能否按元素修改
                }
                send(useSelection: true)
            }
            return
        }
        draft = user.text
        draftAttachments = user.attachments
        send()
    }

    func fixError(in artboardID: UUID) {
        guard let err = artboardErrors[artboardID], let board = document.artboard(artboardID) else { return }
        askDraft = "画板「\(board.name)」运行时报错：\(err)\n请修复这个问题，保持设计不变。"
        artboardErrors[artboardID] = nil
        select(CanvasSelection(artboardID: artboardID, elementID: nil))
        send(useSelection: true)
    }

    // MARK: - 批注

    func addComment(note: String) {
        guard let pending = pendingComment else { return }
        let n = note.trimmed
        guard !n.isEmpty else { pendingComment = nil; return }
        let p = pending.props
        let snippet = (p.text ?? "").trimmed.replacingOccurrences(of: "\n", with: " ")
        let comment = CanvasComment(selector: p.selector, tag: p.tag,
                                    snippet: String(snippet.prefix(160)), note: n,
                                    artboardName: document.artboard(pending.artboardID)?.name)
        app.updateProject(projectID, touch: false) { $0.comments.append(comment) }
        pendingComment = nil
    }

    func removeComment(_ id: UUID) {
        app.updateProject(projectID, touch: false) { $0.comments.removeAll { $0.id == id } }
    }

    /// 元素在界面上的显示名：图层名 > 文字内容 > 标签名
    static func displayName(_ p: ElementProps) -> String {
        if !p.name.isEmpty { return "「\(p.name)」" }
        if let t = p.text?.trimmed, !t.isEmpty { return "“\(t.count > 16 ? t.prefix(15) + "…" : t)”" }
        return "<\(p.tag)>"
    }

    /// 在画布上重新选中消息针对的画板 / 元素
    func reveal(_ target: MessageTarget) {
        Task {
            if let sel = await resolve(target) {
                select(sel)
            } else {
                status = "画板「\(target.artboardName)」已不存在"
            }
        }
    }

    /// 找到消息针对的画板 / 元素（元素按选择器重新定位，找不到时退回整个画板）
    private func resolve(_ target: MessageTarget) async -> CanvasSelection? {
        guard let board = document.artboard(target.artboardID)
                ?? currentPage?.artboard(named: target.artboardName) else { return nil }
        if let page = document.pages.first(where: { $0.artboards.contains { $0.id == board.id } }), page.id != currentPageID {
            currentPageID = page.id
        }
        struct Located: Decodable { var id: Int; var rect: ElementRect }
        if let selector = target.selector,
           let r = await handle(for: board.id).decode(Located.self, "return window.__ds.locate(s)", ["s": selector]) {
            return CanvasSelection(artboardID: board.id, elementID: r.id)
        }
        return CanvasSelection(artboardID: board.id, elementID: nil)
    }

    /// 在画布上高亮批注对应的元素
    func locate(_ comment: CanvasComment) {
        guard let page = currentPage,
              let board = comment.artboardName.flatMap({ page.artboard(named: $0) }) ?? page.artboards.first else { return }
        struct Located: Decodable { var id: Int; var rect: ElementRect }
        Task {
            if let r = await handle(for: board.id).decode(Located.self, "return window.__ds.locate(s)", ["s": comment.selector]) {
                hover = CanvasHover(artboardID: board.id, elementID: r.id, rect: r.rect)
            }
        }
    }

    // MARK: - 可调参数

    /// 当前页面所有画板暴露的参数（按变量名去重）
    var tweakControls: [TweakControl] {
        var seen = Set<String>()
        var result: [TweakControl] = []
        for a in currentPage?.artboards ?? [] {
            for c in TweakParser.parse(a.html) where seen.insert(c.variable).inserted { result.append(c) }
        }
        return result
    }

    func tweakValue(_ control: TweakControl) -> String {
        tweakValues[control.variable] ?? control.value
    }

    func setTweak(_ control: TweakControl, _ raw: String) {
        tweakValues[control.variable] = raw
        for a in currentPage?.artboards ?? [] {
            handle(for: a.id).run("window.__ds.setVar(n, v)", ["n": control.variable, "v": control.cssValue(raw)])
        }
    }

    func resetTweaks() {
        for name in tweakValues.keys {
            for a in currentPage?.artboards ?? [] {
                handle(for: a.id).run("window.__ds.setVar(n, null)", ["n": name])
            }
        }
        tweakValues = [:]
    }

    func bakeTweaks() {
        guard isEditable, !tweakValues.isEmpty, let page = currentPage else { return }
        let values = tweakValues
        let all = tweakControls
        let changed = all.filter { values[$0.variable] != nil }.map(\.label).joined(separator: "、")
        commit { doc in
            for a in page.artboards {
                let controls = TweakParser.parse(a.html)
                guard controls.contains(where: { values[$0.variable] != nil }) else { continue }
                let html = TweakParser.bake(a.html, controls: controls, values: values)
                doc.updateArtboard(a.id) { $0.html = html }
            }
        }
        tweakValues = [:]
        saveVersion(summary: "手动调整了：\(changed)")
    }

    // MARK: - 导出

    /// 导出时作用的画板：选中的画板，否则当前页第一个
    var exportArtboard: Artboard? {
        selectedArtboard ?? currentPage?.artboards.first
    }

    func snapshot(_ artboard: Artboard) async -> NSImage? {
        await handle(for: artboard.id).snapshot(width: artboard.width)
    }

    func pdf(_ artboard: Artboard) async throws -> Data {
        try await handle(for: artboard.id).pdf()
    }
}

/// 图层面板中节点的稳定 ID
nonisolated enum LayerID {
    static func artboard(_ id: UUID) -> String { "a:" + id.uuidString }
    static func element(_ artboard: UUID, _ id: Int) -> String { "e:" + artboard.uuidString + ":" + String(id) }
    static func page(_ id: UUID) -> String { "p:" + id.uuidString }
}
