import AppKit
import SwiftUI

enum UpdateCheckPresentation {
    static func start(app: AppModel, openWindow: OpenWindowAction) {
        let parent = NSApp.keyWindow ?? NSApp.mainWindow
        Task {
            while let result = await app.checkForUpdates() {
                switch result {
                case .available:
                    openWindow(id: UpdateCheckView.windowID)
                case .upToDate:
                    let alert = NSAlert()
                    alert.messageText = "已是最新版本"
                    alert.informativeText = "DesignStudio \(UpdateService.installedVersion ?? "")"
                    alert.addButton(withTitle: "完成")
                    _ = await present(alert, in: parent)
                case .failed(let reason):
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "无法检查更新"
                    alert.informativeText = reason
                    alert.addButton(withTitle: "重试")
                    alert.addButton(withTitle: "取消")
                    if await present(alert, in: parent) == .alertFirstButtonReturn { continue }
                }
                break
            }
        }
    }

    private static func present(_ alert: NSAlert, in window: NSWindow?) async -> NSApplication.ModalResponse {
        alert.icon = NSApp.applicationIconImage
        if let window, window.isVisible {
            return await alert.beginSheetModal(for: window)
        }
        return alert.runModal()
    }
}

struct UpdateCheckView: View {
    static let windowID = "software-update"

    @Environment(AppModel.self) private var app
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let update = app.availableUpdate {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 48, height: 48)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DesignStudio \(update.version) 已发布")
                            .font(.headline)
                        if let version = UpdateService.installedVersion {
                            Text("当前版本 \(version)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !update.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("更新说明").font(.subheadline.weight(.medium))
                        ScrollView {
                            MarkdownText(update.notes)
                                .padding(12)
                        }
                        .frame(height: 220)
                        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Spacer()
                    Button("稍后") { dismissWindow(id: Self.windowID) }
                        .keyboardShortcut(.cancelAction)
                    Button("下载 DMG") { openURL(update.downloadURL) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .frame(width: 420, alignment: .leading)
            .padding(20)
        }
    }
}
