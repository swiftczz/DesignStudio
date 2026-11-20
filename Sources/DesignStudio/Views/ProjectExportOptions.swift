import SwiftUI

struct ProjectExportOptions: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID>
    @State private var includingHistory = true
    @State private var includingComments = true
    private let canvases: [DesignPage]
    private let hasHistory: Bool
    private let hasComments: Bool
    let onContinue: (Set<UUID>, Bool, Bool) -> Void

    init(project: Project, onContinue: @escaping (Set<UUID>, Bool, Bool) -> Void) {
        let canvases = project.workingDocument.pages
        self.canvases = canvases
        self.hasHistory = !project.messages.isEmpty || !project.versions.isEmpty
        self.hasComments = !project.comments.isEmpty
        self.onContinue = onContinue
        _selected = State(initialValue: Set(canvases.map(\.id)))
    }

    private var allSelected: Bool { selected.count == canvases.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导出项目").font(.headline)

            canvasSelection

            if hasComments {
                Toggle("包含所选画布的批注", isOn: $includingComments)
                    .toggleStyle(.checkbox)
            }

            if hasHistory {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("包含对话、参考附件和版本历史", isOn: Binding(
                        get: { allSelected && includingHistory },
                        set: { includingHistory = $0 }
                    ))
                    .toggleStyle(.checkbox)
                    .disabled(!allSelected)
                    if !allSelected {
                        Text("选择全部画布后可附带项目历史。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("继续") {
                    onContinue(selected, allSelected && includingHistory, hasComments && includingComments)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
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
