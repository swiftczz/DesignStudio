import SwiftUI
import WebKit

/// One document per message keeps selection continuous across Markdown blocks.
struct MarkdownText: View {
    enum Style: String { case reply, user, thinking }

    let text: String
    let style: Style
    @State private var height: CGFloat = 22

    init(_ text: String, style: Style = .reply) {
        self.text = text
        self.style = style
    }

    var body: some View {
        MarkdownContentView(text: text, style: style, height: $height)
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }
}

struct MarkdownContentView: NSViewRepresentable {
    private static let dataStore = WKWebsiteDataStore.nonPersistent()

    let text: String
    let style: MarkdownText.Style
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let web = Self.makeWebView(coordinator: context.coordinator)
        updateNSView(web, context: context)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.onHeight = { height = $0 }
        context.coordinator.update(text, style: style, in: web)
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "markdown", contentWorld: .defaultClient)
        web.navigationDelegate = nil
        web.stopLoading()
        coordinator.onHeight = nil
    }

    static func contains(_ responder: NSResponder?) -> Bool {
        guard let view = responder as? NSView else { return false }
        return sequence(first: view, next: { $0.superview }).contains { $0 is MessageWebView }
    }

    static func makeWebView(coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = dataStore
        configuration.userContentController.add(coordinator, contentWorld: .defaultClient, name: "markdown")
        configuration.userContentController.addUserScript(WKUserScript(
            source: bridge, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient
        ))
        let web = MessageWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = coordinator
        web.underPageBackgroundColor = .clear
        if web.responds(to: NSSelectorFromString("setDrawsBackground:")) {
            web.setValue(false, forKey: "drawsBackground")
        }
        web.loadHTMLString(page, baseURL: nil)
        return web
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var onHeight: ((CGFloat) -> Void)?
        private var lastHeight: CGFloat = 0
        private var text: String?
        private var style: MarkdownText.Style = .reply
        private var isReady = false
        private var needsRender = false
        private var isRendering = false

        func update(_ text: String, style: MarkdownText.Style, in webView: WKWebView) {
            guard text != self.text || style != self.style else { return }
            self.text = text
            self.style = style
            needsRender = true
            showContent(in: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isReady = true
            showContent(in: webView)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            isReady = false
            needsRender = true
            isRendering = false
            webView.loadHTMLString(MarkdownContentView.page, baseURL: nil)
        }

        private func showContent(in webView: WKWebView) {
            guard isReady, needsRender, !isRendering, let text else { return }
            needsRender = false
            isRendering = true
            webView.callAsyncJavaScript("updateMarkdown(html, style)",
                                        arguments: ["html": MarkdownDocument.html(text), "style": style.rawValue],
                                        in: nil, in: .defaultClient) { [weak self, weak webView] _ in
                guard let self, let webView else { return }
                self.isRendering = false
                self.showContent(in: webView)
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let value = message.body as? [String: Double] else { return }
            if let height = value["height"], height.isFinite, height > 0 {
                let measured = ceil(height)
                guard measured != lastHeight else { return }
                lastHeight = measured
                onHeight?(measured)
            } else if let y = value["anchor"], y.isFinite, let web = message.webView,
                      let documentView = web.enclosingScrollView?.documentView {
                let localY = web.isFlipped ? y : web.bounds.height - y - 24
                let target = web.convert(NSRect(x: 0, y: localY, width: 1, height: 24), to: documentView)
                documentView.scrollToVisible(target)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.navigationType == .linkActivated, let url = action.request.url {
                if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
                    NSWorkspace.shared.open(url)
                }
                return .cancel
            }
            return !isReady && action.request.url?.absoluteString == "about:blank" ? .allow : .cancel
        }
    }

    private final class MessageWebView: WKWebView {
        override func scrollWheel(with event: NSEvent) {
            // Vertical scrolling belongs to the chat; wide tables and code keep horizontal scrolling.
            if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) || event.modifierFlags.contains(.shift) {
                super.scrollWheel(with: event)
            } else {
                nextResponder?.scrollWheel(with: event)
            }
        }
    }

    private static let bridge = """
    const message = document.querySelector('#message');
    const content = document.querySelector('#content');
    const send = data => window.webkit.messageHandlers.markdown.postMessage(data);
    let pending;

    new ResizeObserver(() => {
        if (document.documentElement.clientWidth > 1 && content.hasChildNodes()) {
            send({height: message.getBoundingClientRect().height});
        }
    }).observe(message);

    function hasSelection() {
        const selection = window.getSelection();
        return selection && !selection.isCollapsed && content.contains(selection.anchorNode);
    }

    function updateMarkdown(html, style) {
        if (hasSelection()) {
            pending = [html, style];
            return;
        }
        pending = null;
        message.className = style;
        content.innerHTML = html;
        for (const target of content.querySelectorAll('table')) {
            const wrapper = document.createElement('div');
            wrapper.className = 'table-scroll';
            target.before(wrapper);
            wrapper.append(target);
        }
    }

    document.addEventListener('selectionchange', () => {
        if (pending && !hasSelection()) updateMarkdown(...pending);
    });
    document.addEventListener('click', event => {
        const link = event.target.closest('a[href^="#"]');
        const target = link && document.getElementById(link.hash.slice(1));
        if (target) {
            event.preventDefault();
            send({anchor: target.getBoundingClientRect().top});
        }
    });
    """

    private static let page = """
    <!doctype html>
    <html><head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="referrer" content="no-referrer">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: http: data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
    <style>
    :root {
        color-scheme: light dark;
        --text: #1d1d20;
        --secondary: #626269;
        --surface: rgba(0,0,0,.055);
        --border: rgba(0,0,0,.14);
        --link: #005eb8;
    }
    @media (prefers-color-scheme: dark) {
        :root {
            --text: #f0f0f2;
            --secondary: #b0b0b8;
            --surface: rgba(255,255,255,.08);
            --border: rgba(255,255,255,.20);
            --link: #78baff;
        }
    }
    html, body { margin: 0; padding: 0; background: transparent; overflow: hidden; }
    body { color: var(--text); font: 14px/1.55 -apple-system, BlinkMacSystemFont, sans-serif; }
    #message { display: flow-root; }
    #content { display: flow-root; overflow-wrap: anywhere; }
    #content > :first-child { margin-top: 0; }
    #content > :last-child { margin-bottom: 0; }
    #message.user { display: flex; justify-content: flex-end; }
    .user #content {
        min-width: 0; max-width: 100%; box-sizing: border-box;
        padding: 9px 14px; border-radius: 18px; background: var(--surface);
    }
    .thinking { color: var(--secondary); }
    p, ul, ol, blockquote, pre, .table-scroll, hr { margin: 0 0 10px; }
    h1, h2, h3, h4, h5, h6 { margin: 14px 0 7px; line-height: 1.35; font-weight: 650; }
    h1 { font-size: 1.5em; } h2 { font-size: 1.3em; } h3 { font-size: 1.15em; }
    h4, h5, h6 { font-size: 1em; }
    ul, ol { padding-inline-start: 1.65em; }
    li + li { margin-top: 4px; }
    li > ul, li > ol { margin: 4px 0 0; }
    li::marker { color: var(--secondary); }
    blockquote { padding-inline-start: 12px; border-inline-start: 2px solid var(--border); color: var(--secondary); }
    blockquote > :last-child { margin-bottom: 0; }
    a { color: var(--link); text-decoration: underline; text-underline-offset: 2px; }
    img { max-width: 100%; height: auto; vertical-align: middle; }
    input[type=checkbox] { vertical-align: middle; margin-inline: 0 .4em; }
    pre, code { font: .88em/1.55 ui-monospace, SFMono-Regular, Menlo, monospace; }
    code { background: var(--surface); padding: .1em .3em; border-radius: 4px; }
    pre { padding: 9px 11px; overflow-x: auto; border-radius: 8px; background: var(--surface); }
    pre code { font-size: 1em; background: none; padding: 0; }
    .table-scroll { overflow-x: auto; }
    table { border-collapse: collapse; min-width: max-content; }
    th, td { border: 1px solid var(--border); padding: 5px 9px; }
    th { background: var(--surface); font-weight: 650; }
    td { max-width: 24em; }
    hr { margin-top: 12px; border: 0; border-top: 1px solid var(--border); }
    .footnotes { margin-top: 12px; color: var(--secondary); font-size: .9em; }
    .footnotes ol:last-child { margin-bottom: 0; }
    </style></head><body><div id="message"><div id="content"></div></div></body></html>
    """
}
