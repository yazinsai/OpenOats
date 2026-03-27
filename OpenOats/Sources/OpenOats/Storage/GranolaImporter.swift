import Foundation
import os

private let log = Logger(subsystem: "com.openoats.app", category: "GranolaImporter")

// MARK: - Granola API Models

struct GranolaNoteSummary: Codable, Sendable {
    let id: String
    let title: String?
    let owner: GranolaUser?
    let created_at: String
    let updated_at: String
}

struct GranolaUser: Codable, Sendable {
    let name: String?
    let email: String?
}

struct GranolaListResponse: Codable, Sendable {
    let notes: [GranolaNoteSummary]
    let hasMore: Bool
    let cursor: String?
}

struct GranolaNote: Codable, Sendable {
    let id: String
    let title: String?
    let owner: GranolaUser?
    let created_at: String
    let updated_at: String
    let summary_text: String?
    let summary_markdown: String?
    let attendees: [GranolaUser]?
    let transcript: [GranolaTranscriptEntry]?
}

struct GranolaTranscriptEntry: Codable, Sendable {
    let speaker: GranolaSpeaker?
    let text: String
    let start_time: String?
    let end_time: String?
}

struct GranolaSpeaker: Codable, Sendable {
    let source: String? // "microphone" or "speaker"
}

// MARK: - Import State

enum GranolaImportState: Sendable {
    case idle
    case fetching(progress: String)
    case importing(current: Int, total: Int)
    case completed(imported: Int, skipped: Int)
    case failed(String)
}

// MARK: - GranolaImporter

