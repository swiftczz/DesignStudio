import Foundation
import AppKit
import Observation

/// 管理 Claude Code、Codex 和 Antigravity CLI 的登录状态。
/// 登录与凭据存储交给各自的官方 CLI。
@MainActor
@Observable
final class CLIAuthService {
    enum State: Equatable {
        case unknown
        case checking
        case notInstalled
        case loggedOut
        case loggedIn(String)
        case failed(String)
        /// 命令行工具装上了但运行不起来（缺少平台组件等），附带修复命令
        case broken(fix: String)

        var isLoggedIn: Bool {
            if case .loggedIn = self { return true }
            return false
        }

        var label: String {
            switch self {
            case .unknown: "未检测"
            case .checking: "检测中…"
            case .notInstalled: "未安装 CLI"
            case .loggedOut: "未登录"
            case .loggedIn(let detail): detail.isEmpty ? "已登录" : "已登录 · \(detail)"
            case .failed(let msg): "检测失败：\(msg)"
            case .broken: "安装不完整"
            }
        }
    }

    private(set) var states: [ProviderKind: State] = [:]
    private(set) var loginInProgress: Set<ProviderKind> = []
    private(set) var logs: [ProviderKind: String] = [:]
    private var terminalFallbacks: [ProviderKind: Bool] = [:]
    @ObservationIgnored private var loginTasks: [ProviderKind: Task<Void, Never>] = [:]
    private let saveAntigravityModels: ([ModelOption]) -> Void

    init(saveAntigravityModels: @escaping ([ModelOption]) -> Void = ModelCatalog.saveAntigravityModels) {
        self.saveAntigravityModels = saveAntigravityModels
    }

    func state(_ kind: ProviderKind) -> State { states[kind] ?? .unknown }

    func canContinueLoginInTerminal(_ kind: ProviderKind) -> Bool {
        terminalFallbacks[kind] != nil && !loginInProgress.contains(kind)
    }

    func continueLoginInTerminal(_ kind: ProviderKind, executable: String) {
        guard let console = terminalFallbacks[kind], canContinueLoginInTerminal(kind) else { return }
        openTerminalLogin(kind, executable: executable, console: console)
    }

    func refreshAll(profiles: [ProviderProfile]) async {
        for kind in [ProviderKind.claudeCode, .codex, .antigravity] {
            let profile = profiles.first { $0.kind == kind }
            if kind == .antigravity && profile == nil { continue }
            let exe = profile?.cliExecutable ?? kind.defaultExecutable
            await refresh(kind, executable: exe)
        }
    }

    func refresh(_ kind: ProviderKind, executable: String) async {
        guard kind.isCLI else { return }
        states[kind] = .checking
        defer {
            if state(kind).isLoggedIn && !loginInProgress.contains(kind) {
                terminalFallbacks[kind] = nil
            }
        }
        switch kind {
        case .claudeCode:
            let r = await CLIRunner.run(executable, ["auth", "status"], timeout: 20)
            if r.status == 127 { states[kind] = .notInstalled; return }
            if r.status != 0, let fix = CLIDiagnosis.reinstallCommand(for: r.combined, kind: kind) {
                states[kind] = .broken(fix: fix); return
            }
            if r.status == 0 {
                states[kind] = .loggedIn(Self.describeClaude(r.stdout))
            } else if r.combined.lowercased().contains("unknown command") || r.combined.lowercased().contains("unknown option") {
                states[kind] = .failed("Claude Code 版本过旧，请运行 `claude update`")
            } else {
                states[kind] = .loggedOut
            }
        case .codex:
            let r = await CLIRunner.run(executable, ["login", "status"], timeout: 20)
            if r.status == 127 { states[kind] = .notInstalled; return }
            // 以前任何失败都显示「未登录」，用户点登录只会重复同样的报错
            if r.status != 0, let fix = CLIDiagnosis.reinstallCommand(for: r.combined, kind: kind) {
                states[kind] = .broken(fix: fix); return
            }
            if r.status == 0 {
                let line = r.combined.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
                states[kind] = .loggedIn(Self.describeCodex(line))
            } else {
                states[kind] = .loggedOut
            }
        case .antigravity:
            // 凭据可能保存在系统钥匙串。通过 CLI 验证会话并更新模型列表。
            let r = await CLIRunner.run(executable, ["models"], timeout: 40)
            if r.status == 127 { states[kind] = .notInstalled; return }
            let output = Self.stripANSI(r.combined)
            if r.status != 0, let fix = CLIDiagnosis.reinstallCommand(for: output, kind: kind) {
                states[kind] = .broken(fix: fix); return
            }
            let models = ModelCatalog.parseAntigravityModels(Self.stripANSI(r.stdout))
            if r.status == 0, !models.isEmpty {
                saveAntigravityModels(models)
                states[kind] = .loggedIn("Google 账号")
            } else if case .notLoggedIn = AntigravityProvider.classify(output) {
                states[kind] = .loggedOut
            } else {
                let fallback = r.status == 0 ? "Antigravity 未返回可用模型" : "无法获取 Antigravity 模型列表"
                states[kind] = .failed(output.trimmed.split(whereSeparator: \.isNewline).last.map(String.init) ?? fallback)
            }
        default:
            break
        }
    }

