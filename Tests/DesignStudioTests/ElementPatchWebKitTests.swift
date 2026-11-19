import AppKit
import Foundation
import Testing
import WebKit
@testable import DesignStudio

struct ElementPatchWebKitTests {
    @MainActor @Test func insertsEditableNotesAndStyledPencilStrokes() async throws {
        let html = HTMLAnnotator.annotate("<!doctype html><html><body></body></html>").html
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let navigation = NavigationWaiter()
        web.navigationDelegate = navigation
        await withCheckedContinuation { continuation in
            navigation.loaded = continuation
            web.loadHTMLString(html, baseURL: nil)
        }
        _ = try await web.evaluateJavaScript(EditorScript.editor)
        let style = PencilStroke(weight: .thick, pattern: .dashed)
        let points = [CGPoint(x: 10, y: 25), CGPoint(x: 20, y: 12), CGPoint(x: 40, y: 35)]
        let stroke = try #require(style.element(for: points))
        #expect(stroke.origin == CGPoint(x: 7, y: 9))
        #expect(style.element(for: [points[0]]) == nil)

        let result = try await web.callAsyncJavaScript("""
            window.__ds.init(source, 'select');
            const note = JSON.parse(window.__ds.insert('<div data-sticky-note style="min-height:30px"></div>', 42, 50));
            const el = document.querySelector('[data-sticky-note]');
            const emptyHint = getComputedStyle(el, '::before').content.includes('双击编辑便签');
            el.dispatchEvent(new MouseEvent('dblclick', {bubbles: true}));
            const editable = el.isContentEditable;
            el.innerText = '记下灵感';
            el.blur();
            const pencil = JSON.parse(window.__ds.insert(stroke, x, y));
            const path = document.querySelector('[data-pencil-stroke] path');
            return [note.props.kind === 'note', emptyHint, editable,
                    pencil.source.includes('记下灵感'), !pencil.source.includes('双击编辑便签'),
                    pencil.props.kind === 'pencil', path.getAttribute('stroke-width') === '4.00',
                    path.getAttribute('stroke-dasharray') === '12.00 8.00',
                    pencil.source.includes('data-pencil-stroke')];
            """, arguments: ["source": html, "stroke": stroke.html, "x": stroke.origin.x, "y": stroke.origin.y], in: nil, contentWorld: .page)
        #expect(result as? [Bool] == Array(repeating: true, count: 9))
    }

    @MainActor @Test func appliesElementPatchInWebKit() async throws {
        let html = HTMLAnnotator.annotate("<button id='goal'>Old</button><div id='group'><span>Keep</span></div>").html
        let web = WKWebView()
        let navigation = NavigationWaiter()
        web.navigationDelegate = navigation
        await withCheckedContinuation { continuation in
            navigation.loaded = continuation
            web.loadHTMLString(html, baseURL: nil)
        }
        _ = try await web.evaluateJavaScript(EditorScript.editor)
        let result = try await web.callAsyncJavaScript("""
            window.__ds.init(source, 'select');
            const id = +(document.querySelector('#goal').getAttribute('data-ds-id'));
            const group = +(document.querySelector('#group').getAttribute('data-ds-id'));
            const patched = JSON.parse(window.__ds.patchElement(id, '<New>', {color: '#f00'}));
            return [patched.source.includes('&lt;New&gt;'), document.querySelector('#goal').textContent === '<New>',
                    document.querySelector('#goal').style.color !== '',
                    window.__ds.patchElement(group, 'Wrong', null) === null,
                    document.querySelector('#group > span').textContent === 'Keep'];
            """, arguments: ["source": html], in: nil, contentWorld: .page)
        #expect(result as? [Bool] == [true, true, true, true, true])
    }

    @MainActor @Test func canvasZoomPreservesResponsiveLayoutAndScalesElementCoordinates() async throws {
        let html = """
        <!doctype html><style>
        body { margin: 0; }
        main { position: absolute; left: 10vw; top: 10vh; width: 50vw; height: 100px; }
        @media (max-width: 799px) { main { width: 100vw; } }
        </style><main>Canvas zoom</main>
        """
        let layoutSize = CGSize(width: 800, height: 600)
        let web = CanvasWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let viewport = ArtboardViewport(webView: web, artboardSize: layoutSize)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: CGSize(width: 1000, height: 800)),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(viewport)
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        let navigation = NavigationWaiter()
        web.navigationDelegate = navigation
        await withCheckedContinuation { continuation in
            navigation.loaded = continuation
            web.loadHTMLString(html, baseURL: nil)
        }

