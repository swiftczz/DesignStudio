import Testing
import Foundation
@testable import DesignStudio

@Suite("HTML 提取")
struct HTMLExtractorTests {
    @Test func extractsFencedHTML() {
        let text = """
        这是一个登录页。

        ```html
        <!DOCTYPE html>
        <html><body>Hi</body></html>
        ```

        - 可以加暗色模式
        """
        #expect(HTMLExtractor.extract(from: text) == "<!DOCTYPE html>\n<html><body>Hi</body></html>")
        #expect(HTMLExtractor.conversationalText(text).contains("```") == false)
        #expect(HTMLExtractor.conversationalText(text).hasPrefix("这是一个登录页。"))
        // 代码块去掉后，说明和建议之间只留一个空行
        #expect(HTMLExtractor.conversationalText(text) == "这是一个登录页。\n\n- 可以加暗色模式")
    }

    @Test func partialWhileStreaming() {
        let text = "好的\n```html\n<!DOCTYPE html>\n<html><body><h1>Half"
        #expect(HTMLExtractor.extract(from: text) == nil)
        #expect(HTMLExtractor.partial(from: text)?.hasPrefix("<!DOCTYPE html>") == true)
        #expect(HTMLExtractor.conversationalText(text) == "好的")
    }

    @Test func rawDocumentFallback() {
        let text = "<!doctype html><html><body>x</body></html>"
        #expect(HTMLExtractor.extract(from: text) == text)
    }
}

@Suite("可调参数")
struct TweakParserTests {
    let html = """
    <html><head>
    <script type="application/json" id="ds-tweaks">
    [{"var":"--accent","label":"主色","type":"color","value":"#D97757"},
     {"var":"--radius","label":"圆角","type":"range","min":0,"max":24,"unit":"px","value":12}]
    </script>
    </head><body></body></html>
    """

    @Test func parsesControls() {
        let controls = TweakParser.parse(html)
        #expect(controls.count == 2)
        #expect(controls[1].value == "12")
        #expect(controls[1].cssValue("16") == "16px")
    }

    @Test func bakesValues() {
        let controls = TweakParser.parse(html)
        let baked = TweakParser.bake(html, controls: controls, values: ["--radius": "20"])
        #expect(baked.contains("--radius: 20px !important;"))
        #expect(TweakParser.parse(baked).first { $0.variable == "--radius" }?.value == "20")
    }
}

@Suite("工具")
struct UtilityTests {
    @Test func splitsArguments() {
        #expect(ArgumentSplitter.split(#"--effort high -c key="a b""#) == ["--effort", "high", "-c", "key=a b"])
        #expect(ArgumentSplitter.split("") == [])
    }

    @Test func buildsEndpoints() throws {
        #expect(try Endpoint.anthropicMessages("https://api.anthropic.com").absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(try Endpoint.anthropicMessages("https://open.bigmodel.cn/api/anthropic/").absoluteString == "https://open.bigmodel.cn/api/anthropic/v1/messages")
        #expect(try Endpoint.chatCompletions("https://api.openai.com/v1").absoluteString == "https://api.openai.com/v1/chat/completions")
    }

    @Test func normalizesRoles() {
        let msgs = DesignPrompt.normalize([
            LLMMessage(role: .assistant, text: "a"),
            LLMMessage(role: .user, text: "u1"),
            LLMMessage(role: .user, text: "u2"),
            LLMMessage(role: .assistant, text: "a2")
        ])
        #expect(msgs.map(\.role) == [.user, .assistant])
        #expect(msgs[0].text == "u1\n\nu2")
    }
}

@Suite("模型来源")
struct ProviderTests {
    @Test func decodesOldProviderJSON() throws {
        // 旧版本保存的配置：没有 models / availableModels / modelLimits，还带着已废弃的 maxTokens
        let json = """
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"DeepSeek","kind":"openAICompatible",
         "baseURL":"https://api.deepseek.com/v1","model":"deepseek-chat","executablePath":"",
         "extraArguments":"","maxTokens":8192,"useBearerAuth":false,"extraHeaders":""}
        """
        let p = try JSONDecoder().decode(ProviderProfile.self, from: Data(json.utf8))
        #expect(p.models == ["deepseek-chat"])
        #expect(p.limits.maxOutput == nil)
    }