    /// 在后台运行登录命令（CLI 会自动打开浏览器完成 OAuth）
    func login(_ kind: ProviderKind, executable: String, console: Bool = false) {
        guard kind.isCLI, !loginInProgress.contains(kind) else { return }
        if kind == .antigravity {
            let instruction = state(kind).isLoggedIn
                ? "请在 Antigravity 中输入 /logout，再按提示登录。如回到终端提示符，请重新运行 Antigravity CLI。"
                : "请按 Antigravity 的提示完成 Google 登录。"
            runInTerminal(kind, name: "login", header: instruction, command: Self.shellQuote(executable))
            return
        }
        loginInProgress.insert(kind)
        logs[kind] = ""
        terminalFallbacks[kind] = console
        let args = Self.loginArguments(for: kind, console: console)

        loginTasks[kind] = Task {
            var exitCode: Int32?
            do {
                for try await line in CLIRunner.stream(executable, args) {
                    guard !Task.isCancelled else { return }
                    switch line {
                    case .stdout(let s), .stderr(let s):
                        let clean = Self.stripANSI(s)
                        if !clean.trimmed.isEmpty { logs[kind, default: ""] += clean + "\n" }
                    case .exit(let code):
                        exitCode = code
                        if code == 127 { logs[kind, default: ""] += "未找到 \(executable)\n" }
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                logs[kind, default: ""] += error.localizedDescription + "\n"
            }
            guard !Task.isCancelled else { return }
            await refresh(kind, executable: executable)
            guard !Task.isCancelled else { return }
            if exitCode == 0 && state(kind).isLoggedIn {
                terminalFallbacks[kind] = nil
            }
            loginInProgress.remove(kind)
            loginTasks[kind] = nil
        }
    }

    func cancelLogin(_ kind: ProviderKind) {
        loginTasks[kind]?.cancel()
        loginTasks[kind] = nil
        loginInProgress.remove(kind)
    }

    func logout(_ kind: ProviderKind, executable: String) async {
        if kind == .antigravity {
            runInTerminal(kind, name: "logout", header: "请在 Antigravity 中输入 /logout，退出当前 Google 账号。",
                          command: Self.shellQuote(executable))
            return
        }
        let args = kind == .claudeCode ? ["auth", "logout"] : ["logout"]
        let r = await CLIRunner.run(executable, args, timeout: 20)
        logs[kind] = r.combined
        await refresh(kind, executable: executable)
    }

    /// 在终端里运行修复命令（重新安装命令行工具），完成后回到应用点刷新
    func openTerminalRepair(_ kind: ProviderKind, command: String) {
        runInTerminal(kind, name: "repair", header: "DesignStudio 正在重新安装命令行工具…", command: command)
    }

    /// 后台登录失败时（例如需要手动粘贴授权码），打开终端交互式登录
    private func openTerminalLogin(_ kind: ProviderKind, executable: String, console: Bool) {
        let exe = Self.shellQuote(executable)
        let command = ([exe] + Self.loginArguments(for: kind, console: console)).joined(separator: " ")
        runInTerminal(kind, name: "login", header: "DesignStudio 正在启动登录流程…", command: command)
    }

    private static func loginArguments(for kind: ProviderKind, console: Bool) -> [String] {
        guard kind == .claudeCode else { return ["login"] }
        return console ? ["auth", "login", "--console"] : ["auth", "login"]
    }

    private func runInTerminal(_ kind: ProviderKind, name: String, header: String, command: String) {
        let script = """
        #!/bin/zsh -l
        export PATH=\(Self.shellQuote(ShellEnvironment.augmentedPATH)):"$PATH"
        clear
        echo "\(header)"
        echo
        \(command)
        echo
        echo "完成后可以关闭此窗口，并回到 DesignStudio 点击刷新。"
        """
        let url = FileManager.default.temporaryDirectory.appending(path: "designstudio-\(name)-\(kind.rawValue).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            if !NSWorkspace.shared.open(url) {
                logs[kind, default: ""] += "无法打开终端。\n"
            }
        } catch {
            logs[kind, default: ""] += "无法打开终端：\(error.localizedDescription)\n"
        }
    }

    // MARK: - Helpers

    static func describeClaude(_ json: String) -> String {
        guard let obj = JSONHelpers.object(json.trimmed) else { return "" }
        var parts: [String] = []
        for key in ["email", "account", "orgName", "organization"] {
            if let v = obj[key] as? String, !v.isEmpty { parts.append(v); break }
        }
        for key in ["subscriptionType", "subscription", "plan", "authMethod", "method"] {
            if let v = obj[key] as? String, !v.isEmpty { parts.append(v); break }
        }
        return parts.joined(separator: " · ")
    }

    static func describeCodex(_ line: String) -> String {
        let lower = line.lowercased()
        if lower.contains("chatgpt") { return "ChatGPT 账号" }
        if lower.contains("api key") { return "API Key" }
        return ""
    }

    static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }

