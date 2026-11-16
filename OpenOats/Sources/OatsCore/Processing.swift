import Foundation

/// Output of the Notes step: Notes markdown, an optional title, and the Vocabulary-corrected Transcript if any.
public struct Notes: Codable, Sendable, Equatable {
    public var title: String?
    public var markdown: String
    public var turns: [Turn]?

    public init(title: String?, markdown: String, turns: [Turn]? = nil) {
        self.title = title
        self.markdown = markdown
        self.turns = turns
    }

    /// Parses a model reply whose first line may be `Title: …`.
    public init(reply: String) {
        var lines = reply.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        var title: String?
        if let first = lines.first, first.lowercased().hasPrefix("title:") {
            title = first.dropFirst(6).trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"*#")))
            lines.removeFirst()
        }
        self.init(title: title?.isEmpty == false ? title : nil, markdown: lines.joined(separator: "\n"))
    }
}

/// Step 3 hook: Vocabulary correction and Notes from the merged Transcript (#755 supplies the real one).
public typealias NotesStep = @Sendable (_ turns: [Turn], _ backend: any NotesBackend) async throws -> Notes

extension Array where Element == Turn {
    /// `[HH:MM:SS] You: text` lines, the Transcript as plain text for a Notes backend.
    public var plainText: String {
        map { "[\(MeetingFileWriter.timestamp($0.start))] \($0.speaker.map { "\($0): " } ?? "")\($0.text)" }
            .joined(separator: "\n")
    }
}

/// What Processing needs besides the Meeting folder.
public struct ProcessingOptions: Sendable {
    public var transcription: any TranscriptionBackend
    /// nil skips the Notes step.
    public var notes: (any NotesBackend)?
    public var notesStep: NotesStep
    /// Where Meeting files are written (the user's notes folder).
    public var notesFolder: URL
    /// false deletes the tracks once the Meeting file exists; true compresses them to `.m4a`.
    public var keepAudio: Bool

    public init(transcription: any TranscriptionBackend, notes: (any NotesBackend)? = nil,
                notesStep: @escaping NotesStep = Processing.defaultNotesStep, notesFolder: URL, keepAudio: Bool = true) {
        self.transcription = transcription
        self.notes = notes
        self.notesStep = notesStep
        self.notesFolder = notesFolder
        self.keepAudio = keepAudio
    }
}

public enum ProcessingError: LocalizedError {
    case noTracks
    case unreadableAudio(String)

    public var errorDescription: String? {
        switch self {
        case .noTracks: "This Meeting has no audio to transcribe."
        case let .unreadableAudio(name): "Couldn't read the audio file \(name)."
        }
    }
}

/// The Processing pipeline: Meeting folder in, Meeting file out. Used by the app (via `ProcessingQueue`) and the CLI.
public enum Processing {
    static let roles = ["mic", "system", "mixed"]

