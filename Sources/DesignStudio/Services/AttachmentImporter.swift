import AppKit
import ImageIO
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
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "添加"
        return panel.runModal() == .OK ? load(panel.urls) : []
    }

    static func load(_ urls: [URL]) -> [ChatAttachment] {
        var attachments: [ChatAttachment] = []
        var failures: [String] = []
        for url in urls where url.isFileURL {
            do {
                attachments.append(try file(from: url))
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        presentFailures(failures)
        return attachments
    }

    /// nil 表示剪贴板没有文件或图片，由文本输入框继续处理粘贴。
    static func pastedAttachments(from pasteboard: NSPasteboard) -> [ChatAttachment]? {
        var attachments: [ChatAttachment] = []
        var handled = false
        var failures: [String] = []
        for item in pasteboard.pasteboardItems ?? [] {
            if let path = item.string(forType: .fileURL), let url = URL(string: path), url.isFileURL {
                handled = true
                do {
                    attachments.append(try file(from: url))
                } catch {
                    failures.append(error.localizedDescription)
                }
                continue
            }

            let imageTypes = [.png, .tiff] as [NSPasteboard.PasteboardType]
            let availableTypes = imageTypes + item.types.filter { type in
                !imageTypes.contains(type) && UTType(type.rawValue)?.conforms(to: .image) == true
            }
            let representations = availableTypes.filter { item.types.contains($0) }
            guard !representations.isEmpty else { continue }
            handled = true
            let image = representations.lazy.compactMap { type in
                item.data(forType: type).flatMap(NSImage.init(data:)).flatMap { image in
                    ImageUtil.attachment(from: image, name: "剪贴板图片.jpg")
                }
            }.first
            if let attachment = image {
                attachments.append(attachment)
            } else {
                failures.append("无法读取剪贴板中的图片。")
            }
        }
        presentFailures(failures)
        return handled ? attachments : nil
    }

    private static func file(from url: URL) throws -> ChatAttachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let file = url.resolvingSymlinksInPath()
        do {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey])
            guard values.isRegularFile == true else { throw CocoaError(.fileReadUnknown) }
            let ext = url.pathExtension.lowercased()
            let contentType = UTType(filenameExtension: ext) ?? values.contentType
            let name = url.lastPathComponent
            let sourcePath = url.standardizedFileURL.path
            let declaredImage = contentType?.conforms(to: .image) == true
            let untyped = contentType == nil || contentType == .data || contentType?.isDynamic == true
            if declaredImage || (untyped && CGImageSourceCreateWithURL(file as CFURL, nil) != nil),
               let image = NSImage(contentsOf: file),
               var attachment = ImageUtil.attachment(from: image, name: name) {
                attachment.sourcePath = sourcePath
                return attachment
            }
            if markdownExtensions.contains(ext) || ext == "txt" || contentType?.conforms(to: .plainText) == true,
               let text = try? document(from: file, originalURL: url) {
                return text
            }
            let mimeType = (declaredImage ? nil : contentType?.preferredMIMEType) ?? "application/octet-stream"
            return ChatAttachment(filename: name, mimeType: mimeType, data: try Data(contentsOf: file),
                                  sourcePath: sourcePath)
        } catch {
            throw ImportError(message: "读取「\(url.lastPathComponent)」失败。请确认文件位置和读取权限。")
        }
    }

    static func includingPastedDocuments(in text: String, attachments: [ChatAttachment]) throws -> [ChatAttachment] {
        guard let pathPattern else { return attachments }
        var result = attachments
        var imported = Set(attachments.compactMap(\.sourcePath))
        for match in pathPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range(at: 1), in: text), let url = fileURL(for: String(text[range])),
                  imported.insert(url.standardizedFileURL.path).inserted else { continue }
            let attachment = try file(from: url)
            guard attachment.documentText != nil else {
                throw ImportError(message: "无法将「\(url.lastPathComponent)」读作文本。请用回形针添加原文件。")
            }
            result.append(attachment)
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

    private static func document(from file: URL, originalURL: URL) throws -> ChatAttachment {
        var encoding = String.Encoding.utf8
        let text = try String(contentsOf: file, usedEncoding: &encoding)
        let markdown = markdownExtensions.contains(originalURL.pathExtension.lowercased())
        return ChatAttachment(filename: originalURL.lastPathComponent, mimeType: markdown ? "text/markdown" : "text/plain",
                              data: Data(text.utf8), sourcePath: originalURL.standardizedFileURL.path)
    }

    private static func presentFailures(_ failures: [String]) {
        guard !failures.isEmpty else { return }
        ExportService.presentError("无法添加附件", ImportError(message: failures.joined(separator: "\n")))
    }

    private struct ImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