    @Test func parsesOpenRouterStyleLimits() {
        let obj: [String: Any] = ["data": [
            ["id": "vendor/new-model", "name": "New Model", "created": 200, "context_length": 1_000_000,
             "top_provider": ["max_completion_tokens": 128_000]],
            ["id": "text-embedding-3-large", "created": 300],
            ["id": "vendor/old-model", "created": 100]
        ]]
        let models = ModelFetcher.parseOpenAI(obj)
        #expect(models.map(\.id) == ["vendor/new-model", "vendor/old-model"])
        #expect(models[0].limits == ModelLimits(contextWindow: 1_000_000, maxOutput: 128_000))
        #expect(models[0].title == "New Model")
    }

    @Test func parsesAnthropicLimits() {
        let obj: [String: Any] = ["data": [
            ["id": "claude-opus-5-5", "display_name": "Claude Opus 5.5",
             "max_input_tokens": 1_000_000, "max_tokens": 128_000]
        ]]
        let m = ModelFetcher.parseAnthropic(obj)
        #expect(m.first?.limits == ModelLimits(contextWindow: 1_000_000, maxOutput: 128_000))
    }

    @Test func requestUsesModelOutputLimit() {
        var profile = ProviderProfile(name: "X", kind: .openAIResponses, baseURL: "https://example.com/v1", model: "m")
        profile.modelLimits["m"] = ModelLimits(contextWindow: 400_000, maxOutput: 64_000)
        let project = Project(name: "t", kind: .landing)
        let req = DesignPrompt.makeRequest(project: project, designSystem: nil,
                                           newMessage: ChatMessage(role: .user, text: "hi"), profile: profile)
        #expect(req.maxTokens == 64_000)

        // 上限未知：不传输出上限
        let unknown = ProviderProfile(name: "Y", kind: .openAICompatible, baseURL: "https://example.com/v1", model: "n")
        let req2 = DesignPrompt.makeRequest(project: project, designSystem: nil,
                                            newMessage: ChatMessage(role: .user, text: "hi"), profile: unknown)
        #expect(req2.maxTokens == nil)
    }

    @Test func endpointsAcceptFullURLs() throws {
        #expect(try Endpoint.responses("https://api.openai.com/v1/").absoluteString == "https://api.openai.com/v1/responses")
        #expect(try Endpoint.openAIModels("https://api.openai.com/v1/chat/completions").absoluteString == "https://api.openai.com/v1/models")
        #expect(try Endpoint.anthropicModels("https://api.anthropic.com").absoluteString == "https://api.anthropic.com/v1/models")
    }
}

@Suite("画板")
struct ArtboardTests {
    @Test func parsesMultipleArtboards() {
        let text = """
        设计了两个界面。

        ```html artboard="首页" width=390 height=844
        <!DOCTYPE html><html><body>A</body></html>
        ```

        ```html artboard='详情页' width="430" height=932
        <!DOCTYPE html><html><body>B</body></html>
        ```

        - 可以加暗色模式
        """
        let boards = ArtboardParser.parse(text)
        #expect(boards.count == 2)
        #expect(boards[0] == ParsedArtboard(name: "首页", width: 390, height: 844,
                                            html: "<!DOCTYPE html><html><body>A</body></html>", complete: true))
        #expect(boards[1].name == "详情页" && boards[1].width == 430 && boards[1].height == 932)
        #expect(HTMLExtractor.conversationalText(text) == "设计了两个界面。\n\n- 可以加暗色模式")
    }

    @Test func partialLastBlock() {
        let text = "好的\n```html artboard=\"封面\"\n<!DOCTYPE html><html><body><h1>标"
        let boards = ArtboardParser.parse(text)
        #expect(boards.count == 1)
        #expect(boards[0].complete == false)
        #expect(boards[0].name == "封面")
    }

    @Test func annotatorSkipsScriptsAndRoundTrips() {
        let html = """
        <!DOCTYPE html><html><head><style>a > b { color: red }</style>
        <script>const s = "<div>not a tag</div>";</script></head>
        <body><main class="x"><p>Hi<br/></p><img src="a.png"></main></body></html>
        """
        let (annotated, maxID) = HTMLAnnotator.annotate(html)
        #expect(maxID == 5)   // body, main, p, br, img
        #expect(annotated.contains("<main class=\"x\" data-ds-id=\"2\">"))
        #expect(annotated.contains("<br data-ds-id=\"4\"/>"))
        #expect(annotated.contains("\"<div>not a tag</div>\""))
        #expect(HTMLAnnotator.strip(annotated) == html)
    }

    @Test func mergeReplacesByNameAndAppendsNew() {
        var doc = DesignDocument(pages: [DesignPage(name: "页面 1", artboards: [
            Artboard(name: "首页", html: "old", width: 390, height: 844)
        ])])
        let pageID = doc.pages[0].id
        let changed = doc.merge([
            ParsedArtboard(name: "首页", html: "new", complete: true),
            ParsedArtboard(name: "设置", width: 390, height: 700, html: "settings", complete: true)
        ], into: pageID, kind: .prototype)
        #expect(changed.count == 2)
        #expect(doc.pages[0].artboards.count == 2)
        #expect(doc.pages[0].artboards[0].html == "new")
        #expect(doc.pages[0].artboards[1].x == 390 + 80)
        #expect(doc.pages[0].artboards[1].height == 700)
    }

    @Test func legacyProjectMigrates() {
        var project = Project(name: "旧项目", kind: .slides)
        project.versions = [DesignVersion(number: 1, html: "<html></html>", summary: "v1")]
        let doc = project.workingDocument
        #expect(doc.allArtboards.count == 1)
        #expect(doc.allArtboards[0].width == 1920)
    }
}