    static func shellQuote(_ s: String) -> String {
        if s.allSatisfy({ $0.isLetter || $0.isNumber || "/._-~".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func installationGuide(for kind: ProviderKind) -> URL? {
        let address = switch kind {
        case .claudeCode: "https://code.claude.com/docs/en/setup#install-claude-code"
        case .codex: "https://learn.chatgpt.com/docs/codex/cli"
        case .antigravity: "https://antigravity.google/docs/getting-started?tab=cli"
        default: ""
        }
        return address.isEmpty ? nil : URL(string: address)
    }

    static func installHint(for kind: ProviderKind) -> String {
        switch kind {
        case .claudeCode: "curl -fsSL https://claude.ai/install.sh | bash"
        case .codex: "npm install -g @openai/codex   # 或 brew install --cask codex"
        case .antigravity: "brew install --cask antigravity-cli"
        default: ""
        }
    }
}

/// 判断命令行工具是不是「装上了但跑不起来」，给出重新安装的命令（生成时的报错也用它）
nonisolated enum CLIDiagnosis {
    /// 典型输出：npm 全局安装缺少当前芯片的平台包（`Missing optional dependency @openai/codex-darwin-arm64`，
    /// 常见于在 Rosetta 下的 Node 里安装过、或 npm 跳过了可选依赖），以及 Node 模块缺失、架构不符、动态库缺失
    static func reinstallCommand(for output: String, kind: ProviderKind) -> String? {
        let lower = output.lowercased()
        let markers = ["missing optional dependency", "cannot find module", "err_module_not_found",
                       "bad cpu type", "library not loaded", "image not found", "exec format error"]
        guard markers.contains(where: lower.contains) else { return nil }
        let viaNPM = lower.contains("node_modules")
        switch kind {
        case .codex: return viaNPM ? "npm install -g @openai/codex@latest" : "brew reinstall --cask codex"
        case .claudeCode: return viaNPM ? "npm install -g @anthropic-ai/claude-code@latest" : "curl -fsSL https://claude.ai/install.sh | bash"
        case .antigravity: return "brew reinstall --cask antigravity-cli"
        default: return nil
        }
    }

    /// 生成时遇到安装问题，给出能直接照做的提示，而不是一段 Node 报错堆栈
    static func brokenInstallMessage(_ output: String, kind: ProviderKind, name: String) -> String? {
        guard let fix = reinstallCommand(for: output, kind: kind) else { return nil }
        return "\(name) 命令行工具安装不完整，无法运行。请在终端运行 `\(fix)` 重新安装，然后重试。"
    }
}
