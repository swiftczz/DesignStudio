import AppKit
import Testing
@testable import DesignStudio

@MainActor
struct AttachmentTests {
    @Test func importsFinderFilesAndDetectsImagesWithoutAnExtension() throws {
        let root = try TempWorkspace.make(prefix: "attachment-test")
        defer { try? FileManager.default.removeItem(at: root) }
        let unknown = root.appending(path: "参考资料.customformat")
        let image = root.appending(path: "截图")
        let bytes = Data([0x01, 0xFF, 0x00])
        try bytes.write(to: unknown)
        try #require(ImageUtil.pngData(makeImage())).write(to: image)

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(pasteboard.writeObjects([unknown as NSURL, image as NSURL]))
        let files = try #require(AttachmentImporter.pastedAttachments(from: pasteboard))
        #expect(files.map(\.filename) == [unknown.lastPathComponent, image.lastPathComponent])
        #expect(files.first?.data == bytes)
        #expect(files.first?.mimeType == "application/octet-stream")
        let preview = try #require(files.last)
        #expect(preview.isImage)
        #expect(NSImage(data: preview.data) != nil)

        let message = ChatMessage(role: .user, text: "参考附件", attachments: files)
        let restored = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        #expect(restored.attachments == files)
    }

    @Test func pastesOneImagePerItemAndLeavesPlainTextForTheEditor() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(pasteboard.setString("普通文本", forType: .string))
        #expect(AttachmentImporter.pastedAttachments(from: pasteboard) == nil)

        pasteboard.clearContents()
        let image = makeImage()
        let item = NSPasteboardItem()
        item.setData(try #require(ImageUtil.pngData(image)), forType: .png)
        item.setData(try #require(image.tiffRepresentation), forType: .tiff)
        #expect(pasteboard.writeObjects([item]))
        let pasted = try #require(AttachmentImporter.pastedAttachments(from: pasteboard))
        #expect(pasted.count == 1)
        let attachment = try #require(pasted.first)
        #expect(attachment.isImage)
        #expect(NSImage(data: attachment.data) != nil)
    }

    @Test func longPasteCountsCharactersAndKeepsTheEntireEditedText() throws {
        let boundary = String(repeating: "👩🏽‍💻", count: 50)
        #expect(PastedTextBlock(pasting: boundary) == nil)
        let original = boundary + "字"
        var block = try #require(PastedTextBlock(pasting: original))
        #expect(block.text == original)
        block.text = "  文档原文\n\n最后一段\n"
        #expect(PastedTextBlock.message("  请总结  ", blocks: [block]) == "请总结\n\n" + block.text)
        #expect(PastedTextBlock.message("", blocks: [block]) == block.text)
    }

    @Test func pastedTextStatisticsCountOriginalLinesAndUTF8Bytes() {
        let empty = PastedTextBlock.statistics(for: "")
        #expect(empty.lines == 0 && empty.bytes == 0)

        let mixed = PastedTextBlock.statistics(for: "中\r\n\nA\n")
        #expect(mixed.lines == 4 && mixed.bytes == 8)
    }

    @Test func makesBinaryAttachmentsAvailableToCLIProviders() throws {
        let project = Project(name: "附件测试", kind: .prototype)
        let file = ChatAttachment(filename: "资料.zip", mimeType: "application/zip", data: Data([0, 255]))
        let message = ChatMessage(role: .user, text: "参考附件", attachments: [file])
        let cli = ProviderProfile(name: "Codex", kind: .codex)
        let api = ProviderProfile(name: "Claude API", kind: .anthropicAPI)
        let request = DesignPrompt.makeRequest(project: project, designSystem: nil, newMessage: message, profile: cli)
        let apiRequest = DesignPrompt.makeRequest(project: project, designSystem: nil, newMessage: message, profile: api)
        #expect(request.files == [file])
        #expect(request.latestImages.isEmpty)
        #expect(apiRequest.files.isEmpty)
        #expect(apiRequest.messages.last?.text.contains(file.filename) == true)

        let dir = try TempWorkspace.make(prefix: "attachment-test")
        defer { try? FileManager.default.removeItem(at: dir) }
        let references = try TempWorkspace.prepareReferenceFiles(request.files, in: dir)
        #expect(references.contains(file.filename))
        #expect(try Data(contentsOf: dir.appending(path: "attachment-1.zip")) == file.data)
    }

    private func makeImage() -> NSImage {
        NSImage(size: NSSize(width: 24, height: 16), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            return true
        }
    }
}
