import Foundation
import CoreGraphics

// MARK: - 文档结构：页面 → 画板

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
    var id = UUID()
    var name: String
    var artboards: [Artboard] = []

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
}

nonisolated struct DesignDocument: Codable, Hashable, Sendable {
    var pages: [DesignPage]

    init(pages: [DesignPage] = [DesignPage(name: "页面 1")]) {
        self.pages = pages.isEmpty ? [DesignPage(name: "页面 1")] : pages
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
        return DesignDocument(pages: [DesignPage(name: "页面 1", artboards: [board])])
    }

    /// 把模型输出的画板合并进指定页面：同名画板替换内容，新名字追加在右侧
    /// - Returns: 被修改或新增的画板 ID
    @discardableResult
    mutating func merge(_ outputs: [ParsedArtboard], into pageID: UUID?, kind: ProjectKind,
                        fallbackTarget: UUID? = nil) -> [UUID] {
        guard !outputs.isEmpty else { return [] }
        let pageIndex = pageID.flatMap { id in pages.firstIndex { $0.id == id } } ?? 0
        var page = pages[pageIndex]
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
                page.artboards[i].html = html
                if let w = out.width { page.artboards[i].width = w }
                if let h = out.height { page.artboards[i].height = h }
                changed.append(page.artboards[i].id)
            } else {
                let origin = page.nextArtboardOrigin()
                let name = out.name ?? Self.defaultName(kind: kind, index: page.artboards.count + 1 + n)
                let board = Artboard(name: name, html: html, x: origin.x, y: origin.y,
                                     width: out.width ?? defaultSize.width,
                                     height: out.height ?? defaultSize.height)
                page.artboards.append(board)
                changed.append(board.id)
            }
        }
        pages[pageIndex] = page
        return changed
    }

    static func defaultName(kind: ProjectKind, index: Int) -> String {
        (kind == .slides ? "幻灯片 " : "画板 ") + String(index)
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
