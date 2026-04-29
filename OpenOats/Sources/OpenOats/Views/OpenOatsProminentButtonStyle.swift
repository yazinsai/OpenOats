import SwiftUI

struct OpenOatsProminentButtonStyle: ButtonStyle {
    var color: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        ProminentButtonBody(configuration: configuration, color: color)
    }
}

private struct ProminentButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let color: Color

    @Environment(\.controlSize) private var controlSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(backgroundColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(borderColor, lineWidth: 1)
                    )
            )
            .shadow(color: shadowColor, radius: shadowRadius, y: shadowOffsetY)
            .scaleEffect(isEnabled && configuration.isPressed ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isEnabled)
    }

    private var foregroundColor: Color {
        if isEnabled {
            return .white
        }
        return Color.white.opacity(colorScheme == .dark ? 0.78 : 0.88)
    }

    private var backgroundColor: Color {
        if !isEnabled {
            return color.opacity(colorScheme == .dark ? 0.38 : 0.26)
        }
        if configuration.isPressed {
            return color.opacity(colorScheme == .dark ? 0.9 : 0.94)
        }
        return color
    }

    private var borderColor: Color {
        if !isEnabled {
            return Color.white.opacity(colorScheme == .dark ? 0.05 : 0.16)
        }
        return Color.white.opacity(colorScheme == .dark ? 0.14 : 0.18)
    }

    private var shadowColor: Color {
        guard isEnabled else { return .clear }
        return Color.black.opacity(colorScheme == .dark ? 0.18 : 0.08)
    }

    private var shadowRadius: CGFloat {
        isEnabled ? 0.75 : 0
    }

    private var shadowOffsetY: CGFloat {
        isEnabled ? 0.5 : 0
    }

    private var horizontalPadding: CGFloat {
        switch controlSize {
        case .mini:
            return 8
        case .small:
            return 10
        case .large:
            return 14
        case .regular, .extraLarge:
            return 12
        @unknown default:
            return 12
        }
    }

    private var verticalPadding: CGFloat {
        switch controlSize {
        case .mini:
            return 4
        case .small:
            return 6
        case .large:
            return 9
        case .regular, .extraLarge:
            return 7
        @unknown default:
            return 7
        }
    }

    private var cornerRadius: CGFloat {
        switch controlSize {
        case .mini:
            return 6
        case .small:
            return 7
        case .large:
            return 10
        case .regular, .extraLarge:
            return 8
        @unknown default:
            return 8
        }
    }
}
