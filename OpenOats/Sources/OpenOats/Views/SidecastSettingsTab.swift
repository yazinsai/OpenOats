import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SidecastSettingsTab: View {
    @Bindable var settings: AppSettings

    @State private var editingPersona: SidecastPersona?
    @State private var draftPersona = SidecastSettingsTab.newPersonaDraft()

    var body: some View {
        ScrollView {
            Form {
                Section("Sidebar") {
                    Picker("Mode", selection: $settings.sidebarMode) {
                        ForEach(SidebarMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .font(.system(size: 12))

                    Text(settings.sidebarMode.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Toggle("Floating sidebar panel", isOn: $settings.suggestionPanelEnabled)
                        .font(.system(size: 12))

                    Picker("Intensity", selection: $settings.sidecastIntensity) {
                        ForEach(SidecastIntensity.allCases) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    .font(.system(size: 12))

                    Text(settings.sidecastIntensity.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Section("Personas") {
                    Text("Build your own cast. Each persona gets a title, avatar, prompt, cadence, and verbosity budget.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    ForEach(settings.sidecastPersonas) { persona in
                        SidecastPersonaRow(
                            persona: persona,
                            onToggle: { enabled in
                                update(personaID: persona.id) { $0.isEnabled = enabled }
                            },
                            onEdit: {
                                draftPersona = persona
                                editingPersona = persona
                            },
                            onDelete: {
                                settings.sidecastPersonas.removeAll { $0.id == persona.id }
                            }
                        )
                    }

                    HStack {
                        Button("Add Persona") {
                            draftPersona = Self.newPersonaDraft()
                            editingPersona = draftPersona
                        }
                        .font(.system(size: 12))

                        Spacer()

                        Button("Reset Starter Cast") {
                            settings.sidecastPersonas = SidecastPersona.starterPack
                        }
                        .font(.system(size: 12))
                    }
                }
            }
            .formStyle(.grouped)
        }
        .sheet(item: $editingPersona) { _ in
            SidecastPersonaEditor(
                draft: draftPersona,
                onCancel: {
                    editingPersona = nil
                },
                onSave: { saved in
                    if let index = settings.sidecastPersonas.firstIndex(where: { $0.id == saved.id }) {
                        settings.sidecastPersonas[index] = saved
                    } else {
                        settings.sidecastPersonas.append(saved)
                    }
                    editingPersona = nil
                }
            )
        }
    }

    private func update(personaID: UUID, mutate: (inout SidecastPersona) -> Void) {
        guard let index = settings.sidecastPersonas.firstIndex(where: { $0.id == personaID }) else { return }
        var updated = settings.sidecastPersonas[index]
        mutate(&updated)
        settings.sidecastPersonas[index] = updated
    }

    private static func newPersonaDraft() -> SidecastPersona {
        SidecastPersona(
            name: "New Persona",
            subtitle: "Custom voice",
            prompt: "Define what this persona should notice, how it should speak, and when it should stay quiet.",
            avatarSymbol: "person.crop.circle.fill",
            avatarTint: .blue,
            verbosity: .short,
            cadence: .normal,
            evidencePolicy: .optional
        )
    }
}

private struct SidecastPersonaRow: View {
    let persona: SidecastPersona
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            SidecastSettingsAvatar(persona: persona)

            VStack(alignment: .leading, spacing: 2) {
                Text(persona.name)
                    .font(.system(size: 12, weight: .medium))
                Text(persona.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Toggle("", isOn: .init(
                get: { persona.isEnabled },
                set: { onToggle($0) }
            ))
            .labelsHidden()

            Button("Edit", action: onEdit)
                .font(.system(size: 11))

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
        }
    }
}

private struct SidecastPersonaEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SidecastPersona
    let onCancel: () -> Void
    let onSave: (SidecastPersona) -> Void

    init(draft: SidecastPersona, onCancel: @escaping () -> Void, onSave: @escaping (SidecastPersona) -> Void) {
        self._draft = State(initialValue: draft)
        self.onCancel = onCancel
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit Persona")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Group {
                        labeledField("Name") {
                            TextField("Persona name", text: $draft.name)
                                .textFieldStyle(.roundedBorder)
                        }

                        labeledField("Subtitle") {
                            TextField("Short descriptor", text: $draft.subtitle)
                                .textFieldStyle(.roundedBorder)
                        }

                        labeledField("Prompt") {
                            TextEditor(text: $draft.prompt)
                                .font(.system(size: 12))
                                .frame(height: 120)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.secondary.opacity(0.2))
                                )
                        }
                    }

                    labeledField("Avatar") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                SidecastSettingsAvatar(persona: draft)
                                VStack(alignment: .leading, spacing: 8) {
                                    TextField("SF Symbol", text: $draft.avatarSymbol)
                                        .textFieldStyle(.roundedBorder)
                                    Picker("Tint", selection: $draft.avatarTint) {
                                        ForEach(PersonaAvatarTint.allCases) { tint in
                                            Text(tint.displayName).tag(tint)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                }
                            }

                            HStack {
                                Text(draft.avatarUsesImage ? draft.avatarImagePath : "No custom image selected")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button("Choose Image") {
                                    chooseAvatarImage()
                                }
                                if draft.avatarUsesImage {
                                    Button("Clear") {
                                        draft.avatarImagePath = ""
                                    }
                                }
                            }
                        }
                    }

                    labeledField("Behavior") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Verbosity", selection: $draft.verbosity) {
                                ForEach(PersonaVerbosity.allCases) { level in
                                    Text(level.displayName).tag(level)
                                }
                            }

                            Picker("Cadence", selection: $draft.cadence) {
                                ForEach(PersonaCadence.allCases) { cadence in
                                    Text(cadence.displayName).tag(cadence)
                                }
                            }

                            Picker("Evidence", selection: $draft.evidencePolicy) {
                                ForEach(PersonaEvidencePolicy.allCases) { policy in
                                    Text(policy.displayName).tag(policy)
                                }
                            }

                            Toggle("Enabled", isOn: $draft.isEnabled)
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(20)
        }
        .frame(width: 520, height: 640)
    }

    @ViewBuilder
    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func chooseAvatarImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .gif, .tiff]
        if panel.runModal() == .OK, let url = panel.url {
            draft.avatarImagePath = url.path
        }
    }
}

private struct SidecastSettingsAvatar: View {
    let persona: SidecastPersona

    var body: some View {
        ZStack {
            Circle()
                .fill(persona.avatarTint.settingsColor.opacity(0.18))
            Circle()
                .stroke(persona.avatarTint.settingsColor.opacity(0.4), lineWidth: 1)

            if let image = avatarImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
                    .padding(3)
            } else {
                Image(systemName: persona.avatarSymbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(persona.avatarTint.settingsColor)
            }
        }
        .frame(width: 30, height: 30)
    }

    private var avatarImage: NSImage? {
        guard persona.avatarUsesImage else { return nil }
        return NSImage(contentsOfFile: persona.avatarImagePath)
    }
}

private extension PersonaAvatarTint {
    var settingsColor: Color {
        switch self {
        case .slate: .gray
        case .blue: .blue
        case .teal: .teal
        case .green: .green
        case .orange: .orange
        case .red: .red
        case .pink: .pink
        case .indigo: .indigo
        }
    }
}
