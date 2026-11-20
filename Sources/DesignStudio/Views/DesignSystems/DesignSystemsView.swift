import SwiftUI
import AppKit

struct DesignSystemsView: View {
    @Environment(AppModel.self) private var app
    @State private var selection: UUID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(app.designSystems) { ds in
                        DesignSystemRow(system: ds, isDefault: app.settings.defaultDesignSystemID == ds.id)
                            .tag(ds.id)
                    }
                }
                .listStyle(.inset)

                SidebarFooterBar {
                    HStack(spacing: 6) {
                        Button {
                            selection = app.addDesignSystem(.blank())
                        } label: { Image(systemName: "plus") }
                        .help("新建设计系统")

                        Button {
                            guard let id = selection, var copy = app.designSystem(for: id) else { return }
                            copy.id = UUID()
                            copy.name += " 副本"
                            copy.colors = copy.colors.map { ColorToken(name: $0.name, hex: $0.hex) }
                            selection = app.addDesignSystem(copy)
                        } label: { Image(systemName: "plus.square.on.square") }
                        .help("复制")
                        .disabled(selection == nil)

                        Button {
                            guard let id = selection else { return }
                            app.deleteDesignSystem(id)
                            selection = app.designSystems.first?.id
                        } label: { Image(systemName: "minus") }
                        .help("删除")
                        .disabled(selection == nil)

                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 8)
                }
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)

            Group {
                if let id = selection, app.designSystem(for: id) != nil {
                    DesignSystemEditor(system: app.designSystemBinding(id))
                        .id(id)
                } else {
                    ContentUnavailableView("选择或新建一个设计系统", systemImage: "paintpalette",
                                           description: Text("设计系统中的颜色、字体和规范会注入到每次生成中，保证产出风格一致。"))
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("设计系统")
        // 与主页一致：不显示标题栏的不透明背景（鼠标移到顶部时的白条），滚动时柔和渐隐
        .scrollEdgeEffectStyle(.soft, for: .top)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onAppear { if selection == nil { selection = app.designSystems.first?.id } }
    }
}

