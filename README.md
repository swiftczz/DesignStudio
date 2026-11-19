# DesignStudio

一个原生 macOS AI 设计画布应用（SwiftUI · Liquid Glass · SPM）。

用自然语言描述想法 → AI 在画布上实时生成可交互的 HTML 设计稿 → 继续对话、直接在画布上批注元素、拖动参数微调 → 导出或交给 Claude Code 落地成生产代码。

可以接入多种模型来源：

| 来源 | 登录 / 鉴权方式 | 说明 |
| --- | --- | --- |
| **Claude 账号** | 官方 Claude Code CLI：`claude auth login` | 支持 Pro / Max 订阅或 Console 账号，额度走你自己的账号 |
| **Codex / ChatGPT 账号** | 官方 Codex CLI：`codex login` | 用 ChatGPT 账号登录，在只读沙箱中流式生成 |
| **Antigravity / Google 账号** | Google Antigravity CLI：首次运行 `agy` 时登录 | 使用 Google AI 订阅额度，`agy -p` 非交互调用 |
| **第三方 API** | API Key（本地 `secrets.json`） | 接口类型可切换：OpenAI Chat Completions / OpenAI Responses / Anthropic Messages；支持 OpenAI、OpenRouter、DeepSeek、Kimi、通义百炼、硅基流动、智谱、Ollama 本地等 |

## 功能

- **参考附件**：在主页或主聊天输入框通过回形针添加图片、Markdown 或纯文本，也支持拖放。在输入框行首粘贴 `.md`、`.markdown` 或 `.txt` 的本地绝对路径时，路径后可接设计需求。文档内容作为对话附件发送给所选模型
- **对话**：支持 CommonMark 和 GitHub 风格的表格、任务列表、删除线、脚注等 Markdown 格式。可在一条消息内跨段落拖选和复制
- **无限画布**：每个界面 / 每页幻灯片是一个画板，全部摊开在画布上；双指滑动或滚轮平移，捏合或 ⌘ + 滚轮缩放（⌘= / ⌘- / ⌘0，⌘1 适应画布，⌘2 缩放到选中）；一个项目可包含多张画布；生成时画板**实时渲染**
- **直接编辑**：点击选中任意元素，双击直接改文字，拖动绝对定位元素；右侧属性面板可改尺寸、定位、自动布局、内外边距、文字、填充、圆角、描边、阴影、图片等；⌘Z 撤销 / ⇧⌘Z 重做，⌘D 复制，⌫ 删除
- **图层结构**：右侧展示整个作品的组织结构（画布 → 画板 → 元素），与画布选中联动
- **浮动工具栏**：选择（V）、抓手（H）、文本（T）、画板（F）、矩形（R）、图片（I）、批注（C），以及「询问 AI」直接修改选中的画板或元素（⌘J）
- **代码 / 调整**：查看并直接修改选中元素或画板的 HTML；AI 暴露的 CSS 变量可用取色器和滑块实时调节，写入后保存为新版本
- **批注**（C / ⇧⌘K）：点击元素留下修改意见，批注连同画板和 CSS 选择器一起交给 AI
- **版本历史**：每次生成自动保存整个文档的快照，可随时恢复（可撤销）
- **设计系统**：管理颜色令牌、字体、圆角、间距与品牌规范，自动注入到提示词；内置 4 套
- **导出**：单个画板导出 HTML / PNG / PDF；从当前画布导出全部 HTML 或合并为一个 PDF（每个画板一页）
- **项目交接**：在工作区选择「导出 → 导出项目」，可将全部或所选画布保存为可编辑的 `.designstudio` 文件，保留画板、共用样式和设计系统。默认导出全部画布并附带对话、参考附件、批注和版本历史，可取消勾选。收件人可在主页点击「导入项目」或按 ⌘O，在本机创建可编辑副本并用自己的模型继续设计
- **交给 Claude Code**：每个画板导出为 HTML，附 `HANDOFF.md`，并在终端中直接启动 `claude` 实现生产代码

## 下载安装

