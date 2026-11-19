import Foundation
import CoreGraphics

// MARK: - 文档结构：画布 → 画板

/// 画布上的一个画板：一个完整独立的 HTML 文档（一个界面 / 一页幻灯片）
nonisolated struct Artboard: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var html: String
    /// 在画布世界坐标中的位置与尺寸（CSS 像素）
    var x: Double = 0
    var y: Double = 0
    var width: Double
    var height: Double
    /// 网页画板：高度跟随页面内容（模型输出 `height=auto`）。nil 时按尺寸判断，见 `fitsContent(in:)`
    var autoHeight: Bool?

    var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    /// 画板高度是否跟随页面内容：网页不限制高度，整页内容都显示出来。
    /// 没有明确标记时，桌面宽度（≥ 1200）且不是 16:9 幻灯片的画板按网页处理；幻灯片、海报项目始终固定尺寸。
    func fitsContent(in kind: ProjectKind) -> Bool {
        guard kind != .slides, kind != .poster else { return false }
        if let autoHeight { return autoHeight }
        return width >= 1200 && abs(width / max(height, 1) - 16.0 / 9.0) > 0.02
    }

    /// 网页里一屏的高度（vh 的基准）：桌面 900（1280 宽为 800），平板 1024，手机 844
    var viewportHeight: Double {
        if width >= 1200 { return min(900, (width * 0.625).rounded()) }
        return width >= 700 ? 1024 : 844
    }
}

nonisolated struct DesignPage: Codable, Identifiable, Hashable, Sendable {
    private static let artboardColumnGap: Double = 80
    private static let artboardRowGap: Double = 200

    var id = UUID()
    var name: String
    var artboards: [Artboard] = []
    /// 画布共用样式：同一画布的每个画板加载时自动带上（模型输出的 ```css shared 代码块）
    var sharedCSS: String?

    static func defaultName(index: Int) -> String { "画布 \(index)" }

    /// 画板带上共用样式后的完整 HTML：导出、拷贝、交接时使用，可以单独打开
    func composedHTML(_ artboard: Artboard) -> String {
        SharedStyles.compose(artboard.html, css: sharedCSS)
    }

    /// 所有画板（HTML 已合并共用样式）
    var composedArtboards: [Artboard] {
        artboards.map { var a = $0; a.html = composedHTML($0); return a }
    }

    /// 兼容旧项目的默认名称，保留保存格式和自定义名称。
    var displayName: String {
        let prefix = "页面 "
        guard name.hasPrefix(prefix), let index = Int(name.dropFirst(prefix.count)),
              index > 0, name == "\(prefix)\(index)" else { return name }
        return Self.defaultName(index: index)
    }

    /// 所有画板的外接矩形
    var bounds: CGRect? {
        guard let first = artboards.first?.frame else { return nil }
        return artboards.dropFirst().reduce(first) { $0.union($1.frame) }
    }

    /// 新画板的默认位置：最右侧画板的右边
    func nextArtboardOrigin(gap: Double = 80) -> CGPoint {
        guard let b = bounds else { return .zero }
        let top = artboards.map(\.y).min() ?? 0
        return CGPoint(x: b.maxX + gap, y: top)
    }

    func artboard(named name: String) -> Artboard? {
        let key = name.trimmed.lowercased()
        return artboards.first { $0.name.trimmed.lowercased() == key }
    }

    /// 自动排列从左到右、从上到下，换行时给下一排的标题留出空间。
    fileprivate static func generatedOrigins(for artboards: [Artboard], from origin: CGPoint) -> [CGPoint] {
        let fourPortraits = artboards.count == 4 && artboards.allSatisfy { $0.height > $0.width }
        var x = origin.x
        var y = origin.y
        var rowHeight: Double = 0
        var rowCount = 0
        var rowLimit = 3
        return artboards.map { board in
            let limit = board.height > board.width && !fourPortraits ? 3 : 2
            if rowCount >= min(rowLimit, limit) {
                x = origin.x
                y += rowHeight + artboardRowGap
                rowHeight = 0
                rowCount = 0
                rowLimit = 3
            }
            let position = CGPoint(x: x, y: y)
            x += board.width + artboardColumnGap
            rowHeight = max(rowHeight, board.height)
            rowCount += 1
            rowLimit = min(rowLimit, limit)
            return position
        }
    }

    fileprivate var generatedRowBelow: CGPoint {
        guard let bounds else { return .zero }
        return CGPoint(x: bounds.minX, y: bounds.maxY + Self.artboardRowGap)
    }

    fileprivate static func matchesGeneratedLayout(_ artboards: [Artboard], from origin: CGPoint) -> Bool {
        zip(artboards, generatedOrigins(for: artboards, from: origin)).allSatisfy { $0.frame.origin == $1 }
    }

    mutating func rearrangeArtboards() {
        guard let bounds, artboards.count > 1 else { return }
        arrangeArtboards(at: Array(artboards.indices), from: bounds.origin)
    }
}

