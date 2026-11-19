import Foundation

/// 画布的共用样式：设计变量、基础排版和通用组件类名只写一次，同一画布的每个画板自动带上。
/// 画板自己的 <style> 写在后面，可以覆盖共用样式。
nonisolated enum SharedStyles {
    /// 画布上加载画板时注入的样式元素 id（编辑脚本可以就地替换内容，不用重新加载）
    static let liveID = "__ds-shared"

    /// 把共用样式放进画板文档的 <head> 开头（在 charset 声明之后、画板自己的样式之前）。
    /// - Parameter live: 画布内部使用：即使没有共用样式也放一个空的 <style>，之后可以直接替换内容
    static func compose(_ html: String, css: String?, live: Bool = false) -> String {
        let css = (css ?? "").trimmed
        guard live || !css.isEmpty else { return html }
        let safe = css.replacingOccurrences(of: "</style", with: "<\\/style", options: .caseInsensitive)
        let tag = live ? "<style id=\"\(liveID)\">\(safe)</style>" : "<style data-ds-shared>\n\(safe)\n</style>"
        if let head = firstMatch(#"<head(?:\s[^>]*)?>"#, in: html) {
            // charset 声明要留在文档开头附近，共用样式放到它后面
            let headEnd = firstMatch(#"</head\s*>"#, in: html)?.lowerBound ?? html.endIndex
            if let charset = firstMatch(#"<meta\s[^>]*charset[^>]*>"#, in: html, range: head.upperBound..<headEnd) {
                return html.replacingCharacters(in: charset.upperBound..<charset.upperBound, with: "\n" + tag)
            }
            return html.replacingCharacters(in: head.upperBound..<head.upperBound, with: "\n" + tag)
        }
        if let root = firstMatch(#"<html(?:\s[^>]*)?>"#, in: html) {
            return html.replacingCharacters(in: root.upperBound..<root.upperBound, with: "<head>" + tag + "</head>")
        }
        if let doctype = firstMatch(#"<!doctype[^>]*>"#, in: html) {
            return html.replacingCharacters(in: doctype.upperBound..<doctype.upperBound, with: "\n" + tag)
        }
        return tag + "\n" + html
    }

    private static func firstMatch(_ pattern: String, in text: String, range: Range<String.Index>? = nil) -> Range<String.Index>? {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive], range: range)
    }
}
