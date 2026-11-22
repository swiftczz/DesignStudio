import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var persistence: PersistenceController?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let persistence, !persistence.flush() else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "有项目尚未保存"
        alert.informativeText = "你可以返回应用，检查保存错误并重试。"
        alert.addButton(withTitle: "返回应用")
        alert.addButton(withTitle: "退出")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run` 启动的可执行文件默认没有 Dock 图标，这里切换为常规 App
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct DesignStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup("DesignStudio", id: "main") {
            RootView()
                .environment(app)
                .frame(minWidth: 1080, minHeight: 680)
                .onOpenURL { app.importProject(from: $0) }
                .onAppear {
                    delegate.persistence = app.persistence
                    app.softwareUpdater.start(legacyAutomaticChecks: app.settings.automaticallyChecksForUpdates)
                }
                .task { await app.auth.refreshAll(profiles: app.providers) }
                .task { await app.refreshSavedChatGPTCatalog() }
        }
        .defaultWindowPlacement { _, context in
            let visibleRect = context.defaultDisplay.visibleRect
            return WindowPlacement(size: CGSize(
                width: min(1480, (visibleRect.width * 0.82).rounded()),
                height: min(920, (visibleRect.height * 0.86).rounded())
            ))
        }
        .windowToolbarStyle(.unified)
        .commands { AppCommands(app: app) }

        // 用普通 Window 而不是 Settings 场景：Settings 会强制使用偏好设置式的大图标工具栏，
        // 普通窗口里的 TabView 才会渲染成「时钟」那样的顶部胶囊标签栏
        Window("设置", id: SettingsWindow.id) {
            SettingsView()
                .environment(app)
                .tint(Theme.accent)
                .frame(minWidth: 780, minHeight: 560)
        }
        .defaultSize(width: 900, height: 640)
        .windowToolbarStyle(.unified)
        .commandsRemoved()
    }
}

enum SettingsWindow {
    static let id = "settings"
}

extension FocusedValues {
    @Entry var composerAttachments: Binding<[ChatAttachment]>?
    @Entry var composerTextBlocks: Binding<[PastedTextBlock]>?
}

struct AppCommands: Commands {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow
    @FocusedBinding(\.composerAttachments) private var composerAttachments
    @FocusedBinding(\.composerTextBlocks) private var composerTextBlocks

    private var canvasSession: ProjectSession? {
        guard let session = app.activeSession, session.showCanvas else { return nil }
        return session
    }

    private func paste() {
        if let current = composerAttachments,
           let pasted = AttachmentImporter.pastedAttachments(from: .general) {
            composerAttachments = current + pasted
        } else if let current = composerTextBlocks,
                  let text = NSPasteboard.general.string(forType: .string),
                  let block = PastedTextBlock(pasting: text) {
            composerTextBlocks = current + [block]
        } else {
            app.performPasteboard(.paste)
        }
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("检查更新…", action: app.softwareUpdater.checkForUpdates)
                .disabled(!app.softwareUpdater.canCheckForUpdates)
        }
        CommandGroup(replacing: .appSettings) {
            Button("设置…") { openWindow(id: SettingsWindow.id) }
                .keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            Button("新建设计") { app.route = .home }
                .keyboardShortcut("n")
            Button("导入项目", action: app.chooseProjectToImport)
                .keyboardShortcut("o")
        }
        // 撤销 / 重做：文本输入框里沿用系统撤销，其余情况撤销画布上的修改
        CommandGroup(replacing: .undoRedo) {
            Button("撤销") { app.performUndo(redo: false) }
                .keyboardShortcut("z")
            Button("重做") { app.performUndo(redo: true) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        // 剪切 / 拷贝 / 粘贴：文字输入框里照常处理文字，画布有焦点时处理画布上的元素
        CommandGroup(replacing: .pasteboard) {
            Button("剪切") { app.performPasteboard(.cut) }
                .keyboardShortcut("x")
            Button("拷贝") { app.performPasteboard(.copy) }
                .keyboardShortcut("c")
            Button("粘贴", action: paste)
                .keyboardShortcut("v")
            Button("全选") { app.performPasteboard(.selectAll) }
                .keyboardShortcut("a")
            Divider()
            Button("拷贝为 PNG") { app.performCanvasCommand { $0.copySelectionAsPNG() } }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("拷贝属性") { app.performCanvasCommand { $0.copyProperties() } }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("粘贴属性") { app.performCanvasCommand { $0.pasteProperties() } }
                .keyboardShortcut("v", modifiers: [.command, .option])
        }
        CommandMenu("设计") {
            Button("批注工具") { canvasSession?.tool = .comment }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(canvasSession == nil)
            Button("询问 AI") { canvasSession?.showAskAI = true }
                .keyboardShortcut("j", modifiers: .command)
                .disabled(canvasSession == nil)
            Button("停止生成") { app.activeSession?.stop() }
                .keyboardShortcut(".", modifiers: .command)
            Divider()
            Button("复制选中") { canvasSession?.duplicateSelection() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(canvasSession == nil)
            Button("编组") { app.performCanvasCommand { $0.groupSelection() } }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(canvasSession?.canGroup != true)
            Button("取消编组") { app.performCanvasCommand { $0.ungroupSelection() } }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(canvasSession?.canUngroup != true)
            Button("新建画板") { canvasSession?.addArtboard() }.disabled(canvasSession == nil)
            Button("新建画布") { canvasSession?.addPage() }.disabled(canvasSession == nil)
            Divider()
            Button("放大") { canvasSession?.zoomIn() }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(canvasSession == nil)
            Button("缩小") { canvasSession?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(canvasSession == nil)
            Button("实际大小") { canvasSession?.zoomTo100() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(canvasSession == nil)
            Button("适应画布") { if let s = canvasSession { s.isFullScreen ? s.fitFullScreen() : s.zoomToFit() } }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(canvasSession == nil)
            Button("缩放到选中") { canvasSession?.zoomToSelection() }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(canvasSession == nil)
            Divider()
            Button("显示 / 隐藏对话") { canvasSession?.showChat.toggle() }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(canvasSession == nil)
            Button("全屏查看画板") { canvasSession?.toggleArtboardFullScreen() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(canvasSession == nil)
            Divider()
            Button("设计系统") { app.route = .designSystems }
                .keyboardShortcut("d", modifiers: [.command, .shift])
        }
    }
}
