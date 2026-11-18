import Foundation

/// 解析模型回复中的画板代码块：
///
///     ```html artboard="首页" width=390 height=844
///     <!DOCTYPE html>…
///     ```
///
/// 支持多个代码块；最后一个未闭合的代码块会以 `complete == false` 返回（用于流式实时预览）。
nonisolated enum ArtboardParser {
    static func parse(_ text: String) -> [ParsedArtboard] {
        var result: [ParsedArtboard] = []
        var cursor = text.startIndex
        var sawElement = false

        while let open = text.range(of: "```html", options: .caseInsensitive, range: cursor..<text.endIndex) {
            // 信息串：```html 后面到行尾
            guard let lineEnd = text[open.upperBound...].firstIndex(of: "\n") else { break }
            let info = String(text[open.upperBound..<lineEnd])
            let bodyStart = text.index(after: lineEnd)
            let attrs = parseInfo(info)

            // ```html element 是元素级修改，不是画板
            if isElementInfo(info) {
                sawElement = true
                guard let close = text.range(of: "\n```", range: bodyStart..<text.endIndex) else { break }
                cursor = close.upperBound
                continue
            }

            if let close = text.range(of: "\n```", range: bodyStart..<text.endIndex) {
                let html = String(text[bodyStart..<close.lowerBound]).trimmed
                result.append(ParsedArtboard(name: attrs.name, width: attrs.width, height: attrs.height,
                                             html: html, complete: true))
                cursor = close.upperBound
            } else {
                let html = String(text[bodyStart...])
                result.append(ParsedArtboard(name: attrs.name, width: attrs.width, height: attrs.height,
                                             html: html, complete: false))
                cursor = text.endIndex
            }
        }

        // 没有代码块时，退化为直接截取完整文档
        if result.isEmpty, !sawElement,
           let s = text.range(of: "<!DOCTYPE html", options: .caseInsensitive) ?? text.range(of: "<html", options: .caseInsensitive) {
            if let e = text.range(of: "</html>", options: [.caseInsensitive, .backwards]), e.lowerBound > s.lowerBound {
                result.append(ParsedArtboard(html: String(text[s.lowerBound..<e.upperBound]), complete: true))
            } else {
                result.append(ParsedArtboard(html: String(text[s.lowerBound...]), complete: false))
            }
        }
        return result
    }

    /// 元素级修改代码块：```html element
    static func isElementInfo(_ info: String) -> Bool {
        let t = info.trimmed.lowercased()
        return t == "element" || t.hasPrefix("element ") || t.hasPrefix("element=")
    }

    /// 取回复中的第一个 ```html element 代码块（元素级修改的结果）
    static func element(_ text: String) -> (html: String, complete: Bool)? {
        var cursor = text.startIndex
        while let open = text.range(of: "```html", options: .caseInsensitive, range: cursor..<text.endIndex) {
            guard let lineEnd = text[open.upperBound...].firstIndex(of: "\n") else { return nil }
            let bodyStart = text.index(after: lineEnd)
            let close = text.range(of: "\n```", range: bodyStart..<text.endIndex)
            if isElementInfo(String(text[open.upperBound..<lineEnd])) {
                guard let close else { return (String(text[bodyStart...]), false) }
                return (String(text[bodyStart..<close.lowerBound]).trimmed, true)
            }
            guard let close else { return nil }
            cursor = close.upperBound
        }
        return nil
    }

    /// 解析 `artboard="名称" width=390 height=844`（也接受 name= / title=、单引号）
    static func parseInfo(_ info: String) -> (name: String?, width: Double?, height: Double?) {
        func value(_ keys: [String]) -> String? {
            for key in keys {
                let pattern = #"\b"# + key + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"']+))"#
                guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                      let m = re.firstMatch(in: info, range: NSRange(info.startIndex..., in: info)) else { continue }
                for g in 1...3 {
                    if let r = Range(m.range(at: g), in: info) { return String(info[r]) }
                }
            }
            return nil
        }
        let name = value(["artboard", "name", "title"]).map(\.trimmed).flatMap { $0.isEmpty ? nil : $0 }
        let width = value(["width", "w"]).flatMap { Double($0.replacingOccurrences(of: "px", with: "")) }
        let height = value(["height", "h"]).flatMap { Double($0.replacingOccurrences(of: "px", with: "")) }
        return (name, width, height)
    }

    /// 只保留有实际内容的部分代码块（实时预览时过滤掉刚开头的块）
    static func previewable(_ text: String, minLength: Int = 300) -> [ParsedArtboard] {
        parse(text).filter { $0.complete || $0.html.count >= minLength }
    }
}

