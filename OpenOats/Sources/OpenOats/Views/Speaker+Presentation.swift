import SwiftUI

extension Speaker {
    /// Color for this speaker in transcript and notes views.
    var color: Color {
        switch self {
        case .you:
            Color(red: 0.35, green: 0.55, blue: 0.75)    // muted blue
        case .them:
            Color(red: 0.82, green: 0.6, blue: 0.3)      // warm amber
        case .remote(let n):
            Self.remoteColors[(n - 1) % Self.remoteColors.count]
        }
    }

    /// Palette for diarized remote speakers (up to 10 distinct).
    private static let remoteColors: [Color] = [
        Color(red: 0.82, green: 0.6, blue: 0.3),      // warm amber (same as .them for Speaker 1)
        Color(red: 0.6, green: 0.75, blue: 0.45),      // sage green
        Color(red: 0.75, green: 0.5, blue: 0.7),       // muted purple
        Color(red: 0.85, green: 0.5, blue: 0.45),      // soft coral
        Color(red: 0.5, green: 0.7, blue: 0.75),       // teal
        Color(red: 0.7, green: 0.65, blue: 0.4),       // olive gold
        Color(red: 0.6, green: 0.55, blue: 0.8),       // lavender
        Color(red: 0.8, green: 0.55, blue: 0.55),      // dusty rose
        Color(red: 0.45, green: 0.7, blue: 0.6),       // seafoam
        Color(red: 0.75, green: 0.65, blue: 0.55),     // tan
    ]
}
