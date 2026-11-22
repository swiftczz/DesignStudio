import SwiftUI
import AppKit

/// 滚动位置：用于判断是否停在底部、用户是否在往上翻
nonisolated struct ScrollMetrics: Equatable, Sendable {
    var offset: CGFloat
    var distanceToBottom: CGFloat
    /// 内容高度：LazyVStack 边滚动边测量真实高度，内容高度变化时 offset 会被系统调整
    var contentHeight: CGFloat = 0
    /// 可见宽度：拖动对话栏宽度时文字重新换行，offset 随之变化
    var width: CGFloat = 0

    static let zero = ScrollMetrics(offset: 0, distanceToBottom: 0)

    init(offset: CGFloat, distanceToBottom: CGFloat, contentHeight: CGFloat = 0) {
        self.offset = offset
        self.distanceToBottom = distanceToBottom
        self.contentHeight = contentHeight
    }

    /// 用可见区域计算：窗口工具栏会给滚动视图加顶部内边距（contentInsets.top），
    /// 直接用 contentOffset 时，内边距生效那一刻 offset 会从 0 跳到 -52，被误判成用户往上翻；
    /// 到底时 containerSize − offset 也会差出这 52，导致「回到底部」按钮一直不消失
    init(_ g: ScrollGeometry) {
        offset = g.contentOffset.y + g.contentInsets.top
        distanceToBottom = g.contentSize.height - g.visibleRect.maxY
        contentHeight = g.contentSize.height
        width = g.containerSize.width
    }

    /// 停在底部时跟随新内容；用户往上滚动时停止跟随。
    /// 内容高度同时变化时的 offset 变化是布局调整（懒加载测量、流式输出），不算用户滚动
    static func shouldFollow(old: ScrollMetrics, new: ScrollMetrics, current: Bool) -> Bool {
        if abs(new.contentHeight - old.contentHeight) > 0.5 || abs(new.width - old.width) > 0.5 { return current }
        if new.distanceToBottom < 40 { return true }
        if new.offset < old.offset - 1 { return false }
        return current
    }
}

struct ChatPanel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var session: ProjectSession
    let loadsHistory: Bool
    /// 是否自动跟随到底部：用户往上翻后停止，回到底部后恢复
    @State private var followBottom = true
    @State private var hasNewReply = false
    @State private var handledSend: UUID?
    @State private var visibleMessageID: UUID?
    /// 滚动视图顶部被窗口标题栏覆盖的高度
    @State private var titleInset: CGFloat = 0

    private var messages: [ChatMessage] { session.project?.messages ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if messages.isEmpty {
                            ContentUnavailableView("开始对话", systemImage: "bubble.left.and.text.bubble.right",
                                                   description: Text("描述你想要的设计，或者对当前画布提出修改。"))
                                .padding(.top, 60)
                        }
                        if loadsHistory {
                            let lastReply = messages.last(where: { $0.role == .assistant })?.id
                            ForEach(messages) { m in
                                MessageView(message: m, session: session, isLastReply: m.id == lastReply,
                                            animatesArrival: followBottom && m.id == session.streamingMessageID)
                                    .id(m.id)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(16)
                    .scrollTargetLayout()
                }
                .scrollPosition(id: $visibleMessageID, anchor: .top)
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentInsets.top }) { _, v in titleInset = v }
                // 窗口标题栏背景是透明的，系统不会画滚动边缘效果：自己遮住滚到标题下方的内容，
                // 并在标题下沿做一段渐隐，避免消息和项目标题叠在一起
                .modifier(TitleFadeMask(inset: titleInset))
                // 打开对话时直接停在最新消息（LazyVStack 的高度是估算的，onAppear 里 scrollTo 不一定到底）
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                // 跟随底部时，内容高度变化（懒加载测量、流式输出）保持贴底；用户往上翻后不再固定
                .defaultScrollAnchor(followBottom ? .bottom : nil, for: .sizeChanges)
                .onScrollGeometryChange(for: ScrollMetrics.self, of: ScrollMetrics.init) { old, new in
                    followBottom = ScrollMetrics.shouldFollow(old: old, new: new, current: followBottom)
                    if followBottom { hasNewReply = false }
                }
                .onChange(of: messages.last?.id) {
                    let sent = handledSend != session.chatSendScrollRequest
                    handledSend = session.chatSendScrollRequest
                    if sent || followBottom {
                        followBottom = true
                        withAnimation(reduceMotion ? nil : WorkspaceMotion.panel) { proxy.scrollTo("bottom", anchor: .bottom) }
                    } else {
                        hasNewReply = true
                    }
                }
                .onChange(of: session.streamingText.count / 240) {
                    if !followBottom { hasNewReply = true }
                }
                .onChange(of: session.streamingMessageID) {
                    if !followBottom { hasNewReply = true }
                }
                .onAppear {
                    handledSend = session.chatSendScrollRequest
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: loadsHistory) { _, ready in
                    if ready && followBottom { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .overlay(alignment: .bottom) {
                    if !followBottom {
                        Button {
                            followBottom = true
                            hasNewReply = false
                            withAnimation(reduceMotion ? nil : WorkspaceMotion.panel) { proxy.scrollTo("bottom", anchor: .bottom) }
                        } label: {
                            Label(hasNewReply ? "有新回复 · 回到最新" : "回到最新", systemImage: "arrow.down")
                                .font(.callout)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .padding(.bottom, 10)
                        .transition(.opacity)
                    }
                }
            }

            ChatComposer(session: session)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // 对话区域整体不用主题色（按钮、光标等系统控件也跟着变成中性色）
        .tint(.primary)
    }
}

