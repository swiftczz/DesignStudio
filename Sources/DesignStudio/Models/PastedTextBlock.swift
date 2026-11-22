import Foundation

nonisolated struct PastedTextBlock: Identifiable, Equatable, Sendable {
    static let characterLimit = 50

    let id = UUID()
    var text: String

    var hasText: Bool { text.contains { !$0.isWhitespace } }

    /// Count the characters in this paste, independently of what is already in the draft.
    init?(pasting text: String) {
        guard !text.dropFirst(Self.characterLimit).isEmpty,
              text.contains(where: { !$0.isWhitespace }) else { return nil }
        self.text = text
    }

    static func message(_ draft: String, blocks: [Self]) -> String {
        var parts = blocks.filter(\.hasText).map(\.text)
        let instruction = draft.trimmed
        if !instruction.isEmpty { parts.insert(instruction, at: 0) }
        return parts.joined(separator: "\n\n")
    }

    static func statistics(for text: String) -> (lines: Int, bytes: Int) {
        var lines = text.isEmpty ? 0 : 1
        for character in text where character.isNewline {
            lines += 1
        }
        return (lines, text.utf8.count)
    }
}
