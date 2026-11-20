import Foundation
import Testing
@testable import DesignStudio

struct ProjectArchiveTests {
    @Test func importsFormerComponentInstancesAsSavedArtboardHTML() throws {
        let folder = try TempWorkspace.make(prefix: "legacy-component-archive")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "旧项目.designstudio")
        let id = UUID()
        let html = #"<button data-ds-component="\#(id)" data-ds-component-text="实例文案">实例文案</button>"#
        let board = Artboard(name: "首页", html: html, width: 390, height: 844)
        let page = DesignPage(name: "移动端", artboards: [board])
        var project = Project(name: "旧项目", kind: .prototype)
        project.document = DesignDocument(pages: [page, DesignPage(name: "桌面端")])
        let archive = try ProjectArchive(project: project, designSystem: nil, includingHistory: false)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var payload = try #require(try JSONSerialization.jsonObject(with: encoder.encode(archive)) as? [String: Any])
        var savedProject = try #require(payload["project"] as? [String: Any])
        var savedDocument = try #require(savedProject["document"] as? [String: Any])
        savedDocument["componentLibrary"] = [["id": id.uuidString, "name": "按钮", "html": "<button>默认文案</button>"]]
        savedProject["document"] = savedDocument
        payload["project"] = savedProject
        var writer = ZipWriter()
        writer.addFile("project.json", contents: try JSONSerialization.data(withJSONObject: payload))
        try writer.finish().write(to: url)

