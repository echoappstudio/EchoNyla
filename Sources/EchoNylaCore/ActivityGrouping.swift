import Foundation

/// One day's worth of activity, with the heading Activity shows above it.
public struct ActivityDaySection: Equatable, Sendable {
    public let title: String
    public let entries: [ActivityEntry]

    public init(title: String, entries: [ActivityEntry]) {
        self.title = title
        self.entries = entries
    }
}

public enum ActivityGrouping {
    /// Groups entries by calendar day, keeping the order they came in (newest first) and the order of
    /// the days. Headings are "Today", "Yesterday", then the weekday and date.
    public static func sections(_ entries: [ActivityEntry], now: Date = Date(), calendar: Calendar = .current) -> [ActivityDaySection] {
        var order: [Date] = []
        var byDay: [Date: [ActivityEntry]] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.date)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(entry)
        }
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        return order.map { day in
            ActivityDaySection(title: heading(for: day, today: today, yesterday: yesterday, calendar: calendar),
                               entries: byDay[day] ?? [])
        }
    }

    static func heading(for day: Date, today: Date, yesterday: Date?, calendar: Calendar) -> String {
        if day == today { return "Today" }
        if let yesterday, day == yesterday { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE, MMM d"
        return formatter.string(from: day)
    }
}
