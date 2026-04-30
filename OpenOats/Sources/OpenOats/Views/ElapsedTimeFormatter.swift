import Foundation

enum ElapsedTimeFormatter {
    static func compactMinutesSeconds(_ elapsedSeconds: Int) -> String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
