import Foundation
import Observation
import PDFKit
import Testing
@testable import DesignStudio

@MainActor
struct ProjectWorkflowTests {
    @Test(.timeLimit(.minutes(1)))
    func newDesignsStartInChatAndRememberCanvasVisibilityPerProject() async throws {
        let folder = try TempWorkspace.make(prefix: "workspace visibility")
        defer { try? FileManager.default.removeItem(at: folder) }
        let persistence = PersistenceController(root: folder)
        let existing = Project(name: "已有项目", kind: .prototype)
        persistence.save(existing)
        #expect(persistence.flush())

        let app = AppModel(persistence: persistence) { _ in WorkspaceDesignProvider() }
        app.providers = [ProviderProfile(name: "Test", kind: .codex)]
        let id = app.createProject(prompt: "设计一个冥想 App", kind: .prototype,
                                   designSystemID: nil, model: ModelChoice(), attachments: [])
        let session = app.session(for: id)
        #expect(app.route == .project(id))
        #expect(!session.showCanvas)
        #expect(app.session(for: existing.id).showCanvas)

        let busy = Observations { session.isPreparingRequest || session.isGenerating }
        for await isBusy in busy {
            if !isBusy { break }
        }
        #expect(session.document.allArtboards.count == 1)
        #expect(app.project(id)?.versions.count == 1)
        #expect(!session.showCanvas)

        session.showCanvas = true
        session.showInspector = true
        session.showCanvas = false
        #expect(persistence.flush())

        let reopened = AppModel(persistence: PersistenceController(root: folder))
        let reopenedSession = reopened.session(for: id)
        #expect(!reopenedSession.showCanvas)
        reopenedSession.showCanvas = true
        #expect(reopenedSession.showInspector)
        #expect(reopened.session(for: existing.id).showCanvas)

        let saved = try #require(persistence.load(AppSettings.self, file: "settings.json"))
        #expect(saved.hiddenCanvasProjectIDs?.contains(id) == false)
    }

    @Test func compareVersionsAndRestoreOnlyOneArtboardWithHistoricalStyles() throws {
        let folder = try TempWorkspace.make(prefix: "restore-artboard")
        defer { try? FileManager.default.removeItem(at: folder) }
        let persistence = PersistenceController(root: folder)
        let app = AppModel(persistence: persistence)
        let board = Artboard(name: "计时", html: "<h1>旧版</h1>", width: 390, height: 844)
        let other = Artboard(name: "日历", html: "<h1>保留</h1>", x: 500, width: 390, height: 844)
        let removed = Artboard(name: "删除", html: "<p>Removed</p>", x: 1000, width: 390, height: 844)
        let added = Artboard(name: "新增", html: "<p>Added</p>", x: 1500, width: 390, height: 844)
        let page = DesignPage(name: "画布", artboards: [board, other, removed], sharedCSS: "body { color: red }")
        var newer = page
        newer.artboards[0].html = "<h1>新版</h1>"
        newer.artboards[0].width = 420
        newer.artboards = Array(newer.artboards.prefix(2)) + [added]
        newer.sharedCSS = "body { color: blue }"
        let oldDocument = DesignDocument(pages: [page])
        let newDocument = DesignDocument(pages: [newer])
        let changes = VersionArtboardChange.compare(oldDocument, to: newDocument)
        #expect(changes.map(\.action) == ["内容、尺寸、共享样式", "共享样式", "新增", "删除"])
        #expect(changes.filter(\.inheritsChangedSharedStyles).map(\.id) == [board.id, other.id])
        let snapshot = try #require(changes.first?.before)
        #expect(snapshot.html.contains("color: red"))
        #expect(changes.first?.after?.html.contains("color: blue") == true)

        var project = Project(name: "版本", kind: .prototype)
        project.document = newDocument
        app.projects = [project]
        let session = app.session(for: project.id)
        session.restoreArtboard(snapshot)

        let restored = try #require(session.document.artboard(board.id))
        #expect(restored.html == board.html && restored.width == board.width)
        #expect(session.document.composedHTML(board.id)?.contains("color: red") == true)
        #expect(session.document.composedHTML(board.id)?.contains("color: blue") == false)
        #expect(session.document.artboard(other.id) == other)
        #expect(session.document.composedHTML(other.id)?.contains("color: blue") == true)
        #expect(session.document.artboard(added.id) == added)
        session.undo()
        #expect(session.document == newDocument)
        #expect(persistence.flush())
    }

