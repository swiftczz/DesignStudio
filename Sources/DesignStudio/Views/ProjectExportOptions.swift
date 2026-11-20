import SwiftUI

struct ProjectExportOptions: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID>
    @State private var includingHistory = true
    @State private var includingComments = true
    private let project: Project
    private let designSystem: DesignSystem?
    private let canvases: [DesignPage]
    private let hasHistory: Bool
    private let hasComments: Bool
    let onContinue: (ProjectArchive) -> Void

    init(project: Project, designSystem: DesignSystem?, onContinue: @escaping (ProjectArchive) -> Void) {
        let canvases = project.workingDocument.pages
        self.project = project
        self.designSystem = designSystem
        self.canvases = canvases
        self.hasHistory = !project.messages.isEmpty || !project.versions.isEmpty
        self.hasComments = !project.comments.isEmpty || project.messages.contains { !$0.comments.isEmpty }
        self.onContinue = onContinue
        _selected = State(initialValue: Set(canvases.map(\.id)))
    }

    private var allSelected: Bool { selected.count == canvases.count }

    var body: some View {
        let archive = try? ProjectArchive(project: project, designSystem: designSystem, includingHistory: includingHistory,
                                         canvasIDs: selected, includingComments: includingComments)
        VStack(alignment: .leading, spacing: 16) {
            Text("导出项目").font(.headline)

            canvasSelection

            if hasComments {
                Toggle("包含所选画布的批注", isOn: $includingComments)
                    .toggleStyle(.checkbox)
            }

            if hasHistory {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(allSelected ? "包含对话、参考附件和版本历史" : "包含所选画布的对话和参考附件",
                           isOn: $includingHistory)
                        .toggleStyle(.checkbox)
                }
            }

            if let archive {
                exportPreview(archive)
                if includingHistory && !allSelected {
                    Text("仅携带能确认归属的对话和参考附件。选择全部画布可附带完整版本历史。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("继续") {
                    guard let archive else { return }
                    onContinue(archive)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(archive == nil)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func exportPreview(_ archive: ProjectArchive) -> some View {
        let copy = archive.project
        let document = copy.workingDocument
        let attachments = copy.messages.reduce(0) { $0 + $1.attachments.count }
        let comments = Set((copy.comments + copy.messages.flatMap(\.comments)).map(\.id)).count
        return VStack(alignment: .leading, spacing: 5) {
            Text("导出内容").font(.subheadline.weight(.semibold))
            Text("\(document.pages.count) 张画布 · \(document.allArtboards.count) 张画板")
            Text("\(copy.messages.count) 条对话 · \(attachments) 个附件 · \(comments) 条批注 · \(copy.versions.count) 个版本")
            if let designSystem = archive.designSystem {
                Text("设计系统 · \(designSystem.name)").lineLimit(1)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 8))
    }

    private var canvasSelection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("画布").font(.subheadline.weight(.semibold))
                Spacer()
                if canvases.count > 1 {
                    Button(allSelected ? "取消全选" : "全选") {
                        selected = allSelected ? [] : Set(canvases.map(\.id))
                    }
                    .buttonStyle(.link)
                }
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(canvases) { canvas in
                        Toggle(isOn: Binding(
                            get: { selected.contains(canvas.id) },
                            set: { included in
                                if included { selected.insert(canvas.id) } else { selected.remove(canvas.id) }
                            }
                        )) {
                            HStack {
                                Text(canvas.displayName)
                                    .lineLimit(1)
                                    .help(canvas.displayName)
                                Spacer()
                                Text("\(canvas.artboards.count) 个画板")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(canvases.count == 1)
                        .frame(height: 30)
                    }
                }
                .padding(.trailing, canvases.count > 6 ? 12 : 0)
            }
            .frame(height: CGFloat(min(canvases.count, 6)) * 30)
        }
    }
}
