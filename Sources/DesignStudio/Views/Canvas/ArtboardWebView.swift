import SwiftUI
import WebKit

/// 画布上的网页视图：关闭 WebKit 的自动内容边距。
///
/// 窗口使用 fullSizeContentView 且标题栏不透明时，WebKit 会按「网页视图与标题栏 / 工具栏重叠的高度」
/// 自动设置顶部 obscuredContentInsets（画板顶部移出窗口时还会加上伸出的距离），并把网页内容推到工具栏下沿。
/// 全屏画布延伸到标题栏下方，往上平移画板时内容就会被往下推、底部被截掉，选中框也随之错位。
/// 画板必须按自身尺寸完整渲染，所以关闭自动调整并把边距固定为 0。
/// （只设置公开的 obscuredContentInsets 不够，WebKit 会在布局时重新计算覆盖它）
final class CanvasWebView: WKWebView {
    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        disableAutomaticContentInsets()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        disableAutomaticContentInsets()
    }

    /// 布局尺寸 = 视图尺寸 ÷ viewScale（_WKLayoutModeDynamicSizeComputedFromViewScale = 2）。
    /// 只设 viewScale 时 WebKit 仍按缩小后的视图宽度排版（document 宽度变成 154 而不是 390）
    private static let usesViewScale: Bool = {
        let probe = NSSelectorFromString("_setLayoutMode:")
        let scale = NSSelectorFromString("_setViewScale:")
        return WKWebView.instancesRespond(to: probe) && WKWebView.instancesRespond(to: scale)
    }()

    func configurePreviewScaling() {
        guard Self.usesViewScale else { return }
        let selector = NSSelectorFromString("_setLayoutMode:")
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(method(for: selector), to: Setter.self)(self, selector, 2)
    }

    private func disableAutomaticContentInsets() {
        let selector = NSSelectorFromString("_setAutomaticallyAdjustsContentInsets:")
        if responds(to: selector) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(method(for: selector), to: Setter.self)(self, selector, false)
        }
        obscuredContentInsets = NSEdgeInsetsZero
    }

    /// 画布缩放：用 WebKit 的 viewScale + 按缩放推算布局尺寸（按画板原始尺寸排版，再整体缩放渲染）。
    /// 不用 pageZoom：缩小时 WebKit 会把小于约 9 个屏幕像素的文字强制放大，导致换行、排版变化，
    /// 编辑脚本上报的元素位置也随缩放变化，选中框就会错位。私有接口不可用时退回 pageZoom。
    var canvasScale: Double {
        get { appliedScale }
        set {
            let value = max(newValue, 0.02)
            guard abs(value - appliedScale) > 0.0005 else { return }
            appliedScale = value
            let selector = NSSelectorFromString("_setViewScale:")
            if Self.usesViewScale {
                typealias Setter = @convention(c) (AnyObject, Selector, Double) -> Void
                unsafeBitCast(method(for: selector), to: Setter.self)(self, selector, value)
            } else {
                pageZoom = value
            }
        }
    }
    private var appliedScale: Double = 1

    /// 画板网页的尺寸完全由画布决定（画板宽高 × 缩放），不提供固有尺寸
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

