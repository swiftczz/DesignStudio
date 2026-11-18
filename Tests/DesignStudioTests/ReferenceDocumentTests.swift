import Foundation
import Testing
@testable import DesignStudio

@MainActor
struct ReferenceDocumentTests {
    @Test func importsPastedMarkdownPathsAndReusesAttachments() throws {
        let root = try TempWorkspace.make(prefix: "reference-test")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "Weft 产品文档.md")
        let document = "# 产品文档\n\n支持设计稿版本对比。"
        try document.write(to: file, atomically: true, encoding: .utf8)

        let pasted = try AttachmentImporter.includingPastedDocuments(
            in: "\(file.path) 看下产品文档\n\"\(file.absoluteString)\"",
            attachments: []
        )
        let attachment = try #require(pasted.first)
        #expect(pasted.count == 1)
        #expect(attachment.filename == "Weft 产品文档.md")
        #expect(attachment.documentText == document)
        #expect(AttachmentImporter.load([file]).map(\.documentText) == [document])

        try FileManager.default.removeItem(at: file)
        let retry = try AttachmentImporter.includingPastedDocuments(in: file.path, attachments: pasted)
        #expect(retry == pasted)
        #expect(throws: (any Error).self) {
            try AttachmentImporter.includingPastedDocuments(in: file.path, attachments: [])
        }
    }

    @Test func sendsDocumentContentsAsReferenceTextAndPreservesImages() throws {
        let document = ChatAttachment(filename: "Weft.md", mimeType: "text/markdown",
                                      data: Data("# 设计资料\n支持版本对比".utf8))
        let image = ChatAttachment(filename: "reference.jpg", mimeType: "image/jpeg", data: Data([0xFF]))
        let message = ChatMessage(role: .user, text: "根据附件设计", attachments: [document, image])
        var project = Project(name: "t", kind: .prototype)
        let profile = ProviderProfile(name: "Claude", kind: .claudeCode)
        let request = DesignPrompt.makeRequest(project: project, designSystem: nil, newMessage: message, profile: profile)
        let prompt = request.flattenedPrompt(includeSystem: false)
        #expect(prompt.contains("根据附件设计"))
        #expect(prompt.contains("<reference_documents>"))
        #expect(prompt.contains("Weft.md"))
        #expect(prompt.contains("支持版本对比"))
        #expect(request.latestImages == [image])

        project.messages = [message, ChatMessage(role: .assistant, text: "好。")]
        let followUp = DesignPrompt.makeRequest(project: project, designSystem: nil,
                                               newMessage: ChatMessage(role: .user, text: "继续做详情页"), profile: profile)
        #expect(followUp.messages.first?.text.contains("支持版本对比") == true)
        #expect(followUp.latestImages.isEmpty)
    }
}
