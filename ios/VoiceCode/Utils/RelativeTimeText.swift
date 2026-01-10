// RelativeTimeText.swift
// Auto-updating relative time display component

import SwiftUI

/// A Text view that displays relative time and auto-updates every 60 seconds.
///
/// Uses TimelineView to periodically re-render, ensuring timestamps like
/// "2 minutes ago" update as time passes without requiring manual refresh.
///
/// Example usage:
/// ```swift
/// RelativeTimeText(session.lastModified)
/// RelativeTimeText(date, font: .body, foregroundColor: .primary)
/// ```
struct RelativeTimeText: View {
    let date: Date
    let font: Font
    let foregroundColor: Color

    init(_ date: Date, font: Font = .caption2, foregroundColor: Color = .secondary) {
        self.date = date
        self.font = font
        self.foregroundColor = foregroundColor
    }

    var body: some View {
        // TimelineView triggers re-render every 60 seconds
        TimelineView(.periodic(from: Date(), by: 60)) { _ in
            Text(date.relativeFormatted())
                .font(font)
                .foregroundColor(foregroundColor)
        }
    }
}

// MARK: - Date Extension for Relative Formatting

extension Date {
    /// Formats a date as a relative time string with custom thresholds.
    ///
    /// - Returns: A human-readable relative time string:
    ///   - "just now" for < 1 minute
    ///   - "X minutes/hours/days ago" for < 7 days
    ///   - "MMM d" for dates in the current year
    ///   - "MMM d, yyyy" for dates in previous years
    func relativeFormatted() -> String {
        let now = Date()
        let interval = now.timeIntervalSince(self)

        // Less than 1 minute
        if interval < 60 {
            return "just now"
        }

        // Less than 7 days: use RelativeDateTimeFormatter
        if interval < 7 * 24 * 60 * 60 {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return formatter.localizedString(for: self, relativeTo: now)
        }

        // 7+ days: use date format
        let calendar = Calendar.current
        let dateFormatter = DateFormatter()

        if calendar.isDate(self, equalTo: now, toGranularity: .year) {
            dateFormatter.dateFormat = "MMM d"
        } else {
            dateFormatter.dateFormat = "MMM d, yyyy"
        }

        return dateFormatter.string(from: self)
    }
}

// MARK: - Preview

struct RelativeTimeText_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: 16) {
            RelativeTimeText(Date())
            RelativeTimeText(Date().addingTimeInterval(-120))  // 2 minutes ago
            RelativeTimeText(Date().addingTimeInterval(-3600)) // 1 hour ago
            RelativeTimeText(Date().addingTimeInterval(-86400 * 3)) // 3 days ago
            RelativeTimeText(Date().addingTimeInterval(-86400 * 30)) // 30 days ago
        }
        .padding()
    }
}