        for scale in [0.47, 1.2, 0.33, 0.75] {
            viewport.setFrameSize(CGSize(width: layoutSize.width * scale, height: layoutSize.height * scale))
            let metrics = try await web.evaluateJavaScript("""
                (() => {
                    const r = document.querySelector('main').getBoundingClientRect();
                    return [innerWidth, innerHeight, r.left, r.top, r.width, r.height];
                })()
                """)
            #expect(metrics as? [Double] == [800, 600, 80, 60, 400, 100])
            let size = viewport.convert(CGSize(width: 400, height: 100), to: window.contentView)
            #expect(abs(size.width - 400 * scale) < 0.001)
            #expect(abs(size.height - 100 * scale) < 0.001)
        }
    }

    @MainActor @Test func selectionTracksTheTransformOfAnAncestor() async throws {
        let html = HTMLAnnotator.annotate("""
            <!doctype html><style>body { margin: 0; } section { margin-top: 40px; }</style>
            <section><div>Card content</div><p>Another selected element</p></section>
            """).html
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 360, height: 280))
        let window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(web)
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        let navigation = NavigationWaiter()
        web.navigationDelegate = navigation
        await withCheckedContinuation { continuation in
            navigation.loaded = continuation
            web.loadHTMLString(html, baseURL: nil)
        }
        _ = try await web.evaluateJavaScript(EditorScript.editor)
        let result = try await web.evaluateJavaScript("""
            (() => {
                const ids = ['div', 'p'].map(tag => +document.querySelector(tag).getAttribute('data-ds-id'));
                const reports = [];
                const callbacks = new Map();
                let nextFrame = 0;
                window.requestAnimationFrame = callback => {
                    callbacks.set(++nextFrame, callback);
                    return nextFrame;
                };
                window.cancelAnimationFrame = frame => callbacks.delete(frame);
                window.webkit = {messageHandlers: {ds: {postMessage(message) {
                    const update = JSON.parse(message);
                    if (update.type === 'selectionGeometry') reports.push(update.geometry.map(entry => entry.rect.y));
                }}}};
                function renderFrame() {
                    const scheduled = Array.from(callbacks.values());
                    callbacks.clear();
                    scheduled.forEach(callback => callback());
                }
                const ancestor = document.querySelector('section');
                window.__ds.trackSelection(ids);
                renderFrame();
                ancestor.style.transform = 'translateY(-4px)';
                renderFrame();
                ancestor.style.transform = 'translateY(-8px)';
                renderFrame();
                renderFrame();
                window.__ds.setMode('off');
                ancestor.style.transform = 'none';
                renderFrame();
                window.__ds.setMode('select');
                renderFrame();
                window.__ds.trackSelection([]);
                renderFrame();
                return callbacks.size === 0 && reports.length === 4 && reports.every((report, i) =>
                    report.length === ids.length && report.every((y, j) => y === reports[0][j] - [0, 4, 8, 0][i]));
            })()
            """)
        #expect(result as? Bool == true)
    }

    @MainActor fileprivate final class NavigationWaiter: NSObject, WKNavigationDelegate {
        var loaded: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded?.resume()
            loaded = nil
        }
    }

}

struct ArtboardAutoHeightTests {
    @Test func parsesAutoHeightAndKeepsMeasuredHeightOnMerge() throws {
        let reply = """
        首页。
        ```html artboard="首页" width=1440 height=auto
        <!DOCTYPE html><html><body><h1>Hi</h1></body></html>
        ```
        """
        let parsed = ArtboardParser.parse(reply)
        let out = try #require(parsed.first)
        #expect(out.autoHeight && out.height == nil && out.width == 1440)

        var doc = DesignDocument()
        doc.merge(parsed, into: nil, kind: .prototype)
        var board = try #require(doc.pages.first?.artboards.first)
        #expect(board.autoHeight == true && board.height == 900)

        // 画布量出整页高度后，模型再次输出 height=auto 不会把高度改回去
        doc.updateArtboard(board.id) { $0.height = 3600 }
        let edited = ArtboardParser.parse(reply.replacingOccurrences(of: "Hi", with: "Hello"))
        doc.merge(edited, into: nil, kind: .prototype)
        board = try #require(doc.pages.first?.artboards.first)
        #expect(board.height == 3600 && board.html.contains("Hello"))
    }

    @Test func detectsWebPagesBySize() {
        let site = Artboard(name: "官网", html: "", width: 1440, height: 4000)
        let app = Artboard(name: "后台", html: "", width: 1440, height: 900)
        let slide = Artboard(name: "封面", html: "", width: 1920, height: 1080)
        let phone = Artboard(name: "首页", html: "", width: 390, height: 844)
        #expect(site.fitsContent(in: .prototype) && app.fitsContent(in: .prototype))
        #expect(!slide.fitsContent(in: .prototype) && !phone.fitsContent(in: .prototype))
        #expect(!site.fitsContent(in: .slides))
        #expect(site.viewportHeight == 900)
    }

