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
                states[kind] = r.status == 127 ? .notInstalled : .loggedOut
                return
            }
            let r = await CLIRunner.run(executable, ["models"], timeout: 40)
            if r.status == 127 { states[kind] = .notInstalled; return }
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

    /// 后台登录失败时（例如需要手动粘贴授权码），打开终端交互式登录
    func openTerminalLogin(_ kind: ProviderKind, executable: String) {
        let exe = Self.shellQuote(executable)
        let command = switch kind {
        case .claudeCode: "\(exe) auth login"
        // 未登录时 agy 启动后会引导用 Google 账号登录；登录完成后输入 /exit 退出
        case .antigravity: "echo '登录完成后输入 /exit 退出 Antigravity。'; echo; \(exe)"
        default: "\(exe) login"
        }
        let script = """
        #!/bin/zsh -l
        clear
        echo "DesignStudio 正在启动登录流程…"
        echo
        \(command)
        echo
        echo "完成后可以关闭此窗口，并回到 DesignStudio 点击刷新。"
        """
        let url = FileManager.default.temporaryDirectory.appending(path: "designstudio-login-\(kind.rawValue).command")
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