nonisolated struct DesignDocument: Codable, Hashable, Sendable {
    var pages: [DesignPage]

    init(pages: [DesignPage] = []) {
        self.pages = pages.isEmpty ? [DesignPage(name: DesignPage.defaultName(index: 1))] : pages
    }

    var isEmpty: Bool { pages.allSatisfy { $0.artboards.isEmpty } }
    var allArtboards: [Artboard] { pages.flatMap(\.artboards) }
    /// 所有画布的画板（HTML 已合并各自画布的共用样式）
    var composedArtboards: [Artboard] { pages.flatMap(\.composedArtboards) }

    /// 画板所在画布的共用样式
    func sharedCSS(for artboardID: UUID) -> String? {
        pages.first { $0.artboards.contains { $0.id == artboardID } }?.sharedCSS
    }

    /// 画板带上所在画布共用样式后的完整 HTML
    func composedHTML(_ artboardID: UUID) -> String? {
        for p in pages { if let a = p.artboards.first(where: { $0.id == artboardID }) { return p.composedHTML(a) } }
        return nil
    }

    /// 替换画布的共用样式；内容没变时返回 false
    @discardableResult
    mutating func setSharedCSS(_ css: String, in pageID: UUID?) -> Bool {
        let index = pageID.flatMap { id in pages.firstIndex { $0.id == id } } ?? 0
        guard pages.indices.contains(index) else { return false }
        let value: String? = css.trimmed.isEmpty ? nil : css.trimmed
        guard pages[index].sharedCSS != value else { return false }
        pages[index].sharedCSS = value
        return true
    }

    func page(_ id: UUID?) -> DesignPage? {
        guard let id else { return pages.first }
        return pages.first { $0.id == id } ?? pages.first
    }

    func artboard(_ id: UUID) -> Artboard? {
        for p in pages { if let a = p.artboards.first(where: { $0.id == id }) { return a } }
        return nil
    }

    func pageID(containing artboardID: UUID) -> UUID? {
        pages.first { $0.artboards.contains { $0.id == artboardID } }?.id
    }

    mutating func updateArtboard(_ id: UUID, _ mutate: (inout Artboard) -> Void) {
        for p in pages.indices {
            if let i = pages[p].artboards.firstIndex(where: { $0.id == id }) {
                mutate(&pages[p].artboards[i])
                return
            }
        }
    }

    mutating func removeArtboard(_ id: UUID) {
        for p in pages.indices { pages[p].artboards.removeAll { $0.id == id } }
    }

    /// 由旧版本的单个 HTML 迁移为一页一个画板
    static func migrated(html: String, kind: ProjectKind) -> DesignDocument {
        let size = kind.artboardSize
        let board = Artboard(name: kind == .slides ? "幻灯片 1" : "画板 1", html: html,
                             width: size.width, height: size.height)
        return DesignDocument(pages: [DesignPage(name: DesignPage.defaultName(index: 1), artboards: [board])])
    }

    /// 把模型输出的画板合并进指定页面：同名画板替换内容，新增画板自动分行。
    /// - Returns: 被修改或新增的画板 ID
    @discardableResult
    mutating func merge(_ outputs: [ParsedArtboard], into pageID: UUID?, kind: ProjectKind,
                        fallbackTarget: UUID? = nil, previewArtboardIDs: Set<UUID> = []) -> [UUID] {
        guard !outputs.isEmpty else { return [] }
        let pageIndex = pageID.flatMap { id in pages.firstIndex { $0.id == id } } ?? 0
        let previous = pages[pageIndex]
        var page = previous
        var changed: [UUID] = []
        // 模型没给尺寸时沿用页面上已有画板的尺寸（同一个设计的平台一致），空页面才用类型的默认尺寸
        let defaultSize = page.artboards.last.map { CGSize(width: $0.width, height: $0.height) } ?? kind.artboardSize

        for (n, out) in outputs.enumerated() {
            let html = out.html.trimmed
            guard !html.isEmpty else { continue }
            // 1. 按名字匹配；2. 没有名字时：唯一输出 + 指定目标 / 页面只有一个画板 → 替换它
            var target: Int?
            if let name = out.name, let i = page.artboards.firstIndex(where: {
                $0.name.trimmed.lowercased() == name.trimmed.lowercased()
            }) {
                target = i
            } else if out.name == nil, outputs.count == 1 {
                if let fallbackTarget, let i = page.artboards.firstIndex(where: { $0.id == fallbackTarget }) {
                    target = i
                } else if page.artboards.count == 1 {
                    target = 0
                }
            }

            if let i = target {
                let current = page.artboards[i]
                guard current.html != html || (out.width ?? current.width) != current.width
                    || (!out.autoHeight && (out.height ?? current.height) != current.height)
                    || (out.autoHeight && current.autoHeight != true) else { continue }
                page.artboards[i].html = html
                if let w = out.width { page.artboards[i].width = w }
                // height=auto：保留画布按内容量出的高度
                if out.autoHeight { page.artboards[i].autoHeight = true }
                else if let h = out.height { page.artboards[i].height = h }
                changed.append(page.artboards[i].id)
            } else {
                let name = out.name ?? Self.defaultName(kind: kind, index: page.artboards.count + 1 + n)
                var board = Artboard(name: name, html: html,
                                     width: out.width ?? defaultSize.width,
                                     height: out.height ?? defaultSize.height)
                if out.autoHeight {
                    board.autoHeight = true
                    board.height = board.viewportHeight   // 加载后按内容增高
                }
                page.artboards.append(board)
                changed.append(board.id)
            }
        }
        if page.artboards.count > previous.artboards.count {
            page.arrangeGeneratedArtboards(previous: previous, previewArtboardIDs: previewArtboardIDs)
        }
        pages[pageIndex] = page
        return changed
    }

    static func defaultName(kind: ProjectKind, index: Int) -> String {
        (kind == .slides ? "幻灯片 " : "画板 ") + String(index)
    }
}

