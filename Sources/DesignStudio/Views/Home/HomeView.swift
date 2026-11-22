import SwiftUI
import AppKit

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var prompt = ""
    @State private var kind: ProjectKind = .prototype
    @State private var designSystemID: UUID?
    @State private var modelChoice = ModelChoice()
    @State private var attachments: [ChatAttachment] = []
    @State private var pastedText: [PastedTextBlock] = []
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
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !attachments.isEmpty {
                AttachmentStrip(attachments: $attachments, provider: app.provider(for: modelChoice.providerID)?.kind)
            }

            PastedTextBlocks(blocks: $pastedText)

            TextField(kind.placeholder, text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .lineLimit(3...10)
                .focused($promptFocused)
                .focusedValue(\.composerAttachments, $attachments)
                .focusedValue(\.composerTextBlocks, $pastedText)
                .onSubmit(start)
                .padding(.horizontal, 6)
                .padding(.top, 4)

            HStack(spacing: 2) {
                projectKindMenu
                AttachButton { attachments += $0 }
                DesignSystemMenu(selection: $designSystemID, compact: true)
                ProviderMenu(selection: $modelChoice)
                Spacer(minLength: 8)
                Button(action: start) {
                    Label("开始设计", systemImage: "arrow.up")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(SendButtonStyle(wide: true))
                .disabled(prompt.trimmed.isEmpty && attachments.isEmpty && !pastedText.contains(where: \.hasText))
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .composerCard(focused: promptFocused, cornerRadius: 22)
    }

    private var projectKindMenu: some View {
        Menu {
            ForEach(ProjectKind.homeKinds) { option in
                Toggle(option.title, isOn: Binding(
                    get: { kind == option },
                    set: { _ in kind = option }
                ))
            }
        } label: {
            ComposerChipLabel {
                Image(systemName: kind.symbol).accessibilityHidden(true)
                Text(kind.title)
            }
        }
        .composerMenuStyle()
        .accessibilityLabel("项目类型")
        .accessibilityValue(kind.title)
    }

    @ViewBuilder private var recentProjects: some View {
        if !app.projects.isEmpty {
            let cardLimit = 4
            let spacing: CGFloat = 14
            let columns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: spacing), count: cardLimit)
            VStack(alignment: .leading, spacing: 12) {
                Text("最近的项目").font(.headline)
                LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
                    ForEach(app.sortedProjects.prefix(cardLimit)) { project in
                        ProjectCard(project: project)
                    }
                }
            }
        }
    }

    private func start() {
        let text = PastedTextBlock.message(prompt, blocks: pastedText)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        do {
            let files = try AttachmentImporter.includingPastedDocuments(in: text, attachments: attachments)
            app.createProject(prompt: prompt.trimmed, kind: kind, designSystemID: designSystemID,
                              model: modelChoice, attachments: files, pastedText: pastedText)
        } catch {
            ExportService.presentError("无法读取参考文件", error)
            return
        }
        prompt = ""
        attachments = []
        pastedText = []
    }
}

struct ProjectCard: View {
    @Environment(AppModel.self) private var app
    let project: Project
    @State private var hovering = false

    private var projectMetadata: String {
        let count = project.workingDocument.allArtboards.count
        let details = "\(project.kind.title) · \(count) 个画板"
        return project.currentVersion.map { "\(details) · v\($0.number)" } ?? details
    }

    var body: some View {
        Button {
            app.route = .project(project.id)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                ProjectThumbnail(project: project)
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.displayName).font(.headline).lineLimit(1)
                    Text(projectMetadata)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(project.updatedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .padding(10)
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
