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
        checkBackgroundEdit(block.html, isPatch: block.isPatch)
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
        #expect(ArtboardParser.parse(text).isEmpty)
        checkBackgroundEdit(block.html, isPatch: block.isPatch)
    }

    private func checkBackgroundEdit(_ content: String, isPatch: Bool) {
        if isPatch {
            let patch = ElementPatch.parse(content)
            #expect(patch?.style?.keys.contains { $0 == "background" || $0 == "background-color" } == true)
            #expect(patch?.text == nil)
        } else {
            #expect(content.hasPrefix("<section"))
            #expect(content.contains("晨间唤醒"))
        }
    }
}

/// 手动运行：DS_LIVE=1 swift test --filter LiveMedium（会真实调用本机的 agy）
/// 检查模型能按需求判断设计的媒介，而不是一律做成手机尺寸
@Suite("Live medium", .enabled(if: ProcessInfo.processInfo.environment["DS_LIVE"] == "1"))
struct LiveMediumTests {
    @MainActor @Test(arguments: [
        ("做一个面向独立开发者的项目管理 SaaS 官网首页", 1440.0),
        ("做一个电商后台的订单管理页面", 1440.0),
        ("做一个记账 App 的首页和记一笔两个页面", 390.0),
        ("做一份季度业务汇报的幻灯片，4 页就行", 1920.0)
    ])
    func picksMedium(prompt: String, expectedWidth: Double) async throws {
        var profile = ProviderProfile.antigravity()
        profile.model = "gemini-3.8-flash-low"
        let project = Project(name: "t", kind: .prototype)
        let req = DesignPrompt.makeRequest(project: project, designSystem: nil,
                                           newMessage: ChatMessage(role: .user, text: prompt),
                                           profile: profile)
        let llm = try ProviderFactory.make(profile)
        var text = ""
        for try await e in llm.stream(req) { if case .text(let t) = e { text += t } }
        let boards = ArtboardParser.parse(text)
        let intro = text.components(separatedBy: "```").first?.trimmed ?? ""
        print("PROMPT \(prompt)\n  INTRO \(intro.prefix(160))\n  BOARDS \(boards.map { "\($0.name ?? "?") \(Int($0.width ?? 0))×\(Int($0.height ?? 0))" })")
        #expect(!boards.isEmpty)
        #expect(boards.allSatisfy { $0.width == expectedWidth }, "\(prompt)")
    }
}

/// 手动运行：DS_LIVE=1 swift test --filter LiveModelListTests（打印本机各 CLI 实际提供的模型列表）
@Suite("Live model lists", .enabled(if: ProcessInfo.processInfo.environment["DS_LIVE"] == "1"))
struct LiveModelListTests {
    @Test func printLists() {
        for kind in [ProviderKind.claudeCode, .codex, .antigravity] {
            let list = ModelCatalog.known(for: kind)
            print("\(kind.rawValue) default=\(ModelCatalog.cliDefaultModel(kind) ?? "-") count=\(list.count)")
            for m in list {
                print("   \(m.id) | \(m.title) | ctx=\(m.limits.contextWindow ?? 0) | efforts=\(m.efforts) default=\(m.defaultEffort ?? "-")")
            }
        }
    }
}

/// 手动运行：DS_LIVE=1 swift test --filter LiveSharedStyles（会真实调用已配置的 DeepSeek）
/// 检查模型先输出画布共用样式，画板里不再重复设计变量
@Suite("Live shared styles", .enabled(if: ProcessInfo.processInfo.environment["DS_LIVE"] == "1"))
struct LiveSharedStylesTests {
    @MainActor @Test(arguments: [
        "做一个面向独立开发者的项目管理 SaaS 官网首页和定价页",
        "做一个记账 App 的首页和记一笔两个页面",
    ])
    func outputsSharedStylesheet(prompt: String) async throws {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "DesignStudio/providers.json")
        let profiles = try JSONDecoder().decode([ProviderProfile].self, from: Data(contentsOf: url))
        let profile = try #require(profiles.first { $0.name == "DeepSeek" })
        let project = Project(name: "t", kind: .prototype)
        let req = DesignPrompt.makeRequest(project: project, designSystem: nil,
                                           newMessage: ChatMessage(role: .user, text: prompt), profile: profile)
        let llm = try ProviderFactory.make(profile)
        var text = ""
        for try await e in llm.stream(req) { if case .text(let t) = e { text += t } }
        let shared = ArtboardParser.sharedCSS(text)
        let boards = ArtboardParser.parse(text)
        let rootsInBoards = boards.filter { $0.html.contains(":root") }.map { $0.name ?? "?" }
        print("PROMPT \(prompt)\n  SHARED \(shared?.css.count ?? 0) chars\n  BOARDS \(boards.map { "\($0.name ?? "?") \(Int($0.width ?? 0))×\($0.autoHeight ? "auto" : String(Int($0.height ?? 0))) \($0.html.count) chars" })\n  :root in boards \(rootsInBoards)")
        #expect(shared?.complete == true)
        #expect(boards.count >= 2)
        #expect(rootsInBoards.isEmpty)
    }
}