// MARK: - Message

/// 用户消息上方的修改对象标签：「冥想计时 › 按钮「开始或暂停」」，点击在画布上选中
struct MessageTargetChip: View {
    let target: MessageTarget
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: target.elementKind.map(ElementKind.symbol) ?? "rectangle.portrait")
                    .font(.system(size: 10, weight: .semibold))
                Text(target.artboardName)
                    .foregroundStyle(target.isElement ? .secondary : .primary)
                if let kind = target.elementKind {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .opacity(0.6)
                    Text("\(ElementKind.title(kind)) \(target.elementName ?? "")")
                }
            }
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(hovering ? 0.08 : 0.04), in: .capsule)
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(target.isElement ? "只修改了这个元素 · 点击在画布上选中" : "针对这个画板修改 · 点击在画布上选中")
    }
}

struct MessageView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let message: ChatMessage
    @Bindable var session: ProjectSession
    /// 最后一条回复：操作栏常驻显示，且可以重新生成
    var isLastReply = false
    var animatesArrival = false
    @State private var hovering = false
    @State private var copied = false
    @State private var appeared = false
    @State private var isEditing = false
    @State private var editedText = ""
    @State private var editSelection: TextSelection?
    @State private var isPlacingEditCaret = false
    @FocusState private var editFocused: Bool

    var body: some View {
        if message.role == .user {
            userBubble
        } else {
            assistantBlock
                .opacity(!reduceMotion && animatesArrival && !appeared ? 0 : 1)
                .onAppear {
                    withAnimation(reduceMotion ? nil : WorkspaceMotion.hover) { appeared = true }
                }
        }
    }

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 6) {
            messageScope
            if let id = message.outputPageID, let page = session.document.pages.first(where: { $0.id == id }) {
                Button { session.revealCanvas(id) } label: {
                    Label("输出到 · \(page.displayName)", systemImage: "rectangle.dashed")
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            if !message.attachments.isEmpty {
                AttachmentThumbs(attachments: message.attachments)
            }
            ForEach(message.comments) { c in
                Label {
                    Text("\(c.note)").font(.caption)
                } icon: {
                    Image(systemName: "scope")
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.primary.opacity(0.05), in: .capsule)
                .help(c.selector)
            }
            if isEditing {
                messageEditor
            } else {
                if !message.text.isEmpty {
                    MarkdownText(message.text, style: .user)
                }
                HStack(spacing: 2) {
                    Button("编辑消息", systemImage: "pencil") {
                        editedText = message.text
                        editSelection = nil
                        isPlacingEditCaret = true
                        isEditing = true
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(MessageActionButtonStyle())
                    .help("编辑并重新发送")

                    if !message.text.isEmpty {
                        copyButton(message.text, title: "复制消息")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
    }

    private var messageEditor: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextField("编辑消息", text: $editedText, selection: $editSelection, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(2...8)
                .focused($editFocused)
                .onChange(of: editSelection) { _, selection in
                    guard isPlacingEditCaret, let selection else { return }
                    isPlacingEditCaret = false
                    if !selection.isInsertion {
                        editSelection = TextSelection(insertionPoint: editedText.endIndex)
                    }
                }
                .onSubmit(resend)
            HStack(spacing: 8) {
                Button("取消", role: .cancel) { isEditing = false }
                Button(action: resend) {
                    Text("重新发送").fontWeight(.semibold)
                }
                .disabled(!canResend)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .composerCard(focused: editFocused, cornerRadius: 14)
        .disabled(session.isPreparingRequest)
        .onAppear { editFocused = true }
        .onExitCommand { if !session.isPreparingRequest { isEditing = false } }
    }

    private var canResend: Bool {
        !session.isGenerating && !session.isPreparingRequest
            && (!editedText.trimmed.isEmpty || !message.attachments.isEmpty || !message.comments.isEmpty)
    }

    private func resend() {
        guard canResend else { return }
        session.resendEditedMessage(id: message.id, text: editedText) { isEditing = false }
    }

    @ViewBuilder
    private var messageScope: some View {
        if let target = message.target {
            MessageTargetChip(target: target) { session.reveal(target) }
        } else if let ids = message.scopeIDs, !ids.isEmpty {
            let targets = ids.map { id in
                MessageTarget(artboardID: id, artboardName: message.scopeArtboardNames?[id]
                              ?? session.document.artboard(id)?.name ?? "已删除的画板")
            }.sorted { $0.artboardName.localizedStandardCompare($1.artboardName) == .orderedAscending }
            if targets.count == 1, let target = targets.first {
                MessageTargetChip(target: target) { session.reveal(target) }
            } else {
                Menu {
                    ForEach(targets, id: \.artboardID) { target in
                        Button(target.artboardName) { session.reveal(target) }
                    }
                } label: {
                    Label("\(targets.count) 张画板", systemImage: "scope").font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(targets.map(\.artboardName).joined(separator: "、"))
            }
        } else if let id = message.requestPageID {
            let name = message.requestPageName ?? session.document.pages.first { $0.id == id }?.displayName ?? "已删除的画布"
            Button { session.revealCanvas(id) } label: {
                Label("整个画布 · \(name)", systemImage: "scope")
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("定位画布「\(name)」")
        }
    }

    private var isStreaming: Bool { session.streamingMessageID == message.id }

    /// 回复来自哪个服务商：按记录的「来源名 · 模型」找到对应来源，找不到再按名称关键字判断
    private var brand: ProviderBrand? {
        guard let name = message.providerName else { return nil }
        let source = name.components(separatedBy: " · ").first ?? name
        if let profile = app.providers.first(where: { $0.name == source }) {
            return ProviderBrand.detect(profile)
        }
        return ProviderBrand.detect(name: name)
    }

    @ViewBuilder private var assistantBlock: some View {
        let raw = isStreaming ? ProjectTitle.splitReply(session.streamingText, streaming: true).body : message.text
        let display = HTMLExtractor.conversationalText(raw)
        let thinking = isStreaming ? session.streamingThinking : (message.thinking ?? "")

        VStack(alignment: .leading, spacing: 10) {
            let thinkingNow = isStreaming && raw.isEmpty && !thinking.trimmed.isEmpty
            if !thinking.trimmed.isEmpty {
                ThinkingSection(text: thinking, isThinking: thinkingNow)
            }

            if !display.isEmpty {
                MarkdownText(display)
            }

            // 思考阶段由上面的「思考中…」表示，不再重复显示进度胶囊
            if isStreaming && !thinkingNow {
                StreamingIndicator(status: session.status,
                                   lines: HTMLExtractor.partialLineCount(raw))
                    .transition(.opacity)
            }

            if let vid = message.versionID,
               let version = session.project?.versions.first(where: { $0.id == vid }) {
                VersionChip(version: version, session: session)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)))
            }

            if message.wasStopped {
                Label("已停止生成", systemImage: "stop.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = message.errorText {
                ErrorCard(message: error, retryTitle: message.recovery != nil && message.versionID != nil ? "重试剩余部分" : "重试",
                          keep: message.recovery != nil && message.versionID == nil
                            ? { session.keepCompletedArtboards(message: message) } : nil) {
                    if message.recovery != nil && message.versionID != nil {
                        session.retryRemaining(message: message)
                    } else {
                        session.retry(assistantMessageID: message.id)
                    }
                }
                .disabled(session.isGenerating)
                .transition(.opacity)
            }

            if let timing = message.generation, isLastReply {
                let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))
                let metrics = [
                    timing.firstText.map { "首字 \($0.formatted(format)) 秒" },
                    timing.firstArtboard.map { "首张画板 \($0.formatted(format)) 秒" },
                    "生成完成 \(timing.total.formatted(format)) 秒"
                ].compactMap { $0 }.joined(separator: " · ")
                Text(metrics)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("从提交生成请求开始计时。首张画板记录首次加载成功的画板。")
            }

            if !isStreaming || message.providerName != nil {
                actionBar(display: display)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }

    /// 模型名仅随悬停显示。最后一条回复的操作按钮常驻。
    private func actionBar(display: String) -> some View {
        let showsActions = hovering || isLastReply
        return HStack(spacing: 2) {
            if !isStreaming {
                HStack(spacing: 2) {
                    if !display.isEmpty {
                        copyButton(display, title: "复制回复")
                    }
                    if isLastReply && message.errorText == nil {
                        Button {
                            session.retry(assistantMessageID: message.id)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(MessageActionButtonStyle())
                        .disabled(session.isGenerating)
                        .help("重新生成这条回复")
                    }
                }
                .opacity(showsActions ? 1 : 0)
                .allowsHitTesting(showsActions)
                .accessibilityHidden(!showsActions)
                .animation(reduceMotion ? nil : WorkspaceMotion.hover, value: showsActions)
            }
            if let name = message.providerName {
                HStack(spacing: 5) {
                    ProviderLogo(brand: brand, size: 12)
                    Text(name)
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.leading, 6)
                .opacity(hovering ? 1 : 0)
                .accessibilityHidden(!hovering)
                .animation(reduceMotion ? nil : WorkspaceMotion.hover, value: hovering)
            }
        }
        .padding(.leading, -5)
    }

    private func copyButton(_ text: String, title: LocalizedStringKey) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation(reduceMotion ? nil : WorkspaceMotion.hover) { copied = true }
        } label: {
            Label(title, systemImage: copied ? "checkmark" : "doc.on.doc")
                .labelStyle(.iconOnly)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(MessageActionButtonStyle())
        .help(copied ? "已复制" : title)
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            withAnimation(reduceMotion ? nil : WorkspaceMotion.hover) { copied = false }
        }
    }
}

/// 消息下方的小图标按钮：灰色图标，悬停时出现浅灰底
private struct MessageActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ActionBody(configuration: configuration)
    }

    private struct ActionBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(hovering && isEnabled ? .primary : .secondary)
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hovering && isEnabled ? 0.07 : 0)))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(.rect)
                .onHover { hovering = $0 }
        }
    }
}

