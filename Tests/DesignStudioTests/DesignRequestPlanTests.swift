import Foundation
import Testing
@testable import DesignStudio

struct DesignRequestPlanTests {
    @Test(arguments: ProviderKind.allCases)
    func preservesTheNewInstructionAndBatchesCompleteSources(for kind: ProviderKind) throws {
        let boards = (1...10).map { index in
            Artboard(name: "Board \(index)",
                     html: "<main id=\"board-\(index)\">" + String(repeating: "<p>Synthetic source for the test.</p>", count: 900) + "</main>",
                     width: 390, height: 844)
        }
        let page = DesignPage(name: "Source", artboards: boards)
        var project = Project(name: "Request budget", kind: .prototype)
        project.document = DesignDocument(pages: [page])
        project.messages = [ChatMessage(role: .user, text: String(repeating: "old history ", count: 25_000))]
        let profile = ProviderProfile(name: "Test", kind: kind, model: "test-fixture-model")
        let requirement = "Translate the complete canvas."
        let plan = try DesignRequestPlan.make(project: project, designSystem: nil,
            message: ChatMessage(role: .user, text: requirement), profile: profile, page: page,
            selection: nil, commentsOnly: false, scope: nil, preserving: [], skipping: [], destinationIDs: nil)
        #expect(plan.batches.count > 1)
        #expect(plan.batches.flatMap(\.expectedIDs).count == boards.count)
        #expect(plan.artboardIDs == Set(boards.map(\.id)))

        for batch in plan.batches {
            let prompt = batch.request.flattenedPrompt(includeSystem: true)
            let instruction = try #require(prompt.range(of: requirement))
            let source = try #require(prompt.range(of: "<main id="))
            #expect(instruction.lowerBound < source.lowerBound)
            #expect(!prompt.contains("old history"))
            let inputs = ArtboardParser.parse(batch.request.messages.last?.text ?? "")
            #expect(inputs.count == batch.expectedIDs.count)
            for board in boards where batch.expectedIDs.contains(board.id) {
                #expect(inputs.contains { $0.name == board.id.uuidString && $0.html == board.html && $0.complete })
            }
            if kind == .antigravity {
                #expect(AntigravityProvider.inputLine(prompt).utf8.count < AntigravityProvider.inputBudgetBytes)
            }
        }
    }

    @Test func acceptsOnlyUniqueCompleteOutputForAssignedIDs() {
        let assigned = UUID()
        let duplicate = UUID()
        let unfinished = UUID()
        let foreign = UUID()
        let text = """
        ```html artboard="\(assigned)"
        <!-- unchanged -->
        ```

        ```html artboard="\(foreign)"
        <p>wrong target</p>
        ```

        ```html artboard="\(duplicate)"
        <p>first</p>
        ```

        ```html artboard="\(duplicate)"
        <p>second</p>
        ```

        ```html artboard="\(unfinished)"
        <p>partial
        """
        let validated = DesignRequestPlan.validate(text, expected: [assigned, duplicate, unfinished])
        #expect(validated.completed == [assigned])
        #expect(ArtboardParser.parse(validated.markdown).map(\.html) == [DesignRequestPlan.unchanged])
    }
}
