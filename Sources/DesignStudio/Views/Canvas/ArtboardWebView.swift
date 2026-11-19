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
    var capturesPointer = false

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        capturesPointer ? nil : super.hitTest(point)
    }

    init(webView: CanvasWebView, artboardSize: CGSize) {
        self.webView = webView
        super.init(frame: CGRect(origin: .zero, size: artboardSize))
        clipsToBounds = true
        webView.autoresizingMask = []
        addSubview(webView)
        setArtboardSize(artboardSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setArtboardSize(_ size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        if bounds != rect { bounds = rect }
        if webView.frame != rect { webView.frame = rect }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let layoutBounds = bounds
        super.setFrameSize(newSize)
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
    var isReady = false
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

    static let baseURL = URL(string: "https://canvas.designstudio.local/")!

    func makeCoordinator() -> Coordinator {
        Coordinator(handle: session.handle(for: artboard.id), session: session, selectedElementIDs: selectedElementIDs)
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
        viewport.capturesPointer = session.tool.capturesPointer && !session.interactivePreview
        context.coordinator.handle.webView = web
        context.coordinator.handle.mode = mode
        context.coordinator.fit = fit
        context.coordinator.load(artboard.html, in: web)
        return viewport
    }

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
        viewport.capturesPointer = session.tool.capturesPointer && !session.interactivePreview
        let web = viewport.webView
        let c = context.coordinator
        c.session = session
        if c.handle.webView !== web { c.handle.webView = web }
        if c.handle.loadedSource != artboard.html {
            c.load(artboard.html, in: web)
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
        coordinator.handle.isReady = false
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let handle: ArtboardHandle
        weak var session: ProjectSession?
        private var annotated = ""
        private var initialized = false
        private var selectedElementIDs: [Int]
        var fit = ArtboardFit(on: false, viewportHeight: 900)

        init(handle: ArtboardHandle, session: ProjectSession, selectedElementIDs: [Int]) {
            self.handle = handle
            self.session = session
            self.selectedElementIDs = selectedElementIDs
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
            handle.loadedSource = html
            handle.isReady = false
            initialized = false
            annotated = HTMLAnnotator.annotate(html).html
            // 网页加载的副本：外部样式表不阻塞渲染；编辑脚本里的源码 DOM 仍用未改动的 annotated
            web.loadHTMLString(HTMLAnnotator.nonBlockingStylesheets(annotated), baseURL: ArtboardWebView.baseURL)
        }

        /// 编辑脚本就绪（DOM 解析完成）后初始化：建立源码 DOM、回传图层树
        private func initialize() {
            guard !initialized else { return }
            initialized = true
            handle.isReady = true
            let id = handle.artboardID
            let source = annotated
            let mode = handle.mode
            Task { [weak self] in
                guard let self else { return }
                struct InitResult: Decodable { var tree: [ElementNode] }
                let r = await self.handle.decode(InitResult.self, """
                    const result = window.__ds.init(s, m);
                    window.__ds.trackSelection(ids);
                    window.__ds.fitContent(on, vh);
                    return result;
                    """, ["s": source, "m": mode.rawValue, "ids": self.selectedElementIDs,
                          "on": self.fit.on, "vh": self.fit.viewportHeight])
                self.session?.artboardDidLoad(id, tree: r?.tree ?? [])
            }
        }

        /// 在右键位置弹出画布菜单（选中已由之前的 select 消息更新）
        private func showContextMenu(_ msg: EditorMessage, in webView: WKWebView?) {
            guard let session, let web = webView ?? handle.webView else { return }
            let x = msg.x ?? 0, y = msg.y ?? 0
            let point = NSPoint(x: x, y: web.isFlipped ? y : web.bounds.height - y)
            let menu = CanvasContextMenu.make(session: session, info: msg.info)
            // 等这次脚本消息处理完再弹出（菜单会进入自己的事件循环）
            DispatchQueue.main.async { menu.popUp(positioning: nil, at: point, in: web) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            initialize()   // 兜底：正常情况下 ready 消息更早到达
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
            if msg.type == "contextMenu" { showContextMenu(msg, in: message.webView); return }
            session?.handleEditorMessage(msg, from: handle.artboardID)
            if msg.type == "editing", let web = message.webView {
                // 画板拦截默认的点击行为，进入行内编辑时把键盘焦点交还给网页。
                web.window?.makeFirstResponder(web)
            }
        }
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

/// 只读预览（播放模式）：按原尺寸渲染并缩放适配，页面可正常交互
struct PreviewWebView: NSViewRepresentable {
    let html: String
    let zoom: Double

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(source: EditorScript.errorHook, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = ucc
        let web = CanvasWebView(frame: .zero, configuration: config)
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

    final class Coordinator {
        var loaded = ""
    }
}
