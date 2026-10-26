import XCTest
@testable import EchoNylaCore

final class ActivityGroupingTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    /// 2026-10-17 at the given hour, UTC.
    private func date(day: Int, hour: Int) -> Date {
        let components = DateComponents(year: 2026, month: 10, day: day, hour: hour)
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    private func entry(_ name: String, day: Int, hour: Int) -> ActivityEntry {
        ActivityEntry(date: date(day: day, hour: hour), kind: .moved, fileName: name, detail: "", filePath: "/tmp/\(name)")
    }

    func testGroupsByDayWithTodayAndYesterdayHeadings() {
        let entries = [
            entry("a.png", day: 17, hour: 9),
            entry("b.png", day: 17, hour: 8),
            entry("c.png", day: 16, hour: 20),
            entry("d.png", day: 14, hour: 12)
        ]
        let sections = ActivityGrouping.sections(entries, now: date(day: 17, hour: 10), calendar: calendar)

        XCTAssertEqual(sections.map(\.title), ["Today", "Yesterday", "Wednesday, Oct 14"])
        XCTAssertEqual(sections.map { $0.entries.map(\.fileName) }, [["a.png", "b.png"], ["c.png"], ["d.png"]])
    }

    func testEmptyListGivesNoSections() {
        XCTAssertTrue(ActivityGrouping.sections([], now: date(day: 17, hour: 10), calendar: calendar).isEmpty)
    }

    func testDaysKeepTheirFirstAppearanceOrderEvenIfEntriesAreOutOfOrder() {
        let entries = [
            entry("a.png", day: 17, hour: 9),
            entry("b.png", day: 16, hour: 9),
            entry("c.png", day: 17, hour: 7)
        ]
        let sections = ActivityGrouping.sections(entries, now: date(day: 17, hour: 10), calendar: calendar)

        XCTAssertEqual(sections.map(\.title), ["Today", "Yesterday"])
        XCTAssertEqual(sections[0].entries.map(\.fileName), ["a.png", "c.png"])
    }

    func testJustAfterMidnightCountsAsTheNewDay() {
        let entries = [entry("late.png", day: 16, hour: 23), entry("early.png", day: 17, hour: 0)]
        let sections = ActivityGrouping.sections(entries, now: date(day: 17, hour: 0), calendar: calendar)

        XCTAssertEqual(sections.map(\.title), ["Yesterday", "Today"])
    }
}
