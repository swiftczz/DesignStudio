import Foundation
import Testing
import WebKit
@testable import DesignStudio

@Suite("聊天 Markdown")
struct ChatMarkdownTests {
    @Test func rendersCommonMarkAndGitHubExtensions() {
        let html = MarkdownDocument.html("""
        # 一级标题
        ###### 六级标题

        商城支持 **粗体**、*斜体*、~~删除~~、`#3D6BA3` 和 [参考][docs]。

        > 引用
        >
        > 1. 第一项
        >    - 嵌套项

        - [x] 已完成
        - [ ] 待处理

        ---

        | 名称 | 说明 |
        | :--- | ---: |
        | 首页 | 样式 |

        ![截图](https://example.com/image.png)

        自动链接 https://example.com 和脚注。[^1]

        [docs]: https://example.com/docs "文档"
        [^1]: 脚注内容。

        ~~~html
        <button>打开</button>
        ~~~
        """)
        for token in ["<h1>", "<h6>", "<strong>粗体</strong>", "<em>斜体</em>", "<del>删除</del>",
                      "<code>#3D6BA3</code>", "<blockquote>", "<ol>", "<li>嵌套项</li>", "type=\"checkbox\"",
                      "<hr", "<table>", "text-align: right", "<img src=\"https://example.com/image.png\"",
                      "href=\"https://example.com\"", "href=\"https://example.com/docs\"",
                      "class=\"footnotes\"", "class=\"language-html\"", "&lt;button&gt;"] {
            #expect(html.contains(token), "\(token) expected in \(html)")
        }
    }

    @Test func separatesDesignOutputFromOrdinaryMarkdownCode() {
        let markdown = """
        示例：

        ````markdown
        ```html artboard="只是示例"
        <!DOCTYPE html><html></html>
        ```
        ````

        ```html
        <button>打开</button>


        <p>保留空行和代码</p>
        ```
        """
        let design = """
        ```html artboard="首页" width=390 height=844
        <main>画板内容</main>
        ```
        """
        let reply = markdown + "\n\n" + design + "\n\n---\n\n完成。"
        #expect(!HTMLExtractor.fenceStarted(markdown))
        #expect(ArtboardParser.parse(markdown).isEmpty)
        #expect(ArtboardParser.parse(reply).map(\.name) == ["首页"])
        #expect(HTMLExtractor.conversationalText(reply) == markdown + "\n\n---\n\n完成。")
        #expect(HTMLExtractor.conversationalText("    indented code") == "    indented code")
    }

    @Test @MainActor func selectsTextAcrossParagraphsAndListItemsInWebKit() async throws {
        let coordinator = MarkdownContentView.Coordinator()
        let web = MarkdownContentView.makeWebView(coordinator: coordinator)
        web.frame.size = CGSize(width: 360, height: 480)
        var height: CGFloat = 0
        coordinator.onHeight = { height = $0 }
        coordinator.update("开头 **加粗**\n\n- 第一项\n- 第二项\n\n最后一段", style: .reply, in: web)
        defer { MarkdownContentView.dismantleNSView(web, coordinator: coordinator) }
        #expect(MarkdownContentView.contains(web))
        #expect(web.responds(to: #selector(NSText.copy(_:))))

        for _ in 0..<125 where height == 0 { try await Task.sleep(for: .milliseconds(40)) }
        try #require(height > 44)

        let selection = try await web.callAsyncJavaScript("""
            const content = document.getElementById('content');
            const opening = content.querySelector('p').firstChild;
            const lastItem = content.querySelector('li:last-child').lastChild;
            const selection = window.getSelection();
            selection.setBaseAndExtent(lastItem, lastItem.length, opening, 0);
            return selection.toString();
            """, arguments: [:], in: nil, contentWorld: .defaultClient) as? String
        #expect(selection?.contains("开头 加粗") == true)
        #expect(selection?.contains("第一项") == true)
        #expect(selection?.contains("第二项") == true)
        #expect(selection?.contains("最后一段") == false)
    }
}
