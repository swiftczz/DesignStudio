import AppKit
import Foundation
import Testing
import WebKit
@testable import DesignStudio

struct ElementPatchWebKitTests {
    @MainActor @Test func componentUpdatesAcrossCanvasesAndPreservesInstanceText() async throws {
        let folder = try TempWorkspace.make(prefix: "component-instances")
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = AppModel(persistence: PersistenceController(root: folder))
        let first = Artboard(name: "源", html: "<button id='open'>默认文案</button>", width: 390, height: 680)
        let second = Artboard(name: "实例", html: "<h1>实例画板</h1>", width: 390, height: 680)
        let firstPage = DesignPage(name: "第一张", artboards: [first])
        let secondPage = DesignPage(name: "第二张", artboards: [second])
        var project = Project(name: "组件测试", kind: .prototype)
        project.document = DesignDocument(pages: [firstPage, secondPage])
        app.projects = [project]
        let session = app.session(for: project.id)

        func installEditor(_ board: Artboard) async throws -> WKWebView {
            let annotated = HTMLAnnotator.annotate(board.html).html
            let web = WKWebView(frame: board.frame)
            let navigation = NavigationWaiter()
            web.navigationDelegate = navigation
            await withCheckedContinuation { continuation in
                navigation.loaded = continuation
                web.loadHTMLString(annotated, baseURL: ArtboardWebView.baseURL)
            }
            _ = try await web.evaluateJavaScript(EditorScript.editor)
            _ = try await web.callAsyncJavaScript("return window.__ds.init(source, 'select')", arguments: ["source": annotated],
                                                 in: nil, contentWorld: .page)
            let handle = session.handle(for: board.id)
            handle.webView = web
            handle.isReady = true
            handle.isInitialized = true
            handle.loadedSource = board.html
            return web
        }

        let sourceWeb = try await installEditor(first)
        let sourceID = try #require(try await sourceWeb.evaluateJavaScript("+document.querySelector('button').dataset.dsId") as? Int)
        session.select(CanvasSelection(artboardID: first.id, elementID: sourceID))
        session.selectedProps = await session.handle(for: first.id).decode(ElementProps.self, "return window.__ds.props(id)", ["id": sourceID])
        let componentID = try #require(await session.createComponent(name: "按钮"))
        let component = try #require(session.document.components.first)
        #expect(component.defaultText == "默认文案")

        session.switchPage(secondPage.id)
        let instanceWeb = try await installEditor(second)
        #expect(await session.insertComponent(componentID, in: second.id))
        #expect(await session.overrideComponentText("实例文案"))
        #expect(await session.insertComponent(componentID, in: second.id))
        let distinctIDs = try await instanceWeb.evaluateJavaScript("new Set([...document.querySelectorAll('button')].map(b => b.id)).size")
        #expect(distinctIDs as? Int == 2)

        let insertedID = try #require(session.selection?.elementID)
        let changed = try #require(await session.handle(for: second.id).decode(EditResult.self,
            "return window.__ds.setAttr(id, 'title', 'Updated')", ["id": insertedID]))
        session.handleEditorMessage(EditorMessage(type: "changed", result: changed), from: second.id)
        #expect(await session.updateComponent(component))

        let working = session.document
        #expect(working.artboard(first.id)?.html.contains("title=\"Updated\"") == true)
        #expect(working.artboard(second.id)?.html.contains("实例文案") == true)
        #expect(working.artboard(second.id)?.html.contains("默认文案") == true)
        #expect(working.artboard(second.id)?.html.components(separatedBy: "title=\"Updated\"").count == 3)

        project.document = working
        let url = folder.appending(path: "component.designstudio")
        try ProjectArchive(project: project, designSystem: nil, includingHistory: false, canvasIDs: [secondPage.id]).write(to: url)
        let imported = try ProjectArchive.read(from: url).importedCopy(existingDesignSystems: []).project
        #expect(imported.workingDocument.components.first?.id == componentID)
        #expect(imported.workingDocument.composedHTML(second.id)?.contains("实例文案") == true)
        #expect(imported.workingDocument.allArtboards.map(\.id) == [second.id])
    }

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
        // SwiftUI sets the full frame on initial layout, before the WebView has loaded.
        viewport.frame = CGRect(x: 30, y: 40, width: 300, height: 225)
        let initialSize = web.convert(layoutSize, to: window.contentView)
        #expect(abs(initialSize.width - 300) < 0.001)
        #expect(abs(initialSize.height - 225) < 0.001)
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
    @Test func opensCanvasesSavedWithPrototypeMetadata() throws {
        let start = Artboard(name: "首页", html: #"<button data-ds-prototype-link="old">打开详情</button>"#,
                            width: 390, height: 680)
        let destination = Artboard(name: "详情", html: "<h1>详情</h1>", width: 390, height: 680)
        let page = DesignPage(name: "画布", artboards: [start, destination])
        let encoded = try JSONEncoder().encode(page)
        var savedPage = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        savedPage["prototype"] = ["startArtboardID": destination.id.uuidString, "links": []]

        let restored = try JSONDecoder().decode(DesignPage.self, from: JSONSerialization.data(withJSONObject: savedPage))
        #expect(restored == page)
        let html = CanvasBundle.make(title: restored.name, artboards: restored.composedArtboards, kind: .prototype)
        #expect(html.contains(#""mode":"canvas""#))
        #expect(!html.contains("wirePrototype"))
    }

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
    @Test func zipsCanvasWithUTF8NamesAndPDFForEachArtboard() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ds-zip-test-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "out.zip")
        let page = String(repeating: "<p>共用样式 shared</p>\n", count: 200)
        let css = "body { margin: 0; }"
        let firstPNG = Data([1, 2, 3])
        let firstPDF = Data("first PDF".utf8)
        let secondPDF = Data("second PDF".utf8)
        try ExportService.makeZip(name: "Weft/首页", at: url) { folder in
            try ExportService.writeCanvasZipContents(to: folder, bundle: page, sharedCSS: css, boards: [
                ("首页", "<p>首页</p>", firstPNG, firstPDF),
                ("书架", "<p>书架</p>", nil, secondPDF),
            ])
        }
        // 用系统 unzip 解出来核对文件名和内容
        let out = dir.appending(path: "x", directoryHint: .isDirectory)
        let unzip = Process()
        unzip.executableURL = URL(filePath: "/usr/bin/unzip")
        unzip.arguments = ["-q", url.path, "-d", out.path]
        try unzip.run()
        unzip.waitUntilExit()
        #expect(unzip.terminationStatus == 0)
        let root = out.appending(path: "Weft-首页", directoryHint: .isDirectory)
        #expect(try String(contentsOf: root.appending(path: "index.html"), encoding: .utf8) == page)
        #expect(try String(contentsOf: root.appending(path: "shared.css"), encoding: .utf8) == css)
        #expect(try String(contentsOf: root.appending(path: "html/01-首页.html"), encoding: .utf8) == "<p>首页</p>")
        #expect(try String(contentsOf: root.appending(path: "html/02-书架.html"), encoding: .utf8) == "<p>书架</p>")
        #expect(try Data(contentsOf: root.appending(path: "png/01-首页.png")) == firstPNG)
        #expect(try Data(contentsOf: root.appending(path: "pdf/01-首页.pdf")) == firstPDF)
        #expect(try Data(contentsOf: root.appending(path: "pdf/02-书架.pdf")) == secondPDF)
        #expect(try Data(contentsOf: url).count < page.utf8.count)   // 确实压缩了
    }
}

