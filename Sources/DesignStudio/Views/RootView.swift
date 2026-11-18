import SwiftUI
import AppKit

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: $app.sidebarVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
                .toolbar(removing: fullScreenSession == nil ? nil : .sidebarToggle)
        } detail: {
            detail
        }
        .tint(Theme.accent)
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

    var body: some View {
        List(selection: selection) {
            Section {
                // 侧边栏列表的图标默认用系统强调色，不跟随 .tint，这里显式用主题色
                Label { Text("新建设计") } icon: {
                    Image(systemName: "plus.bubble").foregroundStyle(Theme.accent)
                }
                .tag(SidebarRoute.home)
                Label { Text("设计系统") } icon: {
                    Image(systemName: "paintpalette").foregroundStyle(Theme.accent)
                }
                .tag(SidebarRoute.designSystems)
            }

            Section("项目") {
                if app.projects.isEmpty {
                    Text("还没有项目").foregroundStyle(.secondary)
                }
                ForEach(app.sortedProjects) { project in
                    ProjectRow(project: project)
                        .tag(SidebarRoute.project(project.id))
                        .contextMenu {
                            Button("重命名…") {
                                renameText = project.name
                                renamingID = project.id
                            }
                            Button("创建副本") { app.duplicate(project.id) }
                            Divider()
                            Button("删除", role: .destructive) { deletingID = project.id }
                        }
                }
            }
        }
        .listStyle(.sidebar)
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

    private var selection: Binding<SidebarRoute?> {
        Binding(
            get: { app.route },
            set: { if let v = $0 { app.route = v } }
        )
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
                Text(project.name).lineLimit(1)
                Text(project.updatedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if app.existingSession(project.id)?.isGenerating == true {
                ProgressView().controlSize(.small)
            }
        }
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
            case .loggedOut, .notInstalled, .failed: return true
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
