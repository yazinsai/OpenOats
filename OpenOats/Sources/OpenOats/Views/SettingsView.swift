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
                Text("Where meeting transcripts are saved as plain text files.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                HStack {
                    Text(settings.notesFolderPath)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button("Choose...") {
                        chooseNotesFolder()
                    }
                }
            }

            Section("Knowledge Base") {
                Text("Optional. Point this to a folder of notes, docs, or reference material (.md, .txt). During meetings, OpenOats searches this folder to surface relevant context and talking points.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                HStack {
                    Text(settings.kbFolderPath.isEmpty ? "Not set" : settings.kbFolderPath)
                        .font(.system(size: 12))
                        .foregroundStyle(settings.kbFolderPath.isEmpty ? .tertiary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    if !settings.kbFolderPath.isEmpty {
                        Button("Clear") {
                            settings.kbFolderPath = ""
                        }
                        .font(.system(size: 12))
                    }

                    Button("Choose...") {
                        chooseKBFolder()
                    }
                }
            }

            Section("LLM Provider") {
                Picker("Provider", selection: $settings.llmProvider) {
                    ForEach(LLMProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .font(.system(size: 12))
                .accessibilityIdentifier("settings.llmProviderPicker")

                switch settings.llmProvider {
                case .openRouter:
                    SecureField("API Key", text: $settings.openRouterApiKey)
                        .font(.system(size: 12, design: .monospaced))

                    TextField("Model", text: $settings.selectedModel, prompt: Text("e.g. google/gemini-3-flash-preview"))
                        .font(.system(size: 12, design: .monospaced))
                case .ollama:
                    TextField("Ollama URL", text: $settings.ollamaBaseURL, prompt: Text("http://localhost:11434"))
                        .font(.system(size: 12, design: .monospaced))

                    TextField("Model", text: $settings.ollamaLLMModel, prompt: Text("e.g. qwen3:8b"))
                        .font(.system(size: 12, design: .monospaced))
                case .mlx:
                    TextField("MLX Server URL", text: $settings.mlxBaseURL, prompt: Text("http://localhost:8080"))
                        .font(.system(size: 12, design: .monospaced))

                    TextField("Model", text: $settings.mlxModel, prompt: Text("e.g. mlx-community/Llama-3.2-3B-Instruct-4bit"))
                        .font(.system(size: 12, design: .monospaced))
                }
            }

            Section("Embedding Provider") {
                Picker("Provider", selection: $settings.embeddingProvider) {
                    ForEach(EmbeddingProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .font(.system(size: 12))

                switch settings.embeddingProvider {
                case .voyageAI:
                    SecureField("API Key", text: $settings.voyageApiKey)
                        .font(.system(size: 12, design: .monospaced))
                case .ollama:
                    TextField("Embedding Model", text: $settings.ollamaEmbedModel, prompt: Text("e.g. nomic-embed-text"))
                        .font(.system(size: 12, design: .monospaced))

                    if settings.llmProvider != .ollama && settings.llmProvider != .mlx {
                        TextField("Ollama URL", text: $settings.ollamaBaseURL, prompt: Text("http://localhost:11434"))
                            .font(.system(size: 12, design: .monospaced))
                    }
                case .openAICompatible:
                    TextField("Endpoint URL", text: $settings.openAIEmbedBaseURL, prompt: Text("http://localhost:8080"))
                        .font(.system(size: 12, design: .monospaced))

                    SecureField("API Key (optional)", text: $settings.openAIEmbedApiKey)
                        .font(.system(size: 12, design: .monospaced))

                    TextField("Model", text: $settings.openAIEmbedModel, prompt: Text("e.g. text-embedding-3-small"))
                        .font(.system(size: 12, design: .monospaced))
                }
            }

            Section("Audio Input") {
                Picker("Microphone", selection: $settings.inputDeviceID) {
                    Text("System Default").tag(AudioDeviceID(0))
                    ForEach(inputDevices, id: \.id) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .font(.system(size: 12))
                .accessibilityIdentifier("settings.microphonePicker")
            }

            Section("Recording") {
                Toggle("Save audio recording", isOn: $settings.saveAudioRecording)
                    .font(.system(size: 12))
                Text("Save a local audio file (.m4a) alongside each transcript. Audio never leaves your device.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Toggle("Echo cancellation", isOn: $settings.enableEchoCancellation)
                    .font(.system(size: 12))
                Text("Reduces duplicate transcription when using speakers and microphone simultaneously. Currently disabled during recording because it conflicts with system audio capture on macOS.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Transcription") {
                Picker("Model", selection: $settings.transcriptionModel) {
                    ForEach(TranscriptionModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .font(.system(size: 12))
                .accessibilityIdentifier("settings.transcriptionModelPicker")

                if settings.transcriptionModel.supportsExplicitLanguageHint {
                    TextField(
                        "\(settings.transcriptionModel.localeFieldTitle) (e.g. en-US)",
                        text: $settings.transcriptionLocale
                    )
                    .font(.system(size: 12, design: .monospaced))
                }

                Text(settings.transcriptionModel.localeHelpText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Show live transcript", isOn: $settings.showLiveTranscript)
                    .font(.system(size: 12))
                Text("When disabled, the transcript panel is hidden during meetings. Transcription still runs in the background for suggestions and notes.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Toggle("Clean up transcript during recording", isOn: $settings.enableTranscriptRefinement)
                    .font(.system(size: 12))
                Text("Automatically removes filler words and fixes punctuation as you record. You can always clean up past transcripts manually from the Notes window.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Custom Keywords")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    ZStack(alignment: .topLeading) {
                        if settings.transcriptionCustomVocabulary.isEmpty {
                            Text("One term per line. Optional aliases: OpenOats: open oats")
                                .font(.system(size: 11))
                                .foregroundStyle(.quaternary)
                                .padding(.top, 6)
                                .padding(.leading, 4)
                                .allowsHitTesting(false)
                        }

                        TextEditor(text: $settings.transcriptionCustomVocabulary)
                            .font(.system(size: 11, design: .monospaced))
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
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Privacy") {
                Toggle("Hide from screen sharing", isOn: $settings.hideFromScreenShare)
                    .font(.system(size: 12))
                Text("When enabled, the app is invisible during screen sharing and recording.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Meeting Detection") {
                Toggle("Auto-detect meetings", isOn: $settings.meetingAutoDetectEnabled)
                    .font(.system(size: 12))
                    .onChange(of: settings.meetingAutoDetectEnabled) {
                        if settings.meetingAutoDetectEnabled && !settings.hasShownAutoDetectExplanation {
                            settings.meetingAutoDetectEnabled = false
                            showAutoDetectExplanation = true
                        }
                    }

                Text("When enabled, OpenOats monitors microphone activation to detect when a meeting app starts a call. No audio is captured until you accept the notification.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                LaunchAtLogin.Toggle("Launch at login")
                    .font(.system(size: 12))
            }
            .sheet(isPresented: $showAutoDetectExplanation) {
                VStack(spacing: 16) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(.tint)

                    Text("How Meeting Detection Works")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 10) {
                        Label("OpenOats watches for microphone activation by meeting apps (Zoom, Teams, FaceTime, etc.)", systemImage: "mic")
                        Label("Only activation status is checked. No audio is captured or recorded until you accept.", systemImage: "lock.shield")
                        Label("When a meeting is detected, you get a macOS notification to start transcribing.", systemImage: "bell")
                        Label("You can always dismiss the notification or mark it as \"not a meeting\".", systemImage: "hand.raised")
                    }
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack {
                        Button("Cancel") {
                            showAutoDetectExplanation = false
                        }
                        .keyboardShortcut(.cancelAction)

                        Button("Enable Detection") {
                            settings.hasShownAutoDetectExplanation = true
                            settings.meetingAutoDetectEnabled = true
                            showAutoDetectExplanation = false
                        }
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
                        Text("Silence timeout")
                            .font(.system(size: 12))
                        Spacer()
                        TextField("", value: $settings.silenceTimeoutMinutes, format: .number)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 50)
                            .multilineTextAlignment(.trailing)
                        Text("min")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Text("Auto-detected sessions stop after this many minutes of silence.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Toggle("Detection log", isOn: $settings.detectionLogEnabled)
                        .font(.system(size: 12))
                    Text("Print detection events to the system console for debugging.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
            }

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $automaticallyChecksForUpdates)
                .font(.system(size: 12))
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
                            .font(.system(size: 12))
                        Spacer()
                        if template.isBuiltIn {
                            Image(systemName: "lock")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Button("Reset") {
                                resetTemplate(id: template.id)
                            }
                            .font(.system(size: 11))
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                        } else {
                            Button {
                                deleteTemplate(id: template.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if isAddingTemplate {
                    VStack(alignment: .leading, spacing: 10) {
                        // Name
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Name")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            TextField("e.g. Sprint Planning", text: $newTemplateName)
                                .font(.system(size: 12))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                                .focused($focusedTemplateField, equals: .name)
                        }

                        // Icon picker
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Icon")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            IconPickerGrid(selected: $newTemplateIcon)
                        }

                        // System prompt
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Notes Prompt")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text("Instructions for how the AI should format notes for this meeting type.")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            ZStack(alignment: .topLeading) {
                                if newTemplatePrompt.isEmpty {
                                    Text("e.g. You are a meeting notes assistant. Given a transcript, produce structured notes with sections for...")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.quaternary)
                                        .padding(.top, 6)
                                        .padding(.leading, 4)
                                        .allowsHitTesting(false)
                                }
                                TextEditor(text: $newTemplatePrompt)
                                    .font(.system(size: 11, design: .monospaced))
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
                            Button("Cancel") {
                                resetNewTemplateForm()
                            }
                            .buttonStyle(.plain)
                            Button("Save") {
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
                            .buttonStyle(.borderedProminent)
                            .disabled(!canSaveNewTemplate)
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    Button("New Template") {
                        isAddingTemplate = true
                        Task { @MainActor in
                            focusedTemplateField = .name
                        }
                    }
                    .font(.system(size: 12))
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
        panel.message = "Choose a folder containing your knowledge base documents (.md, .txt)"

        if panel.runModal() == .OK, let url = panel.url {
            settings.kbFolderPath = url.path
        }
    }

    private func chooseNotesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose where to save meeting transcripts"

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
                        .font(.system(size: 13))
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