/// 生成失败：浅红底 + 细边，文字用正文色便于阅读；只有可能是配置问题时才提供「打开设置」
private struct ErrorCard: View {
    let message: String
    let retryTitle: String
    let keep: (() -> Void)?
    let retry: () -> Void

    @ViewBuilder private var actions: some View {
        if let keep { Button("保留已完成结果", action: keep) }
        Button(action: retry) { Label(retryTitle, systemImage: "arrow.clockwise") }
        if mayNeedSettings && keep == nil && retryTitle == "重试" {
            OpenSettingsButton { Text("打开设置") }
        }
    }

    /// 应用中途退出这类错误与设置无关
    private var mayNeedSettings: Bool { !message.contains("应用在生成过程中退出") }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 9) {
                Text(message)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { actions }
                    VStack(alignment: .leading, spacing: 6) { actions }
                }
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: 360, alignment: .leading)
        .background(Color.red.opacity(0.05), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.red.opacity(0.14)))
    }
}

private struct StreamingIndicator: View {
    let status: String?
    let lines: Int

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(status ?? "生成中…")
                .foregroundStyle(.secondary)
            if lines > 0 {
                Text("· \(lines) 行")
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.quinary, in: .capsule)
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
    }
}

/// 可折叠的思考过程（思维链摘要）：思考进行中默认展开，之后可手动折叠
private struct ThinkingSection: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let text: String
    let isThinking: Bool
    @State private var expanded: Bool?
    @State private var contentHeight: CGFloat = 0
    @State private var follow = true

    /// 思考内容的最大显示高度，超出部分在框内滚动
    static let maxHeight: CGFloat = 180

    private var isExpanded: Bool { expanded ?? isThinking }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : WorkspaceMotion.panel) { expanded = !isExpanded }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                    Text(isThinking ? "思考中…" : "思考过程")
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                // 限制高度，超出在框内滚动；思考中自动跟随最新内容（用户往上翻时不跟随）
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            MarkdownText(text, style: .thinking)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                            Color.clear.frame(height: 1).id("thinkingEnd")
                        }
                    }
                    .frame(height: min(max(contentHeight, 20), Self.maxHeight))
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollIndicators(contentHeight > Self.maxHeight ? .automatic : .hidden)
                    .onScrollGeometryChange(for: ScrollMetrics.self, of: ScrollMetrics.init) { old, new in
                        follow = ScrollMetrics.shouldFollow(old: old, new: new, current: follow)
                    }
                    .onChange(of: text.count / 60) {
                        if isThinking && follow { proxy.scrollTo("thinkingEnd", anchor: .bottom) }
                    }
                    .onAppear { if isThinking { proxy.scrollTo("thinkingEnd", anchor: .bottom) } }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(.separator)
                        .frame(width: 2)
                }
                .transition(.opacity)
            }
        }
        // 思考结束、开始输出正文后自动折叠（除非用户手动展开过）
        .onChange(of: isThinking) { _, now in
            if !now, expanded == nil { expanded = false }
        }
    }
}