@Suite("画布加载")
struct CanvasLoadingTests {
    @Test func externalStylesheetsBecomeNonBlocking() {
        let html = #"<head><link rel="preconnect" href="https://fonts.gstatic.com"><link href="https://fonts.googleapis.com/css2?family=Noto+Sans+SC" rel="stylesheet"><link rel="stylesheet" href="local.css"></head>"#
        let out = HTMLAnnotator.nonBlockingStylesheets(html)
        #expect(out.contains(#"rel="stylesheet" media="print" onload="this.media='all'">"#))
        #expect(out.contains(#"<link rel="preconnect" href="https://fonts.gstatic.com">"#))
        #expect(out.contains(#"<link rel="stylesheet" href="local.css">"#))
    }
}

@Suite("提示词")
struct PromptTests {
    @Test func latestMessageCarriesArtboardReminder() {
        let profile = ProviderProfile(name: "X", kind: .codex)
        let project = Project(name: "t", kind: .prototype)
        let req = DesignPrompt.makeRequest(project: project, designSystem: nil,
                                           newMessage: ChatMessage(role: .user, text: "三个页面"), profile: profile)
        let last = req.messages.last?.text ?? ""
        #expect(last.contains("artboard="))
        #expect(last.contains("不要把多个界面并排画在同一个画板里"))
        #expect(!req.system.contains("single ```html"))
    }

    @Test func elementEditOmitsBothArtboardBodiesAndKeepsStyles() {
        let profile = ProviderProfile(name: "X", kind: .codex)
        var project = Project(name: "t", kind: .prototype)
        project.document = DesignDocument(pages: [DesignPage(name: "页面 1", artboards: [
            Artboard(name: "首页", html: "<html><body><section class=\"hero\">Hi</section><footer>Unrelated footer</footer></body></html>",
                     width: 390, height: 844),
            Artboard(name: "设置", html: "<html><body>settings</body></html>", width: 390, height: 844)
        ])])
        let selection = DesignPrompt.SelectionContext(artboardName: "首页", elementDescription: "<section> 元素",
                                                      elementHTML: "<section class=\"hero\">Hi</section>", elementEdit: true,
                                                      computedStyle: ["background-color": "rgb(255, 255, 255)"])
        let req = DesignPrompt.makeRequest(project: project, designSystem: nil,
                                           newMessage: ChatMessage(role: .user, text: "背景改为黑色"),
                                           profile: profile, selection: selection)
        let last = req.messages.last?.text ?? ""
        #expect(req.elementEdit)
        #expect(last.contains("## 选中的元素"))
        #expect(last.contains("```html element"))
        #expect(last.contains("background-color: rgb(255, 255, 255)"))
        #expect(!last.contains("Unrelated footer"))
        #expect(!last.contains("settings"))
        #expect(!last.contains("不要把多个界面并排画在同一个画板里"))
        #expect(req.system.contains("## Element edits"))
    }

    @Test func artboardScopeKeepsNamedReferencesAndUnscopedChatKeepsAllArtboards() {
        let profile = ProviderProfile(name: "X", kind: .codex)
        var project = Project(name: "t", kind: .prototype)
        project.document = DesignDocument(pages: [DesignPage(name: "当前页面", artboards: [
            Artboard(name: "首页", html: "<main>home body</main>", width: 390, height: 844),
            Artboard(name: "设置", html: "<main>settings body</main>", width: 390, height: 844),
            Artboard(name: "收藏", html: "<main>favorites body</main>", width: 390, height: 844)
        ])])
        let selection = DesignPrompt.SelectionContext(artboardName: "首页", elementHTML: "<button>打开</button>", elementEdit: true)
        let message = ChatMessage(role: .user, text: "参考设置的配色")
        let scoped = DesignPrompt.makeRequest(project: project, designSystem: nil, newMessage: message,
                                              profile: profile, selection: selection)
        #expect(!scoped.elementEdit)
        #expect(scoped.messages.last?.text.contains("home body") == true)
        #expect(scoped.messages.last?.text.contains("settings body") == true)
        #expect(scoped.messages.last?.text.contains("favorites body") == false)
        let all = DesignPrompt.makeRequest(project: project, designSystem: nil, newMessage: message, profile: profile)
        #expect(all.messages.last?.text.contains("favorites body") == true)
    }
}

