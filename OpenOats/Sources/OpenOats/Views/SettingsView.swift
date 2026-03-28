import SwiftUI
import CoreAudio
import LaunchAtLogin
import Sparkle

struct SettingsView: View {
    private enum TemplateField: Hashable {
        case name
    }

    @Bindable var settings: AppSettings
    var updater: SPUUpdater
    @Environment(AppCoordinator.self) private var coordinator
    @State private var inputDevices: [(id: AudioDeviceID, name: String)] = []
    @State private var automaticallyChecksForUpdates = false
    @State private var templates: [MeetingTemplate] = []
    @State private var isAddingTemplate = false
    @State private var newTemplateName = ""
    @State private var newTemplateIcon = "doc.text"
    @State private var newTemplatePrompt = ""
    @FocusState private var focusedTemplateField: TemplateField?
    @State private var showAutoDetectExplanation = false

    var body: some View {
        Form {
            Section("Meeting Notes") {
                Text(String(localized: "where_meeting_transcripts_are_saved_as_plain_text_"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text(settings.notesFolderPath)
                        .font(.footnote)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button(String(localized: "choose")) {
                        chooseNotesFolder()
                    }
.accessibilityLabel(String(localized: "choose"))
.accessibilityHint(String(localized: "choose_folder_hint"))
                }
            }

            Section("Knowledge Base") {
                Text(String(localized: "optional_point_this_to_a_folder_of_notes_docs_or_r"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text(settings.kbFolderPath.isEmpty ? "Not set" : settings.kbFolderPath)
                        .font(.footnote)
                        .foregroundStyle(settings.kbFolderPath.isEmpty ? .tertiary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    if !settings.kbFolderPath.isEmpty {
                        Button(String(localized: "clear")) {
                            settings.kbFolderPath = ""
                        }
.accessibilityLabel(String(localized: "clear"))
.accessibilityHint(String(localized: "clear_field_hint"))
                        .font(.footnote)
                    }

                    Button(String(localized: "choose")) {
                        chooseKBFolder()
                    }
.accessibilityLabel(String(localized: "choose"))
.accessibilityHint(String(localized: "choose_folder_hint"))
                }
            }

            Section("LLM Provider") {
                Picker("Provider", selection: $settings.llmProvider) {
                    ForEach(LLMProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
.accessibilityIdentifier("llm_provider_picker")
                }
                .font(.footnote)
                .accessibilityIdentifier("settings.llmProviderPicker")

                switch settings.llmProvider {
                case .openRouter:
                    SecureField("API Key", text: $settings.openRouterApiKey)
                        .font(.footnote)

                    TextField("Model", text: $settings.selectedModel, prompt: Text("e.g. google/gemini-3-flash-preview"))
                        .font(.footnote)
                case .ollama:
                    TextField("Ollama URL", text: $settings.ollamaBaseURL, prompt: Text("http://localhost:11434"))
                        .font(.footnote)

                    TextField("Model", text: $settings.ollamaLLMModel, prompt: Text("e.g. qwen3:8b"))
                        .font(.footnote)
                case .mlx:
                    TextField("MLX Server URL", text: $settings.mlxBaseURL, prompt: Text("http://localhost:8080"))
                        .font(.footnote)

                    TextField("Model", text: $settings.mlxModel, prompt: Text("e.g. mlx-community/Llama-3.2-3B-Instruct-4bit"))
                        .font(.footnote)
                case .openAICompatible:
                    TextField("Endpoint URL", text: $settings.openAILLMBaseURL, prompt: Text("http://localhost:4000"))
                        .font(.footnote)

                    SecureField("API Key (optional)", text: $settings.openAILLMApiKey)
                        .font(.footnote)

                    TextField("Model", text: $settings.openAILLMModel, prompt: Text("e.g. gpt-4o-mini"))
                        .font(.footnote)
                }
            }

            Section("Embedding Provider") {
                Picker("Provider", selection: $settings.embeddingProvider) {
                    ForEach(EmbeddingProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
.accessibilityIdentifier("llm_provider_picker")
                }
                .font(.footnote)

                switch settings.embeddingProvider {
                case .voyageAI:
                    SecureField("API Key", text: $settings.voyageApiKey)
                        .font(.footnote)
                case .ollama:
                    TextField("Embedding Model", text: $settings.ollamaEmbedModel, prompt: Text("e.g. nomic-embed-text"))
                        .font(.footnote)

                    if settings.llmProvider != .ollama && settings.llmProvider != .mlx {
                        TextField("Ollama URL", text: $settings.ollamaBaseURL, prompt: Text("http://localhost:11434"))
                            .font(.footnote)
                    }
                case .openAICompatible:
                    TextField("Endpoint URL", text: $settings.openAIEmbedBaseURL, prompt: Text("http://localhost:8080"))
                        .font(.footnote)

                    SecureField("API Key (optional)", text: $settings.openAIEmbedApiKey)
                        .font(.footnote)

                    TextField("Model", text: $settings.openAIEmbedModel, prompt: Text("e.g. text-embedding-3-small"))
                        .font(.footnote)
                }
            }

            Section("Suggestions") {
                Picker("Verbosity", selection: $settings.suggestionVerbosity) {
                    ForEach(SuggestionVerbosity.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .font(.footnote)

                Text(settings.suggestionVerbosity.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Audio Input") {
                Picker("Microphone", selection: $settings.inputDeviceID) {
                    Text(String(localized: "system_default")).tag(AudioDeviceID(0))
                    ForEach(inputDevices, id: \.id) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .font(.footnote)
                .accessibilityIdentifier("settings.microphonePicker")
            }

            Section("Recording") {
                Toggle("Save audio recording", isOn: $settings.saveAudioRecording)
.accessibilityHint(String(localized: "toggle_accessibility_hint"))
                    .font(.footnote)
                Text(String(localized: "save_a_local_audio_file_m4a_alongside_each_transcr"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Echo cancellation", isOn: $settings.enableEchoCancellation)
.accessibilityHint(String(localized: "toggle_accessibility_hint"))
                    .font(.footnote)
                Text(String(localized: "reduces_duplicate_transcription_when_using_speaker"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Transcription") {
                Picker("Model", selection: $settings.transcriptionModel) {
                    ForEach(TranscriptionModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
.accessibilityIdentifier("model_picker")
                }
                .font(.footnote)
                .accessibilityIdentifier("settings.transcriptionModelPicker")

                TextField(
                    "\(settings.transcriptionModel.localeFieldTitle) (e.g. en-US)",
                    text: $settings.transcriptionLocale
                )
                .font(.footnote)

                Text(settings.transcriptionModel.localeHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Show live transcript", isOn: $settings.showLiveTranscript)
.accessibilityHint(String(localized: "toggle_accessibility_hint"))
                    .font(.footnote)
                Text(String(localized: "when_disabled_the_transcript_panel_is_hidden_durin"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Clean up transcript during recording", isOn: $settings.enableTranscriptRefinement)
.accessibilityHint(String(localized: "toggle_accessibility_hint"))
                    .font(.footnote)
                Text(String(localized: "automatically_removes_filler_words_and_fixes_punct"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "custom_keywords"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ZStack(alignment: .topLeading) {
                        if settings.transcriptionCustomVocabulary.isEmpty {
                            Text(String(localized: "one_term_per_line_optional_aliases_openoats_open_o"))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 6)
                                .padding(.leading, 4)
                                .allowsHitTesting(false)
                        }

                        TextEditor(text: $settings.transcriptionCustomVocabulary)
                            .font(.caption)
                            .frame(height: 90)
                            .frame(maxWidth: .infinity)
                            .scrollContentBackground(.hidden)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(.quaternary)
                    )

                    Text(
                        "Optional. Boost meeting-specific jargon, names, and product terms for Parakeet TDT v2/v3. Enter one term per line, or use `Preferred Term: alias one, alias two`."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Batch Refinement") {
                Toggle("Enhance transcript after meeting", isOn: $settings.enableBatchRefinement)
.accessibilityHint(String(localized: "toggle_accessibility_hint"))
                    .font(.footnote)
                Text(String(localized: "retranscribes_audio_with_a_higherquality_model_aft"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.enableBatchRefinement {
                    Picker("Batch Model", selection: $settings.batchTranscriptionModel) {
                        ForEach(TranscriptionModel.batchSuitableModels) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .font(.footnote)
                }
            }

            Section("Speaker Diarization") {
                Toggle("Identify multiple remote speakers", isOn: $settings.enableDiarization)
.accessibilityHint(String(localized: "toggle_accessibility_hint"))
                    .font(.footnote)
                Text(String(localized: "uses_lseend_to_distinguish_different_speakers_on_s"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.enableDiarization {
                    Picker("Variant", selection: $settings.diarizationVariant) {
                        ForEach(DiarizationVariant.allCases) { variant in
                            Text(variant.displayName).tag(variant)
                        }
                    }
                    .font(.footnote)
                }
            }

            Section("Privacy") {
                Toggle("Hide from screen sharing", isOn: $settings.hideFromScreenShare)
.accessibilityHint(String(localized: "toggle_accessibility_hint"))
                    .font(.footnote)
                Text(String(localized: "when_enabled_the_app_is_invisible_during_screen_sh"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Meeting Detection") {
                Toggle("Auto-detect meetings", isOn: $settings.meetingAutoDetectEnabled)
.accessibilityHint(String(localized: "toggle_accessibility_hint"))
                    .font(.footnote)
                    .onChange(of: settings.meetingAutoDetectEnabled) {
                        if settings.meetingAutoDetectEnabled && !settings.hasShownAutoDetectExplanation {
                            settings.meetingAutoDetectEnabled = false
                            showAutoDetectExplanation = true
                        }
                    }

                Text(String(localized: "when_enabled_openoats_monitors_microphone_activati"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LaunchAtLogin.Toggle("Launch at login")
.accessibilityHint(String(localized: "toggle_accessibility_hint"))
                    .font(.footnote)
            }
            .sheet(isPresented: $showAutoDetectExplanation) {
                VStack(spacing: 16) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.title)
                        .foregroundStyle(.tint)

                    Text(String(localized: "how_meeting_detection_works"))
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 10) {
                        Label(String(localized: "openoats_watches_for_microphone_activation_by_meet"), systemImage: "mic")
                        Label(String(localized: "only_activation_status_is_checked_no_audio_is_capt"), systemImage: "lock.shield")
                        Label(String(localized: "when_a_meeting_is_detected_you_get_a_macos_notific"), systemImage: "bell")
                        Label("You can always dismiss the notification or mark it as \"not a meeting\".", systemImage: "hand.raised")
                    }
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack {
                        Button(String(localized: "cancel")) {
                            showAutoDetectExplanation = false
                        }
.accessibilityLabel(String(localized: "cancel"))
.accessibilityHint(String(localized: "cancel_action_hint"))
                        .keyboardShortcut(.cancelAction)

                        Button(String(localized: "enable_detection")) {
                            settings.hasShownAutoDetectExplanation = true
                            settings.meetingAutoDetectEnabled = true
                            showAutoDetectExplanation = false
                        }
.accessibilityLabel(String(localized: "enable_detection"))
.accessibilityHint(String(localized: "enable_detection_hint"))
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(24)
                .frame(width: 400)
            }

            if settings.meetingAutoDetectEnabled {
                DisclosureGroup("Advanced Detection Settings") {
                    HStack {
                        Text(String(localized: "silence_timeout"))
                            .font(.footnote)
                        Spacer()
                        TextField("", value: $settings.silenceTimeoutMinutes, format: .number)
                            .font(.footnote)
                            .frame(width: 50)
                            .multilineTextAlignment(.trailing)
                        Text(String(localized: "min"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text(String(localized: "autodetected_sessions_stop_after_this_many_minutes"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Detection log", isOn: $settings.detectionLogEnabled)
.accessibilityHint(String(localized: "toggle_accessibility_hint"))
                        .font(.footnote)
                    Text(String(localized: "print_detection_events_to_the_system_console_for_d"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .font(.footnote)
            }

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $automaticallyChecksForUpdates)
.accessibilityHint(String(localized: "toggle_accessibility_hint"))
                .font(.footnote)
                .onChange(of: automaticallyChecksForUpdates) { _, newValue in
                    syncAutomaticUpdateChecks(to: newValue)
                }
            }

            Section("Meeting Templates") {
                ForEach(templates) { template in
                    HStack {
                        Image(systemName: template.icon)
                            .frame(width: 20)
                            .foregroundStyle(.secondary)
                        Text(template.name)
                            .font(.footnote)
                        Spacer()
                        if template.isBuiltIn {
                            Image(systemName: "lock")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Button(String(localized: "reset")) {
                                resetTemplate(id: template.id)
                            }
.accessibilityLabel(String(localized: "reset"))
                            .font(.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                        } else {
                            Button {
                                deleteTemplate(id: template.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption)
                                    .foregroundStyle(.red)
.accessibilityAddTraits(.updatesFrequently)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if isAddingTemplate {
                    VStack(alignment: .leading, spacing: 10) {
                        // Name
                        VStack(alignment: .leading, spacing: 3) {
                            Text(String(localized: "name"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("e.g. Sprint Planning", text: $newTemplateName)
.accessibilityLabel(String(localized: "textfield_e.g._sprint_planning_label"))
                                .font(.footnote)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                                .focused($focusedTemplateField, equals: .name)
                        }

                        // Icon picker
                        VStack(alignment: .leading, spacing: 3) {
                            Text(String(localized: "icon"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            IconPickerGrid(selected: $newTemplateIcon)
                        }

                        // System prompt
                        VStack(alignment: .leading, spacing: 3) {
                            Text(String(localized: "notes_prompt"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(localized: "instructions_for_how_the_ai_should_format_notes_fo"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            ZStack(alignment: .topLeading) {
                                if newTemplatePrompt.isEmpty {
                                    Text("e.g. You are a meeting notes assistant. Given a transcript, produce structured notes with sections for...")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .padding(.top, 6)
                                        .padding(.leading, 4)
                                        .allowsHitTesting(false)
                                }
                                TextEditor(text: $newTemplatePrompt)
                                    .font(.caption)
                                    .frame(height: 100)
                                    .frame(maxWidth: .infinity)
                                    .scrollContentBackground(.hidden)
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(.quaternary)
                            )
                        }

                        HStack {
                            Button(String(localized: "cancel")) {
                                resetNewTemplateForm()
                            }
.accessibilityLabel(String(localized: "cancel"))
.accessibilityHint(String(localized: "cancel_action_hint"))
                            .buttonStyle(.plain)
                            Button(String(localized: "save")) {
                                let template = MeetingTemplate(
                                    id: UUID(),
                                    name: trimmedTemplateName,
                                    icon: newTemplateIcon,
                                    systemPrompt: trimmedTemplatePrompt,
                                    isBuiltIn: false
                                )
                                addTemplate(template)
                                resetNewTemplateForm()
                            }
.accessibilityLabel(String(localized: "save"))
.accessibilityHint(String(localized: "save_changes_hint"))
                            .buttonStyle(.borderedProminent)
                            .disabled(!canSaveNewTemplate)
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    Button(String(localized: "new_template")) {
                        isAddingTemplate = true
                        Task { @MainActor in
                            focusedTemplateField = .name
                        }
.accessibilityLabel(String(localized: "new_template"))
                    }
                    .font(.footnote)
                }
            }
        }
        .accessibilityIdentifier("settings.form")
        .formStyle(.grouped)
        .frame(width: 450, height: 750)
        .onAppear {
            refreshViewState()
        }
    }

    private func refreshViewState() {
        inputDevices = MicCapture.availableInputDevices()
        Task { @MainActor in
            automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
            templates = coordinator.templateStore.templates
        }
    }

    private func syncAutomaticUpdateChecks(to newValue: Bool) {
        Task { @MainActor in
            updater.automaticallyChecksForUpdates = newValue
        }
    }

    private func addTemplate(_ template: MeetingTemplate) {
        Task { @MainActor in
            coordinator.templateStore.add(template)
            templates = coordinator.templateStore.templates
        }
    }

    private func resetTemplate(id: UUID) {
        Task { @MainActor in
            coordinator.templateStore.resetBuiltIn(id: id)
            templates = coordinator.templateStore.templates
        }
    }

    private func deleteTemplate(id: UUID) {
        Task { @MainActor in
            coordinator.templateStore.delete(id: id)
            templates = coordinator.templateStore.templates
        }
    }

    private func chooseKBFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "choose_a_folder_containing_your_knowledge_base_doc")

        if panel.runModal() == .OK, let url = panel.url {
            settings.kbFolderPath = url.path
        }
    }

    private func chooseNotesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "choose_where_to_save_meeting_transcripts")

        if panel.runModal() == .OK, let url = panel.url {
            settings.notesFolderPath = url.path
        }
    }

    private var trimmedTemplateName: String {
        newTemplateName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedTemplatePrompt: String {
        newTemplatePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSaveNewTemplate: Bool {
        !trimmedTemplateName.isEmpty && !trimmedTemplatePrompt.isEmpty
    }

    private func resetNewTemplateForm() {
        isAddingTemplate = false
        newTemplateName = ""
        newTemplateIcon = "doc.text"
        newTemplatePrompt = ""
        focusedTemplateField = nil
    }
}

// MARK: - Icon Picker

private struct IconPickerGrid: View {
    @Binding var selected: String

    private static let icons = [
        "doc.text", "person.2", "person.3", "person.badge.plus",
        "calendar", "clock", "arrow.up.circle", "magnifyingglass",
        "lightbulb", "star", "flag", "bolt",
        "bubble.left.and.bubble.right", "phone", "video",
        "briefcase", "chart.bar", "list.bullet",
        "checkmark.circle", "gear", "globe", "book",
        "pencil", "megaphone",
    ]

    private let columns = Array(repeating: GridItem(.fixed(28), spacing: 4), count: 8)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(Self.icons, id: \.self) { icon in
                Button {
                    selected = icon
                } label: {
                    Image(systemName: icon)
                        .font(.subheadline)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selected == icon ? Color.accentColor.opacity(0.2) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(selected == icon ? Color.accentColor : Color.clear, lineWidth: 1.5)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected == icon ? .primary : .secondary)
            }
        }
    }
}
