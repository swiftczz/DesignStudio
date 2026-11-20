import SwiftUI
import AppKit

/// 项目工作区：左侧对话（可收起）+ 中间无限画布 + 右侧检查器
struct ProjectWorkspaceView: View {
    @Environment(AppModel.self) private var app
    @Bindable var session: ProjectSession
    @State private var batchExport: CanvasExportJob?
    @State private var comparedVersion: DesignVersion?
    @State private var showsComponents = false
    @State private var loadsWebContent = false
    /// 对话栏宽度：拖动分隔线调整，所有项目共用并记住
    @AppStorage("chatPanelWidth") private var chatWidth: Double = ChatPanelDivider.defaultWidth

    var body: some View {
        GeometryReader { geometry in
            let stacked = geometry.size.width < 700
            let layout = stacked ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
            layout {
                if session.showChat && !stacked {
                    let availableWidth = max(ChatPanelDivider.minWidth, geometry.size.width - 410)
                    let panelWidth = min(ChatPanelDivider.clamp(chatWidth), availableWidth)
                    chat(width: panelWidth)
                    ChatPanelDivider(width: Binding(
                        get: { panelWidth },
                        set: { chatWidth = min($0, availableWidth) }
                    ))
                        .ignoresSafeArea(.container, edges: .top)
                }
                InfiniteCanvasView(session: session, loadsWebContent: loadsWebContent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scrollEdgeEffectHidden(true, for: .top)
                if session.showChat && stacked {
                    Divider()
                    chat(height: min(270, geometry.size.height * 0.37))
                }
            }
        }
        .task {
            // Let the selection, title and workspace draw before installing WebKit views.
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            loadsWebContent = true
        }
        .sheet(item: $batchExport) { job in
            CanvasExportSheet(job: job)
        }
        .sheet(item: $comparedVersion) { version in
            VersionArtboardComparison(session: session, version: version)
        }
        .sheet(isPresented: $showsComponents) {
            ComponentLibraryEditor(session: session)
        }
        .inspector(isPresented: $session.showInspector) {
            InspectorView(session: session)
                .inspectorColumnWidth(min: 280, ideal: 320, max: 460)
        }
        // 全屏查看画板时隐藏标题和工具栏按钮（保留红绿灯），让窗口顶部与背景一致
        .navigationTitle(isFullScreen ? "" : (session.project?.displayName ?? ""))
        .navigationSubtitle(isFullScreen ? "" : subtitle)
        .toolbar {
            if !isFullScreen { toolbarContent }
        }
        // 标题栏透明：画布一直延伸到窗口顶端
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    private func chat(width: CGFloat? = nil, height: CGFloat? = nil) -> some View {
        ChatPanel(session: session, loadsHistory: loadsWebContent)
            .frame(width: width, height: height)
    }

    private var isFullScreen: Bool { session.isFullScreen }

    private var subtitle: String {
        guard let p = session.project else { return "" }
        var parts = [p.kind.title]
        let count = session.document.allArtboards.count
        if count > 0 { parts.append("\(count) 个画板") }
        if let v = p.currentVersion { parts.append("v\(v.number)") }
        if let ds = app.designSystem(for: p.designSystemID) { parts.append(ds.name) }
        return parts.joined(separator: " · ")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                session.undo()
            } label: {
                Label("撤销", systemImage: "arrow.uturn.backward")
            }
            .help("撤销画布上的修改（⌘Z）")
            .disabled(!session.canUndo || !session.isEditable)

            Button {
                session.redo()
            } label: {
                Label("重做", systemImage: "arrow.uturn.forward")
            }
            .help("重做（⇧⌘Z）")
            .disabled(!session.canRedo || !session.isEditable)
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItemGroup(placement: .primaryAction) {
            VersionHistoryButton(session: session) { comparedVersion = $0 }
            ProjectSettingsButton(session: session)
            Button { showsComponents = true } label: {
                Label("组件", systemImage: "square.on.square")
            }
            .help("创建、插入和更新项目组件")
            ExportMenu(session: session) { batchExport = $0 }
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            Button {
                session.showInspector.toggle()
            } label: {
                Label("检查器", systemImage: "sidebar.trailing")
            }
            .help("图层 / 属性 / 代码 / 调整")
        }
    }
}

// MARK: - 版本历史

private struct VersionHistoryButton: View {
    @Bindable var session: ProjectSession
    let onCompare: (DesignVersion) -> Void
    @State private var shown = false

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Label("版本历史", systemImage: "clock.arrow.circlepath")
        }
        .help("版本历史")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VersionHistoryList(session: session) { version in
                shown = false
                DispatchQueue.main.async { onCompare(version) }
            }
                .frame(width: 340, height: 420)
        }
    }
}

