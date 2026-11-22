import Foundation

/// One user turn can require several bounded provider requests.
nonisolated struct DesignRequestPlan {
    static let unchanged = "<!-- unchanged -->"

    struct Batch {
        let request: LLMRequest
        let expectedIDs: Set<UUID>
    }

    let batches: [Batch]
    let artboardIDs: Set<UUID>?

    static func validate(_ text: String, expected: Set<UUID>) -> (markdown: String, completed: Set<UUID>) {
        let blocks = HTMLExtractor.artifacts(in: text).compactMap { artifact -> (UUID, HTMLExtractor.Artifact)? in
            guard !artifact.isSharedCSS, !ArtboardParser.isElementInfo(artifact.info),
                  let name = ArtboardParser.parseInfo(artifact.info).name,
                  let id = UUID(uuidString: name), expected.contains(id) else { return nil }
            return (id, artifact)
        }
        let grouped = Dictionary(grouping: blocks, by: { $0.0 })
        let accepted = blocks.filter { id, artifact in
            grouped[id]?.count == 1 && artifact.complete && !artifact.html.trimmed.isEmpty
        }
        return (accepted.map { String(text[$0.1.range]) }.joined(separator: "\n\n"), Set(accepted.map { $0.0 }))
    }

    static func make(project: Project, designSystem: DesignSystem?, message: ChatMessage,
                     profile: ProviderProfile, page: DesignPage, selection: DesignPrompt.SelectionContext?,
                     commentsOnly: Bool, scope: Set<UUID>?, preserving names: Set<String>,
                     skipping finished: Set<UUID>, destinationIDs: [UUID: UUID]?) throws -> Self {
        let budget = Budget(profile)
        func request(for targets: [UUID: UUID]? = nil) -> LLMRequest {
            DesignPrompt.makeRequest(project: project, designSystem: designSystem, newMessage: message,
                                     profile: profile, pageID: page.id, selection: selection, commentsOnly: commentsOnly,
                                     scopeIDs: scope, preserving: names, batchTargets: targets)
        }

        let preservedNames = Set(names.map { $0.trimmed.lowercased() })
        let commentIDs = Set(message.comments.compactMap { comment in
            comment.artboardID ?? comment.artboardName.flatMap { page.artboard(named: $0)?.id }
        })
        let effectiveScope = scope ?? (commentsOnly && !commentIDs.isEmpty &&
            message.comments.allSatisfy { comment in
                if let id = comment.artboardID { return page.artboards.contains { $0.id == id } }
                return comment.artboardName.flatMap { page.artboard(named: $0) } != nil
            } ? commentIDs : nil)
        let boards = page.artboards.filter {
            (effectiveScope?.contains($0.id) ?? true) && !finished.contains($0.id)
                && !preservedNames.contains($0.name.trimmed.lowercased())
        }
        let normal = request()
        let predictedOutput = boards.reduce(0) { $0 + outputEstimate($1) }
        if destinationIDs == nil, finished.isEmpty,
           let fitted = budget.fitting(normal),
           normal.elementEdit || boards.count < 2 || predictedOutput <= budget.outputTarget {
            return Self(batches: [Batch(request: fitted, expectedIDs: [])], artboardIDs: nil)
        }
        guard !normal.elementEdit, !boards.isEmpty else {
            throw LLMError.invalidResponse("本轮请求超出输入预算。请缩小修改范围或减少参考资料后重试。")
        }

        var batches: [Batch] = []
        var targets: [UUID: UUID] = [:]
        var prepared: LLMRequest?
        var outputTokens = 0
        for board in boards {
            let id = destinationIDs?[board.id] ?? board.id
            let cost = outputEstimate(board)
            var candidate = targets
            candidate[board.id] = id
            if !targets.isEmpty, outputTokens + cost <= budget.outputTarget,
               let fitted = budget.fitting(request(for: candidate)) {
                targets = candidate
                prepared = fitted
                outputTokens += cost
                continue
            }
            if let prepared { batches.append(Batch(request: prepared, expectedIDs: Set(targets.values))) }
            targets = [board.id: id]
            prepared = budget.fitting(request(for: targets))
            guard prepared != nil else {
                throw LLMError.invalidResponse("画板「\(board.name)」与本轮需求超出输入预算。请减少参考资料、选择更大上下文的模型，或选中画板内的元素修改。")
            }
            outputTokens = cost
        }
        if let prepared { batches.append(Batch(request: prepared, expectedIDs: Set(targets.values))) }
        return Self(batches: batches, artboardIDs: Set(batches.flatMap(\.expectedIDs)))
    }

    private static func outputEstimate(_ board: Artboard) -> Int {
        DesignPrompt.estimateTokens(board.html) + 120
    }

    private struct Budget {
        let profile: ProviderProfile
        let inputTarget: Int
        let outputTarget: Int

        init(_ profile: ProviderProfile) {
            self.profile = profile
            let limits = profile.limits
            let context = limits.contextWindow.flatMap { $0 > 0 ? $0 : nil }
            let output = min(max(1, limits.maxOutput ?? 16_000), context.map { max(1, $0 / 3) } ?? 32_000)
            outputTarget = output
            inputTarget = context.map { max(1, $0 - $0 / 10 - output) } ?? 48_000
        }

        /// Keep a contiguous suffix of history after reserving space for the current request.
        func fitting(_ request: LLMRequest) -> LLMRequest? {
            guard let latest = request.messages.last else { return nil }
            let mandatory = DesignPrompt.estimateTokens(request.system) + DesignPrompt.estimateTokens(latest) + 512
            guard mandatory <= inputTarget else { return nil }
            var result = request
            var tokens = mandatory
            var history: [LLMMessage] = []
            for message in request.messages.dropLast().reversed() {
                tokens += DesignPrompt.estimateTokens(message)
                if tokens > inputTarget { break }
                history.append(message)
            }
            result.messages = Array(history.reversed()) + [latest]
            if profile.kind == .antigravity {
                while AntigravityProvider.inputLine(result.flattenedPrompt(includeSystem: true)).utf8.count
                    > AntigravityProvider.inputBudgetBytes - 2048 {
                    guard result.messages.count > 1 else { return nil }
                    result.messages.removeFirst()
                }
            }
            if !profile.kind.isCLI {
                result.messages = DesignPrompt.normalize(result.messages)
                if let maxTokens = result.maxTokens, let context = profile.limits.contextWindow, context > 0 {
                    let actualInput = result.messages.reduce(DesignPrompt.estimateTokens(result.system) + 512) {
                        $0 + DesignPrompt.estimateTokens($1)
                    }
                    result.maxTokens = min(maxTokens, max(1, context - actualInput))
                }
            }
            return result
        }
    }
}
