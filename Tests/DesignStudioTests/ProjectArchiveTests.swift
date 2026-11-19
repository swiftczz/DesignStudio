import Foundation
import Testing
@testable import DesignStudio

struct ProjectArchiveTests {
    @Test(arguments: [false, true])
    func roundTripsEditableProjects(includingHistory: Bool) throws {
        let folder = try TempWorkspace.make(prefix: "project-archive")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "设计交接.designstudio")

        let system = DesignSystem.blank()
        let board = Artboard(name: "首页", html: #"<img src="data:image/png;base64,AA==">"#,
                             x: -35, y: 72, width: 390, height: 844)
        let other = Artboard(name: "详情", html: "<h1>第二张画布</h1>", width: 1440, height: 900, autoHeight: true)
        let document = DesignDocument(pages: [
            DesignPage(name: "手机", artboards: [board], sharedCSS: ":root { --brand: #123456; }"),
            DesignPage(name: "桌面", artboards: [other])
        ])
        let version = DesignVersion(number: 1, document: document, summary: "初稿")
        var message = ChatMessage(role: .user, text: "/private/example/需求.md 调整首页", attachments: [
            ChatAttachment(filename: "需求.md", mimeType: "text/markdown", data: Data("设计说明".utf8),
                           sourcePath: "/private/example/需求.md")
        ])
        message.target = MessageTarget(artboardID: board.id, artboardName: board.name)
        let comment = CanvasComment(selector: "img", tag: "img", snippet: "", note: "换图", artboardName: board.name)
        var project = Project(name: "设计交接", kind: .prototype)
        project.document = document
        project.versions = [version]
        project.currentVersionID = version.id
        project.messages = [message, ChatMessage(role: .assistant, text: "完成", versionID: version.id)]
        project.comments = [comment]
        project.designSystemID = system.id
        project.providerID = UUID()
        project.model = "account-specific-model"
        project.effort = "high"

        try ProjectArchive(project: project, designSystem: system, includingHistory: includingHistory).write(to: file)
        let archive = try ProjectArchive.read(from: file)
        let imported = archive.importedCopy(existingDesignSystems: [])
        let copy = imported.project

        #expect(copy.id != project.id)
        #expect(archive.importedCopy(existingDesignSystems: []).project.id != copy.id)
        #expect(copy.name == project.name)
        #expect(copy.workingDocument == document)
        #expect(copy.workingDocument.composedHTML(board.id)?.contains("--brand") == true)
        #expect(imported.newDesignSystem == system)
        #expect(copy.designSystemID == system.id)
        #expect(archive.project.providerID == nil)
        #expect(copy.providerID == nil && copy.model == nil && copy.effort == nil)
        if includingHistory {
            #expect(copy.currentVersionID == version.id)
            #expect(copy.versions.first?.document == document)
            #expect(copy.messages.last?.versionID == version.id)
            #expect(copy.messages.first?.target?.artboardID == board.id)
            #expect(copy.messages.first?.attachments.first?.documentText == "设计说明")
            #expect(copy.messages.first?.attachments.first?.sourcePath == nil)
            #expect(copy.messages.first?.text == "需求.md 调整首页")
            #expect(copy.comments.map(\.id) == [comment.id])
        } else {
            #expect(copy.messages.isEmpty && copy.versions.isEmpty && copy.comments.isEmpty)
            #expect(copy.currentVersionID == nil)
        }
    }

    @Test func resolvesDesignSystemCollisions() {
        let system = DesignSystem.blank()
        let archive = ProjectArchive(project: Project(name: "t", kind: .prototype),
                                     designSystem: system, includingHistory: false)
        let matched = archive.importedCopy(existingDesignSystems: [system])
        #expect(matched.newDesignSystem == nil)
        #expect(matched.project.designSystemID == system.id)

        var edited = system
        edited.name = "本机修改"
        let conflict = archive.importedCopy(existingDesignSystems: [edited])
        #expect(conflict.newDesignSystem?.name == system.name)
        #expect(conflict.newDesignSystem?.id != system.id)
        #expect(conflict.project.designSystemID == conflict.newDesignSystem?.id)
    }

    @Test func rejectsCorruptArchivesAndReportsNewerFormats() throws {
        let folder = try TempWorkspace.make(prefix: "project-archive")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "wrong.designstudio")
        var unknown = ZipWriter()
        unknown.addFile("project.json", contents: Data(#"{"format":"app.designstudio.mac.project","version":999}"#.utf8))
        let bytes = unknown.finish()
        try bytes.write(to: file)
        do {
            _ = try ProjectArchive.read(from: file)
            Issue.record("Expected to reject the newer format")
        } catch ProjectArchive.ArchiveError.unsupportedVersion(999) {}

        var corrupted = bytes
        corrupted[42] ^= 0xff
        try corrupted.write(to: file)
        #expect(throws: ProjectArchive.ArchiveError.self) { try ProjectArchive.read(from: file) }

        try bytes.dropLast().write(to: file)
        #expect(throws: ProjectArchive.ArchiveError.self) { try ProjectArchive.read(from: file) }

        var unrelated = ZipWriter()
        unrelated.addFile("index.html", contents: Data("<html></html>".utf8))
        try unrelated.finish().write(to: file)
        #expect(throws: ProjectArchive.ArchiveError.self) { try ProjectArchive.read(from: file) }
    }
}
