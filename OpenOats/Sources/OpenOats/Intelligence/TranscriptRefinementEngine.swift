import Foundation

/// Refines utterances by cleaning up filler words and fixing punctuation via LLM.
/// Runs as a background actor with bounded concurrency.
actor TranscriptRefinementEngine {
    private let client = OpenRouterClient()
    private let settings: AppSettings
    private let transcriptStore: TranscriptStore

    private let maxConcurrent = 3
    private var inFlightCount = 0
    private var pendingQueue: [Utterance] = []
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

    /// Hardcoded cheap model for refinement (keeps cost low).
    private let refinementModel = "openai/gpt-4o-mini"
    private let minimumWordCount = 5

    private let systemPrompt = """
        Clean up this speech transcript: remove filler words (uh, um, like, you know), \
        fix punctuation, add sentence breaks. Output only the cleaned text.
        """

    init(settings: AppSettings, transcriptStore: TranscriptStore) {
        self.settings = settings
        self.transcriptStore = transcriptStore
    }

    /// Queue an utterance for refinement.
    func refine(_ utterance: Utterance) {
        // Skip short utterances unless they look like a question
        let words = utterance.text.split(separator: " ")
        if words.count < minimumWordCount && !utterance.text.contains("?") {
            Task { @MainActor in
                transcriptStore.updateRefinedText(id: utterance.id, refinedText: nil, status: .skipped)
            }
            return
        }

        pendingQueue.append(utterance)
        drainQueue()
    }

    /// Await all pending and in-flight refinements, with a timeout.
    func drain(timeout: Duration = .seconds(300)) async {
        let deadline = ContinuousClock.now + timeout
        while (inFlightCount > 0 || !pendingQueue.isEmpty) && ContinuousClock.now < deadline {
            guard let anyTask = activeTasks.values.first else {
                drainQueue()
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            await anyTask.value
        }
    }

    // MARK: - Private

    private func drainQueue() {
        while inFlightCount < maxConcurrent, let utterance = pendingQueue.first {
            pendingQueue.removeFirst()
            inFlightCount += 1

            // Mark as pending on main actor
            let store = transcriptStore
            Task { @MainActor in
                store.updateRefinedText(id: utterance.id, refinedText: nil, status: .pending)
            }

            let task = Task { [weak self] in
                guard let self else { return }
                await self.performRefinement(utterance)
                await self.taskCompleted(id: utterance.id)
            }
            activeTasks[utterance.id] = task
        }
    }

    private func taskCompleted(id: UUID) {
        activeTasks.removeValue(forKey: id)
        inFlightCount -= 1
        drainQueue()
    }

    private func performRefinement(_ utterance: Utterance) async {
        let apiKey: String?
        let baseURL: URL?
        let model: String

        // Read settings on MainActor
        let provider = await MainActor.run { settings.llmProvider }
        let openRouterKey = await MainActor.run { settings.openRouterApiKey }
        let ollamaURL = await MainActor.run { settings.ollamaBaseURL }
        let ollamaModel = await MainActor.run { settings.ollamaLLMModel }
        let mlxURL = await MainActor.run { settings.mlxBaseURL }
        let mlxModelName = await MainActor.run { settings.mlxModel }

        switch provider {
        case .openRouter:
            apiKey = openRouterKey.isEmpty ? nil : openRouterKey
            baseURL = nil
            model = refinementModel
        case .ollama:
            apiKey = nil
            let base = ollamaURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let url = URL(string: base + "/v1/chat/completions") else {
                await markFailed(utterance.id)
                return
            }
            baseURL = url
            model = ollamaModel
        case .mlx:
            apiKey = nil
            let base = mlxURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let url = URL(string: base + "/v1/chat/completions") else {
                await markFailed(utterance.id)
                return
            }
            baseURL = url
            model = mlxModelName
        }

        let messages: [OpenRouterClient.Message] = [
            .init(role: "system", content: systemPrompt),
            .init(role: "user", content: utterance.text)
        ]

        do {
            let refined = try await client.complete(
                apiKey: apiKey,
                model: model,
                messages: messages,
                maxTokens: 512,
                baseURL: baseURL
            )

            let trimmed = refined.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                await markFailed(utterance.id)
                return
            }

            let store = transcriptStore
            Task { @MainActor in
                store.updateRefinedText(id: utterance.id, refinedText: trimmed, status: .completed)
            }
        } catch {
            await markFailed(utterance.id)
        }
    }

    private func markFailed(_ id: UUID) async {
        let store = transcriptStore
        Task { @MainActor in
            store.updateRefinedText(id: id, refinedText: nil, status: .failed)
        }
    }
}
