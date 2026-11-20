import Foundation

nonisolated struct VersionArtboardSnapshot: Equatable, Identifiable, Sendable {
    let board: Artboard
    let pageID: UUID
    let pageName: String
    let sharedCSS: String?

    init(_ board: Artboard, on page: DesignPage) {
        self.board = board
        pageID = page.id
        pageName = page.displayName
        sharedCSS = board.sharedCSSOverride ?? page.sharedCSS
    }

    var id: UUID { board.id }
    var html: String { SharedStyles.compose(board.html, css: sharedCSS) }
}

nonisolated struct VersionArtboardChange: Identifiable, Sendable {
    let before: VersionArtboardSnapshot?
    let after: VersionArtboardSnapshot?
    private let subject: VersionArtboardSnapshot
    var id: UUID { board.id }
    var board: Artboard { subject.board }
    var canvasName: String { subject.pageName }
    var canvasID: UUID { subject.pageID }
    var inheritsChangedSharedStyles: Bool {
        guard let before, let after else { return false }
        return before.pageID == after.pageID && before.sharedCSS != after.sharedCSS
            && before.board.sharedCSSOverride == nil && after.board.sharedCSSOverride == nil
    }

    var action: String {
        guard let before else { return "新增" }
        guard let after else { return "删除" }
        let old = before.board, new = after.board
        var changes: [String] = []
        if old.html != new.html { changes.append("内容") }
        if old.frame.origin != new.frame.origin { changes.append("位置") }
        if old.frame.size != new.frame.size || old.autoHeight != new.autoHeight { changes.append("尺寸") }
        if old.name != new.name { changes.append("名称") }
        if before.pageID != after.pageID || before.pageName != after.pageName { changes.append("所属画布") }
        if inheritsChangedSharedStyles { changes.append("共享样式") }
        else if old.sharedCSSOverride != new.sharedCSSOverride || before.sharedCSS != after.sharedCSS { changes.append("样式") }
        return changes.isEmpty ? "修改" : changes.joined(separator: "、")
    }

    static func compare(_ before: DesignDocument?, to after: DesignDocument) -> [Self] {
        let earlier = snapshots(before)
        let later = snapshots(after)
        let earlierByID = Dictionary(earlier.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let laterIDs = Set(later.map(\.id))
        let updates = later.compactMap { snapshot -> Self? in
            let previous = earlierByID[snapshot.id]
            guard previous != snapshot else { return nil }
            return Self(before: previous, after: snapshot, subject: snapshot)
        }
        return updates + earlier.filter { !laterIDs.contains($0.id) }.map { Self(before: $0, after: nil, subject: $0) }
    }

    private static func snapshots(_ document: DesignDocument?) -> [VersionArtboardSnapshot] {
        document?.pages.flatMap { page in page.artboards.map { VersionArtboardSnapshot($0, on: page) } } ?? []
    }
}