/// 编辑画板始终以原始尺寸排版。外层 frame 随画布缩放，bounds 和网页视口保持原始尺寸。
final class ArtboardViewport: NSView {
    let webView: CanvasWebView
    private var artboardSize: CGSize
    var capturesPointer = false

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        capturesPointer ? nil : super.hitTest(point)
    }

    init(webView: CanvasWebView, artboardSize: CGSize) {
        self.webView = webView
        self.artboardSize = artboardSize
        super.init(frame: CGRect(origin: .zero, size: artboardSize))
        clipsToBounds = true
        webView.autoresizingMask = []
        addSubview(webView)
        setArtboardSize(artboardSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setArtboardSize(_ size: CGSize) {
        artboardSize = size
        restoreLayoutBounds()
        let rect = CGRect(origin: .zero, size: size)
        if webView.frame != rect { webView.frame = rect }
    }

    override var frame: NSRect {
        didSet { restoreLayoutBounds() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        restoreLayoutBounds()
    }

    private func restoreLayoutBounds() {
        // SwiftUI can assign the whole frame on first layout, which resets AppKit's bounds.
        let layoutBounds = CGRect(origin: .zero, size: artboardSize)
        if bounds != layoutBounds { bounds = layoutBounds }
    }
}

/// 网页画板的高度设置
nonisolated struct ArtboardFit: Equatable, Sendable {
    var on: Bool
    var viewportHeight: Double
}

/// 画板网页的编辑模式
nonisolated enum EditorMode: String, Sendable {
    case select, comment, off
}

/// 一个画板对应的网页句柄：Session 通过它调用编辑脚本
@MainActor
final class ArtboardHandle {
    let artboardID: UUID
    weak var webView: WKWebView?
    /// 当前网页加载的源码（干净版本）；与文档中的 html 不同时会重新加载
    var loadedSource: String?
    // 元素编号在重新加载后会重排，即使画板源码相同。
    var loadID = UUID()
    var isReady = false
    var isInitialized = false
    var mode: EditorMode = .select

    init(artboardID: UUID) {
        self.artboardID = artboardID
    }

    /// 调用 `window.__ds` 上的函数，返回字符串结果（脚本内部都 JSON.stringify 过）
    func call(_ body: String, _ arguments: [String: Any] = [:]) async -> String? {
        guard let webView, isReady else { return nil }
        do {
            return try await webView.callAsyncJavaScript(body, arguments: arguments, contentWorld: .page) as? String
        } catch {
            return nil
        }
    }

    func decode<T: Decodable>(_ type: T.Type, _ body: String, _ arguments: [String: Any] = [:]) async -> T? {
        guard let json = await call(body, arguments) else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    func run(_ body: String, _ arguments: [String: Any] = [:]) {
        guard let webView, isReady else { return }
        webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page, completionHandler: nil)
    }

    func snapshot(width: Double? = nil) async -> NSImage? {
        guard let webView else { return nil }
        let config = WKSnapshotConfiguration()
        if let width { config.snapshotWidth = NSNumber(value: width) }
        return try? await webView.takeSnapshot(configuration: config)
    }

    /// 截取画板的一部分（CSS 坐标；nil 为整个画板），输出图片的尺寸等于 CSS 尺寸（Retina 屏上为 2 倍像素）
    func snapshot(cssRect: CGRect?, scale: Double = 1) async -> NSImage? {
        guard let webView else { return nil }
        let config = WKSnapshotConfiguration()
        if let r = cssRect {
            config.rect = r
            config.snapshotWidth = NSNumber(value: r.width * scale)
        } else {
            config.snapshotWidth = NSNumber(value: webView.bounds.width * scale)
        }
        return try? await webView.takeSnapshot(configuration: config)
    }

    func pdf() async throws -> Data {
        guard let webView else { throw LLMError.cli("画板尚未加载") }
        return try await webView.pdf(configuration: WKPDFConfiguration())
    }
}

/// 编辑画板：AppKit 缩放整个网页，WebKit 的布局与元素边界保持在画板坐标中。
struct ArtboardWebView: NSViewRepresentable {
    let artboard: Artboard
    let zoom: Double
    let mode: EditorMode
    let selectedElementIDs: [Int]
    let session: ProjectSession
    let onReady: () -> Void
    var onLoadFailed: () -> Void = {}

    static let baseURL = URL(string: "https://canvas.designstudio.local/")!

    func makeCoordinator() -> Coordinator {
        Coordinator(handle: session.handle(for: artboard.id), session: session,
                    selectedElementIDs: selectedElementIDs, onReady: onReady, onLoadFailed: onLoadFailed)
    }

    func makeNSView(context: Context) -> ArtboardViewport {
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        // WKUserContentController 会强引用消息处理者，用弱引用代理避免循环引用
        ucc.add(WeakMessageHandler(context.coordinator), name: "ds")
        ucc.addUserScript(WKUserScript(source: EditorScript.errorHook, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.addUserScript(WKUserScript(source: EditorScript.editor, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController = ucc

        let web = CanvasWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.isInspectable = true
        web.allowsMagnification = false
        web.allowsBackForwardNavigationGestures = false
        web.underPageBackgroundColor = .white
        let viewport = ArtboardViewport(webView: web, artboardSize: artboard.frame.size)
        viewport.capturesPointer = capturesPointer
        context.coordinator.handle.webView = web
        context.coordinator.handle.mode = mode
        context.coordinator.fit = fit
        context.coordinator.sharedCSS = sharedCSS
        context.coordinator.load(artboard.html, in: web)
        return viewport
    }

    /// 鼠标交给画布处理：使用画布工具时，或这个画板被框选（拖动内容整体移动）时
    private var capturesPointer: Bool {
        guard !session.interactivePreview else { return false }
        return session.tool.capturesPointer
            || session.tool == .select && session.selectedArtboardIDs.contains(artboard.id)
    }

    /// 画板所在画布的共用样式
    private var sharedCSS: String { session.displayedDocument.sharedCSS(for: artboard.id) ?? "" }

    /// 网页画板：高度跟随内容，vh 按一屏高度
    private var fit: ArtboardFit {
        ArtboardFit(on: artboard.fitsContent(in: session.kind), viewportHeight: artboard.viewportHeight)
    }

    /// 始终占满画布给出的尺寸（画板宽高 × 缩放）
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ArtboardViewport, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? artboard.width * zoom, height: proposal.height ?? artboard.height * zoom)
    }

    func updateNSView(_ viewport: ArtboardViewport, context: Context) {
        viewport.setArtboardSize(artboard.frame.size)
        viewport.capturesPointer = capturesPointer
        let web = viewport.webView
        let c = context.coordinator
        c.session = session
        if c.handle.webView !== web { c.handle.webView = web }
        let shared = sharedCSS
        if c.handle.loadedSource != artboard.html {
            c.sharedCSS = shared
            c.load(artboard.html, in: web)
        } else if c.sharedCSS != shared {
            c.sharedCSS = shared
            c.handle.run("window.__ds.setShared(css)", ["css": shared])
        }
        if c.handle.mode != mode {
            c.handle.mode = mode
            c.handle.run("window.__ds && window.__ds.setMode(m)", ["m": mode.rawValue])
        }
        c.trackSelection(selectedElementIDs)
        if c.fit != fit {
            c.fit = fit
            c.applyFit()
        }
    }

    static func dismantleNSView(_ viewport: ArtboardViewport, coordinator: Coordinator) {
        let web = viewport.webView
        web.configuration.userContentController.removeScriptMessageHandler(forName: "ds")
        web.navigationDelegate = nil
        coordinator.cancelPreparation()
        web.stopLoading()
        if coordinator.handle.webView === web {
            coordinator.handle.webView = nil
            coordinator.handle.isReady = false
            coordinator.handle.isInitialized = false
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private static let markupCache: NSCache<NSUUID, ArtboardMarkup> = {
            let cache = NSCache<NSUUID, ArtboardMarkup>()
            cache.totalCostLimit = 16 * 1024 * 1024
            return cache
        }()

        private nonisolated struct InitResult: Decodable {
            var tree: [ElementNode]
        }

        let handle: ArtboardHandle
        let onReady: () -> Void
        let onLoadFailed: () -> Void
        weak var session: ProjectSession?
        private var annotated = ""
        private var initialized = false
        private var preparation: Task<Void, Never>?
        private var navigation: WKNavigation?
        private var navigationCommitted = false
        private var selectedElementIDs: [Int]
        var fit = ArtboardFit(on: false, viewportHeight: 900)
        var sharedCSS = ""

        init(handle: ArtboardHandle, session: ProjectSession, selectedElementIDs: [Int],
             onReady: @escaping () -> Void, onLoadFailed: @escaping () -> Void) {
            self.handle = handle
            self.session = session
            self.selectedElementIDs = selectedElementIDs
            self.onReady = onReady
            self.onLoadFailed = onLoadFailed
        }

        func applyFit() {
            handle.run("window.__ds.fitContent(on, vh)", ["on": fit.on, "vh": fit.viewportHeight])
        }

        func trackSelection(_ ids: [Int]) {
            guard selectedElementIDs != ids else { return }
            selectedElementIDs = ids
            handle.run("window.__ds.trackSelection(ids)", ["ids": ids])
        }

        func load(_ html: String, in web: WKWebView) {
            cancelPreparation()
            handle.loadID = UUID()
            handle.loadedSource = html
            handle.isReady = false
            handle.isInitialized = false
            initialized = false
            let key = handle.artboardID as NSUUID
            if let markup = Self.markupCache.object(forKey: key), markup.source == html {
                load(markup, in: web)
                return
            }

            preparation = Task { [weak self, weak web] in
                guard !Task.isCancelled else { return }
                let worker = Task.detached(priority: .userInitiated) { ArtboardMarkup(source: html) }
                let markup = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled, let self, let web, self.handle.webView === web else { return }
                Self.markupCache.setObject(markup, forKey: key, cost: markup.byteCount)
                self.preparation = nil
                self.load(markup, in: web)
            }
        }

        func cancelPreparation() {
            preparation?.cancel()
            preparation = nil
            navigation = nil
            navigationCommitted = false
        }

        private func load(_ markup: ArtboardMarkup, in web: WKWebView) {
            annotated = markup.annotated
            // 网页加载的副本：带上画布共用样式，外部样式表不阻塞渲染；
            // 编辑脚本里的源码 DOM 仍用未改动的 annotated（共用样式不会被写回画板）
            let page = SharedStyles.compose(markup.preview, css: sharedCSS, live: true)
            navigation = web.loadHTMLString(page, baseURL: ArtboardWebView.baseURL)
        }

        /// 编辑脚本就绪（DOM 解析完成）后初始化：建立源码 DOM、回传图层树
        private func initialize() {
            guard !initialized, navigationCommitted, let navigation else { return }
            initialized = true
            handle.isReady = true
            let id = handle.artboardID
            let source = annotated
            let mode = handle.mode
            Task { [weak self] in
                guard let self else { return }
                let json = await self.handle.call("""
                    const result = window.__ds.init(s, m);
                    window.__ds.trackSelection(ids);
                    window.__ds.setShared(css);
                    window.__ds.fitContent(on, vh);
                    return result;
                    """, ["s": source, "m": mode.rawValue, "ids": self.selectedElementIDs,
                          "css": self.sharedCSS, "on": self.fit.on, "vh": self.fit.viewportHeight])
                let tree = await Task.detached {
                    json.flatMap { try? JSONDecoder().decode(InitResult.self, from: Data($0.utf8)).tree } ?? []
                }.value
                guard self.navigation === navigation else { return }
                self.handle.isInitialized = json != nil
                self.session?.artboardDidLoad(id, tree: tree)
                self.onReady()
            }
        }

        /// 在右键位置弹出画布菜单（选中已由之前的 select 消息更新）
        private func showContextMenu(_ msg: EditorMessage, in webView: WKWebView?) {
            guard let session, let web = webView ?? handle.webView else { return }
            let x = msg.x ?? 0, y = msg.y ?? 0
            let point = NSPoint(x: x, y: web.isFlipped ? y : web.bounds.height - y)
            let menu = CanvasContextMenu.make(session: session, artboardID: handle.artboardID, info: msg.info)
            // 等这次脚本消息处理完再弹出（菜单会进入自己的事件循环）
            DispatchQueue.main.async { menu.popUp(positioning: nil, at: point, in: web) }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            if self.navigation === navigation { navigationCommitted = true }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if self.navigation === navigation { initialize() }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            guard self.navigation === navigation else { return }
            handle.isReady = false
            handle.isInitialized = false
            onLoadFailed()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            self.webView(webView, didFail: navigation, withError: error)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            // 画布里只允许加载画板本身；链接一律不跳转
            if navigationAction.navigationType == .other { return .allow }
            return .cancel
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let json = message.body as? String,
                  let msg = try? JSONDecoder().decode(EditorMessage.self, from: Data(json.utf8)) else { return }
            if msg.type == "ready" { initialize(); return }
            guard navigationCommitted else { return }
            if msg.type == "contextMenu" { showContextMenu(msg, in: message.webView); return }
            session?.handleEditorMessage(msg, from: handle.artboardID)
            if msg.type == "editing", let web = message.webView {
                // 画板拦截默认的点击行为，进入行内编辑时把键盘焦点交还给网页。
                web.window?.makeFirstResponder(web)
            }
        }
    }
}

nonisolated private final class ArtboardMarkup: Sendable {
    let source: String
    let annotated: String
    let preview: String
    var byteCount: Int { source.utf8.count + annotated.utf8.count + preview.utf8.count }

    init(source: String) {
        self.source = source
        annotated = HTMLAnnotator.annotate(source).html
        preview = HTMLAnnotator.nonBlockingStylesheets(annotated)
    }
}

/// 弱引用转发 WKScriptMessage，避免 WKUserContentController ↔ Coordinator 循环引用
@MainActor
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// 只读对比预览：按原尺寸渲染并缩放适配。
struct PreviewWebView: NSViewRepresentable {
    let html: String
    let zoom: Double

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(source: EditorScript.errorHook, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = ucc
        let web = CanvasWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.configurePreviewScaling()
        web.canvasScale = zoom
        web.isInspectable = true
        web.loadHTMLString(HTMLAnnotator.nonBlockingStylesheets(html), baseURL: ArtboardWebView.baseURL)
        context.coordinator.loaded = html
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        if context.coordinator.loaded != html {
            context.coordinator.loaded = html
            web.loadHTMLString(HTMLAnnotator.nonBlockingStylesheets(html), baseURL: ArtboardWebView.baseURL)
        }
        (web as? CanvasWebView)?.canvasScale = zoom
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded = ""

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            action.navigationType == .other ? .allow : .cancel
        }
    }
}
