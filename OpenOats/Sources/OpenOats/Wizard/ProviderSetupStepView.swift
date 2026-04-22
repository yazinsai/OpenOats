import AppKit
import SwiftUI

/// Screen 3: API keys for the cloud path or Ollama readiness for the local path.
struct ProviderSetupStepView: View {
    @Bindable var viewModel: WizardViewModel
    @State private var autoAdvanceCancelled = false
    @State private var autoAdvanceCountdown: Int?

    private var isCloudPath: Bool {
        viewModel.recommendation?.profile.isCloud ?? false
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    viewModel.goBack()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .medium))
                        Text("Back")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Spacer()
            }

            Spacer()

            if isCloudPath {
                cloudSetupContent
            } else {
                ollamaSetupContent
            }

            Spacer()

            HStack {
                Spacer()

                Button {
                    viewModel.advance()
                } label: {
                    Text("Next")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(
                            viewModel.canAdvance ? Color.accentTeal : Color.gray.opacity(0.3),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canAdvance)
            }
        }
        .padding(28)
        .task(id: viewModel.recommendation?.profile) {
            guard !isCloudPath else { return }
            await viewModel.checkOllamaStatus()
        }
        .onChange(of: viewModel.ollamaStatus) { _, newStatus in
            if case .readyWithModels = newStatus, !autoAdvanceCancelled {
                startAutoAdvance()
            } else {
                autoAdvanceCountdown = nil
            }
        }
    }

    // MARK: - Cloud Path

    private var cloudSetupContent: some View {
        VStack(spacing: 20) {
            Text("Connect your cloud AI service")
                .font(.system(size: 16, weight: .semibold))
                .multilineTextAlignment(.center)

            Text("To use cloud AI, you'll need an API key. This is like a password that connects OpenOats to the AI service.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 6) {
                Text("OpenRouter API key")
                    .font(.system(size: 12, weight: .medium))

                HStack(spacing: 8) {
                    TextField("sk-or-v1-...", text: $viewModel.openRouterKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                    validationIndicator(
                        isValidating: viewModel.isValidatingOpenRouter,
                        result: viewModel.openRouterValidation
                    )
                }

                validationMessage(result: viewModel.openRouterValidation)

                Link(
                    "Don't have a key? Get one free in 30 seconds",
                    destination: URL(string: "https://openrouter.ai/keys")!
                )
                .font(.system(size: 11))
                .foregroundStyle(Color.accentTeal)
            }

            if viewModel.intent == .fullCopilot {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Voyage AI key (optional, for knowledge retrieval)")
                        .font(.system(size: 12, weight: .medium))

                    Text("Only needed if you want OpenOats to search a Knowledge Base folder for relevant context during meetings. This does not improve note generation directly.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        TextField("pa-...", text: $viewModel.voyageKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))

                        validationIndicator(
                            isValidating: viewModel.isValidatingVoyage,
                            result: viewModel.voyageValidation
                        )
                    }

                    validationMessage(result: viewModel.voyageValidation)

                    Link(
                        "Don't have a key? Get one free in 30 seconds",
                        destination: URL(string: "https://dash.voyageai.com/api-keys")!
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentTeal)
                }
            }
        }
    }

    // MARK: - Local Path

    private var ollamaSetupContent: some View {
        VStack(spacing: 20) {
            Text("Set up local AI")
                .font(.system(size: 16, weight: .semibold))
                .multilineTextAlignment(.center)

            Text("To run AI on your Mac, OpenOats uses Ollama. Let's check if it's ready.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            ollamaStatusView
        }
    }

    @ViewBuilder
    private var ollamaStatusView: some View {
        switch viewModel.ollamaStatus {
        case .readyWithModels:
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Everything's set up.")
                        .font(.system(size: 13))
                }

                if let countdown = autoAdvanceCountdown, !autoAdvanceCancelled {
                    HStack(spacing: 4) {
                        Text("Looks good. Moving on in \(countdown)...")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        Button("Wait, go back") {
                            autoAdvanceCancelled = true
                            autoAdvanceCountdown = nil
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentTeal)
                        .buttonStyle(.plain)
                    }
                }
            }

        case .missingModels:
            VStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.orange)
                    Text("Ollama is running but needs one more model. We'll download it for you.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if viewModel.isPullingModel {
                    VStack(spacing: 6) {
                        ProgressView(value: viewModel.ollamaPullProgress ?? 0, total: 1.0)
                            .progressViewStyle(.linear)
                        if let progress = viewModel.ollamaPullProgress {
                            Text("\(Int(progress * 100))% downloaded")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if let error = viewModel.ollamaPullError {
                    VStack(spacing: 8) {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)

                        Button("Retry") {
                            Task { await viewModel.pullMissingModels() }
                        }
                        .font(.system(size: 12, weight: .medium))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                } else {
                    Button("Download required models") {
                        Task { await viewModel.pullMissingModels() }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

        case .notReachable:
            VStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("Ollama doesn't seem to be running.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button("Open Ollama") {
                        if let url = URL(string: "ollama://") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Retry") {
                        Task { await viewModel.checkOllamaStatus() }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Link(
                    "Need to install it? Download Ollama",
                    destination: URL(string: "https://ollama.com/download")!
                )
                .font(.system(size: 11))
                .foregroundStyle(Color.accentTeal)
            }
        }
    }

    // MARK: - Validation Helpers

    private func validationIndicator(
        isValidating: Bool,
        result: APIKeyValidator.ValidationResult?
    ) -> some View {
        Group {
            if isValidating {
                ProgressView()
                    .controlSize(.mini)
            } else if let result {
                switch result {
                case .valid:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .invalid:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                case .networkError:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .font(.system(size: 14))
    }

    @ViewBuilder
    private func validationMessage(result: APIKeyValidator.ValidationResult?) -> some View {
        if let result {
            switch result {
            case .valid:
                Text("Connected")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            case .invalid(let message):
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            case .networkError(let message):
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Auto-Advance

    private func startAutoAdvance() {
        autoAdvanceCountdown = 1
        Task {
            try? await Task.sleep(for: .seconds(1))
            guard !autoAdvanceCancelled else { return }
            viewModel.advance()
        }
    }
}
