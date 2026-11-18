import Foundation
import Testing
@testable import DesignStudio

struct CodexStreamingTests {
    @Test(arguments: [false, true])
    func streamsDeltasAndFallsBackForOlderCLI(legacy: Bool) async throws {
        let root = try TempWorkspace.make(prefix: "codex-test")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "mock-codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "exec" ]; then
            cat >/dev/null
            printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","id":"m","text":"Legacy"}}'
            exit 0
        fi
        \(legacy ? "exit 2" : "")
        IFS= read -r line
        printf '%s\\n' '{"id":1,"result":{}}'
        IFS= read -r line
        IFS= read -r line
        printf '%s\\n' '{"id":2,"result":{"thread":{"id":"t"}}}'
        IFS= read -r line
        printf '%s\\n' '{"method":"item/agentMessage/delta","params":{"itemId":"m","delta":"First"}}'
        printf '%s\\n' '{"method":"item/agentMessage/delta","params":{"itemId":"m","delta":" second"}}'
        printf '%s\\n' '{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"m","text":"First second."}}}'
        printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"status":"completed"}}}'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        var profile = ProviderProfile(name: "Mock", kind: .codex)
        profile.executablePath = executable.path
        let request = LLMRequest(system: "", messages: [LLMMessage(role: .user, text: "Draw")])
        var chunks: [String] = []
        for try await event in CodexProvider(profile: profile).stream(request) {
            if case .text(let delta) = event { chunks.append(delta) }
        }
        #expect(chunks == (legacy ? ["Legacy"] : ["First", " second."]))
    }
}
