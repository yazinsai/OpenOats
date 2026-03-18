import SwiftUI
import CoreAudio
import Sparkle

struct SettingsView: View {
    @Bindable var settings: AppSettings
    var updater: SPUUpdater
    @Environment(AppCoordinator.self) private var coordinator
    @State private var inputDevices: [(id: AudioDeviceID, name: String)] = []
    @State private var isAddingTemplate = false
    @State private var newTemplateName = ""
    @State private var newTemplateIcon = "doc.text"
    @State private var newTemplatePrompt = ""

    var body: some View {
        Form {
            Section("Knowledge Base") {
                Text("Point this to a folder of notes, docs, or reference material (.md, .txt). During meetings, OpenOats searches this folder to surface relevant context and talking points.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                HStack {
                    Text(settings.kbFolderPath.isEmpty ? "No folder selected" : settings.kbFolderPath)
                        .font(.system(size: 12))
                        .foregroundStyle(settings.kbFolderPath.isEmpty ? .tertiary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button("Choose...") {
                        chooseFolder()
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

                if settings.embeddingProvider == .voyageAI {
                    SecureField("API Key", text: $settings.voyageApiKey)
                        .font(.system(size: 12, design: .monospaced))
                } else {
                    TextField("Embedding Model", text: $settings.ollamaEmbedModel, prompt: Text("e.g. nomic-embed-text"))
                        .font(.system(size: 12, design: .monospaced))

                    if settings.llmProvider != .ollama {
                        TextField("Ollama URL", text: $settings.ollamaBaseURL, prompt: Text("http://localhost:11434"))
                            .font(.system(size: 12, design: .monospaced))
                    }
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

            Section("Transcription") {
                TextField("Locale (e.g. en-US)", text: $settings.transcriptionLocale)
                    .font(.system(size: 12, design: .monospaced))
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
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Template Name", text: $newTemplateName)
                            .font(.system(size: 12))
                        TextField("SF Symbol (e.g. doc.text)", text: $newTemplateIcon)
                            .font(.system(size: 12, design: .monospaced))
                        TextEditor(text: $newTemplatePrompt)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 100)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(.quaternary)
                            )
                        HStack {
                            Button("Cancel") {
                                isAddingTemplate = false
                                newTemplateName = ""
                                newTemplateIcon = "doc.text"
                                newTemplatePrompt = ""
                            }
                            .buttonStyle(.plain)
                            Button("Save") {
                                let template = MeetingTemplate(
                                    id: UUID(),
                                    name: newTemplateName,
                                    icon: newTemplateIcon,
                                    systemPrompt: newTemplatePrompt,
                                    isBuiltIn: false
                                )
                                coordinator.templateStore.add(template)
                                isAddingTemplate = false
                                newTemplateName = ""
                                newTemplateIcon = "doc.text"
                                newTemplatePrompt = ""
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(newTemplateName.isEmpty || newTemplatePrompt.isEmpty)
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    Button("New Template") {
                        isAddingTemplate = true
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

    private func chooseFolder() {
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