到 [Releases](https://github.com/swiftczz/DesignStudio/releases) 下载最新的 `DesignStudio-*.dmg`，打开后把 DesignStudio 拖到「应用程序」。

应用目前没有 Developer ID 签名，第一次打开如果被拦下，请到「系统设置 → 隐私与安全性」底部点「仍要打开」；或在终端运行：

```bash
xattr -dr com.apple.quarantine /Applications/DesignStudio.app
```

系统要求：搭载 Apple 芯片的 Mac，运行 macOS 26 Tahoe 或更新版本。

安装含应用内更新功能的版本后，可通过菜单「DesignStudio → 检查更新…」下载、校验并安装新版，然后重新启动 DesignStudio。自动检查可在「设置 → 通用 → 软件更新」开启。

## 环境要求

- 搭载 Apple 芯片的 Mac，运行 macOS 26 Tahoe 或更新版本
- Xcode 26 及以上（Swift 6.2+ 工具链；Swift 6 语言模式，默认 MainActor 隔离）

## 运行

```bash
# 方式一：命令行直接运行
swift run

# 方式二：用 Xcode 打开（推荐调试）
open Package.swift          # 选择 DesignStudio scheme → Run

# 方式三：打包成 .app（ad-hoc 签名，可放进「应用程序」）
./Scripts/build-app.sh
open build/DesignStudio.app

# 打包 DMG（arm64，默认读取 Support/Info.plist 中的版本号，输出到 dist/）
./Scripts/release-dmg.sh

# 运行单元测试
swift test

# 修改 Support/AppIcon.svg 后重新生成应用图标（需要 brew install librsvg）
./Scripts/make-icon.sh
```

## 接入模型

打开 **设置（⌘,）→ 模型与账号**：

### Claude 账号

1. 安装 Claude Code：`curl -fsSL https://claude.ai/install.sh | bash`
2. 在 DesignStudio 中点「登录 Claude」（后台运行 `claude auth login`，浏览器完成授权）；需要粘贴授权码时用「在终端中登录」
3. 模型可留空（CLI 默认），或填 `sonnet` / `opus` / `haiku`

应用通过 `claude -p --output-format stream-json --include-partial-messages --system-prompt …` 调用，**令牌由官方 CLI 管理，本应用不读取、不保存**。

### Codex 账号

1. 安装：`npm install -g @openai/codex`（或 `brew install --cask codex`）
2. 点「使用 ChatGPT 登录」（后台运行 `codex login`）
3. 生成时通过 `codex app-server` 接收正文增量。旧版 CLI 或配置了自定义 CLI 参数时使用 `codex exec --json`。两个入口都以 Standard 速度运行。

### Antigravity 账号

1. 安装：`brew install --cask antigravity-cli`
2. 点「在终端中用 Google 登录」，在终端里运行 `agy` 并按提示登录（退出登录在 `agy` 里输入 `/logout`）
3. 生成时调用 `agy --input-format stream-json --output-format stream-json -p=`，提示词以 NDJSON 从 stdin 传入

### 思考强度

输入框的模型菜单里可以按项目选择思考强度：Claude 用 `--effort`，Codex 用 `model_reasoning_effort`，Antigravity 是不同的模型 ID；第三方 API 在 `/models` 声明了支持的强度时（如 DeepSeek），以 `reasoning_effort` / `reasoning.effort` / `output_config.effort` 传递。

### 第三方 API

点左下角 **+** 选择预设，填 API Key，点「拉取模型列表」勾选要用的模型（可多选，在输入框的模型菜单里切换），「测试连接」可快速验证。

- 接口类型可切换：
  - OpenAI Chat Completions：请求 `{Base URL}/chat/completions`
  - OpenAI Responses：请求 `{Base URL}/responses`
  - Anthropic Messages：请求 `{Base URL}/v1/messages`；国内兼容端点一般需要打开「Bearer 认证」
- 模型列表来自 `{Base URL}/models`（Anthropic 为 `/v1/models`）。服务商返回上下文 / 最大输出上限时自动记录，生成时按上限发送：历史对话尽量多带，输出按模型最大值；没有返回上限时显示「自动」，可手动填写
- API Key 保存在 `~/Library/Application Support/DesignStudio/secrets.json`（权限 0600），不使用系统钥匙串
- 支持自定义请求头（如 OpenRouter 的 `HTTP-Referer`）

> GUI 应用拿不到终端的 PATH，DesignStudio 会通过 `zsh -l` 启动 CLI 并补充 `~/.local/bin`、Homebrew、nvm 等常见目录；仍找不到时可在设置里填写可执行文件的绝对路径。

## 项目结构

```
Sources/DesignStudio
├── App/                 入口、全局状态（AppModel）、单项目会话（ProjectSession）
├── Models/              Project / DesignVersion / CanvasComment / TweakControl / DesignSystem / ProviderProfile
├── Persistence/         JSON 存储（~/Library/Application Support/DesignStudio）、API Key 存储（secrets.json）
├── LLM/                 统一的流式接口 + Anthropic / OpenAI 兼容 / Claude Code / Codex / Antigravity CLI 实现
├── Services/            CLI 登录状态、提示词组装、HTML 提取、Tweaks 解析、图片处理、导出
└── Views/
    ├── Home/            主页与项目卡片
    ├── Workspace/       工作区、对话面板、输入框
    ├── Canvas/          无限画布、画板 WKWebView、编辑脚本、浮动工具栏
    ├── Inspector/       图层树、属性面板、代码、调整
    ├── DesignSystems/   设计系统编辑器与预览
    ├── Settings/        模型与账号、通用设置
    └── Components/      通用组件
```

### 生成协议

系统提示词要求模型：先用 1–3 句话说明改动，再把每个画板输出为一个独立的完整 HTML 文档：

```text
```html artboard="首页" width=390 height=844
<!DOCTYPE html>…
```
```

修改时只输出改动或新增的画板（沿用原名称），应用按名称合并进当前画布。画布加载画板前会给每个元素加上 `data-ds-id` 编号，编辑脚本据此把画布上的修改同步写回源码（同时维护一份未执行脚本的源码 DOM，避免把脚本生成的内容写进去），保存前再去掉编号。

设计令牌用 `:root` CSS 变量组织；通过

```html
<script type="application/json" id="ds-tweaks">
[{"var":"--accent","label":"主色","type":"color","value":"#D97757"},
 {"var":"--radius","label":"圆角","type":"range","min":0,"max":32,"unit":"px","value":12}]
</script>
```

暴露可调参数。每轮修改都会把当前画布所有画板的 HTML、选中的元素和画布批注一起发送；历史对话按模型的上下文上限尽量多带，旧回复里的 HTML 替换为占位符。

## 发布

推送 `v*` tag 会触发 GitHub Actions（`.github/workflows/release.yml`）：运行测试 → 按 Conventional Commits 生成更新说明 → 编译 arm64 DMG → 发布到 Releases。

发布时，工作流使用仓库的 `SPARKLE_PRIVATE_ED_KEY` Actions secret 为 DMG 和 `appcast.xml` 签名，上传两者后再公开 Release。签名私钥必须与 `Support/Info.plist` 中的 `SUPublicEDKey` 配对。本机的签名密钥保存在钥匙串的 `app.designstudio.mac` Sparkle 账户中。

发布前更新 `Support/Info.plist` 中的显示版本 `CFBundleShortVersionString`，并用相同版本创建和推送 `v` 开头的 tag。打包时，构建号默认使用截至当前提交的 Git 历史总提交数。手动运行发布工作流时填写版本号，生成的 DMG 会作为工作流产物上传。

本地有 Developer ID Application 证书时，`release-dmg.sh` 会自动用它签名；设置 `NOTARY_PROFILE`（`xcrun notarytool store-credentials` 保存的凭据名）后还会提交公证。

## 说明

- 使用订阅账号时请遵守 Anthropic / OpenAI / Google 的使用条款：本应用只是在你本机调用你自己安装并登录的官方 CLI，不代理、不转发、不共享凭据。
- 生成的设计会加载 Google Fonts、Tailwind CDN 等外部资源，离线时样式可能不完整。
