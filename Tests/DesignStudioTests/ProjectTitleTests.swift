import Foundation
import Testing
@testable import DesignStudio

struct ProjectTitleTests {
    @Test func readsStreamedTitleWithoutChangingTheDesignReply() {
        #expect(ProjectTitle.splitReply("<!-- project-tit", streaming: true).body.isEmpty)
        #expect(ProjectTitle.splitReply("<!-- project-title: Weft", streaming: true).body.isEmpty)
        let body = "已设计阅读社区。\n\n```html artboard=\"发现\" width=1440 height=900\n<html></html>\n```"
        let reply = ProjectTitle.splitReply("<!-- project-title: Weft 阅读社区 -->\n\n" + body)
        #expect(reply.title == "Weft 阅读社区")
        #expect(reply.body == body)
        #expect(ArtboardParser.parse(reply.body).first?.name == "发现")
        #expect(ProjectTitle.splitReply("普通回复").body == "普通回复")
    }

    @Test func legacyPathTitlesUseAttachmentNamesAndManualTitlesArePreserved() {
        let prompt = "/Users/designer/Downloads/Weft_产品文档.md 帮我设计阅读社区"
        let attachment = ChatAttachment(filename: "Weft_产品文档.md", mimeType: "text/markdown", data: Data("# Weft".utf8))
        var project = Project(name: ProjectTitle.legacyName(from: prompt), kind: .prototype)
        project.messages = [.init(role: .user, text: prompt, attachments: [attachment])]
        #expect(project.needsTitleSummary)
        #expect(project.displayName == "Weft 产品文档")
        #expect(ProjectTitle.provisional(from: prompt, attachments: []) == "新建设计")
        #expect(ProjectTitle.clean(prompt) == nil)
        #expect(ProjectTitle.clean("这是一个很长的项目标题需要在侧边栏限制长度")?.count == 14)

        project.titleNeedsSummary = false
        #expect(project.displayName == project.name)
        #expect(!project.needsTitleSummary)
    }

    @Test func separateRequestRegeneratesOnlyTheTitle() {
        var project = Project(name: "阅读设计", kind: .prototype)
        project.messages = [.init(role: .user, text: "设计 Weft 阅读社区")]
        let request = ProjectTitle.request(for: project, maxOutput: 4096)

        #expect(request.maxTokens == 2048)
        #expect(request.replyFormatReminder == "Output only the short project title on one line.")
        #expect(request.messages[0].text.contains("Weft 阅读社区"))
        #expect(request.latestImages.isEmpty)
    }
}
