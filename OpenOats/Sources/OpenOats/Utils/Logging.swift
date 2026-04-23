import Foundation
import os

enum Log {
    static let mic = Logger(subsystem: subsystem, category: "MicCapture")
    static let recorder = Logger(subsystem: subsystem, category: "AudioRecorder")
    static let transcription = Logger(subsystem: subsystem, category: "TranscriptionEngine")
    static let streaming = Logger(subsystem: subsystem, category: "StreamingTranscriber")
    static let transcript = Logger(subsystem: subsystem, category: "TranscriptStore")
    static let echo = Logger(subsystem: subsystem, category: "AcousticEchoFilter")
    static let batchTranscription = Logger(subsystem: subsystem, category: "BatchTranscription")
    static let batchTextCleaner = Logger(subsystem: subsystem, category: "BatchTextCleaner")
    static let diarization = Logger(subsystem: subsystem, category: "Diarization")
    static let granolaImporter = Logger(subsystem: subsystem, category: "GranolaImporter")
    static let markdownMeetingWriter = Logger(subsystem: subsystem, category: "MarkdownMeetingWriter")
    static let meetingDetection = Logger(subsystem: subsystem, category: "MeetingDetection")
    static let sessionRepository = Logger(subsystem: subsystem, category: "SessionRepository")
    static let appleNotes = Logger(subsystem: subsystem, category: "AppleNotes")
    static let webhook = Logger(subsystem: subsystem, category: "Webhook")
    static let whisperkit = Logger(subsystem: subsystem, category: "WhisperKitManager")
    static let knowledgeBase = Logger(subsystem: subsystem, category: "KnowledgeBase")
    static let suggestionEngine = Logger(subsystem: subsystem, category: "SuggestionEngine")
    static let sidecast = Logger(subsystem: subsystem, category: "SidecastEngine")
    static let templateStore = Logger(subsystem: subsystem, category: "TemplateStore")
    static let diagnostics = Logger(subsystem: subsystem, category: "Diagnostics")

    private static let subsystem = Bundle(for: BundleToken.self).bundleIdentifier ?? "com.openoats.app"
}

private final class BundleToken {}
