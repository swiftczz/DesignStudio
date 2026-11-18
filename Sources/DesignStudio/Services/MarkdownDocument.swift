import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// CommonMark with the GitHub extensions used by chat messages.
nonisolated enum MarkdownDocument {
    private static let registeredExtensions: Void = cmark_gfm_core_extensions_ensure_registered()
    private static let renderOptions = CMARK_OPT_VALIDATE_UTF8 | CMARK_OPT_FOOTNOTES
        | CMARK_OPT_TABLE_PREFER_STYLE_ATTRIBUTES

    static func withDocument<T>(_ text: String, githubExtensions: Bool = false,
                                _ action: (UnsafeMutablePointer<cmark_node>, UnsafeMutablePointer<cmark_parser>) -> T) -> T? {
        let options = githubExtensions ? renderOptions : CMARK_OPT_DEFAULT
        guard let parser = cmark_parser_new(options) else { return nil }
        defer { cmark_parser_free(parser) }
        if githubExtensions {
            _ = registeredExtensions
            for name in ["table", "strikethrough", "autolink", "tasklist"] {
                if let syntax = cmark_find_syntax_extension(name) {
                    cmark_parser_attach_syntax_extension(parser, syntax)
                }
            }
        }
        let length = text.utf8.count
        text.withCString { cmark_parser_feed(parser, $0, length) }
        guard let root = cmark_parser_finish(parser) else { return nil }
        defer { cmark_node_free(root) }
        return action(root, parser)
    }

    static func html(_ text: String) -> String {
        withDocument(text, githubExtensions: true) { root, parser in
            // cmark's safe HTML mode preserves Markdown links and images and skips raw HTML.
            guard let html = cmark_render_html(root, renderOptions, cmark_parser_get_syntax_extensions(parser)) else {
                return ""
            }
            defer { free(html) }
            return String(cString: html)
        } ?? ""
    }
}