@Suite("服务商预设")
struct ProviderPresetTests {
    @Test func oneEntryPerVendorAndBaseURLFollowsKind() {
        let names = ProviderPreset.all.map(\.name)
        #expect(Set(names).count == names.count)
        #expect(names.filter { $0.contains("DeepSeek") }.count == 1)

        let toAnthropic = ProviderPreset.switching(baseURL: "https://api.deepseek.com/v1/", to: .anthropicAPI)
        #expect(toAnthropic?.url == "https://api.deepseek.com/anthropic")
        #expect(toAnthropic?.bearer == true)
        #expect(ProviderPreset.switching(baseURL: "https://api.deepseek.com/anthropic", to: .openAIResponses)?.url
                == "https://api.deepseek.com/v1")
        // 自定义地址或该服务商没有对应类型的地址时保持不变
        #expect(ProviderPreset.switching(baseURL: "https://my.proxy/v1", to: .anthropicAPI) == nil)
        #expect(ProviderPreset.switching(baseURL: "https://api.siliconflow.cn/v1", to: .anthropicAPI) == nil)
    }
}

@Suite("形状")
struct ShapeTests {
    @Test func arrowSVGCoversBothEndsWithHead() {
        let (html, origin) = ProjectSession.strokeShapeHTML(.arrow, from: CGPoint(x: 100, y: 200), to: CGPoint(x: 40, y: 120))
        #expect(origin == CGPoint(x: 30, y: 110))             // 左上角留 10px 余量
        #expect(html.contains(#"width="80" height="100""#))
        #expect(html.contains("M70.0 90.0 L10.0 10.0"))       // 起点 → 终点（相对外框）
        #expect(html.components(separatedBy: " M").count == 2) // 箭头多一段箭头折线
        #expect(html.contains(#"data-name="箭头""#))
        let (line, _) = ProjectSession.strokeShapeHTML(.line, from: .zero, to: CGPoint(x: 160, y: 0))
        #expect(!line.contains(" M"))
        #expect(line.contains(#"data-name="直线""#))
    }
}

@Suite("对话显示")
struct ChatDisplayTests {
    @MainActor @Test func providerShownOnlyWhenModelChanges() {
        func ai(_ p: String) -> ChatMessage { ChatMessage(role: .assistant, text: "x", providerName: p) }
        let u = ChatMessage(role: .user, text: "hi")
        let a1 = ai("DeepSeek · Flash"), a2 = ai("DeepSeek · Flash"), a3 = ai("Claude · Opus"), a4 = ai("Claude · Opus"), a5 = ai("DeepSeek · Flash")
        let shown = ChatPanel.providerHeaders([u, a1, u, a2, u, a3, u, a4, u, a5])
        #expect(shown == [a1.id, a3.id, a5.id])
    }
}

