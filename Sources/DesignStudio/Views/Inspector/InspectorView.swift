import SwiftUI

/// 右侧检查器：属性（图层树 + 属性）/ 代码 / 调整
struct InspectorView: View {
    @Bindable var session: ProjectSession
    @State private var tab: Tab = .properties

    enum Tab: String, CaseIterable, Identifiable {
        case properties = "属性"
        case code = "代码"
        case tweaks = "调整"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            GlassTabBar(items: Tab.allCases, title: \.rawValue, selection: $tab)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()
            Group {
                switch tab {
                case .properties:
                    // 不用 VSplitView：它在下方属性面板内容变化、分栏重新分配高度时，
                    // 偶尔不会重新布局里面的 SwiftUI 内容，图层树保持旧高度被居中，顶部出现大片空白
                    LayersPropertiesSplit(session: session)
                case .code:
                    CodeView(session: session)
                case .tweaks:
                    TweaksView(session: session)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - 图层树 / 属性 上下分栏

private struct LayersPropertiesSplit: View {
    let session: ProjectSession
    /// 图层树的高度（拖动中间的分隔条调整）
    @State private var layersHeight: CGFloat = 300
    @State private var dragStart: CGFloat?

    private let minLayers: CGFloat = 120
    private let minProperties: CGFloat = 220

    var body: some View {
        GeometryReader { geo in
            let maxLayers = max(minLayers, geo.size.height - minProperties)
            let height = min(max(layersHeight, minLayers), maxLayers)
            VStack(spacing: 0) {
                LayersView(session: session)
                    .frame(maxWidth: .infinity)
                    .frame(height: height, alignment: .top)
                    .clipped()

                // 分隔条：线居中，上下各留 4pt 的拖动热区
                ZStack {
                    Color.clear
                    Divider()
                }
                .frame(maxWidth: .infinity)
                .frame(height: 9)
                .contentShape(.rect)
                .pointerStyle(.rowResize)
                .gesture(
                    // 用全局坐标：分隔条本身随拖动移动，局部坐标会抖动
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { v in
                            if dragStart == nil { dragStart = height }
                            layersHeight = min(max((dragStart ?? height) + v.translation.height, minLayers), maxLayers)
                        }
                        .onEnded { _ in dragStart = nil }
                )

                PropertiesView(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }
}

// MARK: - 图层树

private struct LayerItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let target: CanvasSelection?
    let dimmed: Bool
    var children: [LayerItem]?
}

struct LayersView: View {
    @Bindable var session: ProjectSession

    var body: some View {
        let items = buildItems()
        if items.isEmpty {
            ContentUnavailableView("还没有画板", systemImage: "square.3.layers.3d",
                                   description: Text("生成设计或用画板工具（F）创建后，这里会显示整个作品的结构。"))
        } else {
            // 自己排布的树：系统 List（NSOutlineView）在「展开祖先 + 滚动到选中行」同时发生时，
            // 偶尔会滚过内容顶部，导致树整体下移、上方留出大片空白
            let rows = flatten(items)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(rows) { r in
                            LayerRowView(item: r.item, depth: r.depth,
                                         isExpanded: isExpanded(r.item.id),
                                         isSelected: r.item.id == selectedID,
                                         session: session,
                                         toggle: { setExpanded(r.item.id, !isExpanded(r.item.id)) })
                                .id(r.item.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .onChange(of: selectedID) { _, id in
                    guard let id else { return }
                    // 等祖先展开后的布局完成再滚动；不指定锚点 = 只滚动到刚好可见，不会越过顶部
                    DispatchQueue.main.async {
                        withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(id) }
                    }
                }
            }
        }
    }

    /// 当前选中对应的图层 ID
    private var selectedID: String? {
        guard let sel = session.selection else { return nil }
        if let e = sel.elementID { return LayerID.element(sel.artboardID, e) }
        return LayerID.artboard(sel.artboardID)
    }

    private struct FlatRow: Identifiable {
        let item: LayerItem
        let depth: Int
        var id: String { item.id }
    }

    /// 按展开状态把树展平成行
    private func flatten(_ items: [LayerItem], depth: Int = 0) -> [FlatRow] {
        var out: [FlatRow] = []
        for item in items {
            out.append(FlatRow(item: item, depth: depth))
            if let children = item.children, !children.isEmpty, isExpanded(item.id) {
                out += flatten(children, depth: depth + 1)
            }
        }
        return out
    }

    /// 画布默认展开（记录「closed:」表示收起），画板 / 元素默认收起
    private func isExpanded(_ id: String) -> Bool {
        session.expandedLayers.contains(id) || id.hasPrefix("p:") && !session.expandedLayers.contains("closed:" + id)
    }

    private func setExpanded(_ id: String, _ open: Bool) {
        if id.hasPrefix("p:") {
            if open { session.expandedLayers.remove("closed:" + id) } else { session.expandedLayers.insert("closed:" + id) }
        } else if open {
            session.expandedLayers.insert(id)
        } else {
            session.expandedLayers.remove(id)
        }
    }

    static func target(for id: String) -> CanvasSelection? {
        let parts = id.split(separator: ":")
        guard parts.count >= 2, let uuid = UUID(uuidString: String(parts[1])) else { return nil }
        switch parts[0] {
        case "a": return CanvasSelection(artboardID: uuid, elementID: nil)
        case "e": return parts.count == 3 ? CanvasSelection(artboardID: uuid, elementID: Int(parts[2])) : nil
        default: return nil
        }
    }

    private func buildItems() -> [LayerItem] {
        let doc = session.displayedDocument
        let boards: (DesignPage) -> [LayerItem] = { page in
            page.artboards.map { a in
                LayerItem(id: LayerID.artboard(a.id), title: a.name, detail: "\(Int(a.width))×\(Int(a.height))",
                          symbol: "number", target: CanvasSelection(artboardID: a.id, elementID: nil), dimmed: false,
                          children: elementItems(session.trees[a.id] ?? [], artboard: a.id))
            }
        }
        if doc.pages.count == 1, let page = doc.pages.first { return boards(page) }
        return doc.pages.map { page in
            LayerItem(id: LayerID.page(page.id), title: page.displayName, detail: "", symbol: "rectangle.dashed",
                      target: nil, dimmed: page.id != session.currentPage?.id, children: boards(page))
        }
    }

    private func elementItems(_ nodes: [ElementNode], artboard: UUID) -> [LayerItem]? {
        guard !nodes.isEmpty else { return nil }
        return nodes.map { n in
            let label = n.name.isEmpty ? n.text : n.name
            return LayerItem(id: LayerID.element(artboard, n.id),
                             title: ElementKind.title(n.kind),
                             detail: label.isEmpty ? "" : "“\(label)”",
                             symbol: ElementKind.symbol(n.kind),
                             target: CanvasSelection(artboardID: artboard, elementID: n.id),
                             dimmed: n.hidden ?? false,
                             children: elementItems(n.children ?? [], artboard: artboard))
        }
    }
}

/// 图层树的一行：缩进 + 展开箭头 + 图标 + 名称
private struct LayerRowView: View {
    let item: LayerItem
    let depth: Int
    let isExpanded: Bool
    let isSelected: Bool
    let session: ProjectSession
    let toggle: () -> Void
    @State private var hovering = false

    private var hasChildren: Bool { !(item.children ?? []).isEmpty }

    var body: some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(depth) * 14, height: 1)
            Group {
                if hasChildren {
                    Button(action: toggle) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 14, height: 16)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear
                }
            }
            .frame(width: 14)
            .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.secondary))

            Group {
                if item.symbol == "number" {
                    HashGlyph()
                        .stroke(style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                        .frame(width: 11, height: 11)
                } else {
                    Image(systemName: item.symbol).font(.caption)
                }
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.secondary))
            .frame(width: 16)
            Text(item.title)
                .fontWeight(.medium)
                .lineLimit(1)
            if !item.detail.isEmpty {
                Text(item.detail)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(
            isSelected ? AnyShapeStyle(Color(nsColor: .selectedContentBackgroundColor))
                : AnyShapeStyle(Color.primary.opacity(hovering ? 0.05 : 0)),
            in: .rect(cornerRadius: 6)
        )
        .opacity(item.dimmed ? 0.45 : 1)
        .contentShape(.rect)
        .onTapGesture {
            if let t = item.target { session.select(t) } else if hasChildren { toggle() }
        }
        .onHover { inside in
            hovering = inside
            guard let t = item.target else { return }
            if inside, let e = t.elementID {
                session.setHover(artboardID: t.artboardID, elementID: e)
            } else if !inside {
                session.hover = nil
            }
        }
        .contextMenu {
            if let t = item.target {
                Button("选中") { session.select(t) }
                Button("复制") { session.select(t); session.duplicateSelection() }
                Divider()
                Button("删除", role: .destructive) { session.select(t); session.deleteSelection() }
            }
        }
    }
}

// MARK: - 代码

struct CodeView: View {
    @Bindable var session: ProjectSession
    @State private var code = ""
    @State private var original = ""
    @State private var title = ""
    /// 元素代码的显示方式：样式展开（默认）或原始源码
    @AppStorage("codeView.expandStyles") private var expandStyles = true

