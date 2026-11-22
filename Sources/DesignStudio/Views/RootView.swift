import SwiftUI
import AppKit

struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var pendingExport: ProjectArchive?
    private let sidebarWidth: CGFloat = 285

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: $app.sidebarVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: sidebarWidth, ideal: sidebarWidth, max: 320)
                .toolbar(removing: fullScreenSession == nil ? nil : .sidebarToggle)
        } detail: {
            detail
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .tint(Theme.accent)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            let persistence = app.persistence
            if let id = persistence.saveErrors.keys.first, let error = persistence.saveErrors[id] {
                HStack {
                    Label("项目保存失败", systemImage: "exclamationmark.triangle")
                    Text(app.project(id).map { "\($0.displayName)：\(error)" } ?? error)
                        .lineLimit(1)
                        .help(error)
                    Spacer()
                    Button("重试保存", action: app.retryProjectSaves)
                }
                .padding(8)
                .background(.regularMaterial)
            } else if persistence.recoveredCount > 0 || persistence.unreadableCount > 0 {
                HStack {
                    Text("从备份恢复 \(persistence.recoveredCount) 个项目，\(persistence.unreadableCount) 个项目暂时无法读取。")
                    Spacer()
                    Button("知道了", action: persistence.dismissLoadNotice)
                }
                .padding(8)
                .background(.regularMaterial)
            }
        }
        .sheet(item: $app.projectToExport, onDismiss: savePendingExport) { project in
            ProjectExportOptions(project: project, designSystem: app.designSystem(for: project.designSystemID)) {
                pendingExport = $0
            }
        }
    }

    private func savePendingExport() {
        guard let pending = pendingExport else { return }
        pendingExport = nil
        ExportService.exportProject(pending)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var deletingID: UUID?
    @State private var projectQuery = ""
    @State private var projectRowFrames: [UUID: CGRect] = [:]
    @GestureState private var draggedProject: (id: UUID, offset: CGFloat)?
    @FocusState private var sidebarFocused: Bool
    @FocusState private var projectSearchFocused: Bool
    private let projectRowInset: CGFloat = 10

    var body: some View {
        let pinned = app.settings.pinnedProjectIDs ?? []
        let query = projectQuery.trimmed
        let matching = app.sortedProjects.filter { query.isEmpty || $0.displayName.localizedStandardContains(query) }
        let projects = matching.filter { pinned.contains($0.id) } + matching.filter { !pinned.contains($0.id) }
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
                    if !app.projects.isEmpty {
                        projectSearch
                    }
                    if projects.isEmpty {
                        Text(query.isEmpty ? "还没有项目" : "没有匹配的项目").foregroundStyle(.secondary)
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
                            Button(pinned.contains(project.id) ? "取消置顶" : "置顶项目",
                                   systemImage: pinned.contains(project.id) ? "pin.slash" : "pin") {
                                var ids = app.settings.pinnedProjectIDs ?? []
                                if ids.remove(project.id) == nil { ids.insert(project.id) }
                                app.settings.pinnedProjectIDs = ids
                                app.saveSettings()
                            }
                            Button("创建副本") { app.duplicate(project.id) }
                            Button("导出项目") { app.exportProject(project.id) }
                            Divider()
                            Button("删除", role: .destructive) { deletingID = project.id }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .backgroundPreferenceValue(ProjectRowBounds.self) { rows in
                projectDragBackground(rows)
            }
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
        .safeAreaBar(edge: .bottom) {
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

    private var projectSearch: some View {
        let spacingBelow: CGFloat = 6
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .frame(width: 18)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
                .onTapGesture { projectSearchFocused = true }

            TextField("搜索项目", text: $projectQuery)
                .textFieldStyle(.plain)
                .focused($projectSearchFocused)
                .accessibilityLabel("搜索项目")
                .onExitCommand {
                    if projectQuery.isEmpty {
                        projectSearchFocused = false
                    } else {
                        projectQuery = ""
                    }
                }

            if !projectQuery.isEmpty {
                Button {
                    projectQuery = ""
                    projectSearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空项目搜索")
            }
        }
        .font(.callout)
        .frame(height: 30)
        .padding(.bottom, spacingBelow)
        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 5, trailing: 0))
        .listRowBackground(
            Capsule()
                .strokeBorder(Theme.accent.opacity(projectSearchFocused ? 0.45 : 0), lineWidth: 1)
                .glassEffect(.regular, in: .capsule)
                .padding(.horizontal, projectRowInset)
                .padding(.vertical, 4)
                .padding(.bottom, spacingBelow)
                .allowsHitTesting(false)
        )
    }

    private func sidebarRow<Content: View>(_ route: SidebarRoute, @ViewBuilder content: () -> Content) -> some View {
        let selected = app.route == route
        let projectID: UUID? = if case .project(let id) = route { id } else { nil }
        return Button {
            sidebarFocused = true
            app.route = route
        } label: {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(nil, value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .simultaneousGesture(projectDragGesture(projectID), including: selected && projectID != nil ? .all : .none)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected && draggedProject == nil ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : .clear)
                .padding(.horizontal, projectRowInset)
                .allowsHitTesting(false)
                .anchorPreference(key: ProjectRowBounds.self, value: .bounds) { bounds in
                    projectID.map { [$0: bounds] } ?? [:]
                }
        )
        .id(route)
    }

    private func projectDragGesture(_ projectID: UUID?) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .global)
            .updating($draggedProject) { value, state, transaction in
                guard let projectID, app.route == .project(projectID),
                      abs(value.translation.height) > abs(value.translation.width) else { return }
                transaction.animation = nil
                state = (projectID, value.translation.height)
            }
            .onEnded { value in
                guard let projectID, app.route == .project(projectID),
                      abs(value.translation.height) > abs(value.translation.width) else { return }
                guard let target = projectRowFrames.first(where: { $0.value.contains(value.location) })?.key,
                      app.project(target) != nil else { return }
                sidebarFocused = true
                app.route = .project(target)
            }
    }

    private func projectDragBackground(_ anchors: [UUID: Anchor<CGRect>]) -> some View {
        GeometryReader { geometry in
            let viewport = CGRect(origin: .zero, size: geometry.size)
            let origin = geometry.frame(in: .global).origin
            let frames = anchors.mapValues { geometry[$0] }.filter { $0.value.intersects(viewport) }
            let dropFrames = frames.mapValues { $0.intersection(viewport).offsetBy(dx: origin.x, dy: origin.y) }
            Color.clear
                .onChange(of: dropFrames, initial: true) { _, visible in projectRowFrames = visible }
            if let drag = draggedProject, let source = frames[drag.id], source.width > 2 * projectRowInset {
                let row = source.insetBy(dx: projectRowInset, dy: 0)
                RoundedRectangle(cornerRadius: 10)
                    .fill(.clear)
                    .frame(width: row.width, height: row.height)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 10))
                    .scaleEffect(reduceMotion ? 1 : 1.02)
                    .position(x: row.midX, y: row.midY + drag.offset)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ProjectRowBounds: PreferenceKey {
    static let defaultValue: [UUID: Anchor<CGRect>] = [:]

    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
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
            if app.settings.pinnedProjectIDs?.contains(project.id) == true {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("已置顶")
            }
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
        SidebarFooterBar {
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
