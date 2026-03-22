import Foundation
import Observation
import os

/// Batch transcript cleanup engine that sends transcript chunks to an LLM
/// to remove filler words and fix punctuation, preserving meaning.
@Observable
@MainActor
final class TranscriptCleanupEngine {
    @ObservationIgnored nonisolated(unsafe) private var _isCleaningUp = false
    private(set) var isCleaningUp: Bool {
        get { access(keyPath: \.isCleaningUp); return _isCleaningUp }
        set { withMutation(keyPath: \.isCleaningUp) { _isCleaningUp = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _chunksCompleted = 0
    private(set) var chunksCompleted: Int {
        get { access(keyPath: \.chunksCompleted); return _chunksCompleted }
        set { withMutation(keyPath: \.chunksCompleted) { _chunksCompleted = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _totalChunks = 0
    private(set) var totalChunks: Int {
        get { access(keyPath: \.totalChunks); return _totalChunks }
        set { withMutation(keyPath: \.totalChunks) { _totalChunks = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _error: String?
    private(set) var error: String? {
        get { access(keyPath: \.error); return _error }
        set { withMutation(keyPath: \.error) { _error = newValue } }
    }

    private nonisolated static let logger = Logger(subsystem: "com.openoats.app", category: "TranscriptCleanup")
    private let client = OpenRouterClient()
    private var currentTask: Task<[SessionRecord], Never>?

    /// The system prompt instructing the LLM how to clean up transcripts.
    private nonisolated static let systemPrompt = """
        You are a transcript cleanup assistant. Your job is to clean up raw speech-to-text output.

        Rules:
        - Remove filler words (um, uh, like, you know, sort of, kind of, I mean, basically, actually, right, so, well) \
        when they add no meaning.
        - Fix punctuation and capitalization.
        - Preserve the original meaning exactly. Do not rephrase, summarize, or add content.
        - Keep the exact same number of lines in the same order.
        - Each line starts with a timestamp and speaker prefix in the format: [HH:MM:SS] Speaker: text
        - Return the cleaned lines in the same format, one per line.
        - Do not add any commentary, explanation, or extra text.
        """

    /// Chunks records into time-based blocks and sends each to an LLM for cleanup.
    /// Returns a new array of `SessionRecord` with `refinedText` populated.
    func cleanup(records: [SessionRecord], settings: AppSettings) async -> [SessionRecord] {
        currentTask?.cancel()
        isCleaningUp = true
        chunksCompleted = 0
        error = nil

        let apiKey: String?
        let baseURL: URL?
        let model: String

        switch settings.llmProvider {
        case .openRouter:
            apiKey = settings.openRouterApiKey.isEmpty ? nil : settings.openRouterApiKey
            baseURL = nil
            model = "openai/gpt-4o-mini"
        case .ollama:
            apiKey = nil
            let base = settings.ollamaBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let ollamaURL = URL(string: base + "/v1/chat/completions") else {
                error = "Invalid Ollama URL: \(settings.ollamaBaseURL)"
                isCleaningUp = false
                return records
            }
            baseURL = ollamaURL
            model = settings.ollamaLLMModel
        case .mlx:
            apiKey = nil
            let base = settings.mlxBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let mlxURL = URL(string: base + "/v1/chat/completions") else {
                error = "Invalid MLX URL: \(settings.mlxBaseURL)"
                isCleaningUp = false
                return records
            }
            baseURL = mlxURL
            model = settings.mlxModel
        case .openAICompatible:
            apiKey = settings.openAILLMApiKey.isEmpty ? nil : settings.openAILLMApiKey
            let base = settings.openAILLMBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let openAIURL = URL(string: base + "/v1/chat/completions") else {
                error = "Invalid OpenAI Compatible URL: \(settings.openAILLMBaseURL)"
                isCleaningUp = false
                return records
            }
            baseURL = openAIURL
            model = settings.openAILLMModel
        }

        let chunks = Self.chunkRecords(records)
        totalChunks = chunks.count

        let task = Task { [weak self, client, apiKey, baseURL, model] () -> [SessionRecord] in
            // Process chunks concurrently (up to 3 at a time) off the main actor.
            let results: [(index: Int, records: [SessionRecord]?)] = await withTaskGroup(
                of: (Int, [SessionRecord]?).self,
                returning: [(Int, [SessionRecord]?)].self
            ) { group in
                var submitted = 0
                var collected: [(Int, [SessionRecord]?)] = []
                collected.reserveCapacity(chunks.count)

                for (chunkIndex, chunk) in chunks.enumerated() {
                    if submitted >= 3 {
                        if let result = await group.next() {
                            collected.append(result)
                            await self?.incrementCompleted()
                        }
                    }

                    guard !Task.isCancelled else { break }

                    group.addTask {
                        let cleaned = await Self.processChunk(
                            chunk,
                            client: client,
                            apiKey: apiKey,
                            model: model,
                            baseURL: baseURL
                        )
                        return (chunkIndex, cleaned)
                    }
                    submitted += 1
                }

                // Collect remaining results.
                for await result in group {
                    collected.append(result)
                    await self?.incrementCompleted()
                }

                return collected
            }

            guard !Task.isCancelled else { return records }

            // Reassemble records in original order, falling back to originals for failed chunks.
            var assembled: [SessionRecord] = []
            let sortedResults = results.sorted { $0.index < $1.index }
            var failedCount = 0

            for (chunkIndex, cleanedRecords) in sortedResults {
                if let cleanedRecords {
                    assembled.append(contentsOf: cleanedRecords)
                } else {
                    failedCount += 1
                    assembled.append(contentsOf: chunks[chunkIndex])
                }
            }

            if failedCount > chunks.count / 2 {
                await self?.setError("Cleanup failed for \(failedCount) of \(chunks.count) chunks")
            }

            return assembled
        }

        currentTask = task
        let result = await task.value
        isCleaningUp = false
        return result
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isCleaningUp = false
        chunksCompleted = 0
        totalChunks = 0
        error = nil
    }

    // MARK: - Private Helpers

    private func incrementCompleted() {
        chunksCompleted += 1
    }

    private func setError(_ message: String) {
        error = message
    }

    /// Splits records into chunks of approximately 2.5 minutes based on timestamps.
    static func chunkRecords(_ records: [SessionRecord]) -> [[SessionRecord]] {
        guard let first = records.first else { return [] }

        let chunkDuration: TimeInterval = 150 // 2.5 minutes
        var chunks: [[SessionRecord]] = []
        var currentChunk: [SessionRecord] = []
        var chunkStart = first.timestamp

        for record in records {
            let elapsed = record.timestamp.timeIntervalSince(chunkStart)
            if elapsed >= chunkDuration && !currentChunk.isEmpty {
                chunks.append(currentChunk)
                currentChunk = [record]
                chunkStart = record.timestamp
            } else {
                currentChunk.append(record)
            }
        }

        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }

        return chunks
    }

    /// Processes a single chunk of records through the LLM. Runs off the main actor.
    private nonisolated static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private nonisolated static func processChunk(
        _ records: [SessionRecord],
        client: OpenRouterClient,
        apiKey: String?,
        model: String,
        baseURL: URL?
    ) async -> [SessionRecord]? {
        let lines = records.map { record in
            let label = record.speaker == .you ? "You" : "Them"
            let text = record.refinedText ?? record.text
            return "[\(timeFormatter.string(from: record.timestamp))] \(label): \(text)"
        }

        let prompt = lines.joined(separator: "\n")

        let messages: [OpenRouterClient.Message] = [
            .init(role: "system", content: systemPrompt),
            .init(role: "user", content: prompt),
        ]

        do {
            let response = try await client.complete(
                apiKey: apiKey,
                model: model,
                messages: messages,
                maxTokens: 4096,
                baseURL: baseURL
            )

            return parseResponse(response, originalRecords: records)
        } catch {
            logger.error("Cleanup chunk failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Parses the LLM response back into session records, stripping the
    /// `[HH:MM:SS] Speaker: ` prefix from each line.
    nonisolated static func parseResponse(
        _ response: String,
        originalRecords: [SessionRecord]
    ) -> [SessionRecord]? {
        let responseLines = response
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        guard responseLines.count == originalRecords.count else {
            // Line count mismatch - fall back to originals.
            return nil
        }

        let prefixPattern = /^\[\d{2}:\d{2}:\d{2}\]\s+\w+:\s*/

        var updated: [SessionRecord] = []
        updated.reserveCapacity(originalRecords.count)

        for (line, original) in zip(responseLines, originalRecords) {
            let cleanedText: String
            if let match = line.prefixMatch(of: prefixPattern) {
                cleanedText = String(line[match.range.upperBound...])
            } else {
                cleanedText = line.trimmingCharacters(in: .whitespaces)
            }

            updated.append(original.withRefinedText(cleanedText.isEmpty ? original.text : cleanedText))
        }

        return updated
    }
}
