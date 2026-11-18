import Foundation
import AppKit
import Observation

/// 管理 Claude Code / Codex CLI 的登录状态。
/// 登录与凭据存储完全交给官方 CLI（`claude auth login` / `codex login`），本应用不接触 OAuth Token。
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
    @ObservationIgnored private var loginTasks: [ProviderKind: Task<Void, Never>] = [:]

    func state(_ kind: ProviderKind) -> State { states[kind] ?? .unknown }

    func refreshAll(profiles: [ProviderProfile]) async {
        for kind in [ProviderKind.claudeCode, .codex, .antigravity] {
            let exe = profiles.first(where: { $0.kind == kind })?.cliExecutable ?? kind.defaultExecutable
            await refresh(kind, executable: exe)
        }
    }

    func refresh(_ kind: ProviderKind, executable: String) async {
        guard kind.isCLI else { return }
        states[kind] = .checking
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
            // agy 没有查询登录状态的命令：未登录时（本机没有 Google 登录凭据）直接判定，不运行任何命令；
            // 有凭据时用 `agy models` 验证，顺便刷新可选模型列表
            if !FileManager.default.fileExists(atPath: Self.antigravityTokenPath) {
                let r = await CLIRunner.run(executable, ["--version"], timeout: 15)
                if r.status != 0, r.status != 127, let fix = CLIDiagnosis.reinstallCommand(for: r.combined, kind: kind) {
                    states[kind] = .broken(fix: fix)
                } else {
                    states[kind] = r.status == 127 ? .notInstalled : .loggedOut
                }
                return
            }
            let r = await CLIRunner.run(executable, ["models"], timeout: 40)
            if r.status == 127 { states[kind] = .notInstalled; return }
            if r.status != 0, let fix = CLIDiagnosis.reinstallCommand(for: r.combined, kind: kind) {
                states[kind] = .broken(fix: fix); return
            }
            let models = ModelCatalog.parseAntigravityModels(r.stdout)
            if r.status == 0, !models.isEmpty {
                ModelCatalog.saveAntigravityModels(models)
                states[kind] = .loggedIn("Google 账号")
            } else if r.combined.lowercased().contains("auth") || r.combined.lowercased().contains("sign in") {
                states[kind] = .loggedOut
            } else {
                states[kind] = .failed(r.combined.trimmed.split(whereSeparator: \.isNewline).last.map(String.init) ?? "未知错误")
            }
        default:
            break
        }
    }

    /// Antigravity CLI 保存 Google 登录凭据的文件（只判断是否存在，不读取内容）
    static var antigravityTokenPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".gemini/jetski-standalone-oauth-token").path
    }

    /// 在后台运行登录命令（CLI 会自动打开浏览器完成 OAuth）
    func login(_ kind: ProviderKind, executable: String, console: Bool = false) {
        guard kind.isCLI, !loginInProgress.contains(kind) else { return }
        // agy 没有单独的登录命令，首次运行时在终端里交互式登录
        if kind == .antigravity { openTerminalLogin(kind, executable: executable); return }
        loginInProgress.insert(kind)
        logs[kind] = ""
        var args = kind == .claudeCode ? ["auth", "login"] : ["login"]
        if kind == .claudeCode && console { args.append("--console") }

        loginTasks[kind] = Task {
            do {
                for try await line in CLIRunner.stream(executable, args) {
                    switch line {
                    case .stdout(let s), .stderr(let s):
                        let clean = Self.stripANSI(s)
                        if !clean.trimmed.isEmpty { logs[kind, default: ""] += clean + "\n" }
                    case .exit(let code):
                        if code == 127 { logs[kind, default: ""] += "未找到 \(executable)\n" }
                    }
                }
            } catch {
                logs[kind, default: ""] += error.localizedDescription + "\n"
            }
            loginInProgress.remove(kind)
            loginTasks[kind] = nil
            await refresh(kind, executable: executable)
        }
    }

    func cancelLogin(_ kind: ProviderKind) {
        loginTasks[kind]?.cancel()
        loginTasks[kind] = nil
        loginInProgress.remove(kind)
    }

    func logout(_ kind: ProviderKind, executable: String) async {
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
    func openTerminalLogin(_ kind: ProviderKind, executable: String) {
        let exe = Self.shellQuote(executable)
        let command = switch kind {
        case .claudeCode: "\(exe) auth login"
        // 未登录时 agy 启动后会引导用 Google 账号登录；登录完成后输入 /exit 退出
        case .antigravity: "echo '登录完成后输入 /exit 退出 Antigravity。'; echo; \(exe)"
        default: "\(exe) login"
        }
        runInTerminal(kind, name: "login", header: "DesignStudio 正在启动登录流程…", command: command)
    }

    private func runInTerminal(_ kind: ProviderKind, name: String, header: String, command: String) {
        let script = """
        #!/bin/zsh -l
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
            NSWorkspace.shared.open(url)
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
