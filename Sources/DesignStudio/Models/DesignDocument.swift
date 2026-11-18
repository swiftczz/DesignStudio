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

    var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

nonisolated struct DesignPage: Codable, Identifiable, Hashable, Sendable {
    private static let artboardColumnGap: Double = 80
    private static let artboardRowGap: Double = 200

    var id = UUID()
    var name: String
    var artboards: [Artboard] = []

    static func defaultName(index: Int) -> String { "画布 \(index)" }

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
                    || (out.height ?? current.height) != current.height else { continue }
                page.artboards[i].html = html
                if let w = out.width { page.artboards[i].width = w }
                if let h = out.height { page.artboards[i].height = h }
                changed.append(page.artboards[i].id)
            } else {
                let name = out.name ?? Self.defaultName(kind: kind, index: page.artboards.count + 1 + n)
                let board = Artboard(name: name, html: html,
                                     width: out.width ?? defaultSize.width,
                                     height: out.height ?? defaultSize.height)
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
    var html: String
    /// 代码块是否已闭合
    var complete: Bool
}