        let imported = try ProjectArchive.read(from: url).importedCopy(existingDesignSystems: []).project
        #expect(imported.workingDocument.artboard(board.id)?.html == html)
        let selected = try ProjectArchive(project: imported, designSystem: nil, includingHistory: false, canvasIDs: [page.id])
        #expect(selected.project.workingDocument.pages == [page])
    }

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

        try ProjectArchive(project: project, designSystem: system, includingHistory: includingHistory,
                           canvasIDs: Set(document.pages.map(\.id))).write(to: file)
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

    @Test func exportsSelectedCanvasesWithoutProjectWideHistory() throws {
        let folder = try TempWorkspace.make(prefix: "project-archive")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "所选画布.designstudio")
        let system = DesignSystem.blank()
        let board = Artboard(name: "首页", html: "<main>首页</main>", x: 42, y: 18, width: 390, height: 844)
        let mobile = DesignPage(name: "移动端", artboards: [board], sharedCSS: "main { color: red; }")
        let privateCanvas = DesignPage(name: "内部草稿", artboards: [
            Artboard(name: "未公开", html: "<main>内部设计</main>", width: 390, height: 844)
        ])
        let desktop = DesignPage(name: "桌面端")
        let document = DesignDocument(pages: [mobile, privateCanvas, desktop])
        let version = DesignVersion(number: 1, document: document, summary: "整项目快照")
        var project = Project(name: "设计交接", kind: .prototype)
        project.document = document
        project.messages = [ChatMessage(role: .assistant, text: "内部草稿", versionID: version.id)]
        project.comments = [CanvasComment(selector: "main", tag: "main", snippet: "", note: "内部批注",
                                          artboardName: "未公开")]
        project.versions = [version]
        project.currentVersionID = version.id

        try ProjectArchive(project: project, designSystem: system, includingHistory: true,
                           canvasIDs: [desktop.id, mobile.id]).write(to: file)
        let archive = try ProjectArchive.read(from: file)
        let copy = archive.importedCopy(existingDesignSystems: [])
        #expect(copy.project.workingDocument.pages == [mobile, desktop])
        #expect(copy.project.workingDocument.composedHTML(board.id)?.contains("color: red") == true)
        #expect(copy.newDesignSystem == system)
        #expect(copy.project.messages.isEmpty && copy.project.comments.isEmpty && copy.project.versions.isEmpty)
        #expect(copy.project.currentVersionID == nil)

        #expect(throws: ProjectArchive.ArchiveError.self) {
            try ProjectArchive(project: project, designSystem: system, includingHistory: false, canvasIDs: [])
        }
        #expect(throws: ProjectArchive.ArchiveError.self) {
            try ProjectArchive(project: project, designSystem: system, includingHistory: false, canvasIDs: [mobile.id, UUID()])
        }
    }

    @Test func exportsOnlyCommentsBelongingToSelectedBoards() throws {
        let first = Artboard(name: "同名", html: "<p>1</p>", width: 390, height: 844)
        let second = Artboard(name: "同名", html: "<p>2</p>", width: 390, height: 844)
        let page = DesignPage(name: "导出", artboards: [first])
        var project = Project(name: "交接", kind: .prototype)
        project.document = DesignDocument(pages: [page, DesignPage(name: "保留", artboards: [second])])
        let kept = CanvasComment(selector: "p", tag: "p", snippet: "", note: "保留", artboardName: first.name,
                                 artboardID: first.id)
        project.comments = [
            kept,
            CanvasComment(selector: "p", tag: "p", snippet: "", note: "画布外", artboardName: second.name,
                          artboardID: second.id),
            CanvasComment(selector: "p", tag: "p", snippet: "", note: "旧数据无法确定归属", artboardName: first.name)
        ]
        let archive = try ProjectArchive(project: project, designSystem: nil, includingHistory: true,
                                         canvasIDs: [page.id], includingComments: true)
        #expect(archive.project.comments == [kept])
        #expect(archive.project.messages.isEmpty)
        #expect(archive.project.versions.isEmpty)
    }

    @Test func partialExportKeepsOnlyAttributableConversationAndAttachments() throws {
        let folder = try TempWorkspace.make(prefix: "scoped-project-archive")
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = Artboard(name: "首页", html: "<p>可分享</p>", width: 390, height: 844)
        let other = Artboard(name: "首页", html: "<p>内部设计</p>", width: 390, height: 844)
        let shared = DesignPage(name: "可分享", artboards: [first])
        let privatePage = DesignPage(name: "内部", artboards: [other])
        let document = DesignDocument(pages: [shared, privatePage])
        let version = DesignVersion(number: 1, document: document, summary: "快照")
        let attachment = ChatAttachment(filename: "说明.md", mimeType: "text/markdown", data: Data("需求".utf8),
                                        sourcePath: "/private/review/说明.md")
        let request = ChatMessage(role: .user, text: "/private/review/说明.md 调整", attachments: [attachment],
                                  requestPageID: shared.id)
        let reply = ChatMessage(role: .assistant, text: "已调整。\n\n```html artboard=\"首页\"\n<p>源码</p>\n```",
                                versionID: version.id, thinking: "内部思考")
        let legacy = ChatMessage(role: .user, text: "再调整", target: MessageTarget(artboardID: first.id, artboardName: first.name))
        let legacyReply = ChatMessage(role: .assistant, text: "已完成。")
        var project = Project(name: "交接", kind: .prototype)
        project.document = document
        project.versions = [version]
        project.currentVersionID = version.id
        project.messages = [
            request, reply, legacy, legacyReply,
            ChatMessage(role: .user, text: "内部对话", requestPageID: privatePage.id),
            ChatMessage(role: .assistant, text: "内部回复"),
            ChatMessage(role: .user, text: "混合范围", scopeIDs: [other.id], requestPageID: shared.id),
            ChatMessage(role: .assistant, text: "混合回复"),
            ChatMessage(role: .user, text: "归属不明"),
            ChatMessage(role: .assistant, text: "不明回复")
        ]

        let url = folder.appending(path: "交接.designstudio")
        try ProjectArchive(project: project, designSystem: nil, includingHistory: true, canvasIDs: [shared.id]).write(to: url)
        let exported = try ProjectArchive.read(from: url).importedCopy(existingDesignSystems: []).project
        #expect(exported.workingDocument.pages == [shared])
        #expect(exported.messages.map(\.id) == [request.id, reply.id, legacy.id, legacyReply.id])
        #expect(exported.messages.map(\.text) == ["说明.md 调整", "已调整。", "再调整", "已完成。"])
        #expect(exported.messages.first?.attachments.first?.documentText == "需求")
        #expect(exported.messages.first?.attachments.first?.sourcePath == nil)
        #expect(exported.messages.allSatisfy { $0.requestPageID == shared.id && $0.versionID == nil && $0.thinking == nil })
        #expect(exported.versions.isEmpty && exported.currentVersionID == nil)
    }

    @Test func resolvesDesignSystemCollisions() throws {
        let system = DesignSystem.blank()
        let archive = try ProjectArchive(project: Project(name: "t", kind: .prototype),
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