@Suite("元素级修改")
struct ElementEditParsingTests {
    @Test func targetDecodesFromOldMessagesAndAppearsInHistory() throws {
        // 旧数据没有 target 字段也能解码
        let old = try JSONDecoder().decode(ChatMessage.self, from: Data(#"{"id":"\#(UUID().uuidString)","role":"user","text":"hi","attachments":[],"comments":[],"createdAt":0,"wasStopped":false}"#.utf8))
        #expect(old.target == nil)

        var project = Project(name: "t", kind: .prototype)
        var user = ChatMessage(role: .user, text: "背景改为黑色")
        user.target = MessageTarget(artboardID: UUID(), artboardName: "冥想计时", elementKind: "button",
                                    elementName: "「开始或暂停」", selector: "button")
        project.messages = [user, ChatMessage(role: .assistant, text: "好的")]
        let req = DesignPrompt.makeRequest(project: project, designSystem: nil,
                                           newMessage: ChatMessage(role: .user, text: "再大一点"),
                                           profile: ProviderProfile(name: "X", kind: .codex))
        #expect(req.messages.first?.text.hasPrefix("（针对画板「冥想计时」中的按钮「开始或暂停」）") == true)
    }

    @Test func parsesElementBlockAndSkipsItAsArtboard() {
        let reply = "已把背景改为黑色。\n\n```html element\n<section class=\"hero\" style=\"background:#000\">Hi</section>\n```\n"
        let block = ArtboardParser.element(reply)
        #expect(block?.complete == true)
        #expect(block?.html == "<section class=\"hero\" style=\"background:#000\">Hi</section>")
        #expect(ArtboardParser.parse(reply).isEmpty)
        #expect(HTMLExtractor.conversationalText(reply).trimmed == "已把背景改为黑色。")
    }

    @Test func partialElementBlockIsIncomplete() {
        let block = ArtboardParser.element("好的\n```html element\n<div>")
        #expect(block?.complete == false)
    }

    @Test func parsesPatchWithoutTreatingJSONAsArtboardOrChat() throws {
        let reply = "已更新按钮。\n```html element patch\n{\"text\":\"\",\"style\":{\"color\":\"#f00\"}}\n```"
        let block = try #require(ArtboardParser.element(reply))
        #expect(block.complete && block.isPatch)
        let patch = try #require(ElementPatch.parse(block.html))
        #expect(patch.text == "")
        #expect(patch.style == ["color": "#f00"])
        #expect(ArtboardParser.parse(reply).isEmpty)
        #expect(HTMLExtractor.conversationalText(reply) == "已更新按钮。")
        #expect(ElementPatch.parse("{}") == nil)
    }

    @Test func artboardsStillParsedAlongsideElementInfo() {
        let reply = "```html artboard=\"首页\" width=390 height=844\n<!DOCTYPE html><html></html>\n```"
        #expect(ArtboardParser.element(reply) == nil)
        #expect(ArtboardParser.parse(reply).map(\.name) == ["首页"])
    }
}

@Suite("思考内容")
struct ThinkingParsingTests {
    private func run(_ chunks: [String]) -> (thinking: String, text: String) {
        var s = ThinkTagSplitter()
        var parts: [ThinkTagSplitter.Part] = []
        for c in chunks { parts += s.feed(c) }
        parts += s.finish()
        return (parts.filter(\.isThinking).map(\.text).joined(), parts.filter { !$0.isThinking }.map(\.text).joined())
    }

    @Test func splitsThinkTagsAcrossChunks() {
        let r = run(["\n<thi", "nk>先想", "一想</th", "ink>\n\n好的，", "设计如下"])
        #expect(r.thinking == "先想一想")
        #expect(r.text == "好的，设计如下")
    }

    @Test func plainContentPassesThrough() {
        let r = run(["好的", "<b>不是思考</b>"])
        #expect(r.thinking.isEmpty)
        #expect(r.text == "好的<b>不是思考</b>")
    }

    @Test func unterminatedThinkingStaysThinking() {
        let r = run(["<think>还在想"])
        #expect(r.thinking == "还在想")
        #expect(r.text.isEmpty)
    }
}

@Suite("对话滚动跟随")
struct ScrollFollowTests {
    private func m(_ offset: CGFloat, _ toBottom: CGFloat) -> ScrollMetrics {
        var x = ScrollMetrics.zero
        x.offset = offset; x.distanceToBottom = toBottom
        return x
    }

    @Test func contentGrowthKeepsFollowing() {
        // 内容变长：offset 不变、离底部变远 → 继续跟随
        #expect(ScrollMetrics.shouldFollow(old: m(500, 0), new: m(500, 300), current: true))
    }

    @Test func userScrollUpStopsFollowing() {
        #expect(!ScrollMetrics.shouldFollow(old: m(500, 0), new: m(380, 120), current: true))
    }

    @Test func returningToBottomResumes() {
        #expect(ScrollMetrics.shouldFollow(old: m(380, 120), new: m(495, 5), current: false))
    }
}

@Suite("服务商 Logo")
@MainActor
struct ProviderBrandTests {
    @Test func detectsPresetsAndAccounts() {
        #expect(ProviderBrand.detect(.claudeCode()) == .claude)
        #expect(ProviderBrand.detect(.codex()) == .openai)
        let expected: [String: ProviderBrand] = [
            "Anthropic": .anthropic, "OpenAI": .openai, "OpenRouter": .openrouter, "DeepSeek": .deepseek,
            "智谱 GLM": .zhipu, "Kimi（Moonshot）": .kimi, "阿里云百炼（通义）": .bailian,
            "硅基流动": .siliconflow, "Ollama（本地）": .ollama
        ]
        for preset in ProviderPreset.all {
            #expect(ProviderBrand.detect(preset.makeProfile()) == expected[preset.name], "\(preset.name)")
        }
        #expect(ProviderBrand.detect(ProviderPreset.custom.makeProfile()) == nil)
        #expect(ProviderBrand.detect(name: "DeepSeek · DeepSeek-V4.1-Flash") == .deepseek)
    }

    @Test func everyLogoRenders() {
        for brand in ProviderBrand.allCases {
            let image = brand.image
            #expect(image != nil, "\(brand)")
            #expect(image?.isTemplate == true)
            #expect(brand.menuImage()?.isTemplate == true)
        }
    }
}

@Suite("对话滚动跟随（布局变化）")
struct ScrollFollowLayoutTests {
    @Test func contentResizeIsNotUserScroll() {
        // 懒加载测量让内容变矮、系统随之调整 offset：不应停止跟随
        let old = ScrollMetrics(offset: 900, distanceToBottom: 120, contentHeight: 1892)
        let new = ScrollMetrics(offset: 780, distanceToBottom: 120, contentHeight: 1765)
        #expect(ScrollMetrics.shouldFollow(old: old, new: new, current: true))
        // 内容不变时往上滚才算用户操作
        let up = ScrollMetrics(offset: 700, distanceToBottom: 200, contentHeight: 1765)
        #expect(!ScrollMetrics.shouldFollow(old: new, new: up, current: true))
    }
}

@Suite("Antigravity")
@MainActor
struct AntigravityTests {
    @Test func parsesModelList() {
        let out = "Fetching available models...\ngemini-4-carbon-medium\tGemini 4 Carbon (Medium)\nclaude-sonnet-4-6\tClaude Sonnet 4.6 (Thinking)\n"
        let models = ModelCatalog.parseAntigravityModels(out)
        #expect(models.map(\.id) == ["gemini-4-carbon-medium", "claude-sonnet-4-6"])
        #expect(models.first?.title == "Gemini 4 Carbon (Medium)")
        #expect(ModelCatalog.parseAntigravityModels("Fetching available models...\n").isEmpty)
    }

    @Test func stdinMessageIsOneNDJSONLine() throws {
        let line = AntigravityProvider.inputLine("第一行\n第二行 \"引号\"")
        #expect(line.hasSuffix("\n"))
        #expect(line.dropLast().contains("\n") == false)
        let obj = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(obj["event"] as? String == "user")
        #expect((obj["message"] as? [String: Any])?["content"] as? String == "第一行\n第二行 \"引号\"")
    }

    @Test func profileUsesAgyAndLogo() {
        let p = ProviderProfile.antigravity()
        #expect(p.kind.isCLI)
        #expect(p.cliExecutable == "agy")
        #expect(ProviderBrand.detect(p) == .antigravity)
        #expect(p.model.isEmpty)
    }
}

@Suite("模型思考强度分组")
struct ModelFamilyTests {
    @Test func groupsEffortsAndKeepsOthers() {
        let titles = ["Gemini 4 Carbon (Medium)", "Gemini 4 Carbon (High)", "Gemini 4 Carbon (Low)",
                      "Gemini 4 Hydrogen (XHigh)", "Gemini 4 Hydrogen (High)",
                      "Orchestrator (Carbon)", "Claude Sonnet 4.6 (Thinking)", "GPT-OSS 120B (Medium)", "GPT-6.1-Sol"]
        let options = titles.map { ModelOption(id: $0.lowercased(), title: $0) }
        let families = ModelFamily.group(options)
        #expect(families.map(\.name) == ["Gemini 4 Carbon", "Gemini 4 Hydrogen", "Orchestrator (Carbon)",
                                         "Claude Sonnet 4.6 (Thinking)", "GPT-OSS 120B (Medium)", "GPT-6.1-Sol"])
        #expect(families[0].variants.map(\.title) == ["Low", "Medium", "High"])
        #expect(families[0].defaultVariant.title == "Medium")
        #expect(families[1].variants.map(\.title) == ["High", "XHigh"])
        #expect(families[1].defaultVariant.title == "High")
        // 只有一个强度的模型仍是普通菜单项，显示原标题
        #expect(families[4].isSingle)
        #expect(families[4].variants[0].option.title == "GPT-OSS 120B (Medium)")
    }
}


