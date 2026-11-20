import SwiftUI

struct ComponentLibraryEditor: View {
    @Environment(\.dismiss) private var dismiss
    let session: ProjectSession
    @State private var componentID: UUID?
    @State private var targetID: UUID?
    @State private var name = ""
    @State private var instanceText = ""
    @State private var busy = false
    @State private var failed = false
    @State private var feedback: String?

    var body: some View {
        let components = session.document.components
        let boards = session.currentPage?.artboards ?? []
        let component = components.first { $0.id == componentID }
        let props = session.selectedProps
        let hasSelectedElement = session.selection?.elementID != nil && session.selection?.elementID == props?.id
            && !["html", "head", "body"].contains(props?.tag ?? "")
        let selectedInstance = hasSelectedElement && component != nil && props?.componentID == componentID
        let target = boards.first { $0.id == targetID }
        let disabled = busy || session.isGenerating

        VStack(alignment: .leading, spacing: 16) {
            Text("项目组件").font(.headline)
            if hasSelectedElement, let props, props.componentID == nil {
                HStack {
                    TextField("组件名称", text: $name)
                    Button("从选中元素创建", systemImage: "plus") {
                        run("组件已创建") {
                            guard let id = await session.createComponent(name: name) else { return false }
                            componentID = id
                            name = ""
                            return true
                        }
                    }
                    .disabled(name.trimmed.isEmpty || disabled)
                }
            } else if components.isEmpty {
                Text("在画布上选中一个元素，即可创建供其他画板使用的组件。")
                    .foregroundStyle(.secondary)
            }

            if !components.isEmpty {
                Picker("组件", selection: $componentID) {
                    ForEach(components) { Text($0.name).tag(Optional($0.id)) }
                }
                if let component {
                    HStack {
                        Picker("插入到", selection: $targetID) {
                            if boards.isEmpty { Text("当前画布没有画板").tag(UUID?.none) }
                            ForEach(boards) { Text($0.name).tag(Optional($0.id)) }
                        }
                        Button("插入实例", systemImage: "plus.square.on.square") {
                            if let target { run("实例已插入「\(target.name)」") { await session.insertComponent(component.id, in: target.id) } }
                        }
                        .disabled(disabled || target == nil)
                    }
                    if selectedInstance {
                        Divider()
                        if let defaultText = component.defaultText {
                            HStack {
                                TextField("此实例的文案", text: $instanceText)
                                Button("应用文案") { run("文案已应用到此实例") { await session.overrideComponentText(instanceText) } }
                                    .disabled(disabled || instanceText.trimmed.isEmpty)
                                Button("重置") {
                                    run("已恢复组件默认文案") {
                                        guard await session.overrideComponentText(nil) else { return false }
                                        instanceText = defaultText
                                        return true
                                    }
                                }
                                .disabled(disabled || props?.componentTextOverride == nil)
                            }
                        }
                        Button("用选中实例更新组件", systemImage: "arrow.trianglehead.clockwise") {
                            run("组件及关联实例已更新") { await session.updateComponent(component) }
                        }
                        .disabled(disabled)
                    } else {
                        Text("在画板上选中对应的组件实例，即可编辑实例文案或同步设计。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Menu("组件操作") {
                        Button("从库中移除并解除实例关联", role: .destructive) {
                            run("已解除实例关联") {
                                guard await session.removeComponent(component, using: target?.id) else { return false }
                                componentID = session.document.components.first?.id
                                return true
                            }
                        }
                        .disabled(disabled || target == nil && session.document.allArtboards.contains(where: component.isReferenced))
                    }
                }
            }
            if failed {
                Text("无法完成组件操作，请确认所选元素或画板已加载后再试。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let feedback {
                Text(feedback).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear {
            componentID = props?.componentID ?? components.first?.id
            targetID = session.selection?.artboardID ?? boards.first?.id
            name = props.map(ProjectSession.displayName) ?? ""
            instanceText = props?.componentTextOverride ?? components.first { $0.id == componentID }?.defaultText ?? ""
        }
        .onChange(of: session.selection) { _, _ in
            instanceText = session.selectedProps?.componentTextOverride
                ?? session.document.components.first { $0.id == componentID }?.defaultText ?? ""
        }
    }

    private func run(_ message: String, _ action: @escaping () async -> Bool) {
        busy = true
        feedback = nil
        Task {
            failed = !(await action())
            if !failed { feedback = message }
            busy = false
        }
    }
}
