import AppKit
import PDFKit
import UniformTypeIdentifiers

@MainActor
enum ExportService {
    static func safeFileName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "[/:\\\\?%*|\"<>…]", with: "-", options: .regularExpression).trimmed
        return cleaned.isEmpty ? "design" : cleaned
    }

    private static func savePanel(name: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = safeFileName(name) + "." + (type.preferredFilenameExtension ?? "")
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func exportHTML(_ html: String, name: String) {
        guard let url = savePanel(name: name, type: .html) else { return }
        try? html.write(to: url, atomically: true, encoding: .utf8)
    }

    static func exportPDF(_ data: Data, name: String) {
        guard let url = savePanel(name: name, type: .pdf) else { return }
        do { try data.write(to: url) } catch { presentError("导出 PDF 失败", error) }
    }

    static func exportPNG(_ image: NSImage?, name: String) {
        guard let image, let data = ImageUtil.pngData(image) else {
            presentError("导出图片失败", nil)
            return
        }
        guard let url = savePanel(name: name, type: .png) else { return }
        try? data.write(to: url)
    }

    /// 把多页 PDF（每个画板一页）合并为一个文件
    static func exportMergedPDF(_ pages: [Data], name: String) {
        let merged = PDFDocument()
        for data in pages {
            guard let doc = PDFDocument(data: data) else { continue }
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i) { merged.insert(page, at: merged.pageCount) }
            }
        }
        guard merged.pageCount > 0, let data = merged.dataRepresentation() else {
            presentError("导出 PDF 失败", nil)
            return
        }
        exportPDF(data, name: name)
    }

    /// 把整个画布导出为一个 HTML 文件：每个画板放在独立的 iframe 里，浏览器直接打开
    static func exportCanvasHTML(_ artboards: [Artboard], kind: ProjectKind, name: String) {
        guard let url = savePanel(name: name, type: .html) else { return }
        do {
            try CanvasBundle.make(title: name, artboards: artboards, kind: kind).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            presentError("导出失败", error)
        }
    }

    /// 把一组画板分别导出为 HTML 文件，放进选定目录下的新文件夹
    static func exportAllHTML(_ artboards: [Artboard], projectName: String) {
        guard let folder = chooseFolder(named: projectName) else { return }
        do {
            for (i, a) in artboards.enumerated() {
                let file = String(format: "%02d-", i + 1) + safeFileName(a.name) + ".html"
                try a.html.write(to: folder.appending(path: file), atomically: true, encoding: .utf8)
            }
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch {
            presentError("导出失败", error)
        }
    }

    private static func chooseFolder(named name: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "导出到此处"
        panel.message = "选择一个目录，DesignStudio 会在其中创建以项目命名的文件夹"
        guard panel.runModal() == .OK, let parent = panel.url else { return nil }
        let folder = parent.appending(path: safeFileName(name), directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func openInBrowser(_ html: String, name: String) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "DesignStudio-Preview", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: safeFileName(name) + ".html")
        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(url)
        } catch {
            presentError("无法打开浏览器预览", error)
        }
    }

    static func copyHTML(_ html: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(html, forType: .string)
    }

    /// 交接给 Claude Code：每个画板导出为一个 HTML，加上 HANDOFF.md，并在终端里启动 claude
    static func handoffToClaudeCode(project: Project, artboards: [Artboard], designSystem: DesignSystem?, executable: String) {
        guard let folder = chooseFolder(named: project.name) else { return }
        do {
            var files: [String] = []
            for (i, a) in artboards.enumerated() {
                let file = String(format: "%02d-", i + 1) + safeFileName(a.name) + ".html"
                try a.html.write(to: folder.appending(path: file), atomically: true, encoding: .utf8)
                files.append("- `\(file)` — \(a.name)（\(Int(a.width))×\(Int(a.height))）")
            }

            var md = """
            # 设计交接：\(project.name)

            类型：\(project.kind.title)
            版本：v\(project.currentVersion?.number ?? 1)

            以下 HTML 文件是在 DesignStudio 中确认过的设计稿，每个文件是一个画板（一个界面 / 一页幻灯片）：

            \(files.joined(separator: "\n"))

            ## 任务
            请把这个设计实现为可维护的生产代码：
            1. 先逐个阅读画板，梳理界面结构、组件、导航关系与交互
            2. 询问或推断目标技术栈（如未指定，默认 React + TypeScript + Tailwind）
            3. 拆分可复用组件、抽取设计令牌（颜色、字体、圆角、间距），保持视觉一致
            4. 保留所有交互状态与响应式行为

            ## 设计过程中的关键需求
            """
            let requests = project.messages.filter { $0.role == .user }.suffix(8)
            for m in requests { md += "\n- " + m.text.replacingOccurrences(of: "\n", with: " ") }
            if let designSystem { md += "\n\n## 设计系统\n```\n\(designSystem.promptDescription)\n```\n" }
            try md.write(to: folder.appending(path: "HANDOFF.md"), atomically: true, encoding: .utf8)

            let script = """
            #!/bin/zsh -l
            cd \(CLIAuthService.shellQuote(folder.path))
            \(CLIAuthService.shellQuote(executable)) "阅读 HANDOFF.md 和所有画板 HTML，按照交接说明把这个设计实现为生产代码。"
            """
            let commandURL = folder.appending(path: "open-in-claude-code.command")
            try script.write(to: commandURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: commandURL.path)
            NSWorkspace.shared.open(commandURL)
        } catch {
            presentError("交接失败", error)
        }
    }

    static func presentError(_ title: String, _ error: Error?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error?.localizedDescription ?? "未知错误"
        alert.alertStyle = .warning
        alert.runModal()
    }
}
