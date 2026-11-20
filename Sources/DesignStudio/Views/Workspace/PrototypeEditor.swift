import SwiftUI

struct PrototypeEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: ProjectSession
    @State private var destination: UUID?
    @State private var previewHTML: String?
    @State private var isLinking = false
    @State private var failed = false

    var body: some View {
        if let previewHTML {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button("返回设置", systemImage: "chevron.left") { self.previewHTML = nil }
                    Spacer()
                    Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                PreviewWebView(html: previewHTML, zoom: 1)
                    .clipShape(.rect(cornerRadius: 10))
            }
            .padding(16)
            .frame(minWidth: 780, minHeight: 560)
        } else if let page = session.document.page(session.currentPageID), let first = page.artboards.first {
            editor(page, first: first)
        }
    }

    private func editor(_ page: DesignPage, first: Artboard) -> some View {
        let boards = page.artboards
        let source = session.selection.flatMap { selection in boards.first { $0.id == selection.artboardID } }
        let element = session.selection?.elementID == session.selectedProps?.id ? session.selectedProps : nil
        let links = page.prototype?.links ?? []
        let playable = Set(page.prototype?.playableLinks(in: boards).map(\.id) ?? [])
        return VStack(alignment: .leading, spacing: 14) {
            Text("原型").font(.headline)
            Picker("起始画板", selection: Binding(
                get: { page.prototype?.startArtboardID.flatMap { id in boards.first { $0.id == id }?.id } ?? first.id },
                set: { session.setPrototypeStart($0, on: page.id) }
            )) {
                ForEach(boards) { Text($0.name).tag($0.id) }
            }
            .disabled(session.isGenerating)
            Toggle("在画布显示连线", isOn: $session.showsPrototypeLinks)
            Divider()
            if let source, let element, !["html", "head", "body"].contains(element.tag) {
                Text("\(source.name) · \(ProjectSession.displayName(element))").lineLimit(2)
                HStack {
                    Picker("点击后跳转到", selection: $destination) {
                        Text("选择目标画板").tag(UUID?.none)
                        ForEach(boards.filter { $0.id != source.id }) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Button(element.prototypeLinkID == nil ? "添加连线" : "保存连线") {
                        guard let destination else { return }
                        isLinking = true
                        Task {
                            failed = !(await session.linkSelectedElement(to: destination, on: page.id))
                            isLinking = false
                        }
                    }
                    .disabled(destination == nil || isLinking || session.isGenerating)
                }
                if failed { Text("无法连接这个元素，请重新选中后再试。").foregroundStyle(.secondary) }
            } else {
                Text("在画布选中按钮、链接或其他元素，即可设置点击后跳转。")
                    .foregroundStyle(.secondary)
            }
            if !links.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(links) { link in
                            HStack {
                                Text("\(boards.first { $0.id == link.sourceArtboardID }?.name ?? "源画板") · \(link.elementName)")
                                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                Text(boards.first { $0.id == link.destinationArtboardID }?.name ?? "目标画板")
                                if !playable.contains(link.id) { Text("源元素不可用").foregroundStyle(.secondary) }
                                Spacer()
                                Button("移除连线", systemImage: "xmark.circle") {
                                    session.deletePrototypeLink(link.id, on: page.id)
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .disabled(session.isGenerating)
                            }
                            .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 160)
            }
            HStack {
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("演示原型", systemImage: "play.fill") {
                    previewHTML = CanvasBundle.make(title: page.displayName, artboards: page.composedArtboards,
                                                     kind: session.kind, prototype: page.prototype ?? CanvasPrototype())
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 470)
        .onAppear {
            destination = links.first { $0.id == element?.prototypeLinkID }?.destinationArtboardID
        }
    }
}