struct ArtboardReflowTests {
    /// 两行：第一行 A B C（手机，间距 80），第二行 D E（第一行下方 200）
    static func page() -> DesignPage {
        func b(_ n: String, _ x: Double, _ y: Double, _ w: Double = 390, _ h: Double = 844) -> Artboard {
            Artboard(name: n, html: "<p>\(n)</p>", x: x, y: y, width: w, height: h)
        }
        return DesignPage(name: "p", artboards: [
            b("A", 0, 0), b("B", 470, 0), b("C", 940, 0),
            b("D", 0, 1044), b("E", 470, 1044),
        ])
    }

    func frames(_ page: DesignPage) -> [String: CGRect] {
        Dictionary(uniqueKeysWithValues: page.artboards.map { ($0.name, $0.frame) })
    }

    func noOverlaps(_ page: DesignPage) -> Bool {
        let f = page.artboards.map(\.frame)
        for i in f.indices { for j in f.indices where i < j && f[i].intersects(f[j]) { return false } }
        return true
    }

    @Test func widerArtboardPushesRowRightKeepingGap() {
        var doc = DesignDocument(pages: [Self.page()])
        let a = doc.pages[0].artboards[0].id
        doc.resizeArtboard(a, width: 1440)
        let f = frames(doc.pages[0])
        #expect(f["B"]!.minX == 1440 + 80 && f["C"]!.minX == f["B"]!.maxX + 80)
        #expect(f["D"]!.minX == 0 && f["E"]!.minX == 470)   // 下一行不受横向影响
        #expect(noOverlaps(doc.pages[0]))

        doc.resizeArtboard(a, width: 390)   // 变回去，右侧画板跟着回来
        #expect(frames(doc.pages[0]) == frames(Self.page()))
    }

    @Test func tallerArtboardPushesLowerRowsDown() {
        var doc = DesignDocument(pages: [Self.page()])
        let b = doc.pages[0].artboards[1].id
        doc.resizeArtboard(b, height: 3000)
        let f = frames(doc.pages[0])
        #expect(f["D"]!.minY == 3000 + 200 && f["E"]!.minY == 3000 + 200)   // 整行一起挪，仍然对齐
        #expect(f["A"]!.minY == 0 && f["C"]!.minX == 940)
        #expect(noOverlaps(doc.pages[0]))

        doc.resizeArtboard(b, height: 844)
        #expect(frames(doc.pages[0]) == frames(Self.page()))
    }

