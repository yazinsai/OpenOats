import SwiftUI
import CoreAudio
import LaunchAtLogin
import ServiceManagement
import Sparkle

// MARK: - Settings Tab Enum

private enum SettingsTab: String, CaseIterable {
    case general
    case transcription
    case intelligence
    case sidecast
    case templates
    case integrations
}

// MARK: - Settings View

struct SettingsView: View {
    @Bindable var settings: AppSettings
    var updater: SPUUpdater
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab(settings: settings, updater: updater)
                .tabItem { Label("General", systemImage: "gear") }
                .tag(SettingsTab.general)

            TranscriptionSettingsTab(settings: settings)
                .tabItem { Label("Transcription", systemImage: "waveform") }
                .tag(SettingsTab.transcription)

            IntelligenceSettingsTab(settings: settings)
                .tabItem { Label("Intelligence", systemImage: "brain") }
                .tag(SettingsTab.intelligence)

            SidecastSettingsTab(settings: settings)
                .tabItem { Label("Sidecast", systemImage: "person.3.sequence") }
                .tag(SettingsTab.sidecast)

            TemplatesSettingsTab()
                .tabItem { Label("Templates", systemImage: "doc.text") }
                .tag(SettingsTab.templates)

            IntegrationsSettingsTab(settings: settings)
                .tabItem { Label("Integrations", systemImage: "arrow.triangle.branch") }
                .tag(SettingsTab.integrations)
        }
        .accessibilityIdentifier("settings.tabView")
        .frame(width: 500, height: 600)
    }
}

// MARK: - General Settings Tab

private struct GeneralSettingsTab: View {
    @Bindable var settings: AppSettings
    var updater: SPUUpdater
    @State private var automaticallyChecksForUpdates = false
    @State private var showAutoDetectExplanation = false
    @State private var launchAtLoginEnabled = false
    @State private var showWizard = false