private extension DesignPage {
    nonisolated mutating func arrangeGeneratedArtboards(previous: DesignPage, previewArtboardIDs: Set<UUID>) {
        var fixedIDs = Set<UUID>()
        if !Self.matchesGeneratedLayout(previous.artboards, from: .zero) {
            let fixed = previous.artboards.filter { !previewArtboardIDs.contains($0.id) }
            let previews = previous.artboards.filter { previewArtboardIDs.contains($0.id) }
            let fixedPage = DesignPage(name: name, artboards: fixed)
            // 预览画板也能手动拖动。只有位置仍符合自动排列时才重新排它们。
            let preserved = Self.matchesGeneratedLayout(previews, from: fixedPage.generatedRowBelow)
                ? fixed : previous.artboards
            fixedIDs = Set(preserved.map(\.id))
        }

        let positions = artboards.indices.filter { !fixedIDs.contains(artboards[$0].id) }
        let fixedPage = DesignPage(name: name, artboards: artboards.filter { fixedIDs.contains($0.id) })
        arrangeArtboards(at: positions, from: fixedPage.generatedRowBelow)
    }

    nonisolated mutating func arrangeArtboards(at positions: [Int], from origin: CGPoint) {
        let origins = Self.generatedOrigins(for: positions.map { artboards[$0] }, from: origin)
        for (index, origin) in zip(positions, origins) {
            artboards[index].x = origin.x
            artboards[index].y = origin.y
        }
    }
}

/// 从模型回复中解析出的一个画板代码块
nonisolated struct ParsedArtboard: Equatable, Sendable {
    var name: String?
    var width: Double?
    var height: Double?
    /// `height=auto`：网页高度随内容
    var autoHeight = false
    var html: String
    /// 代码块是否已闭合
    var complete: Bool
}
