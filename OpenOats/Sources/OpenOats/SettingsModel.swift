import AppKit
import AVFoundation
import OatsCapture
import OatsCore
import SwiftUI

/// What Settings and onboarding bind to, one instance for both windows. Every change is saved at once; API keys go
/// to the Keychain.
@MainActor
final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()
    let store = AppModel.shared.settings
    @Published var settings: OatsCore.Settings {
        didSet {
            guard settings != oldValue else { return }
            store.save(settings)
            if settings.notes != oldValue.notes { notesTest = nil }
            if settings.transcription != oldValue.transcription { transcriptionTest = nil }
            if settings.askToRecordCalls != oldValue.askToRecordCalls { AppModel.shared.watchCalls() }
        }
    }
    @Published var hotkey = Hotkey.saved { didSet { Hotkey.saved = hotkey } }
    @Published private(set) var recordingHotkey = false
    @Published var vocabulary: String { didSet { settings.vocabulary = vocabulary.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } }
    @Published private(set) var notesTest: String?
    @Published private(set) var transcriptionTest: String?
    @Published private(set) var mic = AVCaptureDevice.authorizationStatus(for: .audio)
    /// nil until asked; then "" (asked) or the reason capture couldn't start.
    @Published private(set) var systemAudio: String?
    @Published private(set) var calendarAllowed = CalendarTitles.allowed
    @Published private(set) var calendarDenied = CalendarTitles.denied
    private var monitor: Any?

    /// Parakeet's languages plus common Whisper ones; "" = the system language.
    let languages = ["ar", "bg", "cs", "da", "de", "el", "en", "es", "et", "fa", "fi", "fr", "he", "hi", "hr", "hu", "id", "it", "ja",
                     "ko", "lt", "lv", "ms", "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "th", "tr", "uk", "ur", "vi", "zh"]
        .sorted { SettingsModel.languageName($0) < SettingsModel.languageName($1) }

    private init() {
        let settings = store.load()
        self.settings = settings
        vocabulary = settings.vocabulary.joined(separator: "\n")
    }

    static func languageName(_ code: String) -> String { Locale.current.localizedString(forLanguageCode: code) ?? code }

    var language: Binding<String> {
        Binding { self.settings.language ?? "" } set: { self.settings.language = $0.isEmpty ? nil : $0 }
    }

    var notesPrompt: Binding<String> {
        Binding { self.settings.notesPrompt ?? NotesWriter.defaultPrompt }
            set: { self.settings.notesPrompt = $0 == NotesWriter.defaultPrompt ? nil : $0 }
    }

    /// The backend picker: "" = off (None / On-device), "custom" = an address of your own, else a Preset name.
    func choice<K>(_ path: WritableKeyPath<OatsCore.Settings, BackendConfig<K>>, presets: [Preset<K>], off: K, custom: K) -> Binding<String> {
        Binding {
            let config = self.settings[keyPath: path]
            return config.preset ?? (config.type == off ? "" : "custom")
        } set: { name in
            self.settings[keyPath: path] = presets.first { $0.name == name }.map { BackendConfig(type: $0.type, preset: $0.name) }
                ?? BackendConfig(type: name == "custom" ? custom : off)
        }
    }

    func apiKey<K>(_ path: KeyPath<OatsCore.Settings, BackendConfig<K>>) -> Binding<String> {
        Binding { self.store.apiKey(for: self.settings[keyPath: path]) ?? "" } set: {
            self.objectWillChange.send()
            self.store.setAPIKey($0, for: self.settings[keyPath: path])
        }
    }

    func testNotes() {
        notesTest = "Testing…"
        let backend = store.notesBackend(settings.notes)
        Task { notesTest = await Self.outcome { try await backend?.test() } }
    }

    /// Sends 1 s of the test tone; any reply (even no text) proves the address, key and model.
    func testTranscription() {
        transcriptionTest = "Testing…"
        let backend = store.transcriptionBackend(settings.transcription), language = settings.meetingLanguage
        Task {
            transcriptionTest = await Self.outcome {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("oats-test-\(UUID().uuidString).pcm")
                defer { try? FileManager.default.removeItem(at: url) }
                try ToneSource.tone(440, 0..<Int(TrackAudio.sampleRate)).withUnsafeBytes { try Data($0).write(to: url) }
                _ = try await backend.transcribe(url, language: language)
            }
        }
    }

    private static func outcome(_ work: () async throws -> Void) async -> String {
        do {
            try await work()
            return "Works."
        } catch { return error.localizedDescription }
    }

    func chooseNotesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.notesFolder
        if panel.runModal() == .OK, let url = panel.url { settings.notesFolder = url }
    }

    /// The next ⌃/⌥/⌘ shortcut becomes the hotkey; Esc cancels. The old one is off meanwhile so it can be pressed again.
    func recordHotkey() {
        recordingHotkey = true
        HotkeyMonitor.register(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let key = Hotkey(event), cancel = event.keyCode == 53
            MainActor.assumeIsolated {
                if let key { self?.hotkey = key }
                if key != nil || cancel { self?.endHotkeyRecording() }
            }
            return nil
        }
    }

    func endHotkeyRecording() {
        monitor.map(NSEvent.removeMonitor)
        monitor = nil
        recordingHotkey = false
        HotkeyMonitor.register(hotkey)
    }

    /// The "Name Meetings after calendar events" switch. Turning it on asks for calendar access the first time and
    /// stays on only once access is granted; a declined prompt saves "off", so nothing asks again.
    var calendarTitles: Binding<Bool> {
        Binding { self.settings.titleFromCalendar == true } set: { self.setCalendarTitles($0) }
    }

    func setCalendarTitles(_ on: Bool) {
        guard on else { return settings.titleFromCalendar = false }
        Task {
            settings.titleFromCalendar = await CalendarTitles.requestAccess()
            refreshCalendarAccess()
        }
    }

    /// Calendar access can change in System Settings at any time; re-read it whenever a view shows it.
    func refreshCalendarAccess() {
        calendarAllowed = CalendarTitles.allowed
        calendarDenied = CalendarTitles.denied
    }

    func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            Task { @MainActor in self.mic = AVCaptureDevice.authorizationStatus(for: .audio) }
        }
    }

    /// No preflight API: a short capture makes macOS ask. `stop()` waits while the prompt is up, so off the main thread.
    func requestSystemAudio() {
        systemAudio = nil
        Task.detached {
            let source = LiveCapture { _ in }
            var problem = ""
            do { try source.start { _ in } } catch { problem = error.localizedDescription }
            try? await Task.sleep(for: .seconds(1))
            source.stop()
            await MainActor.run { self.systemAudio = problem }
        }
    }
}

extension Binding where Value == String? {
    /// "" ↔ nil, for optional text fields.
    var orEmpty: Binding<String> {
        Binding<String> { wrappedValue ?? "" } set: { wrappedValue = $0.isEmpty ? nil : $0 }
    }
}
