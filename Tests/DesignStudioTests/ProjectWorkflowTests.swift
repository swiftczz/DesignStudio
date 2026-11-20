import Foundation
import PDFKit
import Testing
@testable import DesignStudio

@MainActor
struct ProjectWorkflowTests {
    @Test func automaticArtboardMeasurementDoesNotReorderProjects() throws {
        let folder = try TempWorkspace.make(prefix: "project-measurement")
        defer { try? FileManager.default.removeItem(at: folder) }
        let persistence = PersistenceController(root: folder)
        let app = AppModel(persistence: persistence)
        let board = Artboard(name: "Page", html: "<p>Page</p>", width: 1440, height: 900, autoHeight: true)
        var project = Project(name: "Website", kind: .prototype)
        project.updatedAt = Date(timeIntervalSince1970: 1000)
        project.document = DesignDocument(pages: [DesignPage(name: "Canvas", artboards: [board])])
        app.projects = [project]
        let session = app.session(for: project.id)

        session.fitArtboardHeight(board.id, contentHeight: 1400)

        #expect(app.project(project.id)?.updatedAt == project.updatedAt)
        #expect(session.document.artboard(board.id)?.height == 1400)
        #expect(persistence.flush())
        #expect(persistence.loadProjects().first?.workingDocument.artboard(board.id)?.height == 1400)
    }

    @Test func savesLatestEditsAndRecoversFromBackup() throws {
        let folder = try TempWorkspace.make(prefix: "project-save")
        defer { try? FileManager.default.removeItem(at: folder) }
        let persistence = PersistenceController(root: folder)
        var project = Project(name: "Draft", kind: .prototype)
        persistence.save(project)
        #expect(persistence.flush())

        project.name = "Intermediate"
        persistence.save(project)
        project.name = "Latest"
        persistence.save(project)
        #expect(persistence.flush())
        #expect(persistence.loadProjects().map(\.name) == ["Latest"])

        let file = persistence.projectDirectory(project.id).appending(path: "project.json")
        try Data("invalid JSON".utf8).write(to: file)
        #expect(persistence.loadProjects().map(\.name) == ["Draft"])
        #expect(persistence.recoveredCount == 1)
        #expect(persistence.unreadableCount == 0)

        let archive = try ProjectArchive(project: project, designSystem: nil, includingHistory: false)
        let exported = folder.appending(path: "Latest.designstudio")
        try archive.write(to: exported)
        let copy = try ProjectArchive.read(from: exported).importedCopy(existingDesignSystems: []).project
        try persistence.saveImportedProject(copy, designSystems: nil)
        #expect(persistence.loadProjects().contains { $0.id == copy.id && $0.name == "Latest" })
    }

    @Test func reportsFailedWritesAndClearsErrorWhenRetried() throws {
        let folder = try TempWorkspace.make(prefix: "project-write-failure")
        defer { try? FileManager.default.removeItem(at: folder) }
        let persistence = PersistenceController(root: folder)
        let project = Project(name: "Draft", kind: .prototype)
        let blocked = persistence.projectDirectory(project.id)
        try Data([0]).write(to: blocked)
        persistence.save(project)
        #expect(!persistence.flush())
        #expect(persistence.saveErrors[project.id] != nil)

        try FileManager.default.removeItem(at: blocked)
        persistence.save(project)
        #expect(persistence.flush())
        #expect(persistence.loadProjects().first?.id == project.id)
    }

    @Test(arguments: [1, 10, 30])
    func scopedPromptOnlyContainsRequestedBoard(_ count: Int) throws {
        let boards = (0..<count).map { i in
            Artboard(name: "Page \(i)", html: "<article>SourceMarker_\(i)_end</article>", width: 390, height: 844)
        }
        let page = DesignPage(name: "Pages", artboards: boards)
        var project = Project(name: "Test project", kind: .prototype)
        project.document = DesignDocument(pages: [page])
        let target = try #require(boards.last)
        let request = DesignPrompt.makeRequest(project: project, designSystem: nil,
                                               newMessage: ChatMessage(role: .user, text: "改标题"),
                                               profile: ProviderProfile(name: "Codex", kind: .codex), pageID: page.id,
                                               scopeIDs: [target.id])
        let prompt = request.flattenedPrompt(includeSystem: false)
        #expect(prompt.contains(target.html))
        for board in boards.dropLast() {
            #expect(!prompt.contains(board.html))
        }
    }

