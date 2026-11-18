import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
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
                .onAppear { app.softwareUpdater.start(legacyAutomaticChecks: app.settings.automaticallyChecksForUpdates) }
                .task { await app.auth.refreshAll(profiles: app.providers) }
        }
        .defaultSize(width: 1480, height: 920)
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
}

struct AppCommands: Commands {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow
    @FocusedBinding(\.composerAttachments) private var composerAttachments

    private func paste() {
        if let current = composerAttachments,
           let pasted = AttachmentImporter.pastedAttachments(from: .general) {
            composerAttachments = current + pasted
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
            Button("批注工具") { app.activeSession?.tool = .comment }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button("询问 AI") { app.activeSession?.showAskAI = true }
                .keyboardShortcut("j", modifiers: .command)
            Button("停止生成") { app.activeSession?.stop() }
                .keyboardShortcut(".", modifiers: .command)
            Divider()
            Button("复制选中") { app.activeSession?.duplicateSelection() }
                .keyboardShortcut("d", modifiers: .command)
            Button("编组") { app.performCanvasCommand { $0.groupSelection() } }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(!(app.activeSession?.canGroup ?? false))
            Button("取消编组") { app.performCanvasCommand { $0.ungroupSelection() } }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!(app.activeSession?.canUngroup ?? false))
            Button("新建画板") { app.activeSession?.addArtboard() }
            Button("新建画布") { app.activeSession?.addPage() }
            Divider()
            Button("放大") { app.activeSession?.zoomIn() }
                .keyboardShortcut("=", modifiers: .command)
            Button("缩小") { app.activeSession?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Button("实际大小") { app.activeSession?.zoomTo100() }
                .keyboardShortcut("0", modifiers: .command)
            Button("适应画布") { if let s = app.activeSession { s.isFullScreen ? s.fitFullScreen() : s.zoomToFit() } }
                .keyboardShortcut("1", modifiers: .command)
            Button("缩放到选中") { app.activeSession?.zoomToSelection() }
                .keyboardShortcut("2", modifiers: .command)
            Divider()
            Button("显示 / 隐藏对话") { app.activeSession?.showChat.toggle() }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Button("全屏查看画板") { app.activeSession?.toggleArtboardFullScreen() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button("设计系统") { app.route = .designSystems }
                .keyboardShortcut("d", modifiers: [.command, .shift])
        }
    }
}
