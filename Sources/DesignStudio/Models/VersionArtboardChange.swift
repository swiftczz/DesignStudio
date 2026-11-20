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
    var action: String {
        if before == nil { return "新增" }
        if after == nil { return "删除" }
        return "修改"
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