    @Test func codexHandoffIncludesDesignAndStartsInTheChosenFolder() throws {
        let folder = try TempWorkspace.make(prefix: "codex handoff")
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appending(path: "fake 'codex'")
        try "#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$@\" > launch-arguments.txt\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let board = Artboard(name: "首页", html: "<h1>交接</h1>", width: 390, height: 844)
        let project = Project(name: "交接", kind: .prototype)
        let launcher = try ExportService.writeHandoff(project: project, artboards: [board], designSystem: nil,
                                                       tool: .codex, executable: executable.path, to: folder)
        let brief = try String(contentsOf: folder.appending(path: "HANDOFF.md"), encoding: .utf8)
        #expect(brief.contains("01-首页.html"))
        #expect(try String(contentsOf: folder.appending(path: "01-首页.html"), encoding: .utf8) == board.html)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", launcher.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let arguments = try String(contentsOf: folder.appending(path: "launch-arguments.txt"), encoding: .utf8)
            .split(whereSeparator: \.isNewline).map(String.init)
        let workingDirectory = try #require(arguments.first)
        let actualDirectory = try FileManager.default.attributesOfItem(atPath: workingDirectory)
        let expectedDirectory = try FileManager.default.attributesOfItem(atPath: folder.path)
        #expect(actualDirectory[.systemFileNumber] as? NSNumber == expectedDirectory[.systemFileNumber] as? NSNumber)
        #expect(arguments.dropFirst().prefix(2) == ["-c", #"service_tier="default""#])
        #expect(arguments.last?.contains("HANDOFF.md") == true)
    }

    @Test(arguments: [1, 10, 30])
    func canvasLoadsVisibleArtboardsAndRetainsOnlyNearbyOrRequestedViews(_ count: Int) {
        let boards = (0..<count).map { index in
            Artboard(name: "Board \(index)", html: "<p>Board</p>", x: Double(index) * 500, width: 400, height: 300)
        }
        let viewport = CGRect(x: 0, y: 0, width: 450, height: 500)
        let initial = CanvasArtboardLoadPlan(boards: boards, viewport: viewport, zoom: 1, required: []) { _ in false }
        #expect(initial.visible == Set(boards.prefix(1).map(\.id)))
        #expect(initial.mountOrder == boards.prefix(2).map(\.id))
        #expect(initial.retained == Set(boards.prefix(2).map(\.id)))

        let panned = viewport.offsetBy(dx: 700, dy: 0)
        let scrolled = CanvasArtboardLoadPlan(boards: boards, viewport: panned, zoom: 1, required: []) { _ in false }
        #expect(scrolled.visible == Set(boards.dropFirst().prefix(2).map(\.id)))
        #expect(!scrolled.retained.contains(boards[0].id))

        let pinned = CanvasArtboardLoadPlan(boards: boards, viewport: viewport, zoom: 1,
                                           required: [boards[count - 1].id]) { _ in true }
        #expect(pinned.visible == initial.visible)
        #expect(pinned.mountOrder == [boards[count - 1].id])
        #expect(pinned.retained == [boards[count - 1].id])
    }

