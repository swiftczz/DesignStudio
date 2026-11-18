import AppKit
import Foundation
import Testing
import WebKit
@testable import DesignStudio

struct ElementPatchWebKitTests {
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

    @MainActor private final class NavigationWaiter: NSObject, WKNavigationDelegate {
        var loaded: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded?.resume()
            loaded = nil
        }
    }

}