    @MainActor @Test func measuresFullPageAndPinsViewportUnits() async throws {
        // 声明 1440×900，但页面有一屏 hero + 1500px 内容，并且 body 被锁成 100vh
        let raw = """
        <!doctype html><html><head><style>
        html, body { margin: 0; height: 100vh; overflow: hidden; }
        .hero { height: 100vh; } .rest { height: 1500px; }
        </style></head><body><section class="hero">Hero</section><section class="rest">More</section></body></html>
        """
        let html = HTMLAnnotator.annotate(raw).html
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let navigation = ElementPatchWebKitTests.NavigationWaiter()
        web.navigationDelegate = navigation
        await withCheckedContinuation { continuation in
            navigation.loaded = continuation
            web.loadHTMLString(html, baseURL: nil)
        }
        _ = try await web.evaluateJavaScript(EditorScript.editor)
        func measure() async throws -> [Double] {
            let r = try await web.callAsyncJavaScript("""
                const hero = document.querySelector('.hero');
                return [hero.getBoundingClientRect().height,
                        Math.max(document.body.scrollHeight, document.body.offsetHeight)];
                """, arguments: [:], in: nil, contentWorld: .page)
            return (r as? [NSNumber])?.map(\.doubleValue) ?? []
        }
        _ = try await web.callAsyncJavaScript("window.__ds.init(source, 'select'); window.__ds.fitContent(true, 900);",
                                              arguments: ["source": html], in: nil, contentWorld: .page)
        #expect(try await measure() == [900, 2400])

        // 画板变高后 hero 仍是一屏，整页高度不变（不会越拉越高）
        web.frame.size.height = 2400
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await measure() == [900, 2400])

        // 代码面板里仍显示原始的 vh 写法
        let code = try await web.callAsyncJavaScript("""
            const id = +document.querySelector('.hero').getAttribute('data-ds-id');
            return window.__ds.inlined(id);
            """, arguments: [:], in: nil, contentWorld: .page) as? String
        #expect(code?.contains("100vh") == true)
    }
}

struct CanvasBundleTests {
    @Test func bundlesEveryArtboardAsIsolatedDocument() throws {
        let boards = [
            Artboard(name: "首页", html: "<!DOCTYPE html><html><body><script>var a = '</script>';</script><!-- x --></body></html>",
                     x: 0, y: 0, width: 1440, height: 3200),
            Artboard(name: "手机 <详情>", html: "<!DOCTYPE html><html><body>m</body></html>", x: 1520, y: 0, width: 390, height: 844),
        ]
        let html = CanvasBundle.make(title: "Weft & 社区", artboards: boards, kind: .prototype)
        #expect(html.contains("<title>Weft &amp; 社区</title>"))
        // 画板源码只出现在 JSON 数据里，不会提前结束外层的 <script>
        let data = try #require(html.range(of: #"<script type="application/json" id="ds-data">"#))
        let end = try #require(html.range(of: "</script>", range: data.upperBound..<html.endIndex))
        let json = String(html[data.upperBound..<end.lowerBound])
        #expect(!json.contains("<"))
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let parsed = try #require(payload["boards"] as? [[String: Any]])
        #expect(parsed.count == 2)
        #expect(parsed[0]["html"] as? String == boards[0].html && parsed[0]["auto"] as? Bool == true)
        #expect(parsed[1]["name"] as? String == "手机 <详情>" && parsed[1]["auto"] as? Bool == false)
        #expect(payload["mode"] as? String == "canvas")
        #expect(CanvasBundle.make(title: "deck", artboards: boards, kind: .slides).contains(#""mode":"single""#))
    }
}

struct SharedStylesTests {
    static let reply = """
    做了首页和详情两个界面，颜色和按钮放在共用样式里。
    ```css shared
    :root { --accent: #3B5BFD; }
    .btn { background: var(--accent); color: #fff; }
    ```
    ```html artboard="首页" width=390 height=844
    <!DOCTYPE html><html><head><meta charset="utf-8"><style>.hero{padding:24px}</style></head><body><button class="btn">开始</button></body></html>
    ```
    ```html artboard="详情" width=390 height=844
    <!DOCTYPE html><html><head><style>.x{}</style></head><body>详情</body></html>
    ```
    """

    @Test func parsesSharedBlockSeparatelyFromArtboards() throws {
        let shared = try #require(ArtboardParser.sharedCSS(Self.reply))
        #expect(shared.complete && shared.css.contains("--accent"))
        let boards = ArtboardParser.parse(Self.reply)
        #expect(boards.map(\.name) == ["首页", "详情"])
        // 对话里只留下说明文字，共用样式代码块也不显示
        #expect(HTMLExtractor.conversationalText(Self.reply) == "做了首页和详情两个界面，颜色和按钮放在共用样式里。")
        // 普通的 css 代码块仍是对话内容
        #expect(ArtboardParser.sharedCSS("看这段：\n```css\n.a{}\n```") == nil)
    }