    /// Runs the steps not yet checkpointed and returns the final status (`done` or `needsAttention`).
    /// Throws only if `meeting.json` can't be read or written.
    @discardableResult
    public static func run(_ folder: MeetingFolder, options: ProcessingOptions) async throws -> MeetingStatus {
        var status = try folder.updateStatus {
            $0.state = .processing
            $0.lastError = nil
        }
        var notesError: Error?
        do {
            if !status.completedSteps.contains(.transcribe) {
                let durations = roles.flatMap(folder.trackFiles).map(TrackAudio.duration)
                guard !durations.isEmpty else { throw ProcessingError.noTracks }
                do {
                    for role in roles where folder.readCheckpoint(role, as: [TimedSegment].self) == nil {
                        guard let track = folder.trackFiles(role).first else { continue }
                        let segments = try await options.transcription.transcribe(track, language: status.language)
                        try folder.writeCheckpoint(role, segments)
                    }
                } catch {
                    await options.transcription.unload()
                    throw error
                }
                await options.transcription.unload()
                status.duration = durations.max()
                status.transcriptionBackend = options.transcription.name
                status.completedSteps.append(.transcribe)
                try folder.writeStatus(status)
            }
            if !status.completedSteps.contains(.merge) {
                let segments = { folder.readCheckpoint($0, as: [TimedSegment].self) ?? [] }
                let turns = FileManager.default.fileExists(atPath: folder.checkpointURL("mixed").path)
                    ? TranscriptMerge.mixed(segments("mixed"), separatesSpeakers: options.transcription.separatesSpeakers)
                    : TranscriptMerge.merge(mic: segments("mic"), system: segments("system"))
                try folder.writeCheckpoint("transcript", turns)
                status.completedSteps.append(.merge)
                try folder.writeStatus(status)
            }
            let turns = folder.readCheckpoint("transcript", as: [Turn].self) ?? []
            if !status.completedSteps.contains(.notes) {
                if let backend = options.notes {
                    do {
                        try folder.writeCheckpoint("notes", try await options.notesStep(turns, backend))
                        status.notesBackend = backend.name
                        status.completedSteps.append(.notes)
                    } catch {
                        notesError = error
                    }
                } else {
                    status.completedSteps.append(.notes)
                }
                try folder.writeStatus(status)
            }
            try writeMeetingFile(folder, &status, turns: turns, options: options)
            try finishAudio(folder, keep: options.keepAudio)
            status.state = notesError == nil ? .done : .needsAttention
            status.lastError = notesError.map { "Notes failed: \($0.localizedDescription)" }
        } catch {
            status.state = .needsAttention
            status.lastError = error.localizedDescription
        }
        try folder.writeStatus(status)
        return status
    }

    /// Clears all checkpoints so the next run starts over (e.g. with a different backend); the Meeting file is kept.
    public static func prepareReprocess(_ folder: MeetingFolder) throws {
        for name in roles + ["transcript", "notes"] {
            try? FileManager.default.removeItem(at: folder.checkpointURL(name))
        }
        try folder.updateStatus {
            $0.completedSteps = []
            $0.state = .processing
        }
    }

    /// Clears the Notes so the next run writes them again (`oats notes`, or after changing the Notes backend).
    public static func prepareNotes(_ folder: MeetingFolder) throws {
        try? FileManager.default.removeItem(at: folder.checkpointURL("notes"))
        try folder.updateStatus { $0.completedSteps.removeAll { $0 == .notes } }
    }

    public static let defaultNotesStep = NotesWriter.step()

    static func writeMeetingFile(_ folder: MeetingFolder, _ status: inout MeetingStatus, turns: [Turn], options: ProcessingOptions) throws {
        let notes = folder.readCheckpoint("notes", as: Notes.self)
        let content = MeetingFileWriter.Content(
            meetingID: folder.id, title: notes?.title, startedAt: status.startedAt,
            duration: status.duration ?? status.endedAt.map { $0.timeIntervalSince(status.startedAt) } ?? 60,
            language: status.language, engine: status.transcriptionBackend, interrupted: status.interrupted,
            notes: notes?.markdown, turns: notes?.turns ?? turns
        )
        let data = Data(MeetingFileWriter.markdown(content).utf8)
        let fm = FileManager.default
        // Replace the previous Meeting file only if the user hasn't edited it since we wrote it.
        if let previous = status.meetingFile.map(URL.init(fileURLWithPath:)), let old = try? Data(contentsOf: previous),
           MeetingFileWriter.hash(old) == status.meetingFileHash {
            try fm.removeItem(at: previous)
        }
        try fm.createDirectory(at: options.notesFolder, withIntermediateDirectories: true)
        let base = MeetingFileWriter.baseName(title: notes?.title, startedAt: status.startedAt)
        let url = MeetingFileWriter.freeURL(base: base, in: options.notesFolder)
        try data.write(to: url, options: .atomic)
        status.meetingFile = url.path
        status.meetingFileHash = MeetingFileWriter.hash(data)
        try folder.writeStatus(status)
    }

    /// Compresses every track to `<role>.m4a` (or deletes them). Only called once the Meeting file exists.
    static func finishAudio(_ folder: MeetingFolder, keep: Bool) throws {
        for role in roles {
            for file in folder.trackFiles(role) where !keep || file.pathExtension != "m4a" {
                if keep { try TrackAudio.compress(file, to: folder.url.appendingPathComponent("\(role).m4a")) }
                try FileManager.default.removeItem(at: file)
            }
        }
    }
}
