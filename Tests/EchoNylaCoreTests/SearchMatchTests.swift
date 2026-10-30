import EchoNylaCore
import Foundation
import XCTest

final class SearchMatchTests: XCTestCase {
    func testTheReasonSaysWhereEachWordWasFound() {
        let insight = FileInsight(summary: "A dentist's invoice for a cleaning.", names: ["Bright Smile Dental"])
        XCTAssertEqual(SearchMatch.reason(words: ["dentist"], name: "Dentist bill.pdf", insight: nil), "Name has “dentist”")
        XCTAssertEqual(SearchMatch.reason(words: ["smile", "cleaning"], name: "scan.pdf", insight: insight),
                       "EchoNyla saw “smile”, “cleaning”")
        // Words in neither came from Spotlight's look at the text.
        XCTAssertEqual(SearchMatch.reason(words: ["bill", "x-ray"], name: "Dentist bill.pdf", insight: nil),
                       "Name has “bill” · Text inside has “x-ray”")
        XCTAssertEqual(SearchMatch.reason(words: [], name: "a.pdf", insight: nil), "")
    }

    func testFilesEchoNylaUnderstoodAreFoundByWhatItSaw() {
        var insights = FileInsights()
        insights.set(FileInsight(summary: "A golden retriever on a beach at sunset."), for: "/Users/me/Pictures/IMG_1.HEIC|100|1")
        insights.set(FileInsight(summary: "A voicemail about the lease.", speech: "Hi Dana, it's about the Denver lease"),
                     for: "/Users/me/Recordings/New Recording 12.m4a|200|2")
        insights.set(FileInsight(summary: "A dog at the park."), for: "/Users/me/Pictures/IMG_2.HEIC|300|3")
        XCTAssertEqual(SearchMatch.insightPaths(words: ["dog"], in: insights), ["/Users/me/Pictures/IMG_2.HEIC"])
        // Every word has to match, and words start matches like Spotlight ("retriev" finds "retriever").
        XCTAssertEqual(SearchMatch.insightPaths(words: ["retriev", "beach"], in: insights), ["/Users/me/Pictures/IMG_1.HEIC"])
        XCTAssertEqual(SearchMatch.insightPaths(words: ["denver", "lease"], in: insights), ["/Users/me/Recordings/New Recording 12.m4a"])
        XCTAssertEqual(SearchMatch.insightPaths(words: ["dog", "beach"], in: insights), [])
        XCTAssertEqual(SearchMatch.insightPaths(words: [], in: insights), [])
    }

    func testThePathComesOutOfTheKey() {
        XCTAssertEqual(SearchMatch.path(fromKey: "/a/b c.pdf|12|34"), "/a/b c.pdf")
        XCTAssertEqual(SearchMatch.path(fromKey: "/a/odd|name.pdf|12|34"), "/a/odd|name.pdf")
        XCTAssertNil(SearchMatch.path(fromKey: "nothing"))
    }

    func testDaysInRange() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_793_000_000)   // 2026-10-26 UTC
        XCTAssertTrue(SpotlightQuery.isInRange(date, from: nil, to: nil, calendar: calendar))
        XCTAssertTrue(SpotlightQuery.isInRange(date, from: "2026-10-01", to: "2026-10-31", calendar: calendar))
        XCTAssertTrue(SpotlightQuery.isInRange(date, from: "2026-10-26", to: "2026-10-26", calendar: calendar))
        XCTAssertFalse(SpotlightQuery.isInRange(date, from: "2026-11-01", to: nil, calendar: calendar))
        XCTAssertFalse(SpotlightQuery.isInRange(nil, from: "2026-10-01", to: nil, calendar: calendar))
    }

    func testFiltersTheSentenceNeverAskedForAreDropped() {
        // The on-device model turned "rocks" into documents from the last two months, hiding every photo.
        let invented = FileSearchRequest(words: ["rocks"], kinds: [.document], fromDay: "2026-09-01", toDay: "2026-10-30")
        XCTAssertEqual(SpotlightQuery.grounded(invented, in: "rocks"), FileSearchRequest(words: ["rocks"]))
        let asked = FileSearchRequest(words: ["tax"], kinds: [.pdf], fromDay: "2026-03-01", toDay: "2026-05-31")
        XCTAssertEqual(SpotlightQuery.grounded(asked, in: "tax PDFs from last spring"), asked)
        XCTAssertEqual(SpotlightQuery.grounded(FileSearchRequest(words: ["beach"], kinds: [.image]), in: "beach jpg"),
                       FileSearchRequest(words: ["beach"], kinds: [.image]))
        XCTAssertEqual(SpotlightQuery.grounded(FileSearchRequest(words: ["lease"], fromDay: "2025-01-01", toDay: "2025-12-31"),
                                               in: "lease 2025"),
                       FileSearchRequest(words: ["lease"], fromDay: "2025-01-01", toDay: "2025-12-31"))
    }

    func testWordsTheModelMadeUpAreDropped() {
        let request = FileSearchRequest(words: ["dog", "vacation", "photograph"])
        XCTAssertEqual(SpotlightQuery.grounded(request, in: "dogs photos").words, ["dog", "photograph"])
        XCTAssertEqual(SpotlightQuery.grounded(FileSearchRequest(source: "chase"), in: "invoice").words, ["invoice"])
        XCTAssertEqual(SpotlightQuery.grounded(FileSearchRequest(words: ["img_41"]), in: "IMG_41").words, ["img_41"])
    }
}
