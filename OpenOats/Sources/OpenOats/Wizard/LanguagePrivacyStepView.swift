import SwiftUI

/// Screen 2: language and privacy, shown only when auto-detection is ambiguous.
struct LanguagePrivacyStepView: View {
    @Bindable var viewModel: WizardViewModel

    private var isLanguageOnly: Bool {
        viewModel.intent == .transcribe
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

            VStack(spacing: 20) {
                Text("What language are your meetings in?")
                    .font(.system(size: 16, weight: .semibold))
                    .multilineTextAlignment(.center)

                if !viewModel.snapshot.isEnglishLocale {
                    let localeCode = String(viewModel.snapshot.systemLocale.prefix(2))
                    let localeName = Locale.current.localizedString(forLanguageCode: localeCode) ?? viewModel.snapshot.systemLocale
                    Text("We noticed your Mac is set to \(localeName)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    languageOption(
                        language: .english,
                        title: "English only",
                        isSelected: viewModel.language == .english
                    )

                    languageOption(
                        language: .multilingual,
                        title: "Other languages",
                        isSelected: viewModel.language == .multilingual
                    )
                }
            }

            if !isLanguageOnly {
                Spacer().frame(height: 32)

                VStack(spacing: 20) {
                    Text("Where should AI processing happen?")
                        .font(.system(size: 16, weight: .semibold))
                        .multilineTextAlignment(.center)

                    VStack(spacing: 12) {
                        privacyOption(
                            privacy: .local,
                            icon: "desktopcomputer",
                            title: "Keep everything on this Mac",
                            subtitle: "Fully private. Nothing leaves your computer.",
                            hint: viewModel.snapshot.ollamaReachable ? "Your Mac is already set up for local AI" : nil,
                            isSelected: viewModel.privacy == .local
                        )

                        privacyOption(
                            privacy: .cloud,
                            icon: "cloud",
                            title: "Use the cloud",
                            subtitle: "Faster, easier setup.",
                            hint: viewModel.snapshot.hasOpenRouterKey ? "Cloud API key detected" : nil,
                            isSelected: viewModel.privacy == .cloud
                        )

                        if viewModel.privacy == .cloud {
                            Text("Transcription always stays on your Mac. Cloud notes and summaries send text only. Calendar titles and participant names are included only if you separately enable calendar context for cloud-generated notes.")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 14)
                        }
                    }
                }
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
        .onAppear {
            if viewModel.language == nil {
                viewModel.language = viewModel.snapshot.isEnglishLocale ? .english : .multilingual
            }

            if !isLanguageOnly && viewModel.privacy == nil {
                if viewModel.snapshot.ollamaReachable && !viewModel.snapshot.hasOpenRouterKey {
                    viewModel.privacy = .local
                } else if viewModel.snapshot.hasOpenRouterKey {
                    viewModel.privacy = .cloud
                }
            }
        }
    }

    private func languageOption(
        language: WizardLanguage,
        title: String,
        isSelected: Bool
    ) -> some View {
        Button {
            viewModel.language = language
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? Color.accentTeal : .primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Color.accentTeal.opacity(0.08) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            isSelected ? Color.accentTeal.opacity(0.4) : Color.secondary.opacity(0.15),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private func privacyOption(
        privacy: WizardPrivacy,
        icon: String,
        title: String,
        subtitle: String,
        hint: String?,
        isSelected: Bool
    ) -> some View {
        Button {
            viewModel.privacy = privacy
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? Color.accentTeal : .secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)

                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    if let hint {
                        Text(hint)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.accentTeal)
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentTeal)
                        .font(.system(size: 14))
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentTeal.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isSelected ? Color.accentTeal.opacity(0.4) : Color.secondary.opacity(0.15),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