    /// 选中对象、其源码或显示方式变化时重新加载
    private var key: String {
        guard let sel = session.selection else { return "none" }
        return sel.artboardID.uuidString + ":" + (sel.elementID.map(String.init) ?? "board") + ":"
            + String(session.document.artboard(sel.artboardID)?.html.hashValue ?? 0) + ":\(expandStyles)"
    }

    private var isElement: Bool { session.selection?.elementID != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
                if isElement {
                    Picker("显示方式", selection: $expandStyles) {
                        Text("样式").tag(true)
                        Text("源码").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("样式：把命中的 CSS 规则展开成每个元素的行内样式（变量换成实际值）\n源码：设计里原本的 HTML（使用 class）")
                }
                Button("还原") { code = original }
                    .disabled(code == original)
                Button("应用") { apply() }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .disabled(code == original || !session.isEditable || title.isEmpty)
            }
            .controlSize(.small)
            .padding(10)
            Divider()
            if title.isEmpty {
                ContentUnavailableView("未选中任何内容", systemImage: "chevron.left.forwardslash.chevron.right",
                                       description: Text("点击画布中的元素，这里显示它的 HTML，可以直接修改；点击画板标题查看整个画板的代码。"))
            } else {
                TextEditor(text: $code)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
            }
        }
        .task(id: key) { await load() }
    }