private struct VersionChip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let version: DesignVersion
    @Bindable var session: ProjectSession

    private var isCurrent: Bool { session.project?.currentVersion?.id == version.id }
    private var isShown: Bool { isCurrent && session.showCanvas }
    private var boardCount: Int { version.document?.allArtboards.count ?? 1 }

    @State private var hovering = false

    var body: some View {
        Button {
            if isCurrent {
                session.showCanvas = true
            } else {
                session.restore(version)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.dashed")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("版本 \(version.number)").font(.callout.weight(.semibold))
                        if isCurrent {
                            Text("当前").font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.primary.opacity(0.07), in: .capsule)
                                .foregroundStyle(.secondary)
                        }
                        if version.truncated {
                            Text("可能被截断").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    Text(isShown ? "\(boardCount) 个画板 · 正在画布中显示" : "\(boardCount) 个画板")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                // 非当前版本：悬停时出现「恢复」提示
                if isCurrent && !isShown {
                    Label("查看画布", systemImage: "arrow.right")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.accent)
                } else if !isCurrent {
                    Label("恢复整个版本", systemImage: "arrow.uturn.backward")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .opacity(hovering ? 1 : 0)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: 320, alignment: .leading)
            .background(Color.primary.opacity(hovering && !isShown ? 0.035 : 0), in: .rect(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.primary.opacity(isShown ? 0.2 : 0.1), lineWidth: 1)
            )
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!isCurrent && !session.canRestoreVersion)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : WorkspaceMotion.hover, value: hovering)
        .help(isCurrent ? (isShown ? "画布当前显示的版本" : "查看画布") : "恢复整个版本（可撤销）")
    }
}