/// 给 HTML 中每个元素加上 `data-ds-id`，让画布上的元素和源码一一对应；保存前再去掉
nonisolated enum HTMLAnnotator {
    static let attribute = "data-ds-id"

    /// 不需要编号的标签（不在 body 中渲染或无法编辑）
    private static let skipped: Set<String> = ["html", "head", "meta", "link", "title", "script", "style",
                                               "base", "noscript", "template"]
    /// 内容是原始文本、不能在里面找标签的元素
    private static let rawText: Set<String> = ["script", "style", "textarea", "title", "xmp", "noscript"]

    /// - Returns: 带编号的 HTML 与最大编号
    static func annotate(_ html: String) -> (html: String, maxID: Int) {
        let bytes = Array(html.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + bytes.count / 8)
        var i = 0
        var counter = 0
        let n = bytes.count

        func isAlpha(_ b: UInt8) -> Bool { (b >= 65 && b <= 90) || (b >= 97 && b <= 122) }
        func lower(_ b: UInt8) -> UInt8 { (b >= 65 && b <= 90) ? b + 32 : b }
        func matches(_ s: String, at idx: Int) -> Bool {
            let u = Array(s.utf8)
            guard idx + u.count <= n else { return false }
            for k in 0..<u.count where lower(bytes[idx + k]) != u[k] { return false }
            return true
        }

        while i < n {
            let b = bytes[i]
            guard b == 0x3C /* < */, i + 1 < n else { out.append(b); i += 1; continue }

            // 注释
            if matches("<!--", at: i) {
                var j = i + 4
                while j < n && !matches("-->", at: j) { j += 1 }
                j = min(n, j + 3)
                out.append(contentsOf: bytes[i..<j]); i = j; continue
            }
            // <!DOCTYPE …>、</tag>、<?…>
            if !isAlpha(bytes[i + 1]) {
                out.append(b); i += 1; continue
            }

            // 开始标签：读标签名
            var j = i + 1
            while j < n, isAlpha(bytes[j]) || (bytes[j] >= 48 && bytes[j] <= 57) || bytes[j] == 0x2D { j += 1 }
            let name = String(decoding: bytes[(i + 1)..<j].map(lower), as: UTF8.self)

            // 找到标签结束的 >（跳过引号内的内容）
            var k = j
            var quote: UInt8 = 0
            while k < n {
                let c = bytes[k]
                if quote != 0 { if c == quote { quote = 0 } }
                else if c == 0x22 || c == 0x27 { quote = c }
                else if c == 0x3E { break }
                k += 1
            }
            guard k < n else { out.append(contentsOf: bytes[i..<n]); i = n; break }

            let selfClosing = k > j && bytes[k - 1] == 0x2F
            let tagEnd = selfClosing ? k - 1 : k
            out.append(contentsOf: bytes[i..<tagEnd])
            if !skipped.contains(name) {
                counter += 1
                out.append(contentsOf: Array(" \(attribute)=\"\(counter)\"".utf8))
            }
            out.append(contentsOf: bytes[tagEnd...k])
            i = k + 1

            // 原始文本元素：直接拷贝到对应的结束标签
            if rawText.contains(name) && !selfClosing {
                var m = i
                while m < n && !(bytes[m] == 0x3C && matches("</" + name, at: m)) { m += 1 }
                out.append(contentsOf: bytes[i..<m]); i = m
            }
        }
        return (String(decoding: out, as: UTF8.self), counter)
    }

    /// 画布加载用：把外部样式表（如 Google Fonts）改为不阻塞渲染，加载完成后再生效。
    /// 外部请求卡住（网络慢或被墙）时，页面也能立即显示。只作用于加载到网页里的副本，不改源码。
    static func nonBlockingStylesheets(_ html: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: .caseInsensitive) else { return html }
        var result = html
        for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
            guard let r = Range(m.range, in: html) else { continue }
            let tag = String(html[r])
            let lower = tag.lowercased()
            guard lower.range(of: #"rel\s*=\s*["']?stylesheet"#, options: .regularExpression) != nil,
                  lower.range(of: #"href\s*=\s*["']?https?://"#, options: .regularExpression) != nil,
                  !lower.contains("media=") else { continue }
            let insert = #" media="print" onload="this.media='all'""#
            let end = tag.hasSuffix("/>") ? tag.index(tag.endIndex, offsetBy: -2) : tag.index(before: tag.endIndex)
            let rewritten = String(tag[..<end]) + insert + String(tag[end...])
            if let rr = Range(m.range, in: result) { result.replaceSubrange(rr, with: rewritten) }
        }
        return result
    }

    /// 去掉编号属性，得到干净的源码
    static func strip(_ html: String) -> String {
        html.replacingOccurrences(of: #"\s+data-ds-id="\d+""#, with: "", options: .regularExpression)
    }
}
