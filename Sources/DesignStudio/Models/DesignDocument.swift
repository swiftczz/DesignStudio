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
    /// 单张恢复时保留历史共用样式。nil 继承画布样式，空字符串表示历史版本没有共用样式。
    var sharedCSSOverride: String?

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
        SharedStyles.compose(artboard.html, css: artboard.sharedCSSOverride ?? sharedCSS)
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
    private(set) var componentLibrary: [ReusableComponent]?

    init(pages: [DesignPage] = []) {
        self.pages = pages.isEmpty ? [DesignPage(name: DesignPage.defaultName(index: 1))] : pages
    }

    var isEmpty: Bool { pages.allSatisfy { $0.artboards.isEmpty } }
    var allArtboards: [Artboard] { pages.flatMap(\.artboards) }
    var components: [ReusableComponent] { componentLibrary ?? [] }

    mutating func saveComponent(_ component: ReusableComponent) {
        var library = components
        if let index = library.firstIndex(where: { $0.id == component.id }) {
            library[index] = component
        } else {
            library.append(component)
        }
        componentLibrary = library
    }

    mutating func removeComponent(_ id: UUID) {
        componentLibrary?.removeAll { $0.id == id }
    }

    func selectingPages(_ selected: [DesignPage]) -> DesignDocument {
        var copy = self
        copy.pages = selected
        if selected.count != pages.count {
            let artboards = selected.flatMap(\.artboards)
            copy.componentLibrary = componentLibrary?.filter { component in
                artboards.contains { component.isReferenced(by: $0) }
            }
        }
        return copy
    }
    /// 所有画布的画板（HTML 已合并各自画布的共用样式）
    var composedArtboards: [Artboard] { pages.flatMap(\.composedArtboards) }

    /// 画板所在画布的共用样式
    func sharedCSS(for artboardID: UUID) -> String? {
        for page in pages {
            if let board = page.artboards.first(where: { $0.id == artboardID }) {
                return board.sharedCSSOverride ?? page.sharedCSS
            }
        }
        return nil
    }

    /// 画板带上所在画布共用样式后的完整 HTML
    func composedHTML(_ artboardID: UUID) -> String? {
        for p in pages { if let a = p.artboards.first(where: { $0.id == artboardID }) { return p.composedHTML(a) } }
        return nil
    }

    /// 改画板尺寸，并挪开右侧和下方的画板，保持原来的间距
    mutating func resizeArtboard(_ id: UUID, width: Double? = nil, height: Double? = nil) {
        for p in pages.indices {
            guard let i = pages[p].artboards.firstIndex(where: { $0.id == id }) else { continue }
            let old = pages[p].artboards[i].frame
            if let width { pages[p].artboards[i].width = width }
            if let height { pages[p].artboards[i].height = height }
            pages[p].reflow(after: id, from: old)
            return
        }
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
                        fallbackTarget: UUID? = nil, previewArtboardIDs: Set<UUID> = [],
                        restrictingTo scopeIDs: Set<UUID>? = nil) -> [UUID] {
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
                (scopeIDs?.contains($0.id) ?? true) && $0.name.trimmed.lowercased() == name.trimmed.lowercased()
            }) {
                target = i
            } else if out.name == nil, outputs.count == 1 {
                if let fallbackTarget, let i = page.artboards.firstIndex(where: { $0.id == fallbackTarget }) {
                    target = i
                } else if page.artboards.count == 1 {
                    target = 0
                }
            }

            if let scopeIDs, target.map({ scopeIDs.contains(page.artboards[$0].id) }) != true { continue }
            if let i = target {
                let current = page.artboards[i]
                let oldFrame = current.frame
                guard current.html != html || (out.width ?? current.width) != current.width
                    || (!out.autoHeight && (out.height ?? current.height) != current.height)
                    || (out.autoHeight && current.autoHeight != true) else { continue }
                page.artboards[i].html = html
                if let w = out.width { page.artboards[i].width = w }
                // height=auto：保留画布按内容量出的高度
                if out.autoHeight { page.artboards[i].autoHeight = true }
                else if let h = out.height { page.artboards[i].height = h }
                // 尺寸变了：挪开右侧和下方的画板，保持原来的间距
                page.reflow(after: current.id, from: oldFrame)
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

// MARK: - 画板尺寸变化后的避让

extension DesignPage {
    /// 画板尺寸从 old 变成现在的大小后，挪动周围的画板，保持原来的间距：
    /// - 变高 / 变矮：同一行最低处变化多少，整行下面的画板就上下挪多少（各行仍然对齐）；
    /// - 变宽 / 变窄：同一行右侧的画板（以及跟它们相连的画板）左右挪动同样的距离。
    /// 缩小时只挪到不会碰到其他画板为止。
    nonisolated mutating func reflow(after id: UUID, from old: CGRect) {
        guard let i = artboards.firstIndex(where: { $0.id == id }) else { return }
        let new = artboards[i].frame
        guard new.size != old.size else { return }
        let others = artboards.indices.filter { $0 != i }

        // 纵向：与原画板上下重叠的是同一行
        let row = others.filter { Self.overlap(artboards[$0].frame, old, vertical: true) }
        let oldBottom = row.map { artboards[$0].frame.maxY }.reduce(old.maxY, max)
        let newBottom = row.map { artboards[$0].frame.maxY }.reduce(new.maxY, max)
        let below = others.filter { artboards[$0].frame.minY >= oldBottom - 0.5 }
        shift(below, by: newBottom - oldBottom, after: oldBottom, vertical: true)

        // 横向：同一行里在右侧的画板，以及与它们左右相连的画板
        var right = row.filter { artboards[$0].frame.minX >= old.maxX - 0.5 }
        var changed = true
        while changed {
            changed = false
            for r in right {
                for n in others where !right.contains(n) && !below.contains(n)
                    && artboards[n].frame.minX >= artboards[r].frame.maxX - 0.5
                    && Self.overlap(artboards[n].frame, artboards[r].frame, vertical: true) {
                    right.append(n)
                    changed = true
                }
            }
        }
        shift(right, by: new.maxX - old.maxX, after: old.maxX, vertical: false)
    }

    /// 两个矩形在另一个方向上是否有重叠（vertical: 比较上下范围）
    nonisolated private static func overlap(_ a: CGRect, _ b: CGRect, vertical: Bool) -> Bool {
        vertical ? a.minY < b.maxY && b.minY < a.maxY : a.minX < b.maxX && b.minX < a.maxX
    }

    /// 平移一组画板。往回收（delta < 0）时，保证不会比原来的间距更贴近其他画板
    nonisolated private mutating func shift(_ indices: [Int], by delta: Double, after edge: Double, vertical: Bool) {
        guard abs(delta) > 0.5, !indices.isEmpty else { return }
        var d = delta
        if d < 0 {
            let moving = Set(indices)
            let start: (CGRect) -> Double = { vertical ? $0.minY : $0.minX }
            let end: (CGRect) -> Double = { vertical ? $0.maxY : $0.maxX }
            let gap = max(indices.map { start(artboards[$0].frame) }.min()! - edge, 0)
            for m in indices {
                let mf = artboards[m].frame
                for n in artboards.indices where !moving.contains(n) {
                    let nf = artboards[n].frame
                    guard Self.overlap(mf, nf, vertical: !vertical), end(nf) <= start(mf) + 0.5 else { continue }
                    d = max(d, -max(start(mf) - end(nf) - gap, 0))
                }
            }
        }
        d = (d * 1000).rounded() / 1000   // 去掉浮点误差，画板坐标保持整齐
        guard abs(d) > 0.5 else { return }
        for k in indices {
            if vertical { artboards[k].y += d } else { artboards[k].x += d }
        }
    }
}