    @Test func growthWithinTallestInRowMovesNothingBelow() {
        var page = Self.page()
        page.artboards[2].height = 2000          // C 最高
        page.artboards[3].y = 2200; page.artboards[4].y = 2200
        var doc = DesignDocument(pages: [page])
        doc.resizeArtboard(page.artboards[0].id, height: 1500)   // A 变高但没超过 C
        let f = frames(doc.pages[0])
        #expect(f["D"]!.minY == 2200 && f["E"]!.minY == 2200)
        // 再超过 C：只挪超出的部分
        doc.resizeArtboard(page.artboards[0].id, height: 2600)
        #expect(frames(doc.pages[0])["D"]!.minY == 2800)
        #expect(noOverlaps(doc.pages[0]))
    }

    @Test func shrinkingNeverPullsIntoOtherArtboards() {
        // C 在 A 右边，但 C 下面紧挨着 F；A 变窄时 B C 左移，不会撞上左下方的画板
        var page = Self.page()
        page.artboards.append(Artboard(name: "F", html: "", x: 470, y: 900, width: 390, height: 100))
        var doc = DesignDocument(pages: [page])
        doc.resizeArtboard(page.artboards[0].id, width: 200)
        #expect(noOverlaps(doc.pages[0]))
        let bx = Double(frames(doc.pages[0])["B"]!.minX)
        #expect(bx == 280, "B.minX = \(bx.debugDescription)")
    }

    @Test func aiReplyWithNewSizeReflowsNeighbours() {
        var doc = DesignDocument(pages: [Self.page()])
        let reply = """
        改成桌面版。
        ```html artboard="A" width=1440 height=900
        <!DOCTYPE html><html><body>A</body></html>
        ```
        """
        doc.merge(ArtboardParser.parse(reply), into: nil, kind: .prototype)
        let f = frames(doc.pages[0])
        #expect(f["A"]!.size == CGSize(width: 1440, height: 900))
        #expect(f["B"]!.minX == 1520 && f["D"]!.minY == 1100)
        #expect(noOverlaps(doc.pages[0]))
    }
}

struct FlowDragTests {
    /// 在 WebKit 里模拟按下、移动、松开，返回 [h1 的 left, top, 第一个元素是否是 h1, 源码里的 h1 样式]
    @MainActor func drag(dx: Double, dy: Double) async throws -> [String] {
        let raw = """
        <!DOCTYPE html><html><body style="margin:0">
        <div class="box" style="padding:20px">
          <p class="eyebrow" style="margin:0;height:20px">WORM</p>
          <h1 id="title" style="margin:0;font-size:32px;height:40px">Recursion Protocol</h1>
          <p class="by" style="margin:0;height:20px">by harborlight</p>
        </div></body></html>
        """
        let html = HTMLAnnotator.annotate(raw).html
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let navigation = ElementPatchWebKitTests.NavigationWaiter()
        web.navigationDelegate = navigation
        await withCheckedContinuation { continuation in
            navigation.loaded = continuation
            web.loadHTMLString(html, baseURL: nil)
        }
        _ = try await web.evaluateJavaScript(EditorScript.editor)
        let result = try await web.callAsyncJavaScript("""
            window.__ds.init(source, 'select');
            let changed = null;
            window.webkit = { messageHandlers: { ds: { postMessage: m => { const o = JSON.parse(m); if (o.type === 'changed') changed = o.result; } } } };
            const h1 = document.getElementById('title');
            const r = h1.getBoundingClientRect();
            const x = r.left + 30, y = r.top + 10;
            const fire = (type, cx, cy) => h1.dispatchEvent(new PointerEvent(type, { bubbles: true, cancelable: true, clientX: cx, clientY: cy, button: 0, pointerId: 1 }));
            fire('pointerdown', x, y);
            for (let i = 1; i <= 5; i++) fire('pointermove', x + dx * i / 5, y + dy * i / 5);
            fire('pointerup', x + dx, y + dy);
            const first = document.querySelector('.box').firstElementChild;
            return [h1.style.left, h1.style.top, String(first === h1), changed ? (changed.source.match(/<h1[^>]*>/) || [''])[0] : 'none'];
            """, arguments: ["source": html, "dx": dx, "dy": dy], in: nil, contentWorld: .page)
        return result as? [String] ?? []
    }

    @MainActor @Test func smallDragInFlowLayoutKeepsElementWhereDropped() async throws {
        let r = try await drag(dx: 60, dy: 8)
        #expect(r[0] == "60px" && r[1] == "8px")
        #expect(r[2] == "false")                           // 没有换位
        #expect(r[3].contains("left: 60px") && r[3].contains("top: 8px") && r[3].contains("position: relative"))
    }

    @MainActor @Test func dragPastSiblingStillReorders() async throws {
        let r = try await drag(dx: 0, dy: -40)
        #expect(r[2] == "true")                            // 移到了 WORM 前面
        #expect(r[0] == "" && r[1] == "")                  // 没有留下偏移
    }
}
