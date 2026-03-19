import SwiftUI
import CoreAudio
import Sparkle

struct SettingsView: View {
    private enum TemplateField: Hashable {
        case name
    }

    @Bindable var settings: AppSettings
    var updater: SPUUpdater
    @Environment(AppCoordinator.self) private var coordinator
    @State private var inputDevices: [(id: AudioDeviceID, name: String)] = []
    @State private var isAddingTemplate = false
    @State private var newTemplateName = ""
    @State private var newTemplateIcon = "doc.text"
    @State private var newTemplatePrompt = ""
    @FocusState private var focusedTemplateField: TemplateField?

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

                if settings.llmProvider == .openRouter {
                    SecureField("API Key", text: $settings.openRouterApiKey)
                        .font(.system(size: 12, design: .monospaced))

                    TextField("Model", text: $settings.selectedModel, prompt: Text("e.g. google/gemini-3-flash-preview"))
                        .font(.system(size: 12, design: .monospaced))
                } else {
                    TextField("Ollama URL", text: $settings.ollamaBaseURL, prompt: Text("http://localhost:11434"))
                        .font(.system(size: 12, design: .monospaced))

                    TextField("Model", text: $settings.ollamaLLMModel, prompt: Text("e.g. qwen3:8b"))
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

                    if settings.llmProvider != .ollama {
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
            }

            Section("Recording") {
                Toggle("Save audio recording", isOn: $settings.saveAudioRecording)
                    .font(.system(size: 12))
                Text("Save a local audio file (.m4a) alongside each transcript. Audio never leaves your device.")
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
            }

            Section("Privacy") {
                Toggle("Hide from screen sharing", isOn: $settings.hideFromScreenShare)
                    .font(.system(size: 12))
                Text("When enabled, the app is invisible during screen sharing and recording.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }
                ))
                .font(.system(size: 12))
            }

            Section("Meeting Templates") {
                ForEach(coordinator.templateStore.templates) { template in
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
                                coordinator.templateStore.resetBuiltIn(id: template.id)
                            }
                            .font(.system(size: 11))
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                        } else {
                            Button {
                                coordinator.templateStore.delete(id: template.id)
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
                                coordinator.templateStore.add(template)
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
        .frame(width: 450, height: 700)
        .onAppear {
            inputDevices = MicCapture.availableInputDevices()
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
