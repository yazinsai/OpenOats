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

/// Step 3: Vocabulary correction and Notes from the merged Transcript (`NotesWriter.step`, or a fake in tests).
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

extension MeetingFolder {
    /// A single mixed-track import rather than a Mic track and System track.
    var isMixed: Bool { !trackFiles(.mixed).isEmpty || FileManager.default.fileExists(atPath: checkpointURL(Track.mixed.rawValue).path) }
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

/// The Processing pipeline: Meeting folder in, Meeting file out. Used by `ProcessingQueue` and the CLI.
public enum Processing {
    /// Runs the steps not yet checkpointed and returns the final status (`done` or `needsAttention`). Holds the
    /// Meeting's lock throughout and changes only the status fields it owns, so a Rename meanwhile is kept.
    /// Throws `MeetingError.busy` if someone else holds the Meeting, or if `meeting.json` can't be read or written
    /// (e.g. the Meeting was deleted).
    @discardableResult
    public static func run(_ folder: MeetingFolder, options: ProcessingOptions) async throws -> MeetingStatus {
        let lock = try folder.lock()
        defer { withExtendedLifetime(lock) {} }
        var status = try folder.updateStatus {
            $0.state = .processing
            $0.lastError = nil
        }
        var notesError: Error?
        do {
            if !status.completedSteps.contains(.transcribe) {
                let durations = Track.allCases.flatMap(folder.trackFiles).map(TrackAudio.duration)
                guard !durations.isEmpty else { throw ProcessingError.noTracks }
                do {
                    for track in Track.allCases where folder.readCheckpoint(track.rawValue, as: [TimedSegment].self) == nil {
                        guard let audio = folder.trackFiles(track).first else { continue }
                        let segments = try await options.transcription.transcribe(audio, language: status.language)
                        try folder.writeCheckpoint(track.rawValue, segments)
                    }
                } catch {
                    await options.transcription.unload()
                    throw error
                }
                await options.transcription.unload()
                status = try folder.updateStatus {
                    $0.duration = durations.max()
                    $0.transcriptionBackend = options.transcription.name
                    $0.completedSteps.append(.transcribe)
                }
            }
            if !status.completedSteps.contains(.merge) {
                let segments = { (track: Track) in folder.readCheckpoint(track.rawValue, as: [TimedSegment].self) ?? [] }
                let turns = folder.isMixed
                    ? TranscriptMerge.mixed(segments(.mixed), separatesSpeakers: options.transcription.separatesSpeakers)
                    : TranscriptMerge.merge(mic: segments(.mic), system: segments(.system))
                try folder.writeCheckpoint("transcript", turns)
                status = try folder.updateStatus { $0.completedSteps.append(.merge) }
            }
            let turns = folder.readCheckpoint("transcript", as: [Turn].self) ?? []
            if !status.completedSteps.contains(.notes) {
                var name: String?
                if let backend = options.notes {
                    do {
                        try folder.writeCheckpoint("notes", try await options.notesStep(turns, backend))
                        name = backend.name
                    } catch {
                        notesError = error
                    }
                }
                if notesError == nil {
                    status = try folder.updateStatus {
                        if let name { $0.notesBackend = name }
                        $0.completedSteps.append(.notes)
                    }
                }
            }
            try writeMeetingFile(folder, turns: turns, options: options)
            try finishAudio(folder, keep: options.keepAudio)
        } catch {
            return try folder.updateStatus {
                $0.state = .needsAttention
                $0.lastError = error.localizedDescription
            }
        }
        return try folder.updateStatus {
            $0.state = notesError == nil ? .done : .needsAttention
            $0.lastError = notesError.map { "Needs attention: the Notes weren't written. \($0.localizedDescription)" }
        }
    }

    /// Clears all checkpoints so the next run starts over (e.g. with a different backend); the Meeting file is kept.
    public static func prepareReprocess(_ folder: MeetingFolder) throws {
        for name in Track.allCases.map(\.rawValue) + ["transcript", "notes"] {
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

    /// Writes the Meeting file into the notes folder, replacing the previous one only if the user hasn't edited it
    /// since; an edited one gets a `-2` (`-3`, …) sibling next to it instead.
    static func writeMeetingFile(_ folder: MeetingFolder, turns: [Turn], options: ProcessingOptions) throws {
        let status = try folder.readStatus()
        let notes = folder.readCheckpoint("notes", as: Notes.self)
        let title = status.title ?? notes?.title
        let content = MeetingFileWriter.Content(
            meetingID: folder.id, title: title, startedAt: status.startedAt, duration: status.length ?? 60,
            language: status.language, engine: status.transcriptionBackend, interrupted: status.interrupted,
            notes: notes?.markdown, turns: notes?.turns ?? turns, defaultSpeaker: folder.isMixed ? "Speaker" : "You"
        )
        let data = Data(MeetingFileWriter.markdown(content).utf8)
        let fm = FileManager.default
        var url: URL
        if let previous = status.meetingFile.map(URL.init(fileURLWithPath:)), let old = try? Data(contentsOf: previous),
           MeetingFileWriter.hash(old) != status.meetingFileHash {
            url = MeetingFileWriter.siblingURL(of: previous)
        } else {
            if let previous = status.meetingFile, fm.fileExists(atPath: previous) { try fm.removeItem(atPath: previous) }
            try fm.createDirectory(at: options.notesFolder, withIntermediateDirectories: true)
            url = MeetingFileWriter.freeURL(base: MeetingFileWriter.baseName(title: title, startedAt: status.startedAt), in: options.notesFolder)
        }
        try data.write(to: url, options: .atomic)
        do {
            try folder.updateStatus {
                $0.meetingFile = url.path
                $0.meetingFileHash = MeetingFileWriter.hash(data)
            }
        } catch {
            try? fm.removeItem(at: url) // the Meeting is gone (deleted meanwhile): leave no orphan Meeting file
            throw error
        }
    }

    /// Compresses every track to `<role>.m4a` (or deletes them). Only called once the Meeting file exists.
    static func finishAudio(_ folder: MeetingFolder, keep: Bool) throws {
        for track in Track.allCases {
            for file in folder.trackFiles(track) where !keep || file.pathExtension != "m4a" {
                if keep { try TrackAudio.compress(file, to: folder.url.appendingPathComponent("\(track.rawValue).m4a")) }
                try FileManager.default.removeItem(at: file)
            }
        }
    }
}
