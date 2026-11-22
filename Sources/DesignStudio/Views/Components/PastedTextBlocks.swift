import SwiftUI

struct PastedTextBlocks: View {
    @Binding var blocks: [PastedTextBlock]
    @State private var editingBlock: PastedTextBlock?
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        if !blocks.isEmpty {
            ScrollView {
                cards
                    .frame(maxWidth: 180)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 16)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
            }
            .frame(height: min(contentHeight, 200))
            .scrollBounceBehavior(.basedOnSize)
            .sheet(item: $editingBlock) { block in
                PastedTextEditor(text: Binding(
                    get: { blocks.first(where: { $0.id == block.id })?.text ?? block.text },
                    set: { text in
                        if let index = blocks.firstIndex(where: { $0.id == block.id }) {
                            blocks[index].text = text
                        }
                    }
                ))
            }
        }
    }

    private var cards: some View {
        VStack(spacing: 6) {
            ForEach(blocks) { block in
                let preview = block.text.drop(while: \.isWhitespace).prefix(400)
                Text(verbatim: preview.isEmpty ? "空文本" : String(preview))
                    .lineLimit(6)
                    .lineSpacing(2)
                    .multilineTextAlignment(.leading)
                    .font(.callout)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.trailing, 28)
                    .overlay(alignment: .trailing) {
                        VStack(spacing: 0) {
                            action("移除文本", symbol: "xmark") {
                                blocks.removeAll { $0.id == block.id }
                            }
                            Spacer(minLength: 0)
                            action("编辑全文", symbol: "pencil") {
                                editingBlock = block
                            }
                        }
                    }
                    .padding(10)
                    .aspectRatio(5.0 / 4.0, contentMode: .fit)
                    .background(.primary.opacity(0.045), in: .rect(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.11)) }
            }
        }
    }

    private func action(_ title: LocalizedStringKey, symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(title)
        .help(title)
    }
}

private struct PastedTextEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        let statistics = PastedTextBlock.statistics(for: text)
        let kilobytes = Double(statistics.bytes) / 1_000
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑文本").font(.headline)

            TextEditor(text: $text)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(10)
                .background(.background, in: .rect(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.12)) }
                .accessibilityLabel("编辑粘贴的文本")

            HStack {
                Text("\(statistics.lines) 行 · \(kilobytes, format: .number.precision(.fractionLength(0...3))) KB")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("行数按原文换行统计，大小按 UTF-8 字节计算")
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(20)
        .frame(width: 660, height: 540)
        .onAppear { focused = true }
        .onExitCommand { dismiss() }
    }
}
