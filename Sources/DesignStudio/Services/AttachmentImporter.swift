import AppKit
import UniformTypeIdentifiers

enum AttachmentImporter {
    private static let markdownExtensions = ["md", "markdown"]
    // 直接粘贴的路径可独占一行，或后接本轮需求。路径中的空格和中文文件名可保留。
    private static let pathPattern = try? NSRegularExpression(
        pattern: #"^[\t ]*["'`]?((?:file://|~/|/)[^"\r\n'`]+?\.(?:markdown|md|txt))(?=$|[\s"'`，。；：、,:;])"#,
        options: [.anchorsMatchLines, .caseInsensitive]
    )

    static func pick() -> [ChatAttachment] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .plainText] + markdownExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "添加"
        return panel.runModal() == .OK ? load(panel.urls) : []
    }

    static func load(_ urls: [URL]) -> [ChatAttachment] {
        var attachments: [ChatAttachment] = []
        var failures: [String] = []
        for url in urls where url.isFileURL {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
            let ext = url.pathExtension.lowercased()
            if markdownExtensions.contains(ext) || ext == "txt" || contentType?.conforms(to: .plainText) == true {
                do {
                    attachments.append(try document(from: url))
                } catch {
                    failures.append(error.localizedDescription)
                }
            } else if let image = ImageUtil.attachment(from: url) {
                attachments.append(image)
            }
        }
        if !failures.isEmpty {
            ExportService.presentError("无法添加附件", ImportError(message: failures.joined(separator: "\n")))
        }
        return attachments
    }

    static func includingPastedDocuments(in text: String, attachments: [ChatAttachment]) throws -> [ChatAttachment] {
        guard let pathPattern else { return attachments }
        var result = attachments
        var imported = Set(attachments.compactMap(\.sourcePath))
        for match in pathPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range(at: 1), in: text), let url = fileURL(for: String(text[range])),
                  imported.insert(url.standardizedFileURL.path).inserted else { continue }
            result.append(try document(from: url))
        }
        return result
    }

    private static func fileURL(for path: String) -> URL? {
        if path.lowercased().hasPrefix("file://") {
            guard let url = URL(string: path), url.isFileURL,
                  [nil, "", "localhost"].contains(url.host?.lowercased()) else { return nil }
            return url
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    private static func document(from url: URL) throws -> ChatAttachment {
        do {
            let file = url.resolvingSymlinksInPath()
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            var encoding = String.Encoding.utf8
            let text = try String(contentsOf: file, usedEncoding: &encoding)
            let markdown = markdownExtensions.contains(url.pathExtension.lowercased())
            return ChatAttachment(filename: url.lastPathComponent, mimeType: markdown ? "text/markdown" : "text/plain",
                                  data: Data(text.utf8), sourcePath: url.standardizedFileURL.path)
        } catch {
            throw ImportError(message: "读取「\(url.lastPathComponent)」失败。请确认文件位置，或用回形针重新选择它。")
        }
    }

    private struct ImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
