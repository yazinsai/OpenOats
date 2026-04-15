import SwiftUI

struct CalendarEventSummaryRow: View {
    let event: CalendarEvent
    var badge: String?
    var iconName: String = "calendar"

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 12))
                .foregroundStyle(.tint)
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if let badge {
                        Text(badge.uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }

                    Text(event.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Text(CalendarEventDisplay.timeRange(for: event))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

struct MatchedCalendarEventBanner: View {
    let event: CalendarEvent

    var body: some View {
        HStack {
            CalendarEventSummaryRow(
                event: event,
                badge: "Calendar",
                iconName: event.isOnlineMeeting ? "video.fill" : "calendar.badge.checkmark"
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}

enum CalendarEventDisplay {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .short
        return formatter
    }()

    static func timeRange(for event: CalendarEvent) -> String {
        if Calendar.current.isDate(event.startDate, inSameDayAs: event.endDate) {
            return "\(timeFormatter.string(from: event.startDate)) - \(timeFormatter.string(from: event.endDate))"
        }

        return "\(dateTimeFormatter.string(from: event.startDate)) - \(dateTimeFormatter.string(from: event.endDate))"
    }
}
