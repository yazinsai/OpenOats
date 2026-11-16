import OatsCore
import SwiftUI

/// Settings: General, AI, Advanced.
struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView {
            GeneralTab(model: model).tabItem { Label("General", systemImage: "gearshape") }
            AITab(model: model).tabItem { Label("AI", systemImage: "sparkles") }
            AdvancedTab(model: model).tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .accessibilityIdentifier("settings.tabView")
        .frame(width: 540, height: 480)
    }
}

struct GeneralTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            LabeledContent("Notes folder") {
                HStack {
                    Text(model.settings.notesFolder.path(percentEncoded: false)).lineLimit(1).truncationMode(.middle)
                    Button("Choose…", action: model.chooseNotesFolder)
                }
            }
            Picker("Language", selection: model.language) {
                Text("System (\(SettingsModel.languageName(OatsCore.Settings().meetingLanguage)))").tag("")
                ForEach(model.languages, id: \.self) { Text(SettingsModel.languageName($0)).tag($0) }
            }
            LabeledContent("Hotkey") {
                HStack {
                    Text(model.recordingHotkey ? "Press a shortcut…" : model.hotkey?.label ?? "Off").foregroundStyle(.secondary)
                    Button(model.recordingHotkey ? "Cancel" : "Change…") {
                        model.recordingHotkey ? model.endHotkeyRecording() : model.recordHotkey()
                    }
                    if model.hotkey != nil, !model.recordingHotkey { Button("Turn Off") { model.hotkey = nil } }
                }
            }
            Section {
                TextEditor(text: $model.vocabulary).font(.body).frame(height: 110)
            } header: { Text("Vocabulary") } footer: {
                Text("Names and terms, one per line. They fix misheard words in the Transcript when a Notes backend is set.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct AITab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            BackendSection(
                title: "Notes backend", offName: "None", presets: Preset<NotesBackendType>.all,
                footer: "None: the Meeting file has the Transcript only. A cloud Preset sends the Transcript to its server.",
                choice: model.choice(\.notes, presets: Preset<NotesBackendType>.all, off: .none, custom: .openAICompatible),
                config: $model.settings.notes, key: model.apiKey(\.notes), status: model.notesTest, test: model.testNotes
            )
            .accessibilityIdentifier("settings.notesBackend")
            BackendSection(
                title: "Transcription backend", offName: "On-device", presets: Preset<TranscriptionBackendType>.all,
                footer: "On-device: audio never leaves this Mac. A cloud Preset uploads the audio to its server.",
                choice: model.choice(\.transcription, presets: Preset<TranscriptionBackendType>.all, off: .onDevice, custom: .openAIStyle),
                config: $model.settings.transcription, key: model.apiKey(\.transcription), status: model.transcriptionTest,
                test: model.testTranscription
            )
            .accessibilityIdentifier("settings.transcriptionBackend")
        }
        .formStyle(.grouped)
    }
}

/// One backend slot: off, a Preset (address and model prefilled as placeholders), or a custom server.
struct BackendSection<Kind: Codable & Sendable & Hashable>: View {
    let title: String, offName: String, presets: [Preset<Kind>], footer: String
    @Binding var choice: String
    @Binding var config: BackendConfig<Kind>
    @Binding var key: String
    let status: String?
    let test: () -> Void

    var body: some View {
        Section {
            Picker("Backend", selection: $choice) {
                Text(offName).tag("")
                ForEach(presets, id: \.name) { Text($0.name).tag($0.name) }
                Text("Custom server").tag("custom")
            }
            if !choice.isEmpty {
                let preset = presets.first { $0.name == choice }
                TextField("Address", text: $config.address.orEmpty, prompt: Text(preset?.address ?? "http://localhost:8000/v1"))
                TextField("Model", text: $config.model.orEmpty, prompt: Text(preset?.model ?? "Server default"))
                if preset?.needsKey ?? true { KeyField(key: $key) }
                HStack {
                    Button("Test", action: test)
                    if let status { Text(status).foregroundStyle(.secondary).lineLimit(2) }
                }
            }
        } header: { Text(title) } footer: { Text(footer).foregroundStyle(.secondary) }
    }
}

/// The API key, saved on Return, on leaving the field or after a pause in typing, not per keystroke.
struct KeyField: View {
    @Binding var key: String
    @State private var draft: String?
    @FocusState private var focused: Bool

    var body: some View {
        SecureField("API key", text: Binding { draft ?? key } set: { draft = $0 })
            .focused($focused)
            .onSubmit(save)
            .onChange(of: focused) { if !focused { save() } }
            .task(id: draft) {
                guard draft != nil, (try? await Task.sleep(for: .milliseconds(600))) != nil else { return }
                save()
            }
            .onDisappear(perform: save)
    }

    private func save() {
        if let draft, draft != key { key = draft }
        draft = nil
    }
}

struct AdvancedTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Notes prompt") {
                TextEditor(text: model.notesPrompt).font(.body.monospaced()).frame(minHeight: 240)
                Button("Reset to Default") { model.settings.notesPrompt = nil }.disabled(model.settings.notesPrompt == nil)
            }
            Toggle("Delete audio after Processing", isOn: $model.settings.deleteAudioAfterProcessing)
        }
        .formStyle(.grouped)
    }
}
