import SwiftUI

struct VersionArtboardComparison: View {
    @Environment(\.dismiss) private var dismiss
    let session: ProjectSession
    let version: DesignVersion
    @State private var comparesToCurrent = false
    @State private var selectedID: UUID?

    var body: some View {
        let earlier = (session.project?.versions ?? []).prefix { $0.id != version.id }.last
        let snapshot = session.versionDocument(version)
        let changes = comparesToCurrent
            ? VersionArtboardChange.compare(snapshot, to: session.document)
            : VersionArtboardChange.compare(earlier.map(session.versionDocument), to: snapshot)
        let selected = changes.first { $0.id == selectedID } ?? changes.first
        let direct = changes.filter { !$0.inheritsChangedSharedStyles }
        let shared = Dictionary(grouping: changes.filter(\.inheritsChangedSharedStyles), by: \.canvasID)
            .values.sorted { ($0.first?.canvasName ?? "").localizedStandardCompare($1.first?.canvasName ?? "") == .orderedAscending }

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("版本 \(version.number) · 画板变更").font(.headline)
                Spacer()
                Picker("比较对象", selection: $comparesToCurrent) {
                    Text("上一版本").tag(false)
                    Text("当前设计").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            if let selected {
                HStack(spacing: 14) {
                    List(selection: Binding(get: { selected.id }, set: { selectedID = $0 })) {
                        ForEach(direct) { change in changeRow(change) }
                        ForEach(shared, id: \.first?.canvasID) { group in
                            if let canvas = group.first?.canvasName {
                                Section("共享样式 · \(canvas)（\(group.count) 张）") {
                                    ForEach(group) { change in changeRow(change) }
                                }
                            }
                        }
                    }
                    .frame(width: 190)
                    Divider()
                    preview(selected.before,
                            title: comparesToCurrent ? "版本 \(version.number)" : earlier.map { "版本 \($0.number)" } ?? "初始状态",
                            restoreVersion: comparesToCurrent ? version.number : earlier?.number)
                    preview(selected.after,
                            title: comparesToCurrent ? "当前设计" : "版本 \(version.number)",
                            restoreVersion: comparesToCurrent ? nil : version.number)
                }
            } else {
                ContentUnavailableView("画板没有变化", systemImage: "rectangle.on.rectangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(minWidth: 860, idealWidth: 980, minHeight: 500, idealHeight: 600)
    }

    private func changeRow(_ change: VersionArtboardChange) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(change.board.name).lineLimit(1)
            Text(change.inheritsChangedSharedStyles ? change.action : "\(change.action) · \(change.canvasName)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 3)
        .tag(change.id)
    }

    private func preview(_ snapshot: VersionArtboardSnapshot?, title: String, restoreVersion: Int?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            if let snapshot {
                let board = snapshot.board
                let html = snapshot.html
                GeometryReader { geometry in
                    let zoom = min(1, geometry.size.width / board.width, geometry.size.height / board.height)
                    PreviewWebView(html: html, zoom: zoom)
                        .frame(width: board.width * zoom, height: board.height * zoom)
                        .background(.white)
                        .allowsHitTesting(false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Text("\(Int(board.width)) × \(Int(board.height))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                ContentUnavailableView("此时没有这张画板", systemImage: "rectangle.dashed")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let snapshot, let restoreVersion {
                Button("恢复此画板到版本 \(restoreVersion)") {
                    session.restoreArtboard(snapshot)
                    dismiss()
                }
                .disabled(!session.canRestoreVersion)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
    }
}
