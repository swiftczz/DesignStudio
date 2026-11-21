import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("模型与账号", systemImage: "person.badge.key") {
                ProvidersSettingsView()
            }
            Tab("通用", systemImage: "gearshape") {
                GeneralSettingsView()
            }
        }
        .tabViewStyle(.tabBarOnly)
    }
}

// MARK: - Providers

struct ProvidersSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(app.providers) { p in
                        HStack(spacing: 8) {
                            ProviderLogo(p, size: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 4) {
                                    Text(p.name).lineLimit(1)
                                    if app.settings.defaultProviderID == p.id {
                                        Text("默认").font(.caption2).foregroundStyle(Theme.accent)
                                    }
                                }
                                Text(providerStatus(p))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .tag(p.id)
                    }
                }
                .listStyle(.inset)

                Divider()
                HStack(spacing: 4) {
                    Menu {
                        Section("账号登录") {
                            Button { add(.claudeCode()) } label: {
                                brandLabel("Claude（Pro / Max / Console 账号）", .claude)
                            }
                            Button { add(.chatGPT()) } label: {
                                brandLabel("ChatGPT（直连）", .openai)
                            }
                            .disabled(app.providers.contains { $0.kind == .chatGPT })
                            Button { add(.codex()) } label: {
                                brandLabel("Codex CLI", .openai)
                            }
                            Button { add(.antigravity()) } label: {
                                brandLabel("Antigravity（Google 账号）", .antigravity)
                            }
                        }
                        Section("API 服务商") {
                            ForEach(ProviderPreset.all) { preset in
                                Button { add(preset.makeProfile()) } label: {
                                    brandLabel(preset.name, ProviderBrand.detect(preset.makeProfile()))
                                }
                            }
                            Button("自定义…") { add(ProviderPreset.custom.makeProfile()) }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()

                    Button {
                        guard let id = selection else { return }
                        if app.provider(for: id)?.kind == .chatGPT {
                            Task {
                                await app.chatGPTAuth.signOut()
                                if !app.chatGPTAuth.isSignedIn { remove(id) }
                            }
                        } else {
                            remove(id)
                        }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selection == nil || (app.provider(for: selection)?.kind == .chatGPT && app.chatGPTAuth.busy))
                    Spacer()
                }
                .padding(8)
            }
            .frame(width: 250)

            Divider()

            Group {
                if let id = selection, app.provider(for: id) != nil {
                    ProviderDetailView(profileID: id)
                        .id(id)
                } else {
                    ContentUnavailableView("选择一个模型来源", systemImage: "cpu",
                                           description: Text("点击左下角 + 添加 Claude / Codex 账号或第三方 API。"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if selection == nil { selection = app.providers.first?.id } }
    }

    /// 添加菜单的条目：服务商 Logo + 名称（菜单里只能用固定尺寸的 NSImage 作图标）
    @ViewBuilder private func brandLabel(_ title: String, _ brand: ProviderBrand?) -> some View {
        if let image = brand?.menuImage() {
            Label { Text(title) } icon: { Image(nsImage: image) }
        } else {
            Text(title)
        }
    }

    private func add(_ profile: ProviderProfile) {
        app.addProvider(profile)
        selection = profile.id
    }

    private func remove(_ id: UUID) {
        app.deleteProvider(id)
        if selection == id { selection = app.providers.first?.id }
    }

    private func providerStatus(_ profile: ProviderProfile) -> String {
        if profile.kind == .chatGPT { return app.chatGPTAuth.status }
        if profile.kind.isCLI { return app.auth.state(profile.kind).label }
        return profile.displayModel
    }
}

struct ProviderDetailView: View {
    @Environment(AppModel.self) private var app
    let profileID: UUID

    @State private var apiKey = ""
    @State private var manualModel = ""
    @State private var fetching = false
    @State private var fetchError: String?
    @State private var showModelPicker = false
    @State private var testing = false
    @State private var testResult: Result<String, Error>?

    var body: some View {
        let binding = app.providerBinding(profileID)
        let profile = binding.wrappedValue

        Form {
            Section("基本") {
                TextField("显示名称", text: binding.name)
                if profile.kind.isCLI || profile.kind == .chatGPT {
                    LabeledContent("类型", value: profile.kind.title)
                } else {
                    Picker("接口类型", selection: Binding(
                        get: { binding.wrappedValue.kind },
                        set: { newKind in
                            // 已知服务商的地址跟着类型切换（例如 DeepSeek …/v1 ↔ …/anthropic）
                            if let switched = ProviderPreset.switching(baseURL: binding.wrappedValue.baseURL, to: newKind) {
                                binding.wrappedValue.baseURL = switched.url
                                binding.wrappedValue.useBearerAuth = switched.bearer
                            }
                            binding.wrappedValue.kind = newKind
                        }
                    )) {
                        ForEach(ProviderKind.apiKinds) { k in
                            Text(k.title).tag(k)
                        }
                    }
                }
                Toggle("设为默认模型来源", isOn: Binding(
                    get: { app.settings.defaultProviderID == profileID },
                    set: { on in
                        if on { app.settings.defaultProviderID = profileID; app.saveSettings() }
                    }
                ))
            }

            switch profile.kind {
            case .claudeCode, .codex, .antigravity:
                AccountSection(profile: profile)
                cliSection(binding)
            case .chatGPT:
                chatGPTAccountSection
                chatGPTModelsSection(binding)
            case .anthropicAPI, .openAICompatible, .openAIResponses:
                apiSection(binding)
                modelsSection(binding)
            }

            Section {
                HStack(spacing: 10) {
                    Button {
                        Task {
                            testing = true
                            testResult = await ProviderFactory.test(binding.wrappedValue)
                            testing = false
                        }
                    } label: {
                        Label("测试连接", systemImage: "bolt.horizontal")
                    }
                    .disabled(testing || (profile.kind == .chatGPT
                        && (!app.chatGPTAuth.canUsePlan || profile.model.isEmpty || app.chatGPTAuth.busy)))
                    if testing { ProgressView().controlSize(.small) }
                    Spacer()
                }
                switch testResult {
                case .success(let text):
                    Label("连接成功：\(text)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failure(let error):
                    Label(error.localizedDescription, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                case nil:
                    EmptyView()
                }
            } footer: {
                Text("测试会发送一个极短的请求，可能产生少量用量。")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if ProviderKind.apiKinds.contains(profile.kind) { apiKey = SecretStore.get(profile.secretAccount) ?? "" }
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(profile: binding)
        }
    }

    private var chatGPTAccountSection: some View {
        let auth = app.chatGPTAuth
        return Section {
            LabeledContent("状态", value: auth.status)
            HStack(spacing: 8) {
                if auth.signingIn {
                    ProgressView().controlSize(.small)
                    Text("等待浏览器授权…").foregroundStyle(.secondary)
                    Button("取消登录") { auth.cancelSignIn() }
                } else {
                    let label = auth.isSignedIn ? (auth.canUsePlan ? "重新登录" : "授权订阅用量") : "使用 ChatGPT 登录"
                    Button(label) { Task { await signInToChatGPT() } }
                        .disabled(auth.busy)
                    if auth.isSignedIn {
                        Button("退出登录", role: .destructive) {
                            Task {
                                await auth.signOut()
                                if !auth.isSignedIn {
                                    app.updateChatGPTModels([], for: profileID)
                                    testResult = nil
                                    fetchError = nil
                                }
                            }
                        }
                        .disabled(auth.busy)
                    } else if auth.hasRegistration {
                        Button("使用其他账号") { Task { await signInToChatGPT(newAccount: true) } }
                            .disabled(auth.busy)
                    }
                }
                Spacer()
                if auth.isSignedIn {
                    Link("管理用量", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                }
            }
            if let error = auth.error {
                Text(error).foregroundStyle(.secondary).textSelection(.enabled)
            }
        } header: {
            Text("账号")
        } footer: {
            Text("在浏览器中授权 DesignStudio 使用符合条件的 ChatGPT 订阅额度。生成通过 OpenAI 官方接口直连，无需安装 Codex CLI。")
        }
    }

    private func chatGPTModelsSection(_ binding: Binding<ProviderProfile>) -> some View {
        let profile = binding.wrappedValue
        return Section("模型") {
            if !profile.availableModels.isEmpty, app.chatGPTAuth.canUsePlan {
                Picker("默认模型", selection: binding.model) {
                    ForEach(profile.availableModels) { model in
                        Text(model.title).tag(model.id)
                    }
                }
            }
            HStack(spacing: 8) {
                Button("拉取模型列表", systemImage: "arrow.down.circle") {
                    Task { await fetchChatGPTModels() }
                }
                .disabled(fetching || !app.chatGPTAuth.canUsePlan || app.chatGPTAuth.busy)
                if fetching { ProgressView().controlSize(.small) }
            }
            if let fetchError {
                Text(fetchError).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }

    private func signInToChatGPT(newAccount: Bool = false) async {
        let auth = app.chatGPTAuth
        let wasSignedIn = auth.isSignedIn
        guard await auth.signIn(newAccount: newAccount) else { return }
        testResult = nil
        if !wasSignedIn || !auth.canUsePlan { app.updateChatGPTModels([], for: profileID) }
        if auth.canUsePlan { await fetchChatGPTModels() }
    }

    private func fetchChatGPTModels() async {
        fetching = true
        fetchError = nil
        defer { fetching = false }
        do {
            try await app.refreshChatGPTModels(for: profileID)
        } catch is CancellationError {
            // 切换账号后丢弃旧账号的模型列表。
        } catch {
            if !app.chatGPTAuth.canUsePlan { app.updateChatGPTModels([], for: profileID) }
            fetchError = error.localizedDescription
        }
    }

    // MARK: CLI

    @ViewBuilder
    private func cliSection(_ binding: Binding<ProviderProfile>) -> some View {
        let kind = binding.wrappedValue.kind
        Section {
            TextField("可执行文件", text: binding.executablePath, prompt: Text(kind.defaultExecutable))
            HStack {
                TextField("模型", text: binding.model, prompt: Text("留空使用 CLI 默认模型"))
                Menu {
                    Button(binding.wrappedValue.cliDefaultTitle) { binding.wrappedValue.model = "" }
                    // 与输入框的模型菜单一致：强度写在模型 ID 里的（Antigravity）合并成一项，强度在子菜单里选；
                    // 强度是参数的（Claude / Codex）在这里只选模型，强度在输入框里按项目选
                    ForEach(ModelFamily.group(ModelCatalog.known(for: kind)), id: \.self) { family in
                        if family.usesEffortParam || family.isSingle {
                            let m = family.variants[0].option
                            Button("\(m.title)（\(m.id)）") { binding.wrappedValue.model = m.id }
                        } else {
                            Menu(family.name) {
                                ForEach(family.variants, id: \.self) { v in
                                    Button("\(v.title)（\(v.option.id)）") { binding.wrappedValue.model = v.option.id }
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            TextField("额外参数", text: binding.extraArguments,
                      prompt: Text(kind == .codex ? "例如 -c model_reasoning_effort=\"high\"" : "例如 --effort high"))
        } header: {
            Text("命令行")
        } footer: {
            switch kind {
            case .claudeCode:
                Text("通过官方 Claude Code CLI 以非交互模式（claude -p）调用，使用你在 CLI 中登录的账号与额度。")
            case .antigravity:
                Text("通过 Google Antigravity CLI 以非交互模式（agy -p）调用，使用你的 Google 账号与 Google AI 订阅额度。模型列表在检测登录状态时从 agy 更新。")
            default:
                Text("调用本机 Codex CLI，沿用 CLI 的登录和模型提供商配置。")
            }
        }
    }

    // MARK: API

    @ViewBuilder
    private func apiSection(_ binding: Binding<ProviderProfile>) -> some View {
        let profile = binding.wrappedValue
        Section {
            TextField("Base URL", text: binding.baseURL,
                      prompt: Text(profile.kind == .anthropicAPI ? "https://api.anthropic.com" : "https://api.openai.com/v1"))
            SecureField("API Key", text: $apiKey, prompt: Text(profile.kind == .anthropicAPI ? "sk-…" : "本地服务可留空"))
                .onChange(of: apiKey) { SecretStore.set(apiKey, for: profile.secretAccount) }
            if profile.kind == .anthropicAPI {
                Toggle("使用 Authorization: Bearer 认证", isOn: binding.useBearerAuth)
            }
        } header: {
            Text("接口")
        } footer: {
            Text("请求 \(profile.kind.endpointHint)。"
                 + (profile.kind == .anthropicAPI ? "官方接口使用 x-api-key；多数国内兼容端点需要开启 Bearer 认证。" : "")
                 + "API Key 只保存在本机的应用数据目录（secrets.json），不使用系统钥匙串。")
        }

    }

    @ViewBuilder
    private func modelsSection(_ binding: Binding<ProviderProfile>) -> some View {
        let profile = binding.wrappedValue
        Section {
            if !profile.models.isEmpty {
                Picker("默认模型", selection: binding.model) {
                    ForEach(profile.models, id: \.self) { id in
                        Text(profile.title(forModel: id)).tag(id)
                    }
                }
                ForEach(profile.models, id: \.self) { id in
                    SelectedModelRow(profile: binding, modelID: id)
                }
            }

            HStack(spacing: 8) {
                Button {
                    Task { await fetchModels(binding) }
                } label: {
                    Label("拉取模型列表", systemImage: "arrow.down.circle")
                }
                .disabled(fetching)
                if fetching { ProgressView().controlSize(.small) }
                if !profile.availableModels.isEmpty {
                    Button("选择模型…") { showModelPicker = true }
                }
                Spacer()
                TextField("手动添加", text: $manualModel, prompt: Text("手动添加模型 ID"))
                    .labelsHidden()
                    .frame(maxWidth: 200)
                    .onSubmit { addManualModel(binding) }
                Button("添加") { addManualModel(binding) }
                    .disabled(manualModel.trimmed.isEmpty)
            }

            if let fetchError {
                Label(fetchError, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        } header: {
            Text("模型")
        } footer: {
            Text("可以选用多个模型，在输入框的模型菜单里切换。上下文和最大输出来自服务商的模型列表，生成时按这两个上限发送：历史对话尽量多带，输出不再额外限制；服务商没提供时显示「自动」，输出交给服务商按模型最大值处理，也可以手动填写。")
        }

        Section {
            TextField("额外请求头", text: binding.extraHeaders, prompt: Text("每行一个，例如 HTTP-Referer: https://example.com"), axis: .vertical)
                .lineLimit(2...5)
                .font(.body.monospaced())
        } header: {
            Text("高级")
        }
    }

    private func fetchModels(_ binding: Binding<ProviderProfile>) async {
        fetching = true
        fetchError = nil
        defer { fetching = false }
        do {
            let models = try await ModelFetcher.fetch(binding.wrappedValue, apiKey: apiKey)
            guard !models.isEmpty else {
                fetchError = "服务商没有返回任何模型"
                return
            }
            var p = binding.wrappedValue
            p.availableModels = models
            // 已选模型补上新拉到的上限（不覆盖手动填写的值）
            for m in models where p.models.contains(m.id) {
                var l = p.modelLimits[m.id] ?? ModelLimits()
                l.contextWindow = l.contextWindow ?? m.limits.contextWindow
                l.maxOutput = l.maxOutput ?? m.limits.maxOutput
                p.modelLimits[m.id] = l
            }
            binding.wrappedValue = p
            showModelPicker = true
        } catch {
            fetchError = error.localizedDescription
        }
    }

    private func addManualModel(_ binding: Binding<ProviderProfile>) {
        let id = manualModel.trimmed
        guard !id.isEmpty else { return }
        var p = binding.wrappedValue
        if !p.models.contains(id) { p.models.append(id) }
        if p.model.trimmed.isEmpty { p.model = id }
        binding.wrappedValue = p
        manualModel = ""
    }
}

/// 已选模型的一行：名称、上下文 / 最大输出（可改）、移除
private struct SelectedModelRow: View {
    @Binding var profile: ProviderProfile
    let modelID: String

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.title(forModel: modelID)).lineLimit(1)
                if profile.title(forModel: modelID) != modelID {
                    Text(modelID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            limitField("上下文", value: limitBinding(\.contextWindow))
            limitField("最大输出", value: limitBinding(\.maxOutput))
            Button {
                remove()
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("移除这个模型")
        }
    }

    private func limitField(_ label: String, value: Binding<Int?>) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, value: value, format: .number, prompt: Text("自动"))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 84)
        }
    }

    private func limitBinding(_ key: WritableKeyPath<ModelLimits, Int?>) -> Binding<Int?> {
        Binding(
            get: { profile.limits(for: modelID)[keyPath: key] },
            set: { newValue in
                var l = profile.limits(for: modelID)
                l[keyPath: key] = newValue.flatMap { $0 > 0 ? $0 : nil }
                profile.modelLimits[modelID] = l
            }
        )
    }

    private func remove() {
        var p = profile
        p.models.removeAll { $0 == modelID }
        p.modelLimits.removeValue(forKey: modelID)
        if p.model == modelID { p.model = p.models.first ?? "" }
        profile = p
    }
}

/// 从拉取到的模型里勾选要用的模型
private struct ModelPickerSheet: View {
    @Binding var profile: ProviderProfile
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [RemoteModel] {
        let q = query.trimmed.lowercased()
        guard !q.isEmpty else { return profile.availableModels }
        return profile.availableModels.filter {
            $0.id.lowercased().contains(q) || ($0.displayName?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("选择模型").font(.headline)
                Spacer()
                Text("共 \(profile.availableModels.count) 个，已选 \(profile.models.count) 个")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField("搜索", text: $query, prompt: Text("搜索模型"))
                .textFieldStyle(.roundedBorder)
            List(filtered) { m in
                Toggle(isOn: selection(m)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.title)
                        HStack(spacing: 8) {
                            if m.title != m.id { Text(m.id) }
                            Text("上下文 \(TokenFormat.short(m.limits.contextWindow)) · 输出 \(TokenFormat.short(m.limits.maxOutput))")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .listStyle(.inset)
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 600)
    }

    private func selection(_ m: RemoteModel) -> Binding<Bool> {
        Binding(
            get: { profile.models.contains(m.id) },
            set: { on in
                var p = profile
                if on {
                    if !p.models.contains(m.id) { p.models.append(m.id) }
                    if p.modelLimits[m.id] == nil { p.modelLimits[m.id] = m.limits }
                    if p.model.trimmed.isEmpty { p.model = m.id }
                } else {
                    p.models.removeAll { $0 == m.id }
                    p.modelLimits.removeValue(forKey: m.id)
                    if p.model == m.id { p.model = p.models.first ?? "" }
                }
                profile = p
            }
        )
    }
}

/// tokens 数的简写：1000000 → 1M，128000 → 128K，nil → 自动
enum TokenFormat {
    static func short(_ value: Int?) -> String {
        guard let v = value else { return "自动" }
        if v >= 1_000_000 { return trim(Double(v) / 1_000_000) + "M" }
        if v >= 1_000 { return trim(Double(v) / 1_000) + "K" }
        return "\(v)"
    }

    private static func trim(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(format: "%.1f", d)
    }
}

// MARK: - Account section (CLI login)

struct AccountSection: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    let profile: ProviderProfile
    @State private var checksOnReturn = false

    var body: some View {
        let auth = app.auth
        let kind = profile.kind
        let state = auth.state(kind)
        let exe = profile.cliExecutable
        let loginInProgress = auth.loginInProgress.contains(kind)

        Section {
            LabeledContent("状态") {
                HStack {
                    AuthStateBadge(state: state)
                    Button {
                        Task { await auth.refresh(kind, executable: exe) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(state == .checking || loginInProgress)
                    .help("重新检测")
                }
            }

            if loginInProgress {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("请在浏览器中完成登录…")
                    Spacer()
                    Button("取消") { auth.cancelLogin(kind) }
                }
            } else if case .broken(let fix) = state {
                VStack(alignment: .leading, spacing: 8) {
                    Text("`\(exe)` 安装不完整。重新安装后回到这里检测。")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("在终端中重新安装") {
                        checksOnReturn = true
                        auth.openTerminalRepair(kind, command: fix)
                    }
                }
            } else if state == .notInstalled {
                VStack(alignment: .leading, spacing: 6) {
                    Text("使用账号登录前，请先安装 `\(exe)`。")
                    if let guide = CLIAuthService.installationGuide(for: kind) {
                        Button("安装 CLI", systemImage: "arrow.up.right") {
                            checksOnReturn = true
                            openURL(guide)
                        }
                        .help("打开官方安装指南")
                    }
                    DisclosureGroup("终端安装命令") {
                        Text(CLIAuthService.installHint(for: kind))
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                    Text("安装完成后回到这里，也可以点刷新重新检测。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if state != .checking && state != .unknown {
                HStack(spacing: 8) {
                    if kind == .claudeCode {
                        Menu(state.isLoggedIn ? "重新登录" : "登录 Claude") {
                            Button("Claude 订阅账号（Pro / Max）") { auth.login(kind, executable: exe) }
                            Button("Anthropic Console 账号（API 计费）") { auth.login(kind, executable: exe, console: true) }
                        } primaryAction: {
                            auth.login(kind, executable: exe)
                        }
                        .fixedSize()
                    } else if kind == .antigravity {
                        Button(state.isLoggedIn ? "重新登录" : "使用 Google 登录") {
                            checksOnReturn = true
                            auth.login(kind, executable: exe)
                        }
                        .help(state.isLoggedIn ? "在终端退出当前会话后重新授权" : "在终端发起 Google 授权")
                    } else {
                        Button(state.isLoggedIn ? "重新登录" : "通过 Codex CLI 登录") {
                            auth.login(kind, executable: exe)
                        }
                    }
                    if state.isLoggedIn {
                        Button("退出登录", role: .destructive) {
                            if kind == .antigravity { checksOnReturn = true }
                            Task { await auth.logout(kind, executable: exe) }
                        }
                        .help(kind == .antigravity ? "打开终端完成 Google 账号退出" : "退出当前账号")
                    }
                    Spacer()
                }
                if auth.canContinueLoginInTerminal(kind) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("浏览器登录未完成，可以在终端中继续。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("在终端中继续") {
                            checksOnReturn = true
                            auth.continueLoginInTerminal(kind, executable: exe)
                        }
                    }
                }
            }

            if let log = auth.logs[kind], !log.trimmed.isEmpty {
                DisclosureGroup("登录详情") {
                    ScrollView {
                        Text(log)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 110)
                }
            }
        } header: {
            Text("账号")
        }
        .task(id: exe) {
            if case .unknown = auth.state(kind) { await auth.refresh(kind, executable: exe) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard checksOnReturn else { return }
            checksOnReturn = false
            if auth.state(kind) != .checking && !auth.loginInProgress.contains(kind) {
                Task { await auth.refresh(kind, executable: exe) }
            }
        }
    }
}

// MARK: - General

/// 主题色色块：点击切换，悬停显示名称
private struct ThemeSwatches: View {
    let selection: ThemeColor
    let select: (ThemeColor) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(ThemeColor.allCases) { theme in
                let selected = theme == selection
                Button {
                    withAnimation(.snappy(duration: 0.2)) { select(theme) }
                } label: {
                    Circle()
                        .fill(theme.color)
                        .frame(width: 20, height: 20)
                        .overlay {
                            if theme == .system {
                                // 跟随系统：画一个小标记区分
                                Image(systemName: "apple.logo")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                            } else if selected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .heavy))
                                    .foregroundStyle(.white)
                            }
                        }
                        .padding(3)
                        .overlay(Circle().strokeBorder(selected ? theme.color : .clear, lineWidth: 2))
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                // 与画布工具栏同样的黑色胶囊提示；设置表单会裁掉行外内容，所以画在独立的小窗口里
                .modifier(FloatingHoverName(text: theme.title))
                .accessibilityLabel(theme.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var updater = app.softwareUpdater
        Form {
            Section("外观") {
                LabeledContent("主题色") {
                    ThemeSwatches(selection: ThemeStore.shared.choice) { app.setAccentTheme($0) }
                }
            }

            Section("默认值") {
                Picker("默认模型来源", selection: Binding(
                    get: { app.settings.defaultProviderID },
                    set: { app.settings.defaultProviderID = $0; app.saveSettings() }
                )) {
                    ForEach(app.providers) { p in Text("\(p.name) · \(p.displayModel)").tag(UUID?.some(p.id)) }
                }
                Picker("默认设计系统", selection: Binding(
                    get: { app.settings.defaultDesignSystemID },
                    set: { app.settings.defaultDesignSystemID = $0; app.saveSettings() }
                )) {
                    Text("无").tag(UUID?.none)
                    ForEach(app.designSystems) { ds in Text(ds.name).tag(UUID?.some(ds.id)) }
                }
            }

            Section("数据") {
                LabeledContent("数据目录") {
                    Text(app.persistence.root.path(percentEncoded: false))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                Button("在 Finder 中打开") {
                    NSWorkspace.shared.activateFileViewerSelecting([app.persistence.root])
                }
            }

            Section("软件更新") {
                Toggle("自动检查更新", isOn: $updater.automaticallyChecksForUpdates)
                    .disabled(!updater.isConfigured)
                Button("检查更新…", action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
            }

            Section("关于") {
                LabeledContent("版本", value: SoftwareUpdater.installedVersion ?? "开发版本")
                Text("DesignStudio 是一个开源的 AI 设计画布：用对话生成可交互的 HTML 设计稿，支持 Claude / Codex 账号登录与第三方 API。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
