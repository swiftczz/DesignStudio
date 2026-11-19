import SwiftUI
import AppKit

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var prompt = ""
    /// 主页只提供交互设计
    private let kind: ProjectKind = .prototype
    @State private var designSystemID: UUID?
    @State private var modelChoice = ModelChoice()
    @State private var attachments: [ChatAttachment] = []
    @State private var didLoadDefaults = false
    @FocusState private var promptFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header
                composer
                recentProjects
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 36)
            .frame(maxWidth: 1040)
            .frame(maxWidth: .infinity)
        }
        // 鼠标移到顶部时系统会显示不透明的标题栏背景（白条）：隐藏它，滚动时用柔和的边缘渐隐
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(CanvasBackground())
        .navigationTitle("新建设计")
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onAppear {
            guard !didLoadDefaults else { return }
            didLoadDefaults = true
            designSystemID = app.settings.defaultDesignSystemID
            modelChoice = ModelChoice(providerID: app.defaultProvider?.id)
            promptFocused = true
        }
        .dropDestination(for: URL.self) { urls, _ in
            let picked = AttachmentImporter.load(urls)
            attachments += picked
            return !picked.isEmpty
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("今天想设计什么？")
                .font(.system(size: 36, weight: .bold))
            Text("描述你的想法，AI 会在画布上生成可交互的设计稿。之后可以继续对话修改，也可以直接在画布上选中元素调整。")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("导入项目", systemImage: "square.and.arrow.down", action: app.chooseProjectToImport)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !attachments.isEmpty {
                AttachmentStrip(attachments: $attachments)
            }

            TextField(kind.placeholder, text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .lineLimit(3...10)
                .focused($promptFocused)
                .focusedValue(\.composerAttachments, $attachments)
                .onSubmit(start)
                .padding(.horizontal, 6)
                .padding(.top, 4)

            HStack(spacing: 2) {
                AttachButton { attachments += $0 }
                DesignSystemMenu(selection: $designSystemID, compact: true)
                ProviderMenu(selection: $modelChoice)
                Spacer(minLength: 8)
                Button(action: start) {
                    Label("开始设计", systemImage: "arrow.up")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(SendButtonStyle(wide: true))
                .disabled(prompt.trimmed.isEmpty && attachments.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .composerCard(focused: promptFocused, cornerRadius: 22)
    }

    @ViewBuilder private var recentProjects: some View {
        if !app.projects.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("最近的项目").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 18)], spacing: 18) {
                    ForEach(app.sortedProjects.prefix(12)) { project in
                        ProjectCard(project: project)
                    }
                }
            }
        }
    }

    private func start() {
        let text = prompt.trimmed
        guard !text.isEmpty || !attachments.isEmpty else { return }
        do {
            let files = try AttachmentImporter.includingPastedDocuments(in: text, attachments: attachments)
            app.createProject(prompt: text, kind: kind, designSystemID: designSystemID,
                              model: modelChoice, attachments: files)
        } catch {
            ExportService.presentError("无法读取参考文件", error)
            return
        }
        prompt = ""
        attachments = []
    }
}

struct ProjectCard: View {
    @Environment(AppModel.self) private var app
    let project: Project
    @State private var hovering = false

    var body: some View {
        Button {
            app.route = .project(project.id)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                ProjectThumbnail(project: project)
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.displayName).font(.headline).lineLimit(1)
                    Text(project.updatedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .padding(12)
            }
            .background(.background, in: .rect(cornerRadius: 16))
            .clipShape(.rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator))
            .shadow(color: .black.opacity(hovering ? 0.12 : 0.05), radius: hovering ? 14 : 6, y: hovering ? 6 : 2)
            .scaleEffect(hovering ? 1.015 : 1)
            .animation(.snappy(duration: 0.2), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            RegenerateProjectTitleButton(projectID: project.id)
            Button("创建副本") { app.duplicate(project.id) }
            Button("导出项目") { app.exportProject(project.id) }
            Button("删除", role: .destructive) { app.deleteProject(project.id) }
        }
    }
}