@Suite("思考强度参数")
struct EffortParamTests {
    @Test func paramEffortsExpandOneModel() {
        // Codex：默认强度已知（high），没有「默认」项
        let codex = ModelOption(id: "gpt-6.1-sol", title: "GPT-6.1-Sol", efforts: ["high", "low", "max"], defaultEffort: "high")
        // Claude：默认强度未知，第一项是「默认」
        let claude = ModelOption(id: "claude-opus-5-5", title: "Opus 5.5", efforts: ["low", "xhigh"])
        let families = ModelFamily.group([codex, claude, ModelOption(id: "plain", title: "Plain")])
        #expect(families.count == 3)
        #expect(families[0].usesEffortParam)
        #expect(families[0].variants.map(\.title) == ["Low", "High", "Max"])
        #expect(families[0].defaultVariant.effort == "high")
        #expect(families[1].variants.map(\.title) == ["默认", "Low", "XHigh"])
        #expect(families[1].defaultVariant.effort == nil)
        #expect(!families[2].usesEffortParam && families[2].isSingle)
    }

    @Test func parsesDeepSeekEfforts() {
        let obj: [String: Any] = ["data": [["id": "deepseek-flash", "name": "DeepSeek-V4.1-Flash",
                                            "effort": ["supported_levels": ["low", "high", "max"], "default_level": "high"]]]]
        let m = ModelFetcher.parseOpenAI(obj)[0]
        #expect(m.efforts == ["low", "high", "max"])
        #expect(m.defaultEffort == "high")
    }

