import AppKit
import SwiftUI

/// Design tokens for the main UI (notes/design.md in the work folder): colours, type, spacing, radii, elevation, motion.
enum Theme {
    // MARK: Colour. HSL per mode; Increase Contrast darkens (light) or brightens (dark) quiet text and lines.
    static let canvas = tone((40, 33, 98.5), (30, 8, 10))
    static let sidebar = tone((38, 24, 95), (30, 7, 13))
    static let raised = tone((38, 20, 91), (30, 6, 18))
    static let line = tone((36, 14, 86), (30, 6, 22), hc: ((30, 8, 60), (30, 6, 55)))
    static let ink = tone((30, 12, 12), (36, 20, 93))
    static let ink2 = tone((30, 7, 34), (34, 8, 72), hc: ((30, 10, 20), (34, 10, 86)))
    static let ink3 = tone((30, 6, 39), (32, 6, 60), hc: ((30, 8, 26), (32, 8, 80)))
    /// Moss: selection, primary actions, You, Processing, the meters.
    static let accent = tone((152, 40, 28), (150, 42, 62), hc: ((152, 50, 20), (150, 50, 74)))
    /// Text and glyphs on an `accent` or `recording` fill.
    static let onFill = tone((0, 0, 100), (30, 8, 10))
    static let them = tone((222, 42, 42), (222, 75, 77), hc: ((222, 50, 32), (222, 80, 85)))
    static let recording = tone((4, 72, 42), (4, 85, 70), hc: ((4, 80, 34), (4, 90, 78)))
    static let attention = tone((30, 90, 30), (38, 90, 62), hc: ((30, 95, 24), (38, 95, 72)))
    static let interrupted = tone((285, 20, 40), (285, 30, 76), hc: ((285, 25, 30), (285, 35, 84)))

    private typealias HSL = (h: Double, s: Double, l: Double)

    private static func tone(_ light: HSL, _ dark: HSL, hc: (HSL, HSL)? = nil) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case .darkAqua: rgb(dark)
            case .accessibilityHighContrastAqua: rgb(hc?.0 ?? light)
            case .accessibilityHighContrastDarkAqua: rgb(hc?.1 ?? dark)
            default: rgb(light)
            }
        })
    }

    private static func rgb(_ c: HSL) -> NSColor {
        let l = c.l / 100, s = c.s / 100, a = s * min(l, 1 - l)
        func f(_ n: Double) -> CGFloat {
            let k = (n + c.h / 30).truncatingRemainder(dividingBy: 12)
            return CGFloat(l - a * max(-1, min(k - 3, 9 - k, 1)))
        }
        return NSColor(srgbRed: f(0), green: f(8), blue: f(4), alpha: 1)
    }

    // MARK: Type. 11 · 12 · 13 · 15 · 17 · 22 · 28. UI in SF Pro, titles in New York, times in SF Mono / Rounded.
    static let caption = Font.system(size: 11)
    static let eyebrow = Font.system(size: 11, weight: .semibold)
    static let meta = Font.system(size: 12)
    static let ui = Font.system(size: 13)
    static let uiStrong = Font.system(size: 13, weight: .semibold)
    static let reading = Font.system(size: 15)
    static let heading = Font.system(size: 17, weight: .semibold, design: .serif)
    static let display = Font.system(size: 22, weight: .semibold, design: .serif)
    static let title = Font.system(size: 28, weight: .semibold, design: .serif)
    static let clock = Font.system(size: 28, weight: .medium, design: .rounded).monospacedDigit()
    static let mono = Font.system(size: 11, design: .monospaced)

    // MARK: Space 4 · 8 · 12 · 16 · 24 · 32 · 48 · 64. Radii 6 · 10 · 14 (continuous).
    static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16
    static let s5: CGFloat = 24, s6: CGFloat = 32, s7: CGFloat = 48, s8: CGFloat = 64
    static let r1: CGFloat = 6, r2: CGFloat = 10, r3: CGFloat = 14
    /// The reading measure of a Meeting file (about 70 characters at 15 pt).
    static let measure: CGFloat = 640

    // MARK: Motion. Springs are interruptible; with Reduce Motion everything becomes a short cross-fade.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Selection, hover-sized changes, buttons.
    static var snappy: Animation { reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.28, dampingFraction: 0.86) }
    /// Layout: list insertion, state changes, panel sections.
    static var gentle: Animation { reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.88) }
    /// Confirmation: a check landing, Start/Stop.
    static var lively: Animation { reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.36, dampingFraction: 0.68) }
    static let fade = Animation.easeOut(duration: 0.12)
    /// Appear from slightly below, or just fade.
    static var rise: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)).combined(with: .scale(scale: 0.98, anchor: .top))
    }
}

extension View {
    /// Elevation: 1 = resting card, 2 = floating (drop target, popovers).
    func elevation(_ level: Int) -> some View {
        shadow(color: .black.opacity(level == 1 ? 0.05 : 0.14), radius: level == 1 ? 1.5 : 16, y: level == 1 ? 1 : 8)
    }

    /// A tinted rounded card: banners, chips, the Notes block.
    func card(_ tint: Color, radius: CGFloat = Theme.r3, fill: Double = 0.1) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(tint.opacity(fill)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(tint.opacity(0.18), lineWidth: 1))
    }
}

/// Filled pill (`tint` fill) or quiet pill (tinted wash) with hover and pressed states.
struct PillButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent
    var filled = true
    var wide = false

    func makeBody(configuration: Configuration) -> some View { Pill(configuration: configuration, style: self) }

    private struct Pill: View {
        let configuration: ButtonStyleConfiguration
        let style: PillButtonStyle
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            configuration.label
                .font(Theme.uiStrong)
                .foregroundStyle(style.filled ? Theme.onFill : style.tint)
                .padding(.horizontal, Theme.s4).frame(height: 32)
                .frame(maxWidth: style.wide ? .infinity : nil)
                .background(Capsule().fill(style.tint.opacity(style.filled ? (hover ? 0.9 : 1) : (hover ? 0.18 : 0.12))))
                .brightness(configuration.isPressed ? -0.06 : 0)
                .scaleEffect(configuration.isPressed && !Theme.reduceMotion ? 0.97 : 1)
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Capsule())
                .onHover { hover = $0 && enabled }
                .animation(Theme.fade, value: hover)
                .animation(Theme.snappy, value: configuration.isPressed)
        }
    }
}

/// A full-width menu row or a square icon button: a quiet wash on hover, deeper when pressed.
struct QuietButtonStyle: ButtonStyle {
    var square = false

    func makeBody(configuration: Configuration) -> some View { Quiet(configuration: configuration, square: square) }

    private struct Quiet: View {
        let configuration: ButtonStyleConfiguration
        let square: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            configuration.label
                .font(Theme.ui)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, square ? 0 : Theme.s2)
                .frame(width: square ? 28 : nil, height: 28)
                .frame(maxWidth: square ? nil : .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.r1, style: .continuous)
                    .fill(Theme.ink.opacity(configuration.isPressed ? 0.1 : hover ? 0.06 : 0)))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { hover = $0 && enabled }
                .animation(Theme.fade, value: hover)
        }
    }
}
