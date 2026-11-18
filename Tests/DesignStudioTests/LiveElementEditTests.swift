import Testing
import Foundation
@testable import DesignStudio

/// 手动运行：DS_LIVE=1 swift test --filter LiveElementEdit（会真实调用已配置的 DeepSeek 和本机的 agy）
@Suite("Live element edit", .enabled(if: ProcessInfo.processInfo.environment["DS_LIVE"] == "1"))
struct LiveElementEditTests {
    @MainActor @Test func deepSeekReturnsOnlyElement() async throws {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "DesignStudio/providers.json")
        let profiles = try JSONDecoder().decode([ProviderProfile].self, from: Data(contentsOf: url))
        let profile = try #require(profiles.first { $0.name == "DeepSeek" })
        var project = Project(name: "t", kind: .prototype)
        let element = #"<section class="hero" data-name="今日推荐" style="padding:24px;border-radius:20px;background:#F3EDE4"><h2>晨间唤醒</h2><p>用十分钟，让呼吸慢下来</p></section>"#
        project.document = DesignDocument(pages: [DesignPage(name: "页面 1", artboards: [
            Artboard(name: "首页", html: "<!DOCTYPE html><html><head><style>body{margin:0;font-family:sans-serif;background:#FAF7F2}h2{margin:0}</style></head><body><header><h1>早安，林岚</h1></header>\(element)<footer>底部导航</footer></body></html>", width: 390, height: 844)
        ])])
        let sel = DesignPrompt.SelectionContext(artboardName: "首页", elementDescription: "<section> 元素（区块「今日推荐」）",
                                                elementHTML: element, elementEdit: true)
        let req = DesignPrompt.makeRequest(project: project, designSystem: nil,
                                           newMessage: ChatMessage(role: .user, text: "将这个背景改为黑色"),
                                           profile: profile, selection: sel)
        let llm = try ProviderFactory.make(profile)
        var text = ""
        for try await e in llm.stream(req) { if case .text(let t) = e { text += t } }
        print("REPLY >>>\n\(text)\n<<<")
        let block = try #require(ArtboardParser.element(text))
        #expect(block.complete)
        #expect(ArtboardParser.parse(text).isEmpty)
        #expect(block.html.hasPrefix("<section"))
        #expect(block.html.contains("晨间唤醒"))
    }

    /// Antigravity CLI：stdin NDJSON 输入、stream-json 输出，按元素修改只返回一个元素代码块
    @MainActor @Test func antigravityReturnsOnlyElement() async throws {
        var profile = ProviderProfile.antigravity()
        profile.model = "gemini-3.8-flash-medium"
        var project = Project(name: "t", kind: .prototype)
        let element = #"<section class="hero" data-name="今日推荐" style="padding:24px;border-radius:20px;background:#F3EDE4"><h2>晨间唤醒</h2><p>用十分钟，让呼吸慢下来</p></section>"#
        project.document = DesignDocument(pages: [DesignPage(name: "页面 1", artboards: [
            Artboard(name: "首页", html: "<!DOCTYPE html><html><head><style>body{margin:0;font-family:sans-serif;background:#FAF7F2}h2{margin:0}</style></head><body><header><h1>早安，林岚</h1></header>\(element)<footer>底部导航</footer></body></html>", width: 390, height: 844)
        ])])
        let sel = DesignPrompt.SelectionContext(artboardName: "首页", elementDescription: "<section> 元素（区块「今日推荐」）",
                                                elementHTML: element, elementEdit: true)
        let req = DesignPrompt.makeRequest(project: project, designSystem: nil,
                                           newMessage: ChatMessage(role: .user, text: "将这个背景改为黑色"),
                                           profile: profile, selection: sel)
        let llm = try ProviderFactory.make(profile)
        var text = "", statuses: [String] = []
        for try await e in llm.stream(req) {
            if case .text(let t) = e { text += t }
            if case .status(let s) = e { statuses.append(s) }
        }
        print("STATUS >>> \(statuses)\nREPLY >>>\n\(text)\n<<<")
        let block = try #require(ArtboardParser.element(text))
        #expect(block.complete)
        #expect(block.html.contains("晨间唤醒"))
    }
}