    @Test func canvasPrefetchAndReleaseMarginsStayStableAtDifferentZooms() {
        let board = Artboard(name: "Edge", html: "<p>Board</p>", x: 900, width: 400, height: 300)
        let viewport = CGRect(x: 0, y: 0, width: 800, height: 800)
        let second = CanvasArtboardLoadPlan(boards: [board], viewport: viewport, zoom: 2, required: []) { _ in false }
        #expect(second.mountOrder.isEmpty)
        #expect(second.retained == [board.id])
        let panned = CanvasArtboardLoadPlan(boards: [board], viewport: viewport.offsetBy(dx: 60, dy: 0),
                                             zoom: 2, required: []) { _ in false }
        #expect(panned.mountOrder == [board.id])
    }

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

    @Test(arguments: [1, 10, 30], [false, true])
    func scopedPromptOnlyContainsRequestedBoardAndTreatsSharedCSSAsReadOnly(_ count: Int, hasSharedCSS: Bool) throws {
        let boards = (0..<count).map { i in
            Artboard(name: "Page \(i)", html: "<article>SourceMarker_\(i)_end</article>", width: 390, height: 844)
        }
        let css = "body { color: #123456 }"
        let page = DesignPage(name: "Pages", artboards: boards, sharedCSS: hasSharedCSS ? css : nil)
        var project = Project(name: "Test project", kind: .prototype)
        project.document = DesignDocument(pages: [page])
        let target = try #require(boards.last)
        let message = ChatMessage(role: .user, text: "改标题")
        let profile = ProviderProfile(name: "Codex", kind: .codex)
        let request = DesignPrompt.makeRequest(project: project, designSystem: nil,
                                               newMessage: message, profile: profile, pageID: page.id,
                                               scopeIDs: [target.id])
        let prompt = request.flattenedPrompt(includeSystem: false)
        #expect(prompt.contains(target.html))
        for board in boards.dropLast() {
            #expect(!prompt.contains(board.html))
        }
        #expect(request.system.contains("shared stylesheet as read-only"))
        #expect(!request.flattenedPrompt(includeSystem: true).contains("```css shared"))
        #expect(prompt.contains(css) == hasSharedCSS)
        #expect(prompt.contains("只输出有改动的指定画板"))

        let fullCanvas = DesignPrompt.makeRequest(project: project, designSystem: nil,
                                                 newMessage: message, profile: profile, pageID: page.id)
        #expect(fullCanvas.system.contains("```css shared"))
        #expect(fullCanvas.messages.last?.text.contains("```css shared") == true)
    }

    @Test func focusingChatOnOneArtboardUsesOnlyItsCommentsAndKeepsTheDraft() throws {
        let folder = try TempWorkspace.make(prefix: "chat-artboard-scope")
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = AppModel(persistence: PersistenceController(root: folder))
        let first = Artboard(name: "推荐", html: "<p>One</p>", width: 390, height: 844)
        let second = Artboard(name: "计时", html: "<p>Two</p>", width: 390, height: 844)
        var project = Project(name: "冥想", kind: .prototype)
        project.document = DesignDocument(pages: [DesignPage(name: "画布", artboards: [first, second])])
        project.comments = [CanvasComment(selector: "p", tag: "p", snippet: "", note: "修改文字",
                                          artboardName: first.name, artboardID: first.id)]
        app.projects = [project]
        let session = app.session(for: project.id)
        session.showChat = false
        session.draftScopeIDs = [first.id]
        session.draft = "调整布局"
        let oldFocus = session.chatFocusRequest

        session.focusChat(onArtboard: second.id)

        #expect(session.showChat)
        #expect(session.chatFocusRequest != oldFocus)
        #expect(session.selection?.artboardID == second.id)
        #expect(session.draftScopeArtboards.map(\.id) == [second.id])
        #expect(session.draft == "调整布局")
        #expect(session.draftComments.isEmpty)
        session.draft = ""
        #expect(!session.canSend)
        session.draftScopeIDs = []
        #expect(session.canSend)
    }

