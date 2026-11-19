import AppKit
import SwiftUI

/// 应用内拷贝的元素：同时写进系统剪贴板（自定义类型 + HTML + 纯文本），可以跨项目粘贴
struct ElementClipboard: Codable, Equatable {
    var artboardID: UUID
    /// 原始源码（保留 class，同一个画板里粘贴）
    var source: String
    /// 样式展开后的代码（粘贴到别的画板时用，不依赖原画板的样式表）
    var inlined: String

    static let type = NSPasteboard.PasteboardType("app.designstudio.element")

    func write(to pb: NSPasteboard) {
        pb.clearContents()
        if let data = try? JSONEncoder().encode(self) { pb.setData(data, forType: Self.type) }
        pb.setString(inlined, forType: .html)
        pb.setString(inlined, forType: .string)
    }

    static func read(from pb: NSPasteboard) -> ElementClipboard? {
        guard let data = pb.data(forType: type) else { return nil }
        return try? JSONDecoder().decode(ElementClipboard.self, from: data)
    }
}

extension String {
    nonisolated var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// 画布上的右键菜单（AppKit 菜单，显示快捷键；快捷键本身由应用菜单 / 画布按键处理）
@MainActor
enum CanvasContextMenu {
    static func make(session: ProjectSession, info: ContextInfo?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let isElement = session.selection?.elementID != nil
        let multi = session.multiSelection.count > 1

        func add(_ title: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command],
                 enabled: Bool = true, destructive: Bool = false, _ action: @escaping () -> Void) {
            let target = MenuActionTarget(action)
            let item = NSMenuItem(title: title, action: #selector(MenuActionTarget.run), keyEquivalent: key)
            item.target = target
            item.representedObject = target   // target 是弱引用，由 representedObject 持有
            item.keyEquivalentModifierMask = key.isEmpty ? [] : mods
            item.isEnabled = enabled
            if destructive {
                item.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.systemRed])
            }
            menu.addItem(item)
        }

        if multi {
            // 多选：只提供对全部元素都有意义的操作
            let header = NSMenuItem(title: "已选 \(session.multiSelection.count) 个元素", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())
            add("编组", "g") { session.groupSelection() }
            add("取消编组", "g", [.command, .shift], enabled: false) {}
            menu.addItem(.separator())
            add("删除", "\u{8}", [], destructive: true) { session.deleteSelection() }
            return menu
        }

        add("询问 AI…", "j", enabled: session.canAskAboutSelection) { session.showAskAI = true }
        menu.addItem(.separator())


        add("剪切", "x", enabled: isElement) { session.cutSelection() }
        add("拷贝", "c", enabled: isElement) { session.copySelection() }
        add("粘贴", "v", enabled: session.canPaste) { session.paste() }
        add("复制一份", "d") { session.duplicateSelection() }
        menu.addItem(.separator())

        add("拷贝为 PNG", "c", [.command, .shift]) { session.copySelectionAsPNG() }
        add("拷贝为 SVG", enabled: isElement) { session.copySelectionAsSVG() }
        add("拷贝为 HTML") { session.copySelectionAsHTML() }
        add("拷贝属性", "c", [.command, .option], enabled: isElement) { session.copyProperties() }
        add("粘贴属性", "v", [.command, .option], enabled: isElement && session.copiedStyle != nil) { session.pasteProperties() }

        if isElement {
            menu.addItem(.separator())
            add("移到最后", "]", [], enabled: !(info?.isLast ?? true)) { session.moveSelection(toLast: true) }
            add("移到最前", "[", [], enabled: !(info?.isFirst ?? true)) { session.moveSelection(toLast: false) }
            // 编组与取消编组同时只有一个可用
            add("编组", "g", enabled: session.canGroup) { session.groupSelection() }
            add("取消编组", "g", [.command, .shift], enabled: session.canUngroup) { session.ungroupSelection() }
            add("水平翻转", "H", [.shift]) { session.flipSelection(horizontal: true) }
            add("垂直翻转", "V", [.shift]) { session.flipSelection(horizontal: false) }
            menu.addItem(.separator())
            add("用 Flex 包裹", "A", [.shift]) { session.wrapSelection(grid: false) }
            add("用 Grid 包裹") { session.wrapSelection(grid: true) }
        }

        menu.addItem(.separator())
        add("删除", "\u{8}", [], destructive: true) { session.deleteSelection() }
        return menu
    }
}

/// 菜单项的动作：持有闭包
final class MenuActionTarget: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() { handler() }
}

/// 文字颜色的常用色（格式工具栏的颜色面板使用）
enum TextMenu {
    static let palette: [(name: String, hex: String)] = [
        ("黑色", "#111111"), ("深灰", "#374151"), ("灰色", "#6B7280"), ("浅灰", "#9CA3AF"), ("白色", "#FFFFFF"),
        ("红色", "#EF4444"), ("橙色", "#F97316"), ("黄色", "#EAB308"), ("绿色", "#22C55E"),
        ("青色", "#14B8A6"), ("蓝色", "#3B82F6"), ("紫色", "#8B5CF6"), ("粉色", "#EC4899")
    ]
}

/// 系统取色面板：选色时实时应用到选中的文字
@MainActor
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var apply: ((String) -> Void)?

    func open(current: String, apply: @escaping (String) -> Void) {
        self.apply = apply
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = false
        panel.color = NSColor(Color(hex: current))
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.orderFront(nil)
    }

    @objc private func changed(_ panel: NSColorPanel) {
        guard let c = panel.color.usingColorSpace(.sRGB) else { return }
        let hex = String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                         Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
        apply?(hex)
    }
}
