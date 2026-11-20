import AppKit
import PDFKit
import UniformTypeIdentifiers

@MainActor
enum ExportService {
    nonisolated static func safeFileName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "[/:\\\\?%*|\"<>…]", with: "-", options: .regularExpression).trimmed
        return cleaned.isEmpty ? "design" : cleaned
    }

    static func savePanel(name: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = safeFileName(name) + "." + (type.preferredFilenameExtension ?? "")
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func exportHTML(_ html: String, name: String) {
        guard let url = savePanel(name: name, type: .html) else { return }
        do { try html.write(to: url, atomically: true, encoding: .utf8) } catch { presentError("导出 HTML 失败", error) }
    }

    static func exportProject(_ archive: ProjectArchive) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ProjectArchive.contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = safeFileName(archive.project.displayName) + "." + ProjectArchive.filenameExtension
        panel.title = "导出项目"
        panel.prompt = "导出项目"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    try archive.write(to: url)
                }.value
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                presentError("导出项目失败", error)
            }
        }
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
        do { try data.write(to: url, options: .atomic) } catch { presentError("导出 PNG 失败", error) }
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

    /// 单个画板打包成 ZIP：独立 HTML（含共用样式）、PNG、PDF
    static func exportArtboardZip(name: String, html: String, png: Data?, pdf: Data?) {
        writeZip(name: name) { folder in
            let base = safeFileName(name)
            try html.write(to: folder.appending(path: base + ".html"), atomically: true, encoding: .utf8)
            if let png { try png.write(to: folder.appending(path: base + ".png")) }
            if let pdf { try pdf.write(to: folder.appending(path: base + ".pdf")) }
        }
    }

    static func exportSVG(_ svg: String, name: String) {
        guard let url = savePanel(name: name, type: .svg) else { return }
        do { try svg.write(to: url, atomically: true, encoding: .utf8) } catch { presentError("导出 SVG 失败", error) }
    }

    /// 选中元素打包成 ZIP：HTML、PNG、SVG
    static func exportElementZip(name: String, html: String?, png: Data?, svg: String?) {
        writeZip(name: name) { folder in
            let base = safeFileName(name)
            if let html { try html.write(to: folder.appending(path: base + ".html"), atomically: true, encoding: .utf8) }
            if let png { try png.write(to: folder.appending(path: base + ".png")) }
            if let svg { try svg.write(to: folder.appending(path: base + ".svg"), atomically: true, encoding: .utf8) }
        }
    }

    nonisolated static func writeCanvasZipContents(to folder: URL, bundle: String, sharedCSS: String?,
                                                   boards: [(name: String, html: String, png: Data?, pdf: Data)]) throws {
        try bundle.write(to: folder.appending(path: "index.html"), atomically: true, encoding: .utf8)
        if let css = sharedCSS?.trimmed, !css.isEmpty {
            try css.write(to: folder.appending(path: "shared.css"), atomically: true, encoding: .utf8)
        }
        let html = folder.appending(path: "html", directoryHint: .isDirectory)
        let png = folder.appending(path: "png", directoryHint: .isDirectory)
        let pdf = folder.appending(path: "pdf", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: html, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pdf, withIntermediateDirectories: true)
        for (index, board) in boards.enumerated() {
            let file = String(format: "%02d-", index + 1) + safeFileName(board.name)
            try board.html.write(to: html.appending(path: file + ".html"), atomically: true, encoding: .utf8)
            if let data = board.png {
                try FileManager.default.createDirectory(at: png, withIntermediateDirectories: true)
                try data.write(to: png.appending(path: file + ".png"))
            }
            try board.pdf.write(to: pdf.appending(path: file + ".pdf"))
        }
    }

    /// 选好保存位置后，组装文件夹并压缩成 .zip
    private static func writeZip(name: String, build: (URL) throws -> Void) {
        guard let url = savePanel(name: name, type: .zip) else { return }
        do {
            try makeZip(name: name, at: url, build: build)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            presentError("导出 ZIP 失败", error)
        }
    }

    /// 在临时目录里组装以 name 命名的文件夹，压缩后放到 url（已存在则替换）
    nonisolated static func makeZip(name: String, at url: URL, build: (URL) throws -> Void) throws {
        let work = FileManager.default.temporaryDirectory.appending(path: "DesignStudio-Zip-" + UUID().uuidString,
                                                                     directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: work) }
        let folder = work.appending(path: safeFileName(name), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try build(folder)
        try ZipWriter.zip(folder: folder).write(to: url, options: .atomic)
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

    enum HandoffTool: CaseIterable {
        case claudeCode, codex

        var kind: ProviderKind { self == .claudeCode ? .claudeCode : .codex }
        var title: String { self == .claudeCode ? "Claude Code" : "Codex" }
        var launcherName: String { self == .claudeCode ? "open-in-claude-code.command" : "open-in-codex.command" }
    }

    static func handoff(project: Project, artboards: [Artboard], designSystem: DesignSystem?,
                        tool: HandoffTool, executable: String) {
        guard let folder = chooseFolder(named: project.name) else { return }
        do {
            let launcher = try writeHandoff(project: project, artboards: artboards, designSystem: designSystem,
                                            tool: tool, executable: executable, to: folder)
            guard NSWorkspace.shared.open(launcher) else { throw LLMError.cli("无法打开终端启动脚本。") }
        } catch {
            presentError("交接失败", error)
        }
    }

    static func writeHandoff(project: Project, artboards: [Artboard], designSystem: DesignSystem?,
                             tool: HandoffTool, executable: String, to folder: URL) throws -> URL {
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

        let options = tool == .codex ? #" -c 'service_tier="default"'"# : ""
        let script = """
        #!/bin/zsh -l
        cd -- "${0:A:h}" || exit 1
        exec \(CLIAuthService.shellQuote(executable))\(options) "阅读 HANDOFF.md 和所有画板 HTML，按照交接说明把这个设计实现为生产代码。"
        """
        let commandURL = folder.appending(path: tool.launcherName)
        try script.write(to: commandURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: commandURL.path)
        return commandURL
    }

    static func presentError(_ title: String, _ error: Error?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error?.localizedDescription ?? "未知错误"
        alert.alertStyle = .warning
        alert.runModal()
    }
}
