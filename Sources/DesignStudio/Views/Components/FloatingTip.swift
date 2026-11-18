import SwiftUI
import AppKit

/// 悬停名称（与画布底部工具栏的 HoverName 同样式：黑色胶囊、白色小字、立即出现），
/// 但画在一个独立的无边框小窗口里，不会被设置表单这类会裁剪内容的容器挡住。
struct FloatingHoverName: ViewModifier {
    let text: String
    @State private var anchor = TipAnchor()

    func body(content: Content) -> some View {
        content
            .background(TipAnchorView(anchor: anchor))
            .onHover { inside in
                if inside { FloatingTipWindow.shared.show(text, above: anchor.screenRect) }
                else { FloatingTipWindow.shared.hide(for: text) }
            }
            .onDisappear { FloatingTipWindow.shared.hide(for: text) }
    }
}

/// 记下被悬停视图对应的 NSView，用来换算它在屏幕上的位置
@MainActor
final class TipAnchor {
    weak var view: NSView?

    var screenRect: NSRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

private struct TipAnchorView: NSViewRepresentable {
    let anchor: TipAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

/// 全局共用的提示小窗口：不抢焦点、不接收鼠标
@MainActor
final class FloatingTipWindow {
    static let shared = FloatingTipWindow()

    private let panel: NSPanel
    private let host = NSHostingView(rootView: TipLabel(text: ""))
    private var currentText: String?

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = host
    }

    /// 显示在目标上方居中，与目标留 8pt 间距（与工具栏提示的位置一致）
    func show(_ text: String, above rect: NSRect?) {
        guard let rect else { return }
        currentText = text
        host.rootView = TipLabel(text: text)
        let size = host.fittingSize
        let origin = NSPoint(x: (rect.midX - size.width / 2).rounded(), y: (rect.maxY + 8).rounded())
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    /// 只在仍显示着这条提示时隐藏（从一个色块移到相邻色块时，新的提示先出现，旧的离开事件不能把它关掉）
    func hide(for text: String) {
        guard currentText == text else { return }
        currentText = nil
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.currentText == nil else { return }
                self.panel.orderOut(nil)
            }
        }
    }
}

/// 与 HoverName 相同的外观
private struct TipLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.78), in: .capsule)
            .fixedSize()
    }
}
