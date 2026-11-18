import Foundation
import Darwin

/// GUI 应用默认拿不到终端里的 PATH，这里补全常见安装位置，并通过登录 shell 启动命令
nonisolated enum ShellEnvironment {
    static var augmentedPATH: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = [
            "\(home)/.local/bin",
            "\(home)/.claude/local",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
            "\(home)/Library/pnpm",
            "\(home)/.cargo/bin"
        ]
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            dirs += versions.sorted(by: >).map { "\(nvm)/\($0)/bin" }
        }
        let current = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return (dirs + [current]).joined(separator: ":")
    }

    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = augmentedPATH
        env["NO_COLOR"] = "1"
        env["FORCE_COLOR"] = "0"
        return env
    }
}

nonisolated enum CLILine: Sendable {
    case stdout(String)
    case stderr(String)
    case exit(Int32)
}

nonisolated struct CLIResult: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
    var combined: String { (stdout + "\n" + stderr).trimmed }
}

/// 按行切分管道输出
nonisolated private final class LineBuffer: @unchecked Sendable {
    private var buffer = Data()
    private let emit: (String) -> Void
    init(emit: @escaping (String) -> Void) { self.emit = emit }

    func append(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            emit(String(decoding: lineData, as: UTF8.self))
        }
    }

    func finish() {
        if !buffer.isEmpty {
            emit(String(decoding: buffer, as: UTF8.self))
            buffer.removeAll()
        }
    }
}

nonisolated enum CLIRunner {
    /// 通过 `zsh -lc 'exec "$0" "$@"'` 启动，PATH 与用户终端保持一致；exec 保证 terminate 能直接结束子进程
    static func makeProcess(executable: String, arguments: [String], cwd: URL?) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "exec \"$0\" \"$@\"", executable] + arguments
        process.environment = ShellEnvironment.environment()
        if let cwd { process.currentDirectoryURL = cwd }
        return process
    }

    static func stream(_ executable: String, _ arguments: [String],
                       stdin: String? = nil, cwd: URL? = nil) -> AsyncThrowingStream<CLILine, Error> {
        stream(makeProcess(executable: executable, arguments: arguments, cwd: cwd), stdin: stdin,
               name: executable)
    }

    static func stream(_ process: Process, stdin: String? = nil, inputPipe: Pipe? = nil,
                       name: String) -> AsyncThrowingStream<CLILine, Error> {
        AsyncThrowingStream { continuation in
            let outPipe = Pipe()
            let errPipe = Pipe()
            let inPipe = inputPipe ?? Pipe()
            // CLI 可能在握手前就退出（例如旧版不认识 app-server）。让写入抛错而非触发 SIGPIPE。
            _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.standardInput = inPipe

            let group = DispatchGroup()
            group.enter()
            group.enter()

            let outBuffer = LineBuffer { continuation.yield(.stdout($0)) }
            let errBuffer = LineBuffer { continuation.yield(.stderr($0)) }

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    outBuffer.finish()
                    group.leave()
                } else {
                    outBuffer.append(data)
                }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    errBuffer.finish()
                    group.leave()
                } else {
                    errBuffer.append(data)
                }
            }

            process.terminationHandler = { p in
                group.notify(queue: .global()) {
                    continuation.yield(.exit(p.terminationStatus))
                    continuation.finish()
                }
            }

            do {
                try process.run()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                continuation.finish(throwing: LLMError.notInstalled(name))
                return
            }

            let writer = inPipe.fileHandleForWriting
            if let stdin {
                DispatchQueue.global(qos: .userInitiated).async {
                    try? writer.write(contentsOf: Data(stdin.utf8))
                    try? writer.close()
                }
            } else if inputPipe == nil {
                try? writer.close()
            }

            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }
        }
    }

    /// 运行并收集全部输出（带超时）
    static func run(_ executable: String, _ arguments: [String],
                    stdin: String? = nil, cwd: URL? = nil, timeout: TimeInterval = 30) async -> CLIResult {
        let work = Task { () -> CLIResult in
            var out = "", err = ""
            var status: Int32 = -1
            do {
                for try await line in stream(executable, arguments, stdin: stdin, cwd: cwd) {
                    switch line {
                    case .stdout(let s): out += s + "\n"
                    case .stderr(let s): err += s + "\n"
                    case .exit(let code): status = code
                    }
                }
            } catch {
                err += error.localizedDescription
            }
            return CLIResult(status: status, stdout: out, stderr: err)
        }
        let timer = Task {
            try? await Task.sleep(for: .seconds(timeout))
            work.cancel()
        }
        let result = await work.value
        timer.cancel()
        return result
    }
}

/// 简单的参数切分，支持引号
nonisolated enum ArgumentSplitter {
    static func split(_ s: String) -> [String] {
        var args: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false
        for ch in s {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                hasToken = true
            } else if ch.isWhitespace {
                if hasToken || !current.isEmpty { args.append(current); current = ""; hasToken = false }
            } else {
                current.append(ch)
                hasToken = true
            }
        }
        if hasToken || !current.isEmpty { args.append(current) }
        return args
    }
}

/// 每次 CLI 调用使用独立的临时工作目录
nonisolated enum TempWorkspace {
    static func make(prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "DesignStudio", directoryHint: .isDirectory)
            .appending(path: "\(prefix)-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func writeImages(_ images: [ChatAttachment], to dir: URL) throws -> [URL] {
        try images.enumerated().map { index, img in
            let url = dir.appending(path: "reference-\(index + 1).\(img.fileExtension)")
            try img.data.write(to: url)
            return url
        }
    }
}
