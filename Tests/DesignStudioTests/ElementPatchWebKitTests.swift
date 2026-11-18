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

    @MainActor private final class NavigationWaiter: NSObject, WKNavigationDelegate {
        var loaded: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded?.resume()
            loaded = nil
        }
    }

}