    @Test func composesSharedStylesForExport() throws {
        var doc = DesignDocument()
        doc.setSharedCSS(try #require(ArtboardParser.sharedCSS(Self.reply)).css, in: nil)
        doc.merge(ArtboardParser.parse(Self.reply), into: nil, kind: .prototype)
        let page = try #require(doc.pages.first)
        let home = try #require(page.artboard(named: "首页"))
        #expect(!home.html.contains("--accent"))   // 画板本身不含共用样式

        let composed = page.composedHTML(home)
        let charset = try #require(composed.range(of: "<meta charset=\"utf-8\">"))
        let shared = try #require(composed.range(of: "<style data-ds-shared>"))
        let own = try #require(composed.range(of: "<style>.hero"))
        #expect(charset.upperBound <= shared.lowerBound && shared.upperBound <= own.lowerBound)

        let detail = page.composedHTML(try #require(page.artboard(named: "详情")))
        #expect(detail.contains("<head>\n<style data-ds-shared>"))
        #expect(SharedStyles.compose("<p>x</p>", css: ".a{}").hasPrefix("<style data-ds-shared>"))
        #expect(SharedStyles.compose("<p>x</p>", css: nil) == "<p>x</p>")
        #expect(!SharedStyles.compose("<head></head>", css: "a{content:'</style>'}").contains("'</style>'"))

        // 只改共用样式的回复：画板不变，共用样式更新
        var restyled = doc
        let first = restyled.setSharedCSS(":root { --accent: #FF6A3D; }", in: nil)
        let again = restyled.setSharedCSS(":root { --accent: #FF6A3D; }", in: nil)
        #expect(first && !again)
        #expect(restyled.pages[0].artboards == doc.pages[0].artboards)
    }

    @MainActor @Test func canvasPageUsesSharedStylesWithoutWritingThemBack() async throws {
        let raw = "<!DOCTYPE html><html><head><style>.own{color:red}</style></head><body><button class=\"btn\">Go</button></body></html>"
        let annotated = HTMLAnnotator.annotate(raw).html
        let live = SharedStyles.compose(annotated, css: ".btn{background:rgb(1, 2, 3)}", live: true)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let navigation = ElementPatchWebKitTests.NavigationWaiter()
        web.navigationDelegate = navigation
        await withCheckedContinuation { continuation in
            navigation.loaded = continuation
            web.loadHTMLString(live, baseURL: nil)
        }
        _ = try await web.evaluateJavaScript(EditorScript.editor)
        let result = try await web.callAsyncJavaScript("""
            window.__ds.init(source, 'select');
            const btn = document.querySelector('.btn');
            const before = getComputedStyle(btn).backgroundColor;
            const id = +btn.getAttribute('data-ds-id');
            const edited = JSON.parse(window.__ds.patchElement(id, 'Start', null));
            window.__ds.setShared('.btn{background:rgb(9, 8, 7)}');
            const after = getComputedStyle(btn).backgroundColor;
            const code = window.__ds.inlined(id);
            return [before, after, edited.source.includes('rgb(1, 2, 3)') ? 'leaked' : 'clean', code.includes('rgb(9, 8, 7)') || code.includes('#090807') ? 'shown' : code];
            """, arguments: ["source": annotated], in: nil, contentWorld: .page)
        #expect(result as? [String] == ["rgb(1, 2, 3)", "rgb(9, 8, 7)", "clean", "shown"])
    }
}

struct ZipExportTests {
    @Test func zipsFolderWithUTF8Names() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ds-zip-test-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "out.zip")
        let page = String(repeating: "<p>共用样式 shared</p>\n", count: 200)
        try ExportService.makeZip(name: "Weft/首页", at: url) { folder in
            try page.write(to: folder.appending(path: "首页.html"), atomically: true, encoding: .utf8)
            let sub = folder.appending(path: "png", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: sub.appending(path: "01-首页.png"))
        }
        // 用系统 unzip 解出来核对文件名和内容
        let out = dir.appending(path: "x", directoryHint: .isDirectory)
        let unzip = Process()
        unzip.executableURL = URL(filePath: "/usr/bin/unzip")
        unzip.arguments = ["-q", url.path, "-d", out.path]
        try unzip.run()
        unzip.waitUntilExit()
        #expect(unzip.terminationStatus == 0)
        let html = try String(contentsOf: out.appending(path: "Weft-首页/首页.html"), encoding: .utf8)
        #expect(html == page)
        #expect(try Data(contentsOf: out.appending(path: "Weft-首页/png/01-首页.png")) == Data([1, 2, 3]))
        #expect(try Data(contentsOf: url).count < page.utf8.count)   // 确实压缩了
    }
}
