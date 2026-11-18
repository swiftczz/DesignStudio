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
    let persistence = PersistenceController()
    let auth = CLIAuthService()

    var projects: [Project] = []
    var designSystems: [DesignSystem] = []
    var providers: [ProviderProfile] = []
    var settings = AppSettings()
    var route: SidebarRoute = .home {
        didSet {
            // 从主页 / 设计系统进入项目时收起项目边栏，只留对话栏和画布；离开项目回到这些页面时再展开。
            // 在项目之间切换（边栏已手动打开）时保持用户当前的状态
            switch (oldValue, route) {
            case (.project, .project): break
            case (_, .project): withAnimation(.snappy(duration: 0.25)) { sidebarVisibility = .detailOnly }
            case (.project, _): withAnimation(.snappy(duration: 0.25)) { sidebarVisibility = .all }
            default: break
            }
        }
    }
    /// 左侧项目边栏的显示状态（进入项目和全屏时收起）
    var sidebarVisibility: NavigationSplitViewVisibility = .all
    var thumbnailStamps: [UUID: Date] = [:]

    @ObservationIgnored private var sessions: [UUID: ProjectSession] = [:]
    @ObservationIgnored private var thumbnailCache: [UUID: (Date, NSImage)] = [:]

    init() {
        projects = persistence.loadProjects()
        persistence.clearGeneratingMarkers()
        markInterruptedReplies()
        designSystems = persistence.load([DesignSystem].self, file: "design-systems.json") ?? DesignSystem.builtIns
        providers = persistence.load([ProviderProfile].self, file: "providers.json")
            ?? [.claudeCode(), .codex(), .anthropic()]
        settings = persistence.load(AppSettings.self, file: "settings.json") ?? AppSettings()
        ThemeStore.shared.choice = settings.accentTheme.flatMap(ThemeColor.init(rawValue:)) ?? .terracotta
        if settings.defaultProviderID == nil || provider(for: settings.defaultProviderID) == nil {
            settings.defaultProviderID = providers.first?.id
        }
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
                guard m.role == .assistant, m.text.trimmed.isEmpty, m.errorText == nil,
                      !m.wasStopped, m.versionID == nil else { continue }
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
        var p = Project(name: Project.suggestedName(from: prompt), kind: kind)
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
        updateProject(id) { $0.name = n }
    }

    func duplicate(_ id: UUID) {
        guard var copy = project(id) else { return }
        copy.id = UUID()
        copy.name += " 副本"
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

    func deleteProject(_ id: UUID) {
        sessions[id]?.stop()
        persistence.setGenerating(id, false)
        sessions[id] = nil
        projects.removeAll { $0.id == id }
        persistence.deleteProject(id)
        thumbnailStamps[id] = nil
        thumbnailCache[id] = nil
        if route == .project(id) { route = .home }
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
        if responder is NSTextView || activeSession == nil {
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
        let responder = NSApp.keyWindow?.firstResponder
        if responder is NSTextView { return false }
        if responder is WKWebView { return !s.isEditingText && !s.interactivePreview }
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
