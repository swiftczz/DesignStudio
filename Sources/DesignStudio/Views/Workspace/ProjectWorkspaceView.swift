import SwiftUI
import AppKit

/// 项目工作区：左侧对话（可收起）+ 中间无限画布 + 右侧检查器
struct ProjectWorkspaceView: View {
    @Environment(AppModel.self) private var app
    @Bindable var session: ProjectSession
    /// 对话栏宽度：拖动分隔线调整，所有项目共用并记住
    @AppStorage("chatPanelWidth") private var chatWidth: Double = ChatPanelDivider.defaultWidth

    var body: some View {
        HStack(spacing: 0) {
            if session.showChat {
                ChatPanel(session: session)
                    .frame(width: ChatPanelDivider.clamp(chatWidth))
                    .transition(.move(edge: .leading).combined(with: .opacity))
                // 与画布一样延伸到窗口顶端，上下两端的分隔一致（标题栏背景是透明的）
                ChatPanelDivider(width: $chatWidth)
                    .ignoresSafeArea(.container, edges: .top)
            }
            InfiniteCanvasView(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 画板网页（WKWebView 是滚动视图）移到标题栏下方时，系统会画一条不透明的「滚动边缘效果」盖住画布
                .scrollEdgeEffectHidden(true, for: .top)
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
            VersionHistoryButton(session: session)
            ProjectSettingsButton(session: session)
            ExportMenu(session: session)
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
    @State private var shown = false

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Label("版本历史", systemImage: "clock.arrow.circlepath")
        }
        .help("版本历史")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VersionHistoryList(session: session)
                .frame(width: 340, height: 420)
        }
    }
}

private struct VersionHistoryList: View {
    @Bindable var session: ProjectSession

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
                List {
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
                            if !isCurrent {
                                Button("恢复") { session.restore(v) }
                                    .controlSize(.small)
                                    .disabled(!session.isEditable)
                            }
                        }
                        .padding(.vertical, 3)
                        .contextMenu {
                            Button("恢复到此版本") { session.restore(v) }
                            Divider()
                            Button("删除此版本", role: .destructive) { session.deleteVersion(v) }
                        }
                    }
                }
                .listStyle(.inset)
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

    var body: some View {
        Menu {
            if let project = session.project {
                Button("导出可编辑项目（.designstudio）…", systemImage: "doc.zipper") {
                    app.exportProject(project.id)
                }
                Divider()
            }
            if let project = session.project, let page = session.currentPage, !page.artboards.isEmpty {
                // 工具栏的导出针对整个画布；单个画板在画板标题栏右侧导出。导出的 HTML 都合并了画布共用样式
                let boards = page.composedArtboards
                let name = session.document.pages.count > 1 ? "\(project.name)-\(page.displayName)" : project.name
                Section("当前画布（\(boards.count) 个画板）") {
                    Button("导出为一个 HTML 文件…", systemImage: "doc.richtext") {
                        ExportService.exportCanvasHTML(boards, kind: session.kind, name: name)
                    }
                    Button("在浏览器中打开整个画布", systemImage: "safari") {
                        ExportService.openInBrowser(CanvasBundle.make(title: name, artboards: boards, kind: session.kind),
                                                    name: name)
                    }
                    Button("导出 ZIP（HTML + PNG）…", systemImage: "doc.zipper") {
                        let bundle = CanvasBundle.make(title: name, artboards: boards, kind: session.kind)
                        Task {
                            var files: [(name: String, html: String, png: Data?)] = []
                            for b in boards {
                                let png = await session.snapshot(b).flatMap { ImageUtil.pngData($0) }
                                files.append((b.name, b.html, png))
                            }
                            ExportService.exportCanvasZip(name: name, bundle: bundle, sharedCSS: page.sharedCSS, boards: files)
                        }
                    }
                    Button("导出全部 HTML…", systemImage: "folder") {
                        ExportService.exportAllHTML(boards, projectName: name)
                    }
                    Button("导出为一个 PDF（每个画板一页）…", systemImage: "doc.on.doc") {
                        Task {
                            var pages: [Data] = []
                            for b in boards { if let d = try? await session.pdf(b) { pages.append(d) } }
                            ExportService.exportMergedPDF(pages, name: name)
                        }
                    }
                }
                Divider()
                Button("交给 Claude Code 实现…", systemImage: "hammer") {
                    let exe = app.providers.first(where: { $0.kind == .claudeCode })?.cliExecutable ?? "claude"
                    ExportService.handoffToClaudeCode(project: project, artboards: session.document.composedArtboards,
                                                      designSystem: app.designSystem(for: project.designSystemID),
                                                      executable: exe)
                }
            } else {
                Text("还没有可导出的设计")
            }
        } label: {
            Label("导出", systemImage: "square.and.arrow.up")
        }
        .help("导出整个画布与交接")
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