// MARK: - Composer

struct ChatComposer: View {
    @Environment(AppModel.self) private var app
    @Bindable var session: ProjectSession
    @FocusState private var focused: Bool

    var body: some View {
        let comments = session.draftComments
        let boards = session.document.page(session.currentPageID)?.artboards ?? []
        VStack(alignment: .leading, spacing: 10) {
            if !boards.isEmpty || session.draftScopeIssue != nil {
                scopeMenu(boards)
            }
            if let issue = session.draftScopeIssue {
                Label(issue, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let notice = session.requestNotice, notice != session.draftScopeIssue {
                HStack(alignment: .top) {
                    Label(notice, systemImage: "info.circle").frame(maxWidth: .infinity, alignment: .leading)
                    Button("关闭提示", systemImage: "xmark") { session.requestNotice = nil }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if session.isPreparingRequest {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在确认修改对象…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if !comments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(comments) { c in
                            HStack(spacing: 4) {
                                Image(systemName: "scope")
                                Text(c.note).lineLimit(1)
                                Button {
                                    session.removeComment(c.id)
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .buttonStyle(.plain)
                            }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.06), in: .capsule)
                            .onHover { if $0 { session.locate(c) } else { session.hover = nil } }
                        }
                    }
                }
            }

            if !session.draftAttachments.isEmpty {
                AttachmentStrip(attachments: $session.draftAttachments, provider: session.provider?.kind)
            }

            PastedTextBlocks(blocks: $session.draftTextBlocks)

            TextField(placeholder(hasComments: !comments.isEmpty), text: $session.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...8)
                .focused($focused)
                .focusedValue(\.composerAttachments, $session.draftAttachments)
                .focusedValue(\.composerTextBlocks, $session.draftTextBlocks)
                .onSubmit { session.send() }
                .padding(.horizontal, 4)
                .padding(.top, 2)

            ViewThatFits(in: .horizontal) {
                composerActions(showsProvider: true)
                composerActions(showsProvider: false)
                composerActions(showsProvider: false, maximumModelWidth: 124)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .composerCard(focused: focused)
        .padding(12)
        .dropDestination(for: URL.self) { urls, _ in
            let picked = AttachmentImporter.load(urls)
            session.draftAttachments += picked
            return !picked.isEmpty
        }
        .onAppear { focused = true }
        .onChange(of: session.chatFocusRequest) { _, _ in focused = true }
    }

    private func composerActions(showsProvider: Bool, maximumModelWidth: CGFloat? = nil) -> some View {
        HStack(spacing: 2) {
            AttachButton { session.draftAttachments += $0 }
            Spacer(minLength: showsProvider ? 8 : 4)
            ProviderMenu(selection: providerBinding, showsLogo: showsProvider,
                         showsProviderName: showsProvider, maximumTitleWidth: maximumModelWidth)
            if session.isGenerating {
                Button {
                    session.stop()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(SendButtonStyle(stop: true))
                .help("停止（⌘.）")
            } else {
                Button {
                    session.send()
                } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(SendButtonStyle())
                .disabled(!session.canSend)
                .help("发送（Return；⌥Return 换行）")
            }
        }
    }

    private func scopeMenu(_ boards: [Artboard]) -> some View {
        let selected = session.draftScopeArtboards
        let issue = session.draftScopeIssue
        let scopeTitle = switch (issue != nil, selected.count) {
        case (true, _): "重新选择修改范围"
        case (_, 0): "整个画布"
        case (_, 1): "仅修改：\(selected[0].name)"
        default: "仅修改 \(selected.count) 张画板"
        }
        let title = session.draftCreatesCanvasCopy && !boards.isEmpty ? scopeTitle + " · 新画布" : scopeTitle
        return Menu {
            Button {
                session.draftScopeIDs = []
                session.requestNotice = nil
            } label: {
                if session.draftScopeIDs.isEmpty {
                    Label("整个画布", systemImage: "checkmark")
                } else {
                    Text("整个画布")
                }
            }
            if issue == nil, session.canAskAboutSelection, session.selection?.elementID != nil {
                Button("修改选中的元素") {
                    session.askDraft = session.draft
                    session.askTextBlocks = session.draftTextBlocks
                    session.showAskAI = true
                }
            }
            if !boards.isEmpty {
                Toggle("输出到新画布", isOn: $session.draftCreatesCanvasCopy)
            }
            Divider()
            ForEach(boards) { board in
                Toggle(board.name, isOn: Binding(
                    get: { issue == nil && session.draftScopeIDs.contains(board.id) },
                    set: { included in
                        if included {
                            if issue != nil { session.draftScopeIDs = [board.id] }
                            else { session.draftScopeIDs.insert(board.id) }
                        }
                        else { session.draftScopeIDs.remove(board.id) }
                        session.requestNotice = nil
                    }))
            }
        } label: {
            ComposerChipLabel(idleTint: session.draftScopeIDs.isEmpty && !session.draftCreatesCanvasCopy ? nil : Theme.accent) {
                Image(systemName: "scope").accessibilityHidden(true)
                Text(title)
            }
        }
        .composerMenuStyle(fitsContent: false)
        .help(issue ?? (selected.count > 1 ? selected.map(\.name).joined(separator: "、") : title))
        .accessibilityLabel("修改范围")
        .accessibilityValue(title)
    }

    private func placeholder(hasComments: Bool) -> String {
        if hasComments { return "补充说明（可选），发送后按批注修改…" }
        return session.hasDesign ? "描述想要的修改…" : "描述你想设计的内容…"
    }

    private var providerBinding: Binding<ModelChoice> {
        Binding(
            get: {
                guard let project = session.project, let id = project.providerID,
                      app.provider(for: id) != nil else {
                    return ModelChoice(providerID: app.defaultProvider?.id)
                }
                return ModelChoice(providerID: id, model: project.model, effort: project.effort)
            },
            set: { newValue in
                app.updateProject(session.projectID, touch: false) {
                    $0.providerID = newValue.providerID
                    $0.model = newValue.model
                    $0.effort = newValue.effort
                }
            }
        )
    }
}


/// 遮住滚到窗口标题下方的内容，标题下沿渐隐
private struct TitleFadeMask: ViewModifier {
    let inset: CGFloat

    func body(content: Content) -> some View {
        content.mask {
            VStack(spacing: 0) {
                Color.clear.frame(height: max(inset - 4, 0))
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: 16)
                Color.black
            }
            .ignoresSafeArea()
        }
    }
}
