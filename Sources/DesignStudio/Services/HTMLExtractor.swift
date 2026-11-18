import Foundation

/// 从模型回复中提取 HTML 设计稿
nonisolated enum HTMLExtractor {
    private static func fenceRange(in text: String) -> Range<String.Index>? {
        text.range(of: "```html", options: .caseInsensitive)
    }

    static func fenceStarted(_ text: String) -> Bool {
        fenceRange(in: text) != nil || text.range(of: "<!DOCTYPE html", options: .caseInsensitive) != nil
    }

    /// 完整提取；代码块未闭合时返回 nil
    static func extract(from text: String) -> String? {
        if let start = fenceRange(in: text) {
            let afterTag = text[start.upperBound...]
            guard let nl = afterTag.firstIndex(of: "\n") else { return nil }
            let body = text[text.index(after: nl)...]
            if let end = body.range(of: "\n```") {
                let html = String(body[..<end.lowerBound]).trimmed
                return html.isEmpty ? nil : html
            }
            return nil
        }
        // 没有代码块时，尝试直接截取完整文档
        if let s = text.range(of: "<!DOCTYPE html", options: .caseInsensitive) ?? text.range(of: "<html", options: .caseInsensitive),
           let e = text.range(of: "</html>", options: [.caseInsensitive, .backwards]),
           e.lowerBound > s.lowerBound {
            return String(text[s.lowerBound..<e.upperBound])
        }
        return nil
    }

    /// 流式过程中的部分 HTML（用于实时预览）
    static func partial(from text: String) -> String? {
        if let full = extract(from: text) { return full }
        if let start = fenceRange(in: text) {
            let afterTag = text[start.upperBound...]
            guard let nl = afterTag.firstIndex(of: "\n") else { return nil }
            let body = String(text[text.index(after: nl)...])
            return body.isEmpty ? nil : body
        }
        if let s = text.range(of: "<!DOCTYPE html", options: .caseInsensitive) ?? text.range(of: "<html", options: .caseInsensitive) {
            return String(text[s.lowerBound...])
        }
        return nil
    }

    /// 用于聊天区展示：去掉所有 HTML 代码块（多画板时有多个）
    static func conversationalText(_ text: String, placeholder: String = "") -> String {
        var result = text
        var removedFence = false
        while let start = fenceRange(in: result) {
            removedFence = true
            let afterStart = result[start.upperBound...]
            if let nl = afterStart.firstIndex(of: "\n"),
               let end = result[result.index(after: nl)...].range(of: "\n```") {
                result.replaceSubrange(start.lowerBound..<end.upperBound, with: placeholder)
            } else {
                result.replaceSubrange(start.lowerBound..<result.endIndex, with: placeholder)
                break
            }
        }
        if !removedFence, let s = result.range(of: "<!DOCTYPE html", options: .caseInsensitive) {
            if let e = result.range(of: "</html>", options: [.caseInsensitive, .backwards]), e.lowerBound > s.lowerBound {
                result.replaceSubrange(s.lowerBound..<e.upperBound, with: placeholder)
            } else {
                result.replaceSubrange(s.lowerBound..<result.endIndex, with: placeholder)
            }
        }
        // 去掉代码块后前后的换行会叠在一起，连续空行合并成一个
        result = result.replacingOccurrences(of: #"\n[ \t]*(?:\n[ \t]*){2,}"#, with: "\n\n",
                                             options: .regularExpression)
        return result.trimmed
    }

    /// 流式过程中已写出的 HTML 总行数（用于进度提示）
    static func partialLineCount(_ text: String) -> Int {
        ArtboardParser.parse(text).reduce(0) { sum, a in sum + a.html.reduce(0) { $1 == "\n" ? $0 + 1 : $0 } }
    }
}

/// 解析 / 写回模型暴露的可调参数
nonisolated enum TweakParser {
    private static let markers = ["id=\"ds-tweaks\"", "id='ds-tweaks'"]

    private static func jsonRange(in html: String) -> Range<String.Index>? {
        guard let idRange = markers.lazy.compactMap({ html.range(of: $0) }).first,
              let open = html[idRange.upperBound...].firstIndex(of: ">") else { return nil }
        let start = html.index(after: open)
        guard let close = html[start...].range(of: "</script>") else { return nil }
        return start..<close.lowerBound
    }

    static func parse(_ html: String) -> [TweakControl] {
        guard let range = jsonRange(in: html) else { return [] }
        let json = String(html[range]).trimmed
        return (try? JSONDecoder().decode([TweakControl].self, from: Data(json.utf8))) ?? []
    }

    /// 把当前调整值写回 HTML：更新默认值，并追加覆盖样式
    static func bake(_ html: String, controls: [TweakControl], values: [String: String]) -> String {
        var result = html

        // 1. 更新 JSON 中的默认值
        let updated = controls.map { c -> TweakControl in
            var c = c
            if let v = values[c.variable] { c.value = v }
            return c
        }
        if let range = jsonRange(in: result),
           let data = try? JSONEncoder().encode(updated),
           let json = String(data: data, encoding: .utf8) {
            result.replaceSubrange(range, with: "\n" + json + "\n")
        }

        // 2. 覆盖样式（先移除旧的）
        let openTag = "<style id=\"ds-tweak-overrides\">"
        if let s = result.range(of: openTag),
           let e = result[s.upperBound...].range(of: "</style>") {
            result.removeSubrange(s.lowerBound..<e.upperBound)
        }
        let declarations = updated
            .map { "\($0.variable): \($0.cssValue($0.value)) !important;" }
            .joined(separator: " ")
        let style = "\(openTag):root { \(declarations) }</style>"
        if let head = result.range(of: "</head>", options: .caseInsensitive) {
            result.insert(contentsOf: style, at: head.lowerBound)
        } else {
            result = style + result
        }
        return result
    }
}
