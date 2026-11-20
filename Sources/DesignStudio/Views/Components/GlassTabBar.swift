import SwiftUI

// MARK: - Liquid Glass 标签栏

/// 玻璃质感的分段标签栏：选中块是一块可拖动的玻璃，按住在标签上左右滑动即可切换
struct GlassTabBar<Item: Hashable & Identifiable>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let items: [Item]
    let title: (Item) -> String
    @Binding var selection: Item

    /// 拖动中选中块的中心位置；nil 表示停靠在当前选中项
    @GestureState private var dragX: CGFloat?

    private let height: CGFloat = 30
    private let inset: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let count = CGFloat(max(items.count, 1))
            let segment = (geo.size.width - inset * 2) / count
            let index = CGFloat(items.firstIndex(of: selection) ?? 0)
            let restX = inset + index * segment
            let indicatorX = dragX.map { min(max($0 - segment / 2, inset), geo.size.width - inset - segment) } ?? restX

            GlassEffectContainer {
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.clear)
                        .frame(width: segment, height: height)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .offset(x: indicatorX)
                        .animation(dragX == nil && !reduceMotion ? WorkspaceMotion.panel : nil, value: selection)

                    HStack(spacing: 0) {
                        ForEach(items) { item in
                            Text(title(item))
                                .font(.callout.weight(item == selection ? .semibold : .regular))
                                .foregroundStyle(item == selection ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.primary))
                                .frame(width: segment, height: height)
                                .contentShape(.rect)
                        }
                    }
                    .padding(.horizontal, inset)
                    .allowsHitTesting(false)
                }
                .frame(width: geo.size.width, height: height + inset * 2)
                .glassEffect(.regular, in: .capsule)
            }
            .contentShape(.capsule)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragX) { value, position, transaction in
                        guard abs(value.translation.width) > 3 || position != nil else { return }
                        transaction.animation = nil
                        position = value.location.x
                    }
                    .onEnded { value in
                        select(at: value.location.x, segment: segment)
                    }
            )
        }
        .frame(height: height + inset * 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("标签页")
        .accessibilityValue(title(selection))
        .accessibilityAdjustableAction { direction in
            guard let i = items.firstIndex(of: selection) else { return }
            switch direction {
            case .increment: if i + 1 < items.count { selection = items[i + 1] }
            case .decrement: if i > 0 { selection = items[i - 1] }
            @unknown default: break
            }
        }
    }

    private func select(at x: CGFloat, segment: CGFloat) {
        guard !items.isEmpty, segment > 0 else { return }
        let i = min(max(Int((x - inset) / segment), 0), items.count - 1)
        if items[i] != selection { selection = items[i] }
    }
}

// MARK: - 可调参数行

struct TweakRow: View {
    let control: TweakControl
    @Binding var value: String

    var body: some View {
        switch control.type {
        case "color":
            ColorPicker(control.label, selection: Binding(
                get: { Color(hex: value) },
                set: { value = $0.hexString }
            ), supportsOpacity: false)

        case "range":
            let lower = control.min ?? 0
            let upper = max(control.max ?? 100, lower + 0.0001)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(control.label)
                    Spacer()
                    Text(value + (control.unit ?? ""))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(
                    get: { min(max(Double(value) ?? lower, lower), upper) },
                    set: { value = TweakControl.format(($0 * 100).rounded() / 100) }
                ), in: lower...upper)
            }

        case "select":
            Picker(control.label, selection: $value) {
                ForEach(control.options ?? [value], id: \.self) { Text($0).tag($0) }
            }

        default:
            TextField(control.label, text: $value)
        }
    }
}
