import Foundation

nonisolated struct ReusableComponent: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var html: String
    var defaultText: String?

    func isReferenced(by artboard: Artboard) -> Bool {
        artboard.html.contains("data-ds-component=\"\(id.uuidString)\"")
            || artboard.html.contains("data-ds-component='\(id.uuidString)'")
    }
}