    @Test func resolvedCarriesEffort() {
        let p = ProviderProfile.claudeCode().resolved(model: "claude-opus-5-5", effort: "max")
        #expect(p.model == "claude-opus-5-5")
        #expect(p.effort == "max")
        #expect(ProviderProfile.claudeCode().resolved(model: nil).effort == "")
    }
}


@Suite("命令行工具安装诊断")
struct CLIDiagnosisTests {
    /// 用户截图里的实际输出：npm 全局安装缺少 Apple 芯片的平台包
    static let codexBroken = """
    file:///usr/local/lib/node_modules/@openai/codex/bin/codex.js:108
      throw new Error(
            ^
    Error: Missing optional dependency @openai/codex-darwin-arm64. Reinstall Codex: npm install -g @openai/codex@latest
        at findCodexExecutable (file:///usr/local/lib/node_modules/@openai/codex/bin/codex.js:108:9)
    Node.js v25.2.1
    """

    @Test func detectsBrokenNPMInstall() {
        #expect(CLIDiagnosis.reinstallCommand(for: Self.codexBroken, kind: .codex) == "npm install -g @openai/codex@latest")
        let error = CodexProvider.classify(Self.codexBroken)
        #expect(error.localizedDescription.contains("npm install -g @openai/codex@latest"))
        #expect(!error.localizedDescription.contains("findCodexExecutable"))
    }

    /// 用一个假的 codex（输出同样的报错并以 1 退出）跑真实的状态检测
    @MainActor @Test func refreshReportsBrokenInsteadOfLoggedOut() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ds-fake-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appending(path: "codex")
        try "#!/bin/sh\ncat >&2 <<'EOF'\n\(Self.codexBroken)\nEOF\nexit 1\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let auth = CLIAuthService()
        await auth.refresh(.codex, executable: fake.path)
        #expect(auth.state(.codex) == .broken(fix: "npm install -g @openai/codex@latest"))
        #expect(auth.state(.codex).label == "安装不完整")
    }

    @Test func normalLoggedOutIsNotBroken() {
        #expect(CLIDiagnosis.reinstallCommand(for: "Not logged in", kind: .codex) == nil)
        #expect(CLIDiagnosis.reinstallCommand(for: "zsh: command not found: codex", kind: .codex) == nil)
    }
}

@Suite("CLI 默认模型")
struct CLIDefaultModelTests {
    @Test func reportedModelIsRecordedWithoutContextSuffix() {
        let key = "cliReportedModel." + ProviderKind.claudeCode.rawValue
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        ModelCatalog.recordReportedModel("claude-opus-5-5[1m]", kind: .claudeCode)
        #expect(ModelCatalog.lastReportedModel(.claudeCode) == "claude-opus-5-5")
    }

    @Test func displayModelNeverSaysDefaultWhenKnown() {
        var p = ProviderProfile.codex()
        p.model = ""
        if let id = ModelCatalog.cliDefaultModel(.codex) {
            #expect(p.displayModel == ModelCatalog.title(for: id, kind: .codex))
            #expect(p.cliDefaultTitle.hasPrefix("默认（"))
        } else {
            #expect(p.displayModel == "默认模型")
        }
    }
}