private struct VersionHistoryList: View {
    @Bindable var session: ProjectSession
    let onCompare: (DesignVersion) -> Void

    var body: some View {
        let versions = (session.project?.versions ?? []).reversed()
        VStack(spacing: 0) {
            HStack {
                Text("版本历史").font(.headline)
                Spacer()
                Button("保存当前为版本") { session.saveVersion(summary: "手动保存") }
                    .controlSize(.small)
                    .disabled(!session.hasDesign)
            }
            .padding(12)
            Divider()
            if versions.isEmpty {
                ContentUnavailableView("还没有版本", systemImage: "clock",
                                       description: Text("每次 AI 生成都会保存一个版本，可随时恢复。"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(versions)) { v in
                            let isCurrent = session.project?.currentVersionID == v.id
                            HStack(alignment: .top, spacing: 10) {
                                Text("v\(v.number)")
                                    .font(.callout.monospacedDigit().weight(.semibold))
                                    .frame(width: 36, height: 24)
                                    .background(isCurrent ? Theme.accent : Color.secondary.opacity(0.15), in: .rect(cornerRadius: 6))
                                    .foregroundStyle(isCurrent ? .white : .primary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(v.summary).lineLimit(2).font(.callout)
                                    HStack(spacing: 6) {
                                        Text(v.createdAt, format: .relative(presentation: .named))
                                        Text("· \(v.document?.allArtboards.count ?? 1) 个画板")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                VStack(alignment: .trailing, spacing: 5) {
                                    Button("画板变更") { onCompare(v) }
                                        .buttonStyle(.borderless)
                                    if !isCurrent {
                                        Button("恢复") { session.restore(v) }
                                            .buttonStyle(.borderless)
                                            .disabled(!session.isEditable)
                                    }
                                }
                                .controlSize(.small)
                            }
                            .padding(.vertical, 8)
                            .contextMenu {
                                Button("查看画板变更") { onCompare(v) }
                                Button("恢复到此版本") { session.restore(v) }
                                Divider()
                                Button("删除此版本", role: .destructive) { session.deleteVersion(v) }
                            }
                            Divider()
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
    }
}

// MARK: - 项目设置

private struct ProjectSettingsButton: View {
    @Environment(AppModel.self) private var app
    @Bindable var session: ProjectSession
    @State private var shown = false

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Label("项目设置", systemImage: "info.circle")
        }
        .help("项目名称、类型与设计系统")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            if let project = session.project {
                Form {
                    TextField("名称", text: Binding(
                        get: { project.displayName },
                        set: { app.rename(project.id, to: $0) }
                    ))
                    Picker("类型", selection: Binding(
                        get: { project.kind },
                        set: { newKind in app.updateProject(project.id) { $0.kind = newKind } }
                    )) {
                        ForEach(ProjectKind.homeKinds) { k in Label(k.title, systemImage: k.symbol).tag(k) }
                        if !ProjectKind.homeKinds.contains(project.kind) {
                            Label(project.kind.title, systemImage: project.kind.symbol).tag(project.kind)
                        }
                    }
                    Picker("设计系统", selection: Binding(
                        get: { project.designSystemID },
                        set: { newID in app.updateProject(project.id) { $0.designSystemID = newID } }
                    )) {
                        Text("无").tag(UUID?.none)
                        ForEach(app.designSystems) { ds in Text(ds.name).tag(UUID?.some(ds.id)) }
                    }
                    LabeledContent("版本数", value: "\(project.versions.count)")
                    if let u = session.lastUsage {
                        LabeledContent("上次用量", value: "输入 \(u.input) · 输出 \(u.output) tokens")
                    }
                    Button("在 Finder 中显示项目文件") {
                        NSWorkspace.shared.activateFileViewerSelecting([app.persistence.projectDirectory(project.id)])
                    }
                }
                .formStyle(.grouped)
                .frame(width: 360)
            }
        }
    }
}

// MARK: - 导出

struct ExportMenu: View {
    @Environment(AppModel.self) private var app
    let session: ProjectSession
    let startExport: (CanvasExportJob) -> Void

    var body: some View {
        Menu {
            if let project = session.project {
                Button("导出项目", systemImage: "doc.zipper") {
                    app.exportProject(project.id)
                }
                Divider()
            }
            if let project = session.project, let page = session.document.page(session.currentPageID), !page.artboards.isEmpty {
                // 工具栏的导出针对整个画布；单个画板在画板标题栏右侧导出。导出的 HTML 都合并了画布共用样式
                let boards = page.composedArtboards
                let name = session.document.pages.count > 1 ? "\(project.displayName)-\(page.displayName)" : project.displayName
                Section("当前画布（\(boards.count) 个画板）") {
                    Button("导出一个 HTML", systemImage: "doc.richtext") {
                        ExportService.exportCanvasHTML(boards, kind: session.kind, name: name)
                    }
                    Button("导出分开的 HTML", systemImage: "folder") {
                        ExportService.exportAllHTML(boards, projectName: name)
                    }
                    Button("导出一个 PDF", systemImage: "doc.on.doc") {
                        startExport(CanvasExportJob(name: name, page: page, kind: session.kind, format: .pdf))
                    }
                    Button("导出 ZIP（HTML + PNG + PDF）", systemImage: "doc.zipper") {
                        startExport(CanvasExportJob(name: name, page: page, kind: session.kind, format: .zip))
                    }
                    Button("在浏览器中打开整个画布", systemImage: "safari") {
                        ExportService.openInBrowser(CanvasBundle.make(title: name, artboards: boards, kind: session.kind),
                                                    name: name)
                    }
                }
                Divider()
                ForEach(ExportService.HandoffTool.allCases, id: \.self) { tool in
                    Button("交给 \(tool.title) 实现", systemImage: "hammer") {
                        let exe = app.providers.first(where: { $0.kind == tool.kind })?.cliExecutable
                            ?? tool.kind.defaultExecutable
                        ExportService.handoff(project: project, artboards: session.document.composedArtboards,
                                              designSystem: app.designSystem(for: project.designSystemID),
                                              tool: tool, executable: exe)
                    }
                }
            } else {
                Text("还没有可导出的设计")
            }
        } label: {
            Label("导出", systemImage: "square.and.arrow.up")
        }
        .accessibilityLabel("导出")
        .help("导出整个画布与交接")
    }
}

private struct CanvasExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let job: CanvasExportJob
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(job.format.title).font(.headline)
            ProgressView(value: Double(job.completed.count), total: Double(job.boards.count)) {
                if let index = job.renderingIndex {
                    Text("正在渲染「\(job.boards[index].name)」")
                } else {
                    Text("已准备 \(job.completed.count) / \(job.boards.count) 张画板")
                }
            }
            if !job.failures.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(job.failures.keys.sorted(), id: \.self) { index in
                            Label("\(job.boards[index].name) · \(job.failures[index] ?? "")",
                                  systemImage: "exclamationmark.triangle")
                                .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: min(CGFloat(job.failures.count) * 34, 130))
            }
            if let saveError { Text(saveError).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(job.isRunning ? "取消导出" : "关闭", role: .cancel) {
                    job.cancel()
                    dismiss()
                }
                .disabled(isSaving)
                if job.isComplete {
                    Button(isSaving ? "正在保存…" : "保存", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isSaving)
                } else if !job.isRunning {
                    Button("重试失败的画板", action: job.render)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { job.render() }
        .onDisappear { job.cancel() }
        .interactiveDismissDisabled(isSaving)
    }

    private func save() {
        guard let url = ExportService.savePanel(name: job.name, type: job.format == .pdf ? .pdf : .zip) else { return }
        isSaving = true
        saveError = nil
        Task {
            defer { isSaving = false }
            do {
                try await job.save(to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                dismiss()
            } catch {
                saveError = error.localizedDescription
            }
        }
    }
}

/// 对话栏右侧的分隔线：左右拖动调整对话栏宽度，双击恢复默认宽度。
/// 可见的仍是 1pt 的系统分隔线，两侧各留出几 pt 的透明拖动区域
struct ChatPanelDivider: View {
    @Binding var width: Double
    @State private var dragStart: Double?
    @State private var hovering = false

    static let defaultWidth: Double = 360
    static let minWidth: Double = 300
    static let maxWidth: Double = 640

    static func clamp(_ w: Double) -> Double { min(max(w, minWidth), maxWidth) }

    var body: some View {
        Divider()
            .overlay {
                Rectangle()
                    .fill(Color.primary.opacity(hovering || dragStart != nil ? 0.18 : 0))
                    .frame(width: 2)
                    .animation(.easeOut(duration: 0.15).delay(hovering ? 0.25 : 0), value: hovering)
            }
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(.rect)
                    .pointerStyle(.columnResize)
                    .onHover { hovering = $0 }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { v in
                                let start = dragStart ?? Self.clamp(width)
                                if dragStart == nil { dragStart = start }
                                width = Self.clamp(start + v.translation.width)
                            }
                            .onEnded { _ in dragStart = nil }
                    )
                    // 与拖动手势并存：单独的 onTapGesture 会被拖动手势吞掉
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        withAnimation(.snappy(duration: 0.25)) { width = Self.defaultWidth }
                    })
                    .help("拖动调整对话栏宽度，双击恢复默认")
            }
            .zIndex(1)
    }
}
