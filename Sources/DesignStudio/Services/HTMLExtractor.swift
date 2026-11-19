import Foundation
import cmark_gfm

/// 把生成的设计代码与对话 Markdown 分开。只识别顶层代码块或完整 HTML 文档。
nonisolated enum HTMLExtractor {
    struct Artifact {
        var info: String
        var html: String
        var complete: Bool
        var range: Range<String.Index>
    }

    static func artifacts(in text: String) -> [Artifact] {
        guard text.range(of: "html", options: .caseInsensitive) != nil,
              text.contains("```") || text.contains("~~~") || text.contains("<") else { return [] }
        return MarkdownDocument.withDocument(text) { root, _ in
            let lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }
            var artifacts: [Artifact] = []
            var next = cmark_node_first_child(root)
            while let node = next {
                next = cmark_node_next(node)
                let start = Int(cmark_node_get_start_line(node)) - 1
                guard lines.indices.contains(start) else { continue }
                let lower = lines[start].startIndex
                if let last = artifacts.last, lower < last.range.upperBound { continue }

                let type = cmark_node_get_type(node)
                if type == CMARK_NODE_CODE_BLOCK {
                    let end = Int(cmark_node_get_end_line(node)) - 1
                    guard lines.indices.contains(end), start <= end else { continue }
                    var length: Int32 = 0
                    var offset: Int32 = 0
                    var character: CChar = 0
                    guard cmark_node_get_fenced(node, &length, &offset, &character) != 0,
                          let fenceInfo = cmark_node_get_fence_info(node),
                          let literal = cmark_node_get_literal(node) else { continue }
                    let parts = String(cString: fenceInfo).split(maxSplits: 1, whereSeparator: \.isWhitespace)
                    guard parts.first?.lowercased() == "html" else { continue }
                    let info = parts.count == 2 ? String(parts[1]) : ""
                    let html = String(cString: literal)
                    let dimensions = ArtboardParser.parseInfo(info)
                    guard ArtboardParser.isElementInfo(info) || dimensions.name != nil
                            || dimensions.width != nil || dimensions.height != nil || dimensions.autoHeight
                            || startsHTMLDocument(html) else { continue }

                    let fence = Character(UnicodeScalar(UInt8(bitPattern: character)))
                    let closing = lines[end].drop(while: { $0 == " " || $0 == "\t" })
                    let markers = closing.prefix(while: { $0 == fence })
                    let complete = end > start && markers.count >= Int(length)
                        && closing.dropFirst(markers.count).allSatisfy(\.isWhitespace)
                    artifacts.append(Artifact(info: info, html: complete ? html.trimmed : html,
                                              complete: complete, range: lower..<lines[end].endIndex))

                } else if startsHTMLDocument(lines[start]) {
                    let closing = text.range(of: "</html>", options: .caseInsensitive, range: lower..<text.endIndex)
                    let upper = closing?.upperBound ?? text.endIndex
                    artifacts.append(Artifact(info: "", html: String(text[lower..<upper]).trimmed,
                                              complete: closing != nil, range: lower..<upper))
                }
            }
            return artifacts
        } ?? []
    }

    private static func startsHTMLDocument(_ text: some StringProtocol) -> Bool {
        let prefix = text.drop(while: \.isWhitespace).prefix(15).lowercased()
        return prefix.hasPrefix("<!doctype html") || prefix == "<html" || prefix.hasPrefix("<html>")
            || prefix.hasPrefix("<html ") || prefix.hasPrefix("<html\t") || prefix.hasPrefix("<html\n")
    }

    static func fenceStarted(_ text: String) -> Bool {
        !artifacts(in: text).isEmpty
    }

    static func extract(from text: String) -> String? {
        guard let first = artifacts(in: text).first, first.complete, !first.html.isEmpty else { return nil }
        return first.html
    }

    static func partial(from text: String) -> String? {
        guard let first = artifacts(in: text).first, !first.html.isEmpty else { return nil }
        return first.html
    }

    static func conversationalText(_ text: String, placeholder: String = "") -> String {
        let artifacts = artifacts(in: text)
        guard !artifacts.isEmpty else { return trimmingBlankLines(text[...]) }

        var pieces: [String] = []
        var cursor = text.startIndex
        let replacement = placeholder.trimmed
        for artifact in artifacts {
            let prose = trimmingBlankLines(text[cursor..<artifact.range.lowerBound])
            if !prose.isEmpty { pieces.append(prose) }
            if !replacement.isEmpty { pieces.append(replacement) }
            cursor = artifact.range.upperBound
        }
        let trailing = trimmingBlankLines(text[cursor...])
        if !trailing.isEmpty { pieces.append(trailing) }
        return pieces.joined(separator: "\n\n")
    }

    private static func trimmingBlankLines(_ text: Substring) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
        guard let first = lines.first(where: { !$0.allSatisfy(\.isWhitespace) }),
              let last = lines.last(where: { !$0.allSatisfy(\.isWhitespace) }) else { return "" }
        return String(text[first.startIndex..<last.endIndex])
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