private struct DesignSystemRow: View {
    let system: DesignSystem
    let isDefault: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: -5) {
                ForEach(system.colors.prefix(4)) { c in
                    Circle()
                        .fill(Color(hex: c.hex))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1.2))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(system.name).lineLimit(1)
                    if isDefault {
                        Text("默认").font(.caption2).foregroundStyle(Theme.accent)
                    }
                }
                Text(system.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct DesignSystemEditor: View {
    @Environment(AppModel.self) private var app
    @Binding var system: DesignSystem

    private let fontSuggestions = [
        "Inter", "Fraunces", "Space Grotesk", "DM Sans", "DM Serif Display", "Playfair Display",
        "Manrope", "Plus Jakarta Sans", "IBM Plex Sans", "Noto Sans SC", "Noto Serif SC",
        "JetBrains Mono", "IBM Plex Mono", "Geist", "Geist Mono"
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Form {
                Section("基本信息") {
                    TextField("名称", text: $system.name)
                    TextField("气质描述", text: $system.summary, axis: .vertical)
                        .lineLimit(1...3)
                    Toggle("设为新项目的默认设计系统", isOn: Binding(
                        get: { app.settings.defaultDesignSystemID == system.id },
                        set: { on in
                            app.settings.defaultDesignSystemID = on ? system.id : nil
                            app.saveSettings()
                        }
                    ))
                }

                Section {
                    ForEach(system.colors) { token in
                        HStack {
                            ColorPicker("", selection: Binding(
                                get: { Color(hex: tokenBinding(token.id, \.hex).wrappedValue) },
                                set: { tokenBinding(token.id, \.hex).wrappedValue = $0.hexString }
                            ), supportsOpacity: false)
                            .labelsHidden()
                            TextField("名称", text: tokenBinding(token.id, \.name))
                            TextField("HEX", text: tokenBinding(token.id, \.hex))
                                .font(.body.monospaced())
                                .frame(width: 96)
                            Button {
                                let id = token.id
                                DispatchQueue.main.async { system.colors.removeAll { $0.id == id } }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button {
                        system.colors.append(ColorToken(name: "Color \(system.colors.count + 1)", hex: "#888888"))
                    } label: {
                        Label("添加颜色", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text("颜色")
                }

                Section("字体") {
                    fontField("标题字体", text: $system.headingFont)
                    fontField("正文字体", text: $system.bodyFont)
                    fontField("等宽字体", text: $system.monoFont)
                }

                Section("形状与间距") {
                    LabeledContent("圆角") {
                        HStack {
                            Slider(value: $system.cornerRadius, in: 0...32, step: 1)
                            Text("\(Int(system.cornerRadius)) px").monospacedDigit().frame(width: 52, alignment: .trailing)
                        }
                    }
                    LabeledContent("间距单位") {
                        Picker("", selection: $system.spacingUnit) {
                            ForEach([4.0, 6.0, 8.0, 10.0, 12.0], id: \.self) { Text("\(Int($0)) px").tag($0) }
                        }
                        .labelsHidden()
                    }
                }

                Section {
                    TextEditor(text: $system.guidelines)
                        .font(.body)
                        .frame(minHeight: 120)
                } header: {
                    Text("品牌规范")
                } footer: {
                    Text("用自然语言描述品牌的语气、排版习惯、禁止事项等，会原样交给 AI。")
                }
            }
            .formStyle(.grouped)

            DesignSystemPreview(system: system)
                .frame(width: 280)
                .padding(16)
        }
    }

    private func tokenBinding(_ id: UUID, _ keyPath: WritableKeyPath<ColorToken, String>) -> Binding<String> {
        Binding(
            get: { system.colors.first(where: { $0.id == id })?[keyPath: keyPath] ?? "" },
            set: { newValue in
                if let i = system.colors.firstIndex(where: { $0.id == id }) {
                    system.colors[i][keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func fontField(_ title: String, text: Binding<String>) -> some View {
        HStack {
            TextField(title, text: text)
            Menu {
                ForEach(fontSuggestions, id: \.self) { f in
                    Button(f) { text.wrappedValue = f }
                }
            } label: {
                Image(systemName: "textformat")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

/// 用 SwiftUI 粗略预览设计令牌
private struct DesignSystemPreview: View {
    let system: DesignSystem

    private func token(_ names: [String], fallback: String) -> Color {
        for n in names {
            if let t = system.colors.first(where: { $0.name.lowercased().contains(n) }) { return Color(hex: t.hex) }
        }
        return Color(hex: fallback)
    }

    private func contrast(_ label: String, foreground: Color, background: Color) -> some View {
        let ratio = (max(luminance(foreground), luminance(background)) + 0.05)
            / (min(luminance(foreground), luminance(background)) + 0.05)
        let value = ratio.formatted(.number.precision(.fractionLength(2))) + ":1"
        return LabeledContent(label) {
            Text(value).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label)对比度")
        .accessibilityValue(value)
    }

    private func luminance(_ color: Color) -> Double {
        let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .black
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
    }

    var body: some View {
        let bg = token(["background", "bg"], fallback: "#FFFFFF")
        let surface = token(["surface", "card"], fallback: "#F4F4F5")
        let text = token(["text", "foreground"], fallback: "#111111")
        let muted = token(["muted", "secondary"], fallback: "#777777")
        let primary = token(["primary", "brand"], fallback: "#3B82F6")
        let radius = system.cornerRadius

        VStack(alignment: .leading, spacing: 14) {
            Text("预览").font(.headline)
            VStack(alignment: .leading, spacing: 12) {
                Text("Aa 标题示例")
                    .font(.custom(system.headingFont, size: 26).weight(.semibold))
                    .foregroundStyle(text)
                Text("这是一段正文示例，用于预览正文字体与颜色搭配的效果。")
                    .font(.custom(system.bodyFont, size: 13))
                    .foregroundStyle(muted)
                VStack(alignment: .leading, spacing: 8) {
                    Text("卡片").font(.custom(system.bodyFont, size: 13).weight(.semibold)).foregroundStyle(text)
                    Text("const radius = \(Int(radius))").font(.custom(system.monoFont, size: 11)).foregroundStyle(muted)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(surface, in: .rect(cornerRadius: radius))
                HStack(spacing: 8) {
                    Text("主要按钮")
                        .font(.custom(system.bodyFont, size: 13).weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(primary, in: .rect(cornerRadius: radius))
                        .foregroundStyle(.white)
                    Text("次要")
                        .font(.custom(system.bodyFont, size: 13))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(primary))
                        .foregroundStyle(primary)
                }
            }
            .padding(18)
            .background(bg, in: .rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator))

            VStack(alignment: .leading, spacing: 5) {
                contrast("正文", foreground: text, background: bg)
                contrast("次要正文", foreground: muted, background: bg)
                contrast("主要按钮文字", foreground: .white, background: primary)
            }
            .font(.caption)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 8)], spacing: 8) {
                ForEach(system.colors) { c in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 8).fill(Color(hex: c.hex)).frame(height: 40)
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                        Text(c.name).font(.caption2).lineLimit(1)
                        Text(c.hex).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
    }
}
