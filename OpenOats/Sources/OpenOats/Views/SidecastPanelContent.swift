import AppKit
import SwiftUI

/// Full-height sidecast sidebar with persona cards and bottom controls.
struct SidecastPanelContent: View {
    @Bindable var settings: AppSettings
    let engine: SidecastEngine?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            SidecastHeader(isGenerating: engine?.isGenerating ?? false)

            Divider().opacity(0.3)

            // Persona cards
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(settings.enabledSidecastPersonas) { persona in
                            SidecastPersonaCard(
                                persona: persona,
                                message: engine?.message(for: persona.id),
                                now: timeline.date,
                                lifetime: settings.sidecastIntensity.bubbleLifetimeSeconds
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }

            Spacer(minLength: 0)

            Divider().opacity(0.3)

            // Bottom bar
            SidecastBottomBar(settings: settings)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color(red: 0.08, green: 0.08, blue: 0.12)
                .opacity(0.92)
        )
    }
}

// MARK: - Header

private struct SidecastHeader: View {
    let isGenerating: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))

            Text("AI Enhanced")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)

            Text("LIVE")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(isGenerating ? Color.orange : Color.green)
                )

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)

        Text("Live on-screen commentary from AI personas")
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.45))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
    }
}

// MARK: - Persona Card

private struct SidecastPersonaCard: View {
    let persona: SidecastPersona
    let message: SidecastMessage?
    let now: Date
    let lifetime: TimeInterval

    private var visibleMessage: SidecastMessage? {
        guard let message else { return nil }
        guard now.timeIntervalSince(message.timestamp) <= lifetime else { return nil }
        return message
    }

    private var timeAgoText: String? {
        guard let message = visibleMessage else { return nil }
        let elapsed = Int(now.timeIntervalSince(message.timestamp))
        if elapsed < 5 { return "just now" }
        if elapsed < 60 { return "\(elapsed)s ago" }
        return "\(elapsed / 60)m ago"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Avatar
            personaAvatar
                .frame(width: 56, height: 56)

            // Content
            VStack(alignment: .leading, spacing: 6) {
                // Name + subtitle badge
                HStack(spacing: 8) {
                    Text(persona.name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)

                    Text(persona.subtitle)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(persona.avatarTint.bubbleColor)
                        )
                }

                // Message text
                if let visibleMessage {
                    Text(visibleMessage.text)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(4)
                        .transition(.opacity.combined(with: .move(edge: .top)))

                    // Confidence + time
                    HStack(spacing: 6) {
                        if visibleMessage.confidence >= 0.7 {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 6, height: 6)
                            Text("High confidence")
                                .font(.system(size: 10))
                                .foregroundStyle(.blue.opacity(0.8))
                            Text("·")
                                .foregroundStyle(.white.opacity(0.3))
                        }
                        if let timeAgo = timeAgoText {
                            Spacer()
                            Text(timeAgo)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                } else {
                    Text("Listening…")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.25))
                        .italic()
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(persona.avatarTint.bubbleColor.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(persona.avatarTint.bubbleColor.opacity(0.25), lineWidth: 1)
                )
        )
        .animation(.easeInOut(duration: 0.3), value: visibleMessage?.id)
    }

    private var personaAvatar: some View {
        ZStack {
            Circle()
                .fill(persona.avatarTint.bubbleColor.opacity(0.3))
            Circle()
                .stroke(persona.avatarTint.bubbleColor.opacity(0.5), lineWidth: 2)

            if let image = avatarImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
                    .padding(2)
            } else {
                Image(systemName: persona.avatarSymbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(persona.avatarTint.bubbleColor)
            }
        }
    }

    private var avatarImage: NSImage? {
        guard persona.avatarUsesImage else { return nil }
        return NSImage(contentsOfFile: persona.avatarImagePath)
    }
}

// MARK: - Bottom Bar

private struct SidecastBottomBar: View {
    @Bindable var settings: AppSettings

    var body: some View {
        HStack(spacing: 12) {
            // Intensity picker
            Menu {
                ForEach(SidecastIntensity.allCases) { intensity in
                    Button {
                        settings.sidecastIntensity = intensity
                    } label: {
                        HStack {
                            Text(intensity.displayName)
                            if settings.sidecastIntensity == intensity {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(settings.sidecastIntensity.displayName + " Mix")
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: "chevron.up")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(.white.opacity(0.1))
                        .stroke(.white.opacity(0.15), lineWidth: 1)
                )
            }
            .menuStyle(.borderlessButton)

            Spacer()

            // Persona toggle circles
            HStack(spacing: -4) {
                ForEach(settings.sidecastPersonas.indices, id: \.self) { index in
                    PersonaToggleCircle(
                        persona: settings.sidecastPersonas[index],
                        isEnabled: settings.sidecastPersonas[index].isEnabled,
                        onToggle: {
                            settings.toggleSidecastPersona(at: index)
                        }
                    )
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct PersonaToggleCircle: View {
    let persona: SidecastPersona
    let isEnabled: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            ZStack(alignment: .bottomTrailing) {
                // Avatar
                ZStack {
                    Circle()
                        .fill(persona.avatarTint.bubbleColor.opacity(isEnabled ? 0.6 : 0.15))
                    Circle()
                        .stroke(.white.opacity(isEnabled ? 0.4 : 0.1), lineWidth: 1.5)

                    if let image = avatarImage {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .clipShape(Circle())
                            .padding(2)
                            .opacity(isEnabled ? 1 : 0.35)
                    } else {
                        Image(systemName: persona.avatarSymbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(
                                isEnabled
                                    ? persona.avatarTint.bubbleColor
                                    : .white.opacity(0.2)
                            )
                    }
                }
                .frame(width: 32, height: 32)

                // Check/uncheck badge
                ZStack {
                    Circle()
                        .fill(isEnabled ? Color.blue : Color.red.opacity(0.7))
                    Image(systemName: isEnabled ? "checkmark" : "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 14, height: 14)
                .offset(x: 2, y: 2)
            }
        }
        .buttonStyle(.plain)
        .help(isEnabled ? "Disable \(persona.name)" : "Enable \(persona.name)")
    }

    private var avatarImage: NSImage? {
        guard persona.avatarUsesImage else { return nil }
        return NSImage(contentsOfFile: persona.avatarImagePath)
    }
}

// MARK: - Color extension for bubbles

extension PersonaAvatarTint {
    var bubbleColor: Color {
        switch self {
        case .slate: Color(red: 0.35, green: 0.38, blue: 0.42)
        case .blue: Color(red: 0.22, green: 0.42, blue: 0.72)
        case .teal: Color(red: 0.18, green: 0.52, blue: 0.55)
        case .green: Color(red: 0.22, green: 0.55, blue: 0.32)
        case .orange: Color(red: 0.78, green: 0.48, blue: 0.15)
        case .red: Color(red: 0.72, green: 0.22, blue: 0.22)
        case .pink: Color(red: 0.72, green: 0.28, blue: 0.52)
        case .indigo: Color(red: 0.35, green: 0.28, blue: 0.65)
        }
    }
}