    @Test func failedGenerationKeepsCommentsPendingUntilCompletedBoardsAreAccepted() async throws {
        let folder = try TempWorkspace.make(prefix: "project-generation")
        defer { try? FileManager.default.removeItem(at: folder) }
        let persistence = PersistenceController(root: folder)
        let app = AppModel(persistence: persistence) { _ in InterruptedProvider() }
        app.providers = [ProviderProfile(name: "Test", kind: .codex)]
        let first = Artboard(name: "A", html: "<p>Old A</p>", width: 400, height: 250)
        let second = Artboard(name: "B", html: "<p>Old B</p>", width: 400, height: 250)
        let page = DesignPage(name: "Test", artboards: [first, second])
        var project = Project(name: "Test", kind: .prototype)
        project.document = DesignDocument(pages: [page])
        project.comments = [first, second].map {
            CanvasComment(selector: "p", tag: "p", snippet: "", note: "Adjust title", artboardName: $0.name,
                          artboardID: $0.id)
        }
        app.projects = [project]
        let session = app.session(for: project.id)
        session.draft = "Use the comments."
        session.send()

        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while app.project(project.id)?.messages.last?.errorText == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let reply = try #require(app.project(project.id)?.messages.last)
        #expect(reply.errorText != nil)
        #expect(reply.recovery?.boardNames == ["A"])
        #expect(reply.generation?.firstText != nil)
        #expect(session.pendingComments.count == 2)
        #expect(session.document.artboard(first.id)?.html == first.html)

        session.keepCompletedArtboards(message: reply)
        #expect(session.document.artboard(first.id)?.html.contains("New A") == true)
        #expect(session.document.artboard(second.id)?.html == second.html)
        #expect(session.pendingComments.map(\.artboardID) == [second.id])
        #expect(app.project(project.id)?.versions.count == 1)
        #expect(persistence.flush())
    }

    @Test func interruptionPreservesRecoveryAfterRestart() throws {
        let folder = try TempWorkspace.make(prefix: "project-interrupted")
        defer { try? FileManager.default.removeItem(at: folder) }
        let persistence = PersistenceController(root: folder)
        var project = Project(name: "Test", kind: .prototype)
        let recovery = GenerationRecovery(pageID: UUID(), boardNames: ["A"], includesSharedStyles: false)
        project.messages = [
            ChatMessage(role: .user, text: "Design this"),
            ChatMessage(role: .assistant, text: "Draft progress", recovery: recovery, generationInProgress: true)
        ]
        persistence.save(project)
        #expect(persistence.flush())
        let app = AppModel(persistence: persistence)
        let reply = app.project(project.id)?.messages.last
        #expect(reply?.errorText != nil)
        #expect(reply?.recovery == recovery)
        #expect(persistence.flush())
    }

    @Test func exportsSavedArtboardsFromAnOfflineProjectCopy() async throws {
        let folder = try TempWorkspace.make(prefix: "canvas-export-offline")
        defer { try? FileManager.default.removeItem(at: folder) }
        let page = DesignPage(name: "Offline", artboards: [
            Artboard(name: "First", html: """
                <!doctype html><html><body><h1>Saved first</h1>
                <img src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7">
                </body></html>
                """, width: 400, height: 250),
            Artboard(name: "Second", html: "<h1>Saved second</h1>", width: 400, height: 250)
        ], sharedCSS: "body { color: #123456; background: #f2f1ee; font-family: serif }")
        var project = Project(name: "Saved snapshot", kind: .prototype)
        project.document = DesignDocument(pages: [page])
        let file = folder.appending(path: "project.designstudio")
        try ProjectArchive(project: project, designSystem: nil, includingHistory: false).write(to: file)
        let copy = try ProjectArchive.read(from: file).importedCopy(existingDesignSystems: []).project
        let importedPage = try #require(copy.workingDocument.pages.first)
        #expect(importedPage == page)
        let job = CanvasExportJob(name: copy.name, page: importedPage, kind: copy.kind, format: .pdf)
        job.render()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while job.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(job.failures.isEmpty)
        #expect(job.completed == [0, 1])
        let pdfURL = folder.appending(path: "pages.pdf")
        try await job.save(to: pdfURL)
        let pdf = try #require(PDFDocument(url: pdfURL))
        #expect(pdf.pageCount == 2)
        #expect(pdf.page(at: 0)?.string?.contains("Saved first") == true)
        #expect(pdf.page(at: 1)?.string?.contains("Saved second") == true)

        let first = try #require(importedPage.composedArtboards.first)
        #expect(first.html.contains("#123456") && first.html.contains("data:image/gif"))
        let rendered = try await CanvasExportRenderer.render(first, kind: .prototype, png: true)
        let png = try #require(rendered.png)
        #expect(png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]))
    }
}

private struct InterruptedProvider: LLMProvider {
    nonisolated func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text("""
                ```html artboard="A" width=400 height=250
                <!doctype html><html><body><p>New A</p></body></html>
                ```
                ```html artboard="B" width=400 height=250
                <!doctype html><html><body><p>Incomplete B
                """))
            continuation.finish(throwing: URLError(.networkConnectionLost))
        }
    }
}
