import Foundation

/// The status document `meeting.json` in every Meeting folder.
public struct MeetingStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case recording, processing, needsAttention = "needs-attention", done }
    public enum Step: String, Codable, Sendable { case transcribe, merge, notes }

    public var state: State
    public var startedAt: Date
    public var endedAt: Date?
    /// True for an Interrupted meeting (recording ended without Stop).
    public var interrupted = false
    public var language: String?
    /// Length of the longest track in seconds, set by Processing.
    public var duration: TimeInterval?
    public var completedSteps: [Step] = []
    public var transcriptionBackend: String?
    public var notesBackend: String?
    public var lastError: String?
    /// The Meeting file last written and the SHA-256 of what was written, for the re-process rule.
    public var meetingFile: String?
    public var meetingFileHash: String?
    /// Set by Rename; wins over the Notes title when the Meeting file is written again.
    public var title: String?

    public init(state: State, startedAt: Date, language: String? = nil) {
        self.state = state
        self.startedAt = startedAt
        self.language = language
    }

    /// The Meeting's length: the longest track once processed, else the time from start to end.
    public var length: TimeInterval? { duration ?? endedAt.map { $0.timeIntervalSince(startedAt) } }
}

public enum MeetingError: LocalizedError {
    case busy

    public var errorDescription: String? { "This Meeting is being recorded or processed by another OpenOats." }
}

/// An exclusive `flock` on a Meeting folder, held by whoever records or processes it. The system drops it when the
/// holder exits, even on a crash, so a recovered Meeting is never held by a dead process.
public final class MeetingLock: Sendable {
    private let fd: Int32

    init?(_ url: URL) {
        fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
    }

    deinit { close(fd) }
}

/// One Meeting's working folder: tracks, `meeting.json` and checkpoints.
public struct MeetingFolder: Sendable, Hashable {
    public static let micTrackName = "mic.pcm"
    public static let systemTrackName = "system.pcm"

    public let url: URL
    public var id: String { url.lastPathComponent }
    public var statusURL: URL { url.appendingPathComponent("meeting.json") }
    /// Raw 16 kHz mono Int16 PCM written by the Recorder.
    public var micTrackURL: URL { url.appendingPathComponent(Self.micTrackName) }
    public var systemTrackURL: URL { url.appendingPathComponent(Self.systemTrackName) }

    public init(url: URL) { self.url = url }

    public func readStatus() throws -> MeetingStatus {
        try JSONDecoder.oats.decode(MeetingStatus.self, from: Data(contentsOf: statusURL))
    }

    public func writeStatus(_ status: MeetingStatus) throws {
        try JSONEncoder.oats.encode(status).write(to: statusURL, options: .atomic)
    }

    @discardableResult
    public func updateStatus(_ change: (inout MeetingStatus) -> Void) throws -> MeetingStatus {
        var status = try readStatus()
        change(&status)
        try writeStatus(status)
        return status
    }

    /// Takes the Meeting's lock, or throws `MeetingError.busy` if another recorder or Processing holds it.
    public func lock() throws -> MeetingLock {
        guard let lock = MeetingLock(url) else {
            throw FileManager.default.fileExists(atPath: url.path) ? MeetingError.busy : CocoaError(.fileNoSuchFile)
        }
        return lock
    }

    /// True while another recorder or Processing holds the Meeting.
    public var isBusy: Bool { FileManager.default.fileExists(atPath: url.path) && MeetingLock(url) == nil }

    /// Audio files of a track, whatever the extension.
    func trackFiles(_ track: Track) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.deletingPathExtension().lastPathComponent == track.rawValue && $0.pathExtension != "json" }
            .sorted { ($0.pathExtension == "pcm" ? 0 : 1) < ($1.pathExtension == "pcm" ? 0 : 1) }
    }

    func checkpointURL(_ name: String) -> URL { url.appendingPathComponent("\(name).json") }

    func readCheckpoint<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: checkpointURL(name)) else { return nil }
        return try? JSONDecoder.oats.decode(T.self, from: data)
    }

    func writeCheckpoint<T: Encodable>(_ name: String, _ value: T) throws {
        try JSONEncoder.oats.encode(value).write(to: checkpointURL(name), options: .atomic)
    }
}

/// Lists, creates and imports Meetings under one root folder.
public struct MeetingStore: Sendable {
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenOats/Meetings", isDirectory: true)
    }

    public let root: URL

    public init(root: URL = MeetingStore.defaultRoot) { self.root = root }

    /// A new, empty Meeting folder in state `recording` (the Recorder then writes `mic.pcm` / `system.pcm`).
    public func create(startedAt: Date = Date(), language: String? = nil) throws -> MeetingFolder {
        let stamp = Self.idFormatter.string(from: startedAt)
        let folder = MeetingFolder(url: root.appendingPathComponent("\(stamp)-\(UUID().uuidString.prefix(4).lowercased())"))
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        try folder.writeStatus(MeetingStatus(state: .recording, startedAt: startedAt, language: language))
        return folder
    }

    /// Imports audio as a Meeting in state `processing`: one file is a single mixed track, two are Mic track then System track.
    public func importAudio(_ files: [URL], startedAt: Date? = nil, language: String? = nil) throws -> MeetingFolder {
        let tracks: [Track]
        switch files.count {
        case 1: tracks = [.mixed]
        case 2: tracks = [.mic, .system]
        default: throw ProcessingError.noTracks
        }
        let start = startedAt ?? ((try? files[0].resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date())
        let folder = try create(startedAt: start, language: language)
        for (file, track) in zip(files, tracks) {
            let ext = file.pathExtension.isEmpty ? "audio" : file.pathExtension.lowercased()
            try FileManager.default.copyItem(at: file, to: folder.url.appendingPathComponent("\(track.rawValue).\(ext)"))
        }
        try folder.updateStatus { $0.state = .processing }
        return folder
    }

    /// All Meeting folders, oldest first.
    public func list() -> [MeetingFolder] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return urls.map(MeetingFolder.init)
            .filter { FileManager.default.fileExists(atPath: $0.statusURL.path) }
            .sorted { $0.id < $1.id }
    }

    public func folder(id: String) -> MeetingFolder? {
        let folder = MeetingFolder(url: root.appendingPathComponent(id))
        return FileManager.default.fileExists(atPath: folder.statusURL.path) ? folder : nil
    }

    private static var idFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }
}

extension JSONEncoder {
    static var oats: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var oats: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
