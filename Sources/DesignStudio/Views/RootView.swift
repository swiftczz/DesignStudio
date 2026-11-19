import SwiftUI
import AppKit

struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var pendingExport: (project: Project, canvasIDs: Set<UUID>, includingHistory: Bool)?
    private let sidebarWidth: CGFloat = 285

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: $app.sidebarVisibility) {
            SidebarView()
                .frame(minWidth: sidebarWidth, maxWidth: 320)
                .navigationSplitViewColumnWidth(min: sidebarWidth, ideal: sidebarWidth, max: 320)
                .toolbar(removing: fullScreenSession == nil ? nil : .sidebarToggle)
        } detail: {
            detail
        }
        .tint(Theme.accent)
        .sheet(item: $app.projectToExport, onDismiss: savePendingExport) { project in
            ProjectExportOptions(project: project) { ids, includingHistory in
                pendingExport = (project, ids, includingHistory)
            }
        }
    }

    private func savePendingExport() {
        guard let pending = pendingExport else { return }
        pendingExport = nil
        app.saveProjectExport(pending.project, canvasIDs: pending.canvasIDs, includingHistory: pending.includingHistory)
    }

    /// 正在全屏查看画板的项目
    private var fullScreenSession: ProjectSession? {
        guard case .project(let id) = app.route, let s = app.existingSession(id), s.isFullScreen else { return nil }
        return s
    }

    @ViewBuilder private var detail: some View {
        switch app.route {
        case .home:
            HomeView()
        case .designSystems:
            DesignSystemsView()
        case .project(let id):
            if app.project(id) != nil {
                ProjectWorkspaceView(session: app.session(for: id))
                    .id(id)
            } else {
                ContentUnavailableView("项目不存在", systemImage: "questionmark.folder")
            }
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var deletingID: UUID?
    @FocusState private var sidebarFocused: Bool

    var body: some View {
        let projects = app.sortedProjects
        ScrollViewReader { scroll in
            List {
                Section {
                    sidebarRow(.home) {
                        Label {
                            Text("新建设计").fontWeight(app.route == .home ? .semibold : .regular)
                        } icon: {
                            Image(systemName: "plus.bubble").foregroundStyle(Theme.accent)
                        }
                    }
                    sidebarRow(.designSystems) {
                        Label {
                            Text("设计系统").fontWeight(app.route == .designSystems ? .semibold : .regular)
                        } icon: {
                            Image(systemName: "paintpalette").foregroundStyle(Theme.accent)
                        }
                    }
                }

                Section("项目") {
                    if projects.isEmpty {
                        Text("还没有项目").foregroundStyle(.secondary)
                    }
                    ForEach(projects) { project in
                        sidebarRow(.project(project.id)) {
                            ProjectRow(project: project)
                        }
                        .contextMenu {
                            Button("重命名…") {
                                renameText = project.displayName
                                renamingID = project.id
                            }
                            RegenerateProjectTitleButton(projectID: project.id)
                            Button("创建副本") { app.duplicate(project.id) }
                            Button("导出项目") { app.exportProject(project.id) }
                            Divider()
                            Button("删除", role: .destructive) { deletingID = project.id }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .focusable()
            .focusEffectDisabled()
            .focused($sidebarFocused)
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                guard sidebarFocused else { return .ignored }
                let routes: [SidebarRoute] = [.home, .designSystems] + projects.map { .project($0.id) }
                guard let index = routes.firstIndex(of: app.route) else { return .ignored }
                let next = index + (press.key == .upArrow ? -1 : 1)
                if routes.indices.contains(next) {
                    let route = routes[next]
                    app.route = route
                    scroll.scrollTo(route)
                }
                return .handled
            }
        }
        .safeAreaInset(edge: .bottom) {
            SidebarFooter()
        }
        .alert("重命名项目", isPresented: Binding(get: { renamingID != nil }, set: { if !$0 { renamingID = nil } })) {
            TextField("名称", text: $renameText)
            Button("保存") {
                if let id = renamingID { app.rename(id, to: renameText) }
                renamingID = nil
            }
            Button("取消", role: .cancel) { renamingID = nil }
        }
        .confirmationDialog("删除这个项目？", isPresented: Binding(get: { deletingID != nil }, set: { if !$0 { deletingID = nil } })) {
            Button("移到废纸篓", role: .destructive) {
                if let id = deletingID { app.deleteProject(id) }
                deletingID = nil
            }
        } message: {
            Text("项目文件夹会被移到废纸篓，可以从废纸篓恢复。")
        }
    }

    private func sidebarRow<Content: View>(_ route: SidebarRoute, @ViewBuilder content: () -> Content) -> some View {
        let selected = app.route == route
        return Button {
            sidebarFocused = true
            app.route = route
        } label: {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .listRowBackground(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : .clear)
                .padding(.horizontal, 10)
                .allowsHitTesting(false)
        )
        .id(route)
    }
}

private struct ProjectRow: View {
    @Environment(AppModel.self) private var app
    let project: Project

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: project.kind.symbol)
                .foregroundStyle(Theme.accent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.displayName)
                    .fontWeight(app.route == .project(project.id) ? .semibold : .regular)
                    .lineLimit(1)
                    .help(project.displayName)
                Text(project.updatedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if app.existingSession(project.id)?.isGenerating == true || app.regeneratingTitles.contains(project.id) {
                ProgressView().controlSize(.small)
            }
        }
    }
}

struct RegenerateProjectTitleButton: View {
    @Environment(AppModel.self) private var app
    let projectID: UUID

    var body: some View {
        Button("重新生成标题", systemImage: "sparkles") {
            Task { await app.regenerateTitle(projectID) }
        }
        .disabled(app.regeneratingTitles.contains(projectID))
    }
}

private struct SidebarFooter: View {
    @Environment(AppModel.self) private var app

    /// 账号登录类来源中有问题的（未登录、未安装、检测失败）；都正常时不显示，只留设置按钮
    private var problems: [ProviderProfile] {
        var seen = Set<ProviderKind>()
        return app.providers.filter { p in
            guard p.kind.isCLI, seen.insert(p.kind).inserted else { return false }
            switch app.auth.state(p.kind) {
            case .loggedOut, .notInstalled, .failed, .broken: return true
            default: return false
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 10) {
                ForEach(problems) { p in problemBadge(p) }
                Spacer()
                OpenSettingsButton {
                    // 不随这一行的 caption 字号缩小
                    Image(systemName: "gear")
                        .font(.system(size: 16))
                        .frame(width: 26, height: 26)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .help("设置")
            }
            .font(.caption)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .animation(.snappy(duration: 0.2), value: problems.map(\.id))
    }

    /// 「Claude 未登录」：点击打开设置去处理
    private func problemBadge(_ p: ProviderProfile) -> some View {
        let state = app.auth.state(p.kind)
        let short = switch state {
        case .notInstalled: "未安装"
        case .failed: "检测失败"
        case .broken: "安装不完整"
        default: "未登录"
        }
        return OpenSettingsButton {
            HStack(spacing: 4) {
                Circle().fill(Color.orange).frame(width: 7, height: 7)
                Text("\(p.name) \(short)").foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("\(p.name)：\(state.label)。点击打开设置")
        .transition(.opacity)
    }
}
