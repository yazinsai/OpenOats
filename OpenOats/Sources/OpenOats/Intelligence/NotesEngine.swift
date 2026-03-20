import Foundation
import Observation

/// Generates structured meeting notes from a transcript using the LLM.
@Observable
@MainActor
final class NotesEngine {
    enum Mode {
        case live
        case scripted(markdown: String)
    }

    @ObservationIgnored nonisolated(unsafe) private var _isGenerating = false
    private(set) var isGenerating: Bool {
        get { access(keyPath: \.isGenerating); return _isGenerating }
        set { withMutation(keyPath: \.isGenerating) { _isGenerating = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _generatedMarkdown = ""
    private(set) var generatedMarkdown: String {
        get { access(keyPath: \.generatedMarkdown); return _generatedMarkdown }
        set { withMutation(keyPath: \.generatedMarkdown) { _generatedMarkdown = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _error: String?
    private(set) var error: String? {
        get { access(keyPath: \.error); return _error }
        set { withMutation(keyPath: \.error) { _error = newValue } }
    }

    private let client = OpenRouterClient()
    private var currentTask: Task<Void, Never>?
    private let mode: Mode

    init(mode: Mode = .live) {
        self.mode = mode
    }

    /// Streams note generation from the LLM, updating `generatedMarkdown` in real time.
    func generate(
        transcript: [SessionRecord],
        template: MeetingTemplate,
        settings: AppSettings
    ) async {
        currentTask?.cancel()
        isGenerating = true
        generatedMarkdown = ""
        error = nil

        if case .scripted(let markdown) = mode {
            generatedMarkdown = markdown
            isGenerating = false
            return
        }

        let apiKey: String?
        let baseURL: URL?
        let model: String

        switch settings.llmProvider {
        case .openRouter:
            apiKey = settings.openRouterApiKey.isEmpty ? nil : settings.openRouterApiKey
            baseURL = nil
            model = settings.selectedModel
        case .ollama:
            apiKey = nil
            let base = settings.ollamaBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let ollamaURL = URL(string: base + "/v1/chat/completions") else {
                error = "Invalid Ollama URL: \(settings.ollamaBaseURL)"
                isGenerating = false
                return
            }
            baseURL = ollamaURL
            model = settings.ollamaLLMModel
        case .mlx:
            apiKey = nil
            let base = settings.mlxBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let mlxURL = URL(string: base + "/v1/chat/completions") else {
                error = "Invalid MLX URL: \(settings.mlxBaseURL)"
                isGenerating = false
                return
            }
            baseURL = mlxURL
            model = settings.mlxModel
        }

        let transcriptText = formatTranscript(transcript)
        let messages: [OpenRouterClient.Message] = [
            .init(role: "system", content: template.systemPrompt),
            .init(role: "user", content: "Here is the meeting transcript:\n\n\(transcriptText)\n\nGenerate the meeting notes in markdown:")
        ]

        let task = Task { [weak self] in
            do {
                let stream = await self?.client.streamCompletion(
                    apiKey: apiKey,
                    model: model,
                    messages: messages,
                    maxTokens: 4096,
                    baseURL: baseURL
                )
                guard let stream else { return }

                for try await chunk in stream {
                    guard !Task.isCancelled else { return }
                    self?.generatedMarkdown += chunk
                }
            } catch {
                if !Task.isCancelled {
                    self?.error = error.localizedDescription
                }
            }
            self?.isGenerating = false
        }
        currentTask = task
        await task.value
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isGenerating = false
    }

    private func formatTranscript(_ records: [SessionRecord]) -> String {
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"

        var lines: [String] = []
        var totalChars = 0
        let maxChars = 60_000

        for record in records {
            let label = record.speaker == .you ? "You" : "Them"
            let bestText = record.refinedText ?? record.text
            let line = "[\(timeFmt.string(from: record.timestamp))] \(label): \(bestText)"
            totalChars += line.count
            lines.append(line)
        }

        // Truncate middle if too long
        if totalChars > maxChars {
            let keepLines = lines.count / 3
            let head = Array(lines.prefix(keepLines))
            let tail = Array(lines.suffix(keepLines))
            let omitted = lines.count - (keepLines * 2)
            return (head + ["[... \(omitted) utterances omitted ...]"] + tail).joined(separator: "\n")
        }

        return lines.joined(separator: "\n")
    }
}
