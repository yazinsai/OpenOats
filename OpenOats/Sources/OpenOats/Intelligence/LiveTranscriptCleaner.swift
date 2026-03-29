import Foundation

/// Cleans utterances by removing filler words and fixing punctuation via LLM.
/// Runs as a background actor with bounded concurrency.
actor LiveTranscriptCleaner {
    private let client = OpenRouterClient()
    private let settings: AppSettings
    private let transcriptStore: TranscriptStore

    private let maxConcurrent = 3
    private var inFlightCount = 0
    private var pendingQueue: [Utterance] = []
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

    /// Hardcoded cheap model for cleanup (keeps cost low).
    private let cleanupModel = "openai/gpt-4o-mini"
    private let minimumWordCount = 5

    private let systemPrompt = """
        Clean up this speech transcript: remove filler words (uh, um, like, you know), \
        fix punctuation, add sentence breaks. Output only the cleaned text.
        """

    init(settings: AppSettings, transcriptStore: TranscriptStore) {
        self.settings = settings
        self.transcriptStore = transcriptStore
    }

    /// Queue an utterance for cleanup.
    func clean(_ utterance: Utterance) {
        // Skip short utterances unless they look like a question
        let words = utterance.text.split(separator: " ")
        if words.count < minimumWordCount && !utterance.text.contains("?") {
            Task { @MainActor in
                transcriptStore.updateCleanedText(id: utterance.id, cleanedText: nil, status: .skipped)
            }
            return
        }

        pendingQueue.append(utterance)
        drainQueue()
    }

    /// Await all pending and in-flight cleanups, with a timeout.
    func drain(timeout: Duration = .seconds(5)) async {
        guard inFlightCount > 0 || !pendingQueue.isEmpty else { return }

        let tasks = activeTasks.values.map { $0 }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for task in tasks {
                    await task.value
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            // Return as soon as either completes
            await group.next()
            group.cancelAll()
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
                store.updateCleanedText(id: utterance.id, cleanedText: nil, status: .pending)
            }

            let task = Task { [weak self] in
                guard let self else { return }
                await self.performCleanup(utterance)
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

    private func performCleanup(_ utterance: Utterance) async {
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
        let openAILLMURL = await MainActor.run { settings.openAILLMBaseURL }
        let openAILLMKey = await MainActor.run { settings.openAILLMApiKey }
        let openAILLMModelName = await MainActor.run { settings.openAILLMModel }

        switch provider {
        case .openRouter:
            apiKey = openRouterKey.isEmpty ? nil : openRouterKey
            baseURL = nil
            model = cleanupModel
        case .ollama:
            apiKey = nil
            guard let url = OpenRouterClient.chatCompletionsURL(from: ollamaURL) else {
                await markFailed(utterance.id)
                return
            }
            baseURL = url
            model = ollamaModel
        case .mlx:
            apiKey = nil
            guard let url = OpenRouterClient.chatCompletionsURL(from: mlxURL) else {
                await markFailed(utterance.id)
                return
            }
            baseURL = url
            model = mlxModelName
        case .openAICompatible:
            apiKey = openAILLMKey.isEmpty ? nil : openAILLMKey
            guard let url = OpenRouterClient.chatCompletionsURL(from: openAILLMURL) else {
                await markFailed(utterance.id)
                return
            }
            baseURL = url
            model = openAILLMModelName
        }

        let messages: [OpenRouterClient.Message] = [
            .init(role: "system", content: systemPrompt),
            .init(role: "user", content: utterance.text)
        ]

        do {
            let cleaned = try await client.complete(
                apiKey: apiKey,
                model: model,
                messages: messages,
                maxTokens: 512,
                baseURL: baseURL
            )

            let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                await markFailed(utterance.id)
                return
            }

            let store = transcriptStore
            Task { @MainActor in
                store.updateCleanedText(id: utterance.id, cleanedText: trimmed, status: .completed)
            }
        } catch {
            await markFailed(utterance.id)
        }
    }

    private func markFailed(_ id: UUID) async {
        let store = transcriptStore
        Task { @MainActor in
            store.updateCleanedText(id: id, cleanedText: nil, status: .failed)
        }
    }
}