@Suite("Claude 实际思考强度")
struct ClaudeEffortTests {
    static let catalogJSON = #"""
    {"catalog": {"config": {"models": [
        {"id": "claude-opus-5-5", "runtime": {"effort_levels": ["low","medium","high","xhigh","max"], "default_effort": "medium"}},
        {"id": "claude-sonnet-5-5", "runtime": {"effort_levels": ["low","medium","high"], "default_effort": "medium"}}
      ]},
      "state": {"model": "claude-opus-5-5", "thinking_by_model": [{"id": "claude-opus-5-5", "thinking": {"type": "effort", "effort": "xhigh"}}]}}}
    """#

    @Test func parsesCatalog() throws {
        let c = try #require(ModelCatalog.parseClaudeCatalog(Data(Self.catalogJSON.utf8)))
        #expect(c.currentModel == "claude-opus-5-5")
        #expect(c.levels["claude-sonnet-5-5"] == ["low", "medium", "high"])
        #expect(c.builtinDefault["claude-opus-5-5"] == "medium")
        #expect(c.stateEffort["claude-opus-5-5"] == "xhigh")
    }

    @Test func precedenceMatchesClaudeCode() throws {
        let c = try #require(ModelCatalog.parseClaudeCatalog(Data(Self.catalogJSON.utf8)))
        // settings 里该模型的强度最优先（环境变量除外）
        let perModel: [String: Any] = ["modelSettings": ["claude-opus-5-5": ["effortLevel": "high"]], "effortLevel": "low"]
        #expect(ModelCatalog.claudeEffectiveEffort(model: "claude-opus-5-5", catalog: c, settings: perModel) == "high")
        // 其次是顶层 effortLevel
        #expect(ModelCatalog.claudeEffectiveEffort(model: "claude-sonnet-5-5", catalog: c, settings: perModel) == "low")
        // 再其次是目录里这个账号的强度，最后是内置默认
        #expect(ModelCatalog.claudeEffectiveEffort(model: "claude-opus-5-5", catalog: c, settings: [:]) == "xhigh")
        #expect(ModelCatalog.claudeEffectiveEffort(model: "claude-sonnet-5-5", catalog: c, settings: [:]) == "medium")
    }
}

@Suite("不内置模型")
struct NoBuiltInModelTests {
    @Test func claudeModelsComeFromClaudeCodeCatalog() throws {
        let json = #"""
        {"catalog": {"config": {
          "models": [
            {"id": "claude-new-9", "name": "New 9", "section": "main",
             "runtime": {"max_input_tokens": 2000000, "max_output_tokens": 64000, "effort_levels": ["low","high"], "default_effort": "high"}},
            {"id": "claude-old-1", "name": "Old 1", "section": "overflow", "runtime": {}}
          ],
          "provider_alias_targets": {"new": {"default": "claude-new-9"}}
        }, "state": {"model": "claude-new-9"}}}
        """#
        let c = try #require(ModelCatalog.parseClaudeCatalog(Data(json.utf8)))
        // 只有 Claude Code 选择器里的模型（section = main）进入菜单，旧模型只用于查名称和上限
        #expect(c.pickerModels.map(\.id) == ["claude-new-9"])
        #expect(c.pickerModels[0].title == "New 9")
        #expect(c.pickerModels[0].limits.contextWindow == 2_000_000)
        #expect(c.pickerModels[0].efforts == ["low", "high"])
        #expect(c.allModels.count == 2)
        #expect(c.aliases["new"] == "claude-new-9")
    }

    @Test func presetsHaveNoDefaultModel() {
        for preset in ProviderPreset.all {
            #expect(preset.makeProfile().model.isEmpty, "\(preset.name)")
        }
        #expect(ProviderProfile.anthropic().model.isEmpty)
    }

    @Test func thinkingSummaryByVersionNotByList() {
        let api = URL(string: "https://api.anthropic.com")!
        #expect(AnthropicProvider.supportsThinkingSummary(model: "claude-opus-4-6", url: api))
        #expect(AnthropicProvider.supportsThinkingSummary(model: "claude-sonnet-7-1", url: api))   // 未来的新模型
        #expect(AnthropicProvider.supportsThinkingSummary(model: "claude-newfamily-5", url: api))
        #expect(!AnthropicProvider.supportsThinkingSummary(model: "claude-haiku-4-5-20251001", url: api))
        #expect(!AnthropicProvider.supportsThinkingSummary(model: "claude-opus-4-20250514", url: api))
        #expect(!AnthropicProvider.supportsThinkingSummary(model: "claude-3-5-sonnet-20241022", url: api))
        #expect(!AnthropicProvider.supportsThinkingSummary(model: "claude-opus-4-6", url: URL(string: "https://open.bigmodel.cn")!))
    }
}
