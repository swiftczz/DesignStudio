import SwiftUI
import AppKit
import WebKit
import Observation

enum SidebarRoute: Hashable {
    case home
    case designSystems
    case project(UUID)
}

@MainActor
@Observable
final class AppModel {
    let persistence: PersistenceController
    let makeProvider: @MainActor (ProviderProfile) throws -> any LLMProvider
    let auth = CLIAuthService()
    let chatGPTAuth = ChatGPTAuthService.shared
    let softwareUpdater = SoftwareUpdater()

    var projects: [Project] = []
    var designSystems: [DesignSystem] = []
    var providers: [ProviderProfile] = []
    var settings = AppSettings()
    var projectToExport: Project?
    var route: SidebarRoute = .home {
        didSet {
            // 离开全屏查看的项目时，恢复进入全屏前的侧栏状态。
            guard oldValue != route, case .project(let id) = oldValue else { return }
            sessions[id]?.exitFullScreen()
        }
    }
    /// 左侧项目边栏默认展开，仅随手动切换和画板全屏变化。
    var sidebarVisibility: NavigationSplitViewVisibility = .all
    var thumbnailStamps: [UUID: Date] = [:]
    private(set) var regeneratingTitles: Set<UUID> = []

    @ObservationIgnored private var sessions: [UUID: ProjectSession] = [:]
    @ObservationIgnored private var thumbnailCache: [UUID: (Date, NSImage)] = [:]

    init(persistence: PersistenceController = PersistenceController(),
         makeProvider: @escaping @MainActor (ProviderProfile) throws -> any LLMProvider = ProviderFactory.make) {
        self.persistence = persistence
        self.makeProvider = makeProvider
        projects = persistence.loadProjects()
        persistence.clearGeneratingMarkers()
        markInterruptedReplies()
        designSystems = persistence.load([DesignSystem].self, file: "design-systems.json") ?? DesignSystem.builtIns
        providers = persistence.load([ProviderProfile].self, file: "providers.json")
            ?? [.claudeCode(), .chatGPT(), .codex(), .anthropic()]
        settings = persistence.load(AppSettings.self, file: "settings.json") ?? AppSettings()
        if settings.defaultProviderID == nil || provider(for: settings.defaultProviderID) == nil {
            settings.defaultProviderID = providers.first?.id
        }
        if settings.didAddChatGPTProvider != true {
            if let index = providers.firstIndex(where: { $0.kind == .codex }) {
                if providers[index].name == "Codex" { providers[index].name = "Codex CLI" }
                if !providers.contains(where: { $0.kind == .chatGPT }) {
                    providers.insert(.chatGPT(), at: index)
                }
            }
            // 保留旧 CLI 来源的 ID，项目、默认模型和 CLI 参数继续沿用原来的配置。
            settings.didAddChatGPTProvider = true
            saveProviders()
            saveSettings()
        }
        ThemeStore.shared.choice = settings.accentTheme.flatMap(ThemeColor.init(rawValue:)) ?? .terracotta
        let fm = FileManager.default
        for p in projects where fm.fileExists(atPath: persistence.thumbnailURL(p.id).path) {
            thumbnailStamps[p.id] = p.updatedAt
        }
    }

    /// 应用在生成过程中退出时，助手消息会留下空内容：标记为未完成，以便「重试」
    private func markInterruptedReplies() {
        for i in projects.indices {
            var changed = false
            for j in projects[i].messages.indices {
                let m = projects[i].messages[j]
                guard m.role == .assistant, m.errorText == nil, !m.wasStopped, m.versionID == nil,
                      m.generationInProgress == true || m.text.trimmed.isEmpty else { continue }
                projects[i].messages[j].generationInProgress = nil
                projects[i].messages[j].errorText = "生成未完成：应用在生成过程中退出了。"
                changed = true
            }
            if changed { persistence.save(projects[i]) }
        }
    }

    // MARK: - Projects