actor GranolaImporter {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - API

    /// Fetch all notes from Granola, paginating through results.
    func fetchAllNotes(apiKey: String) async throws -> [GranolaNoteSummary] {
        var allNotes: [GranolaNoteSummary] = []
        var cursor: String? = nil

        repeat {
            let response = try await fetchNotesPage(apiKey: apiKey, cursor: cursor, pageSize: 30)
            allNotes.append(contentsOf: response.notes)
            cursor = response.hasMore ? response.cursor : nil
        } while cursor != nil

        return allNotes
    }

    private func fetchNotesPage(apiKey: String, cursor: String?, pageSize: Int) async throws -> GranolaListResponse {
        var components = URLComponents(string: "https://public-api.granola.ai/v1/notes")!
        var queryItems = [URLQueryItem(name: "page_size", value: "\(pageSize)")]
        if let cursor {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw GranolaImportError.networkError("Invalid response")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 {
                throw GranolaImportError.unauthorized
            }
            throw GranolaImportError.networkError("HTTP \(http.statusCode)")
        }

        let decoder = JSONDecoder()
        return try decoder.decode(GranolaListResponse.self, from: data)
    }

    /// Fetch a single note with transcript included.
    func fetchNote(id: String, apiKey: String) async throws -> GranolaNote {
        var components = URLComponents(string: "https://public-api.granola.ai/v1/notes/\(id)")!
        components.queryItems = [URLQueryItem(name: "include", value: "transcript")]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GranolaImportError.networkError("Failed to fetch note \(id)")
        }

        let decoder = JSONDecoder()
        return try decoder.decode(GranolaNote.self, from: data)
    }

    // MARK: - Import

    /// Import all Granola notes into OpenOats sessions.
    /// Returns (imported, skipped) counts.
    func importAll(
        apiKey: String,
        sessionRepository: SessionRepository,
        onProgress: @Sendable (GranolaImportState) -> Void
    ) async throws -> (imported: Int, skipped: Int) {
        onProgress(.fetching(progress: "Fetching note list from Granola..."))

        let notes = try await fetchAllNotes(apiKey: apiKey)
        log.info("Fetched \(notes.count) notes from Granola")

        if notes.isEmpty {
            onProgress(.completed(imported: 0, skipped: 0))
            return (0, 0)
        }

        // Get existing session IDs to detect duplicates
        let existingSessions = await sessionRepository.listSessions()
        let existingGranolaIDs = Set(
            existingSessions
                .filter { $0.source == "granola" }
                .compactMap { $0.tags?.first(where: { $0.hasPrefix("granola:") }) }
        )

        var imported = 0
        var skipped = 0

        for (index, noteSummary) in notes.enumerated() {
            let granolaTag = "granola:\(noteSummary.id)"

            // Skip if already imported
            if existingGranolaIDs.contains(granolaTag) {
                skipped += 1
                onProgress(.importing(current: index + 1, total: notes.count))
                continue
            }

            do {
                let fullNote = try await fetchNote(id: noteSummary.id, apiKey: apiKey)
                try await importSingleNote(fullNote, sessionRepository: sessionRepository)
                imported += 1
            } catch {
                log.error("Failed to import note \(noteSummary.id): \(error.localizedDescription, privacy: .public)")
                // Continue with remaining notes
            }

            onProgress(.importing(current: index + 1, total: notes.count))
        }

        onProgress(.completed(imported: imported, skipped: skipped))
        return (imported, skipped)
    }

    private func importSingleNote(_ note: GranolaNote, sessionRepository: SessionRepository) async throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let startDate = iso.date(from: note.created_at) ?? Date()

        // Determine end date from last transcript entry or creation date
        let endDate: Date
        if let lastEntry = note.transcript?.last,
           let endTime = lastEntry.end_time,
           let parsed = iso.date(from: endTime) {
            endDate = parsed
        } else {
            endDate = startDate.addingTimeInterval(3600) // Default 1hr
        }

        let title = note.title ?? "Granola Import"
        let granolaTag = "granola:\(note.id)"

        // Create session
        let sessionID = await sessionRepository.createImportedSession(
            config: .init(
                title: title,
                startedAt: startDate,
                endedAt: endDate,
                language: nil,
                engine: nil
            )
        )

        // Update source and tags
        await sessionRepository.updateSessionSource(sessionID: sessionID, source: "granola", tags: [granolaTag])

        // Convert transcript
        if let transcript = note.transcript, !transcript.isEmpty {
            let records = transcript.compactMap { entry -> SessionRecord? in
                let speaker: Speaker
                if entry.speaker?.source == "microphone" {
                    speaker = .you
                } else {
                    speaker = .them
                }

                let timestamp: Date
                if let startTime = entry.start_time, let parsed = iso.date(from: startTime) {
                    timestamp = parsed
                } else {
                    timestamp = startDate
                }

                return SessionRecord(
                    speaker: speaker,
                    text: entry.text,
                    timestamp: timestamp
                )
            }

            await sessionRepository.saveFinalTranscript(sessionID: sessionID, records: records)
            await sessionRepository.finalizeImportedSession(
                sessionID: sessionID,
                utteranceCount: records.count,
                endedAt: endDate
            )
        }

        // Import notes/summary as EnhancedNotes
        if let markdown = note.summary_markdown ?? note.summary_text {
            let importTemplate = TemplateSnapshot(
                id: UUID(uuidString: "00000000-0000-0000-0000-4772616E6F6C") ?? UUID(),
                name: "Granola Import",
                icon: "square.and.arrow.down",
                systemPrompt: ""
            )
            let enhancedNotes = EnhancedNotes(
                template: importTemplate,
                generatedAt: startDate,
                markdown: markdown
            )
            await sessionRepository.saveNotes(sessionID: sessionID, notes: enhancedNotes)
        }

        log.info("Imported Granola note \(note.id) as session \(sessionID)")
    }
}

// MARK: - Errors

enum GranolaImportError: LocalizedError {
    case unauthorized
    case networkError(String)
    case noApiKey

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Invalid Granola API key. Generate one in the Granola desktop app."
        case .networkError(let msg): "Network error: \(msg)"
        case .noApiKey: "No Granola API key configured. Add it in Settings."
        }
    }
}