    private func load() async {
        if let sel = session.selection, sel.elementID != nil {
            let html = await (expandStyles ? session.selectedElementInlinedHTML() : session.selectedElementHTML()) ?? ""
            let p = session.selectedProps
            title = p.map { "<\($0.tag)> \(ElementKind.title($0.kind))\($0.name.isEmpty ? "" : "「\($0.name)」")" } ?? "元素"
            code = html; original = html
        } else if let board = session.selectedArtboard {
            title = "画板「\(board.name)」"
            code = board.html; original = board.html
        } else {
            title = ""; code = ""; original = ""
        }
    }

    private func apply() {
        if let sel = session.selection, sel.elementID != nil {
            session.replaceSelectedElementHTML(code)
        } else if let board = session.selectedArtboard {
            session.setArtboardHTML(board.id, code)
        }
        original = code
    }
}

// MARK: - 调整（Tweaks）

struct TweaksView: View {
    @Bindable var session: ProjectSession

    var body: some View {
        let controls = session.tweakControls
        if controls.isEmpty {
            ContentUnavailableView {
                Label("没有可调参数", systemImage: "slider.horizontal.3")
            } description: {
                Text("当前画布的画板没有暴露可调参数。可以让 AI「提供几个可以调节的主题参数」。")
            } actions: {
                Button("让 AI 添加参数") {
                    session.draft = "请为当前设计的每个画板暴露 4–6 个相同的可调参数（主色、圆角、字号比例、间距密度等），保持设计不变。"
                    session.send()
                }
                .disabled(session.isGenerating || !session.hasDesign)
            }
        } else {
            Form {
                Section {
                    ForEach(controls) { c in
                        TweakRow(control: c, value: Binding(
                            get: { session.tweakValue(c) },
                            set: { session.setTweak(c, $0) }
                        ))
                    }
                } footer: {
                    Text("调整会实时作用于当前画布的所有画板，满意后写入设计并保存为新版本。")
                }
                Section {
                    HStack {
                        Button("重置") { session.resetTweaks() }
                            .disabled(session.tweakValues.isEmpty)
                        Spacer()
                        Button("写入设计") { session.bakeTweaks() }
                            .buttonStyle(PrimaryActionButtonStyle())
                            .disabled(session.tweakValues.isEmpty || session.isGenerating)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}