    var body: some View {
        ScrollView {
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

                    Toggle("Launch at login", isOn: $launchAtLoginEnabled)
                        .font(.system(size: 12))
                        .onChange(of: launchAtLoginEnabled) { _, newValue in
                            LaunchAtLogin.isEnabled = newValue
                        }
                        .task {
                            launchAtLoginEnabled = await Task.detached {
                                SMAppService.mainApp.status == .enabled
                            }.value
                        }
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

                if !settings.ignoredAppBundleIDs.isEmpty {
                    Section("Ignored Apps") {
                        Text("These apps won't trigger meeting detection notifications.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        ForEach(settings.ignoredAppBundleIDs, id: \.self) { bundleID in
                            HStack {
                                Text(bundleID)
                                    .font(.system(size: 12, design: .monospaced))
                                Spacer()
                                Button {
                                    settings.ignoredAppBundleIDs.removeAll { $0 == bundleID }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Stop ignoring this app")
                            }
                        }
                    }
                }

                Section("Privacy") {
                    Toggle("Hide from screen sharing", isOn: $settings.hideFromScreenShare)
                        .font(.system(size: 12))
                    Text("When enabled, the app is invisible during screen sharing and recording.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Section("Updates") {
                    Toggle("Automatically check for updates", isOn: $automaticallyChecksForUpdates)
                        .font(.system(size: 12))
                        .onChange(of: automaticallyChecksForUpdates) { _, newValue in
                            Task { @MainActor in
                                updater.automaticallyChecksForUpdates = newValue
                            }
                        }
                }

                Section("Setup") {
                    Button("Re-run Setup Wizard") {
                        showWizard = true
                    }
                    .font(.system(size: 12))

                    Text("Re-runs the initial setup wizard. Your current settings will be shown as starting values.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .onAppear {
            Task { @MainActor in
                automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
            }
        }
        .sheet(isPresented: $showWizard) {
            SetupWizardView(
                isPresented: $showWizard,
                settings: settings,
                isReconfiguration: true
            )
            .frame(width: 500, height: 550)
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
}

// MARK: - Transcription Settings Tab

private struct TranscriptionSettingsTab: View {
    @Bindable var settings: AppSettings
    @State private var inputDevices: [(id: AudioDeviceID, name: String)] = []
    @State private var outputDevices: [(id: AudioDeviceID, name: String)] = []

    var body: some View {
        ScrollView {
            Form {
                Section("Audio Input") {
                    Picker("Microphone", selection: $settings.inputDeviceID) {
                        Text("System Default").tag(AudioDeviceID(0))
                        ForEach(inputDevices, id: \.id) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .font(.system(size: 12))
                    .accessibilityIdentifier("settings.microphonePicker")

                    Picker("Speaker / Output", selection: $settings.outputDeviceID) {
                        Text("System Default").tag(AudioDeviceID(0))
                        ForEach(outputDevices, id: \.id) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .font(.system(size: 12))
                    .accessibilityIdentifier("settings.outputDevicePicker")
                    Text("Select the output device carrying your meeting audio. If using AirPods or Bluetooth headphones, select them explicitly.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
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
                        Section("Local") {
                            ForEach(TranscriptionModel.allCases.filter { !$0.isCloud }) { model in
                                Text(model.displayName).tag(model)
                            }
                        }
                        Section("Cloud") {
                            ForEach(TranscriptionModel.allCases.filter { $0.isCloud }) { model in
                                Text(model.displayName).tag(model)
                            }
                        }
                    }
                    .font(.system(size: 12))
                    .accessibilityIdentifier("settings.transcriptionModelPicker")

                    if settings.transcriptionModel.isCloud {
                        switch settings.transcriptionModel {
                        case .assemblyAI:
                            SecureField("AssemblyAI API Key", text: $settings.assemblyAIApiKey)
                                .font(.system(size: 12, design: .monospaced))
                            Text("Audio segments are sent to AssemblyAI for transcription. AssemblyAI states audio is deleted after processing. Review their privacy policy at assemblyai.com/security.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        case .elevenLabsScribe:
                            SecureField("ElevenLabs API Key", text: $settings.elevenLabsApiKey)
                                .font(.system(size: 12, design: .monospaced))
                            Text("Audio segments are sent to ElevenLabs for transcription. Review their privacy policy at elevenlabs.io/privacy.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Toggle("Remove filler words", isOn: $settings.removeFillerWords)
                                .font(.system(size: 12))
                            Text("Strips filler words, false starts, and non-speech sounds server-side before returning the transcript.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        default:
                            EmptyView()
                        }
                    }

                    TextField(
                        "\(settings.transcriptionModel.localeFieldTitle) (e.g. en-US)",
                        text: $settings.transcriptionLocale
                    )
                    .font(.system(size: 12, design: .monospaced))

                    Text(settings.transcriptionModel.localeHelpText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle("Show live transcript", isOn: $settings.showLiveTranscript)
                        .font(.system(size: 12))
                    Text("When disabled, the transcript panel is hidden during meetings. Transcription still runs in the background for suggestions and notes.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Toggle("Clean up transcript during recording", isOn: $settings.enableLiveTranscriptCleanup)
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
                            "Boost meeting-specific jargon, names, and product terms. Enter one term per line, or use `Preferred Term: alias one, alias two`. Parakeet: full alias support. AssemblyAI: aliases map to custom spelling. ElevenLabs: terms boost recognition."
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section("Transcript Quality") {
                    Toggle("Re-transcribe with higher accuracy after meeting", isOn: $settings.enableBatchRetranscription)
                        .font(.system(size: 12))
                    Text("Re-transcribes audio with a higher-quality model after each meeting for better accuracy. Runs in the background.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    if settings.enableBatchRetranscription {
                        Picker("Batch Model", selection: $settings.batchTranscriptionModel) {
                            ForEach(TranscriptionModel.batchSuitableModels) { model in
                                Text(model.displayName).tag(model)
                            }
                        }
                        .font(.system(size: 12))
                    }
                }

                Section("Speaker Diarization") {
                    Toggle("Identify multiple remote speakers", isOn: $settings.enableDiarization)
                        .font(.system(size: 12))
                    Text("Uses LS-EEND to distinguish different speakers on system audio. Requires a one-time model download (~50 MB).")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    if settings.enableDiarization {
                        Picker("Variant", selection: $settings.diarizationVariant) {
                            ForEach(DiarizationVariant.allCases) { variant in
                                Text(variant.displayName).tag(variant)
                            }
                        }
                        .font(.system(size: 12))
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onAppear {
            inputDevices = MicCapture.availableInputDevices()
            outputDevices = SystemAudioCapture.availableOutputDevices()
        }
    }
}

// MARK: - Intelligence Settings Tab

private struct IntelligenceSettingsTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        ScrollView {
            Form {
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

                        OllamaModelField(modelName: $settings.ollamaLLMModel, baseURL: settings.ollamaBaseURL, placeholder: "e.g. qwen3:8b")
                    case .mlx:
                        TextField("MLX Server URL", text: $settings.mlxBaseURL, prompt: Text("http://localhost:8080"))
                            .font(.system(size: 12, design: .monospaced))

                        TextField("Model", text: $settings.mlxModel, prompt: Text("e.g. mlx-community/Llama-3.2-3B-Instruct-4bit"))
                            .font(.system(size: 12, design: .monospaced))
                    case .openAICompatible:
                        TextField("Endpoint URL", text: $settings.openAILLMBaseURL, prompt: Text("http://localhost:4000"))
                            .font(.system(size: 12, design: .monospaced))

                        SecureField("API Key (optional)", text: $settings.openAILLMApiKey)
                            .font(.system(size: 12, design: .monospaced))

                        TextField("Model", text: $settings.openAILLMModel, prompt: Text("e.g. gpt-4o-mini"))
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
                        OllamaModelField(modelName: $settings.ollamaEmbedModel, baseURL: settings.ollamaBaseURL, placeholder: "e.g. nomic-embed-text")

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

                Section("Classic Suggestions") {
                    Toggle("Floating suggestion panel", isOn: $settings.suggestionPanelEnabled)
                        .font(.system(size: 12))
                    Text("Configure the original single-stream suggestion panel. The multi-persona sidebar lives in the Sidecast tab.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    switch settings.llmProvider {
                    case .openRouter:
                        TextField("Speed Model", text: $settings.realtimeModel, prompt: Text("e.g. google/gemini-2.0-flash-001"))
                            .font(.system(size: 12, design: .monospaced))
                        Text("A fast model used for real-time suggestion synthesis. Separate from your main model.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    case .ollama:
                        OllamaModelField(modelName: $settings.realtimeOllamaModel, baseURL: settings.ollamaBaseURL, placeholder: "Leave empty to use main model")
                        Text("Optional Ollama model for real-time suggestions. Uses your main model if empty.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    case .mlx, .openAICompatible:
                        Text("Real-time suggestions currently reuse the active provider model for this provider.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
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

                Section("Suggestions") {
                    Picker("Verbosity", selection: $settings.suggestionVerbosity) {
                        ForEach(SuggestionVerbosity.allCases) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    .font(.system(size: 12))

                    Text(settings.suggestionVerbosity.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
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
}

// MARK: - Templates Settings Tab

private struct TemplatesSettingsTab: View {
    private enum TemplateField: Hashable {
        case name
    }

    @Environment(AppCoordinator.self) private var coordinator
    @State private var templates: [MeetingTemplate] = []
    @State private var isAddingTemplate = false
    @State private var newTemplateName = ""
    @State private var newTemplateIcon = "doc.text"
    @State private var newTemplatePrompt = ""
    @FocusState private var focusedTemplateField: TemplateField?

    var body: some View {
        ScrollView {
            Form {
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
            .formStyle(.grouped)
        }
        .onAppear {
            Task { @MainActor in
                templates = coordinator.templateStore.templates
            }
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

    private func resetNewTemplateForm() {
        isAddingTemplate = false
        newTemplateName = ""
        newTemplateIcon = "doc.text"
        newTemplatePrompt = ""
        focusedTemplateField = nil
    }
}

// MARK: - Integrations Settings Tab

private struct IntegrationsSettingsTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        ScrollView {
            Form {
                Section("Webhook") {
                    Toggle("Send webhook when meeting ends", isOn: $settings.webhookEnabled)
                        .font(.system(size: 12))
                    Text("POST a JSON payload to a URL after each meeting with session metadata and transcript.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    if settings.webhookEnabled {
                        TextField("URL", text: $settings.webhookURL, prompt: Text("https://example.com/webhook"))
                            .font(.system(size: 12, design: .monospaced))

                        SecureField("Signing Secret (optional)", text: $settings.webhookSecret)
                            .font(.system(size: 12, design: .monospaced))
                        Text("If set, each request includes an X-OpenOats-Signature header (HMAC-SHA256) for payload verification.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Import") {
                    Text("Import meetings from Granola. Generate an API key in the Granola desktop app under Settings.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    SecureField("Granola API Key", text: $settings.granolaApiKey)
                        .font(.system(size: 12, design: .monospaced))

                    GranolaImportButton(apiKey: settings.granolaApiKey)
                }
            }
            .formStyle(.grouped)
        }
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

// MARK: - Granola Import Button

private struct GranolaImportButton: View {
    @Environment(AppCoordinator.self) private var coordinator
    let apiKey: String
    @State private var importState: GranolaImportState = .idle
    @State private var isImporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch importState {
            case .idle:
                EmptyView()
            case .fetching(let progress):
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(progress)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            case .importing(let current, let total):
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Importing \(current) of \(total)...")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            case .completed(let imported, let skipped):
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 12))
                    Text("Imported \(imported) meeting\(imported == 1 ? "" : "s")\(skipped > 0 ? ", \(skipped) already existed" : "")")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            case .failed(let error):
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 12))
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }

            Button("Import from Granola") {
                startImport()
            }
            .font(.system(size: 12))
            .disabled(isImporting)
        }
    }

    private func startImport() {
        guard !apiKey.isEmpty else {
            importState = .failed("Enter your Granola API key above.")
            return
        }

        isImporting = true
        importState = .fetching(progress: "Connecting to Granola...")

        let repo = coordinator.sessionRepository
        let importer = GranolaImporter()

        Task { @MainActor in
            do {
                let result = try await importer.importAll(
                    apiKey: apiKey,
                    sessionRepository: repo,
                    onProgress: { state in
                        Task { @MainActor in
                            self.importState = state
                        }
                    }
                )
                importState = .completed(imported: result.imported, skipped: result.skipped)
                isImporting = false
                await coordinator.loadHistory()
            } catch {
                importState = .failed(error.localizedDescription)
                isImporting = false
            }
        }
    }
}