    var sortedProjects: [Project] { projects.sorted { $0.updatedAt > $1.updatedAt } }

    func project(_ id: UUID) -> Project? { projects.first { $0.id == id } }

    func updateProject(_ id: UUID, touch: Bool = true, _ mutate: (inout Project) -> Void) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        mutate(&projects[i])
        if touch { projects[i].updatedAt = .now }
        persistence.save(projects[i])
    }

    @discardableResult
    func createProject(prompt: String, kind: ProjectKind, designSystemID: UUID?,
                       model choice: ModelChoice, attachments: [ChatAttachment]) -> UUID {
        var p = Project(name: ProjectTitle.provisional(from: prompt, attachments: attachments), kind: kind)
        p.titleNeedsSummary = true
        p.designSystemID = designSystemID
        p.providerID = choice.providerID ?? settings.defaultProviderID
        p.model = choice.providerID == nil ? nil : choice.model
        p.effort = choice.providerID == nil ? nil : choice.effort
        projects.append(p)
        persistence.save(p)

        let s = session(for: p.id)
        s.draft = prompt
        s.draftAttachments = attachments
        route = .project(p.id)
        s.send()
        return p.id
    }

    func rename(_ id: UUID, to name: String) {
        let n = name.trimmed
        guard !n.isEmpty else { return }
        updateProject(id) {
            $0.name = n
            $0.titleNeedsSummary = false
        }
    }

    func exportProject(_ id: UUID) {
        guard var project = project(id) else { return }
        project.document = project.workingDocument
        projectToExport = project
    }

    func chooseProjectToImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [ProjectArchive.contentType]
        panel.canChooseDirectories = false
        panel.title = "导入项目"
        panel.prompt = "导入项目"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importProject(from: url)
    }

    func importProject(from url: URL) {
        guard url.isFileURL, url.pathExtension.lowercased() == ProjectArchive.filenameExtension else { return }
        Task {
            do {
                let archive = try await Task.detached(priority: .userInitiated) {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    return try ProjectArchive.read(from: url)
                }.value
                let imported = archive.importedCopy(existingDesignSystems: designSystems)
                let systems = imported.newDesignSystem.map { designSystems + [$0] }
                try persistence.saveImportedProject(imported.project, designSystems: systems)
                if let systems { designSystems = systems }
                projects.append(imported.project)
                route = .project(imported.project.id)
            } catch {
                ExportService.presentError("无法导入项目", error)
            }
        }
    }

    func regenerateTitle(_ id: UUID) async {
        guard let project = project(id), regeneratingTitles.insert(id).inserted else { return }
        defer { regeneratingTitles.remove(id) }
        do {
            guard let profile = session(for: id).provider else {
                throw LLMError.invalidResponse("请先在设置中添加模型来源。")
            }
            let provider = try ProviderFactory.make(profile)
            let request = ProjectTitle.request(for: project, maxOutput: profile.limits.maxOutput)
            var response = ""
            for try await event in provider.stream(request) {
                if case .text(let delta) = event { response += delta }
            }
            guard let current = self.project(id), current.name == project.name,
                  current.titleNeedsSummary == project.titleNeedsSummary else { return }
            guard let title = ProjectTitle.clean(response) else { throw LLMError.emptyResponse }
            updateProject(id, touch: false) {
                $0.name = title
                $0.titleNeedsSummary = false
            }
        } catch {
            if self.project(id) != nil { ExportService.presentError("无法重新生成标题", error) }
        }
    }

    func duplicate(_ id: UUID) {
        guard var copy = project(id) else { return }
        copy.id = UUID()
        copy.name = copy.displayName + " 副本"
        copy.titleNeedsSummary = false
        copy.createdAt = .now
        copy.updatedAt = .now
        projects.append(copy)
        persistence.save(copy)
        let src = persistence.thumbnailURL(id)
        if FileManager.default.fileExists(atPath: src.path) {
            try? FileManager.default.createDirectory(at: persistence.projectDirectory(copy.id), withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: src, to: persistence.thumbnailURL(copy.id))
            thumbnailStamps[copy.id] = .now
        }
    }

    func retryProjectSaves() {
        for project in projects where persistence.saveErrors[project.id] != nil {
            persistence.save(project)
        }
    }

    func deleteProject(_ id: UUID) {
        do {
            try persistence.deleteProject(id)
        } catch {
            ExportService.presentError("无法将项目移到废纸篓", error)
            return
        }
        sessions[id]?.stop()
        persistence.setGenerating(id, false)
        if route == .project(id) { route = .home }
        sessions[id] = nil
        projects.removeAll { $0.id == id }
        settings.pinnedProjectIDs?.remove(id)
        saveSettings()
        thumbnailStamps[id] = nil
        thumbnailCache[id] = nil
    }

    // MARK: - Sessions

    func session(for id: UUID) -> ProjectSession {
        if let s = sessions[id] { return s }
        let s = ProjectSession(app: self, projectID: id)
        sessions[id] = s
        return s
    }

    func existingSession(_ id: UUID) -> ProjectSession? { sessions[id] }

    var activeSession: ProjectSession? {
        if case .project(let id) = route { return sessions[id] }
        return nil
    }

    /// 文本输入框获得焦点时交给系统撤销（编辑中的文字），否则撤销画布上的修改
    func performUndo(redo: Bool) {
        let action = Selector(redo ? "redo:" : "undo:")
        let responder = NSApp.keyWindow?.firstResponder
        if responder is NSTextView || MarkdownContentView.contains(responder) || activeSession == nil || activeSession?.isEditingText == true {
            NSApp.sendAction(action, to: nil, from: nil)
            return
        }
        if redo { activeSession?.redo() } else { activeSession?.undo() }
    }

    enum PasteboardAction { case cut, copy, paste, selectAll }

    /// 剪切 / 拷贝 / 粘贴：文字输入框（对话、代码、设置）或画板里正在编辑的文字交给系统处理，
    /// 画布有焦点时作用于画布上选中的元素 / 画板
    func performPasteboard(_ action: PasteboardAction) {
        let selector: Selector = switch action {
        case .cut: #selector(NSText.cut(_:))
        case .copy: #selector(NSText.copy(_:))
        case .paste: #selector(NSText.paste(_:))
        case .selectAll: #selector(NSText.selectAll(_:))
        }
        guard let s = activeSession, action != .selectAll, canvasOwnsKeyboard(s) else {
            NSApp.sendAction(selector, to: nil, from: nil)
            return
        }
        switch action {
        case .cut: s.cutSelection()
        case .copy: s.copySelection()
        case .paste: s.paste()
        case .selectAll: break
        }
    }

    /// 画布相关的菜单命令（拷贝为 PNG、编组…）只在画布有焦点时生效
    func performCanvasCommand(_ body: (ProjectSession) -> Void) {
        guard let s = activeSession, canvasOwnsKeyboard(s) else { return }
        body(s)
    }

    private func canvasOwnsKeyboard(_ s: ProjectSession) -> Bool {
        guard !s.isEditingText else { return false }
        let responder = NSApp.keyWindow?.firstResponder
        if responder is NSTextView || MarkdownContentView.contains(responder) { return false }
        if responder is WKWebView { return !s.interactivePreview }
        return s.canvasFocused
    }

    // MARK: - Thumbnails

    func thumbnail(for id: UUID) -> NSImage? {
        guard let stamp = thumbnailStamps[id] else { return nil }
        if let cached = thumbnailCache[id], cached.0 == stamp { return cached.1 }
        guard let image = NSImage(contentsOf: persistence.thumbnailURL(id)) else { return nil }
        thumbnailCache[id] = (stamp, image)
        return image
    }

    func saveThumbnail(_ image: NSImage, for id: UUID) {
        persistence.saveThumbnail(image, for: id)
        thumbnailStamps[id] = .now
    }

    // MARK: - Providers

    func provider(for id: UUID?) -> ProviderProfile? {
        guard let id else { return nil }
        return providers.first { $0.id == id }
    }

    var defaultProvider: ProviderProfile? { provider(for: settings.defaultProviderID) ?? providers.first }

    func addProvider(_ profile: ProviderProfile) {
        providers.append(profile)
        saveProviders()
    }

    func deleteProvider(_ id: UUID) {
        providers.removeAll { $0.id == id }
        SecretStore.remove(id.uuidString)
        if settings.defaultProviderID == id {
            settings.defaultProviderID = providers.first?.id
            saveSettings()
        }
        saveProviders()
    }

    func providerBinding(_ id: UUID) -> Binding<ProviderProfile> {
        Binding(
            get: { [unowned self] in
                self.providers.first { $0.id == id } ?? ProviderProfile(name: "", kind: .openAICompatible)
            },
            set: { [unowned self] newValue in
                guard let i = self.providers.firstIndex(where: { $0.id == id }) else { return }
                self.providers[i] = newValue
                self.saveProviders()
            }
        )
    }

    func refreshSavedChatGPTCatalog() async {
        guard chatGPTAuth.canUsePlan,
              let profile = providers.first(where: { $0.kind == .chatGPT }),
              profile.availableModels.isEmpty || profile.availableModels.contains(where: { $0.efforts == nil }) else { return }
        // 旧版目录未保存思考强度。应用打开后在后台拉取，沿用已有账号。
        try? await refreshChatGPTModels(for: profile.id)
    }

    func refreshChatGPTModels(for id: UUID) async throws {
        guard let profile = provider(for: id), profile.kind == .chatGPT else { return }
        let models = try await ModelFetcher.fetch(profile, apiKey: "")
        try Task.checkCancellation()
        guard chatGPTAuth.canUsePlan else { throw CancellationError() }
        updateChatGPTModels(models, for: id)
        guard !models.isEmpty else { throw LLMError.invalidResponse("该账号没有返回可用的 ChatGPT 模型。") }
    }

    func updateChatGPTModels(_ models: [RemoteModel], for id: UUID) {
        guard let index = providers.firstIndex(where: { $0.id == id && $0.kind == .chatGPT }) else { return }
        var profile = providers[index]
        profile.availableModels = models
        profile.models = models.map(\.id)
        if !profile.models.contains(profile.model) { profile.model = profile.models.first ?? "" }
        guard profile != providers[index] else { return }
        providers[index] = profile
        saveProviders()
    }

    func saveProviders() { persistence.store(providers, file: "providers.json") }
    func saveSettings() { persistence.store(settings, file: "settings.json") }

    func setAccentTheme(_ theme: ThemeColor) {
        ThemeStore.shared.choice = theme
        settings.accentTheme = theme.rawValue
        saveSettings()
    }

    // MARK: - Design systems

    func designSystem(for id: UUID?) -> DesignSystem? {
        guard let id else { return nil }
        return designSystems.first { $0.id == id }
    }

    func designSystemBinding(_ id: UUID) -> Binding<DesignSystem> {
        Binding(
            get: { [unowned self] in
                self.designSystems.first { $0.id == id } ?? .blank()
            },
            set: { [unowned self] newValue in
                guard let i = self.designSystems.firstIndex(where: { $0.id == id }) else { return }
                self.designSystems[i] = newValue
                self.saveDesignSystems()
            }
        )
    }

    @discardableResult
    func addDesignSystem(_ ds: DesignSystem) -> UUID {
        designSystems.append(ds)
        saveDesignSystems()
        return ds.id
    }

    func deleteDesignSystem(_ id: UUID) {
        designSystems.removeAll { $0.id == id }
        if settings.defaultDesignSystemID == id {
            settings.defaultDesignSystemID = nil
            saveSettings()
        }
        saveDesignSystems()
    }

    func saveDesignSystems() { persistence.store(designSystems, file: "design-systems.json") }
}
