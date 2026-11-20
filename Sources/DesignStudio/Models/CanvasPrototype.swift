import Foundation

nonisolated struct CanvasPrototype: Codable, Hashable, Sendable {
    var startArtboardID: UUID?
    var links: [PrototypeLink] = []

    mutating func removeArtboard(_ id: UUID) {
        if startArtboardID == id { startArtboardID = nil }
        links.removeAll { $0.sourceArtboardID == id || $0.destinationArtboardID == id }
    }

    func playableLinks(in boards: [Artboard]) -> [PrototypeLink] {
        let sources = Dictionary(boards.map { ($0.id, $0.html) }, uniquingKeysWith: { first, _ in first })
        return links.filter {
            sources[$0.sourceArtboardID]?.contains($0.id.uuidString) == true && sources[$0.destinationArtboardID] != nil
        }
    }
}

nonisolated struct PrototypeLink: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var sourceArtboardID: UUID
    var destinationArtboardID: UUID
    var elementName: String
    var sourceY: Double
}