    @Test func keepsTheDraftScopeWhenSwitchingCanvasesAndBlocksDeletedTargets() throws {
        let folder = try TempWorkspace.make(prefix: "chat-invalid-scope")
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = AppModel(persistence: PersistenceController(root: folder))
        let board = Artboard(name: "首页", html: "<p>Old</p>", width: 390, height: 844)
        let page = DesignPage(name: "移动端", artboards: [board])
        let other = DesignPage(name: "桌面")
        var project = Project(name: "范围", kind: .prototype)
        project.document = DesignDocument(pages: [page, other])
        app.projects = [project]
        let session = app.session(for: project.id)
        session.draft = "调整首页"
        session.focusChat(onArtboard: board.id)

        session.switchPage(other.id)
        #expect(session.draftScopeIDs == [board.id])
        #expect(!session.canSend)
        session.switchPage(page.id)
        #expect(session.canSend)
        session.deleteArtboard(board.id)
        session.send()
        #expect(session.draftScopeIssue?.contains("已删除") == true)
        #expect(session.draft == "调整首页")
        #expect(app.project(project.id)?.messages.isEmpty == true)
        session.undo()
        #expect(session.canSend)
    }

    @Test func retryKeepsTheOriginalTurnWhenItsTargetWasDeleted() async throws {
        let folder = try TempWorkspace.make(prefix: "retry-deleted-target")
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = AppModel(persistence: PersistenceController(root: folder)) { _ in InterruptedProvider() }
        app.providers = [ProviderProfile(name: "Test", kind: .codex)]
        let replacement = Artboard(name: "首页", html: "<p>Replacement</p>", width: 390, height: 844)
        let page = DesignPage(name: "画布", artboards: [replacement])
        var user = ChatMessage(role: .user, text: "改标题", requestPageID: page.id)
        user.target = MessageTarget(artboardID: UUID(), artboardName: replacement.name, elementKind: "text", selector: "p")
        let reply = ChatMessage(role: .assistant, text: "", errorText: "生成失败")
        var project = Project(name: "重试", kind: .prototype)
        project.document = DesignDocument(pages: [page])
        project.messages = [user, reply]
        app.projects = [project]
        let session = app.session(for: project.id)
        session.select(CanvasSelection(artboardID: replacement.id, elementID: nil))
        session.draft = "保留我的草稿"

        session.retry(assistantMessageID: reply.id)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while session.isPreparingRequest, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!session.isGenerating)
        #expect(session.requestNotice?.contains("原目标画板") == true)
        #expect(app.project(project.id)?.messages.map(\.id) == [user.id, reply.id])
        #expect(session.draft == "保留我的草稿")
    }

    @Test(.timeLimit(.minutes(1)))
    func editedMessageResendsWithItsOriginalScopeAndKeepsHistory() async throws {
        let folder = try TempWorkspace.make(prefix: "edited-message")
        defer { try? FileManager.default.removeItem(at: folder) }
        let persistence = PersistenceController(root: folder)
        let app = AppModel(persistence: persistence) { _ in WorkspaceDesignProvider() }
        app.providers = [ProviderProfile(name: "Test", kind: .codex)]
        let board = Artboard(name: "今日推荐", html: "<h1>旧版</h1>", width: 390, height: 844)
        let page = DesignPage(name: "移动端", artboards: [board])
        let otherPage = DesignPage(name: "桌面")
        let document = DesignDocument(pages: [page, otherPage])
        let version = DesignVersion(number: 1, document: document, summary: "旧版")
        let attachment = ChatAttachment(filename: "需求.md", mimeType: "text/markdown", data: Data("设计需求".utf8))
        let original = ChatMessage(role: .user, text: "原始需求", attachments: [attachment],
                                   scopeIDs: [board.id], requestPageID: page.id)
        let reply = ChatMessage(role: .assistant, text: "旧回复", versionID: version.id)
        let laterMessage = ChatMessage(role: .user, text: "后续需求")
        let laterReply = ChatMessage(role: .assistant, text: "后续回复")
        let history = [original, reply, laterMessage, laterReply]
        var project = Project(name: "编辑消息", kind: .prototype)
        project.document = document
        project.versions = [version]
        project.currentVersionID = version.id
        project.messages = history
        app.projects = [project]
        let session = app.session(for: project.id)
        session.switchPage(otherPage.id)
        session.draft = "未发送的草稿"
        let scrollRequest = session.chatSendScrollRequest
        var didSubmit = false

        session.resendEditedMessage(id: original.id, text: "调整今日推荐") { didSubmit = true }
        let busy = Observations { session.isPreparingRequest || session.isGenerating }
        for await isBusy in busy {
            if !isBusy { break }
        }

        let saved = try #require(app.project(project.id))
        let edited = try #require(saved.messages.dropFirst(history.count).first)
        #expect(didSubmit)
        #expect(session.chatSendScrollRequest != scrollRequest)
        #expect(session.draft == "未发送的草稿")
        #expect(saved.messages.prefix(history.count).map(\.id) == history.map(\.id))
        #expect(saved.messages.first?.text == original.text)
        #expect(saved.messages.count == 6)
        #expect(edited.text == "调整今日推荐")
        #expect(edited.attachments == [attachment])
        #expect(edited.requestPageID == page.id)
        #expect(edited.scopeIDs == [board.id])
        #expect(saved.versions.map(\.number) == [1, 2])
        #expect(saved.versions.first?.document?.artboard(board.id)?.html == board.html)
        #expect(session.document.artboard(board.id)?.html.contains("<h1>今日推荐</h1>") == true)
        #expect(session.document.page(otherPage.id)?.artboards.isEmpty == true)
        #expect(persistence.flush())
    }

    @Test func restoresEachCanvasZoomCenterAndSelectionAfterResizing() throws {
        let folder = try TempWorkspace.make(prefix: "canvas-viewport")
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = AppModel(persistence: PersistenceController(root: folder))
        let board = Artboard(name: "首页", html: "<p>First</p>", width: 390, height: 844)
        let page = DesignPage(name: "移动端", artboards: [board])
        let other = DesignPage(name: "桌面")
        var project = Project(name: "视口", kind: .prototype)
        project.document = DesignDocument(pages: [page, other])
        app.projects = [project]
        let session = app.session(for: project.id)
        session.viewportDidChange(CGSize(width: 40, height: 60))
        #expect(session.viewportSize == .zero)
        session.viewportDidChange(CGSize(width: 1000, height: 700))
        session.setZoom(1.25)
        session.panBy(dx: 53, dy: -31)
        session.select(CanvasSelection(artboardID: board.id, elementID: nil))
        let center = session.worldPoint(CGPoint(x: 500, y: 350))

        session.switchPage(other.id)
        session.viewportDidChange(CGSize(width: 700, height: 600))
        session.switchPage(page.id)
        let restored = session.worldPoint(CGPoint(x: 350, y: 300))
        #expect(session.zoom == 1.25)
        #expect(abs(restored.x - center.x) < 0.001 && abs(restored.y - center.y) < 0.001)
        #expect(session.selection?.artboardID == board.id)
    }

    @Test(.timeLimit(.minutes(1)))
    func failedGenerationKeepsCommentsPendingUntilCompletedBoardsAreAccepted() async throws {
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

        // Both preparation and generation run in tasks scheduled on the main actor.
        let busy = Observations { session.isPreparingRequest || session.isGenerating }
        for await isBusy in busy {
            if !isBusy { break }
        }
        let reply = try #require(app.project(project.id)?.messages.last)
        try #require(reply.errorText != nil)
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

private struct WorkspaceDesignProvider: LLMProvider {
    nonisolated func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text("""
                <!-- project-title: 冥想 App -->
                完成了今日推荐画板。
                ```html artboard="今日推荐" width=390 height=844
                <!doctype html><html><body><h1>今日推荐</h1></body></html>
                ```
                """))
            continuation.finish()
        }
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
