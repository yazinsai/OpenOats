import SwiftUI

/// A text field with a dropdown button that lists models available on the configured Ollama instance.
struct OllamaModelField: View {
    @Binding var modelName: String
    let baseURL: String
    let placeholder: String

    @State private var availableModels: [String] = []
    @State private var isLoading = false

    var body: some View {
        HStack(spacing: 4) {
            TextField("Model", text: $modelName, prompt: Text(placeholder))
                .font(.system(size: 12, design: .monospaced))

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            } else {
                Menu {
                    if availableModels.isEmpty {
                        Button("No models found") {}
                            .disabled(true)
                    } else {
                        ForEach(availableModels, id: \.self) { model in
                            Button(model) {
                                modelName = model
                            }
                        }
                    }
                    Divider()
                    Button("Refresh") {
                        Task { await fetchModels() }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10))
                        .frame(width: 16, height: 16)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .task(id: baseURL) {
            await fetchModels()
        }
    }

    private func fetchModels() async {
        guard !baseURL.trimmingCharacters(in: .whitespaces).isEmpty else {
            availableModels = []
            return
        }
        isLoading = true
        availableModels = await OllamaModelFetcher.fetchModelsLegacy(baseURL: baseURL)
        isLoading = false
    }
}
