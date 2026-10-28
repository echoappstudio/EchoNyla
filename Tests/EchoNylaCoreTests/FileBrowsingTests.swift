import EchoNylaCore
import Foundation
import XCTest

final class FileBrowsingTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func day(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    private func item(_ name: String, folder: Bool = false, size: Int64? = nil, modified: String? = nil, kind: String = "",
                      opened: String? = nil, added: String? = nil, screenshot: Bool = false) -> BrowserItem {
        BrowserItem(path: "/Users/me/Downloads/" + name, isFolder: folder, byteCount: size, modified: modified.map(day),
                    added: added.map(day), lastOpened: opened.map(day), kindText: kind, isScreenshot: screenshot)
    }

    func testFoldersComeFirstThenTheChosenColumn() {
        let items = [item("b.pdf", size: 10), item("Zed", folder: true), item("a.pdf", size: 30), item("Alpha", folder: true)]
        XCTAssertEqual(BrowserSort().sorted(items).map(\.name), ["Alpha", "Zed", "a.pdf", "b.pdf"])
        XCTAssertEqual(BrowserSort(key: .size, ascending: false).sorted(items).map(\.name), ["Alpha", "Zed", "a.pdf", "b.pdf"])
        XCTAssertEqual(BrowserSort(key: .size, ascending: true).sorted(items).map(\.name), ["Alpha", "Zed", "b.pdf", "a.pdf"])
        // Numbers in names sort the way people count.
        XCTAssertEqual(BrowserSort().sorted([item("file 10.txt"), item("file 9.txt")]).map(\.name), ["file 9.txt", "file 10.txt"])
    }

    func testClickingAColumnTurnsTheOrderAround() {
        let byName = BrowserSort()
        XCTAssertEqual(byName.clicking(.name), BrowserSort(key: .name, ascending: false))
        XCTAssertEqual(byName.clicking(.modified), BrowserSort(key: .modified, ascending: false))
        XCTAssertEqual(byName.clicking(.kind), BrowserSort(key: .kind, ascending: true))
    }

    func testNameFilterNeedsEveryWord() {
        XCTAssertTrue(NameFilter.matches("Chase Statement March.pdf", "chase march"))
        XCTAssertTrue(NameFilter.matches("Café menu.pdf", "cafe"))
        XCTAssertFalse(NameFilter.matches("Chase Statement.pdf", "chase april"))
        XCTAssertTrue(NameFilter.matches("anything", "  "))
    }

    func testFilesGroupByWhatTheyAre() {
        XCTAssertEqual(FileCategory.of(name: "Invoice-2291.pdf", isFolder: false, isScreenshot: false), .receipts)
        XCTAssertEqual(FileCategory.of(name: "IMG_4821.jpg", isFolder: false, isScreenshot: false, summary: "A receipt from Target"), .receipts)
        XCTAssertEqual(FileCategory.of(name: "Screenshot 2026-10-27 at 9.41.02 AM.png", isFolder: false, isScreenshot: true), .screenshots)
        XCTAssertEqual(FileCategory.of(name: "Chase Statement March.pdf", isFolder: false, isScreenshot: false), .bankStatements)
        XCTAssertEqual(FileCategory.of(name: "Zoom-6.2.dmg", isFolder: false, isScreenshot: false), .installers)
        XCTAssertEqual(FileCategory.of(name: "New Recording 4.m4a", isFolder: false, isScreenshot: false), .recordings)
        XCTAssertEqual(FileCategory.of(name: "IMG_4821.heic", isFolder: false, isScreenshot: false), .pictures)
        XCTAssertEqual(FileCategory.of(name: "Notes.pdf", isFolder: false, isScreenshot: false), .documents)
        XCTAssertEqual(FileCategory.of(name: "Bills", isFolder: true, isScreenshot: false), .folders)
        // A recording about an order is still a recording.
        XCTAssertEqual(FileCategory.of(name: "order call.m4a", isFolder: false, isScreenshot: false), .recordings)
    }

    func testGroupsByMeaningKindAndDate() {
        let items = [item("receipt.pdf", modified: "2026-10-28 09:00"), item("Photos", folder: true, modified: "2026-10-27 09:00"),
                     item("trip.mov", modified: "2026-10-20 09:00"), item("notes.txt", modified: "2026-03-02 09:00"),
                     item("old.txt", modified: "2024-05-01 09:00")]
        let meaning = BrowserGroups.make(items, by: .meaning)
        XCTAssertEqual(meaning.map(\.title), ["Folders", "Receipts", "Recordings and videos", "Documents"])
        XCTAssertEqual(meaning.last?.items.map(\.name), ["notes.txt", "old.txt"])
        let kinds = BrowserGroups.make(items, by: .kind)
        XCTAssertEqual(kinds.map(\.title), ["Folders", "PDFs", "Videos", "Text"])
        let now = day("2026-10-28 18:00")
        let dates = BrowserGroups.make(items, by: .date, now: now, calendar: calendar)
        XCTAssertEqual(dates.map(\.title), ["Today", "Yesterday", "Previous 30 Days", "March", "2024"])
        XCTAssertEqual(BrowserGroups.make(items, by: .none).first?.items.count, 5)
    }

    func testClutterFlags() {
        let now = day("2026-10-28 12:00")
        let big = item("movie.mov", size: 600_000_000, modified: "2026-10-01 12:00")
        XCTAssertEqual(ClutterCheck.flags(big, isCopy: false, isUsedInstaller: false, now: now), [.large])
        let old = item("old.pdf", size: 10, modified: "2025-01-01 12:00", added: "2025-01-01 12:00")
        XCTAssertEqual(ClutterCheck.flags(old, isCopy: true, isUsedInstaller: false, now: now), [.copy, .untouched])
        // Opened last month: not untouched, however old it is.
        let opened = item("old.pdf", size: 10, modified: "2023-01-01 12:00", opened: "2026-09-30 12:00")
        XCTAssertEqual(ClutterCheck.flags(opened, isCopy: false, isUsedInstaller: true, now: now), [.usedInstaller])
        XCTAssertEqual(ClutterCheck.flags(item("Old", folder: true, modified: "2020-01-01 12:00"), isCopy: false, isUsedInstaller: false, now: now), [])
    }

    func testExactCopiesAreCheckedByteForByte() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("echonyla-copies-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("Report.pdf")
        let copy = folder.appendingPathComponent("Report (1).pdf")
        let sameSizeDifferent = folder.appendingPathComponent("Other.pdf")
        let empty1 = folder.appendingPathComponent("a.txt")
        let empty2 = folder.appendingPathComponent("b.txt")
        var bytes = Data((0..<3_000_000).map { UInt8($0 % 251) })
        try bytes.write(to: original)
        try bytes.write(to: copy)
        bytes[2_999_999] ^= 0xFF
        try bytes.write(to: sameSizeDifferent)
        try Data().write(to: empty1)
        try Data().write(to: empty2)

        XCTAssertTrue(ExactCopy.same(original, copy))
        XCTAssertFalse(ExactCopy.same(original, sameSizeDifferent), "One different byte at the very end")
        XCTAssertFalse(ExactCopy.same(original, original), "A file isn't a copy of itself")
        XCTAssertFalse(ExactCopy.same(empty1, empty2), "Empty files aren't copies")
        let groups = ExactCopy.groups([original, copy, sameSizeDifferent, empty1, empty2])
        XCTAssertEqual(groups.map { $0.map(\.lastPathComponent).sorted() }, [["Report (1).pdf", "Report.pdf"]])
    }

    func testFolderPeekSummaries() {
        let now = day("2026-10-28 12:00")
        XCTAssertEqual(FolderPeek.summary(categories: [], folderCount: 0, newest: nil, now: now, calendar: calendar), "Empty folder")
        let mostlyPDFs: [FileCategory] = Array(repeating: .documents, count: 7) + [.screenshots, .screenshots, .pictures]
        XCTAssertEqual(FolderPeek.summary(categories: mostlyPDFs, folderCount: 2, newest: day("2026-10-28 08:00"), now: now, calendar: calendar),
                       "10 files and 2 folders: mostly documents, newest from today")
        let mixed: [FileCategory] = [.documents, .documents, .screenshots, .screenshots, .pictures]
        XCTAssertEqual(FolderPeek.summary(categories: mixed, folderCount: 0, newest: day("2026-10-25 08:00"), now: now, calendar: calendar),
                       "5 files: mostly documents and screenshots, newest from 3 days ago")
        XCTAssertEqual(FolderPeek.summary(categories: [.receipts], folderCount: 0, newest: day("2026-10-03 08:00"), now: now, calendar: calendar),
                       "1 file: a receipt, newest from Oct 3")
        XCTAssertEqual(FolderPeek.summary(categories: [.pictures, .pictures], folderCount: 0, newest: day("2024-10-03 08:00"), now: now, calendar: calendar),
                       "2 files: all pictures, newest from 2024")
    }

    func testFolderSizeAddsUpEverythingInside() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("echonyla-size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("inner"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(count: 1_000).write(to: folder.appendingPathComponent("a.bin"))
        try Data(count: 2_500).write(to: folder.appendingPathComponent("inner/b.bin"))
        XCTAssertEqual(FolderSize.total(of: folder), 3_500)
        XCTAssertEqual(ByteText.text(3_500), "4 KB")
        XCTAssertEqual(ByteText.text(3_450_000), "3.5 MB")
        XCTAssertEqual(ByteText.text(999), "999 bytes")
        XCTAssertEqual(ByteText.text(1_234_000_000), "1.2 GB")
        XCTAssertEqual(ByteText.text(450_000_000), "450 MB")
    }

    func testBackAndForward() {
        var history = BrowserHistory(start: "/a")
        XCTAssertFalse(history.canGoBack)
        history.visit("/a/b")
        history.visit("/a/b/c")
        history.goBack()
        XCTAssertEqual(history.current, "/a/b")
        XCTAssertTrue(history.canGoForward)
        history.goForward()
        XCTAssertEqual(history.current, "/a/b/c")
        history.goBack()
        history.visit("/x")
        XCTAssertFalse(history.canGoForward, "Going somewhere new clears Forward")
        XCTAssertEqual(history.back, ["/a", "/a/b"])
    }

    func testPathBarStartsAtHome() {
        XCTAssertEqual(PathTrail.steps(to: "/Users/me/Documents/Bills", home: "/Users/me").map(\.name), ["Home", "Documents", "Bills"])
        XCTAssertEqual(PathTrail.steps(to: "/Users/me/Documents/Bills", home: "/Users/me").last?.path, "/Users/me/Documents/Bills")
        XCTAssertEqual(PathTrail.steps(to: "/Volumes/Backup/Photos", home: "/Users/me").map(\.name), ["Computer", "Volumes", "Backup", "Photos"])
        XCTAssertTrue(PathTrail.isInside("/Users/me/Documents/Bills", "/Users/me/Documents"))
        XCTAssertFalse(PathTrail.isInside("/Users/me/Documents2", "/Users/me/Documents"))
    }

    func testSelectingWithShiftAndArrows() {
        let order = ["a", "b", "c", "d"]
        XCTAssertEqual(SelectionRange.between("c", "a", in: order), ["a", "b", "c"])
        XCTAssertEqual(SelectionRange.step(from: "b", by: 1, in: order), "c")
        XCTAssertEqual(SelectionRange.step(from: "d", by: 1, in: order), "d")
        XCTAssertEqual(SelectionRange.step(from: nil, by: 1, in: order), "a")
        XCTAssertEqual(SelectionRange.step(from: nil, by: -1, in: order), "d")
    }

    func testNumberedFoldersAreTheMostUsed() {
        let ids = ["bills", "work", "photos", "school"]
        XCTAssertEqual(QuickSortFolders.pick(ids, uses: ["photos": 5, "school": 2]), ["photos", "school", "bills", "work"])
        XCTAssertEqual(QuickSortFolders.pick(ids, uses: [:], limit: 2), ["bills", "work"])
    }

    func testInsightsKeepTheNewest() {
        var insights = FileInsights()
        for index in 0..<(FileInsights.limit + 5) {
            insights.set(FileInsight(summary: "File \(index)"), for: "key\(index)")
        }
        XCTAssertEqual(insights.count, FileInsights.limit)
        XCTAssertNil(insights.insight(for: "key0"))
        XCTAssertEqual(insights.insight(for: "key\(FileInsights.limit + 4)")?.summary, "File \(FileInsights.limit + 4)")
        XCTAssertEqual(FileInsight(summary: "", speech: String(repeating: "a", count: 900)).speech.count, 601)
    }

    func testHistoryFollowsAFileBack() {
        var history = FileHistory()
        history.record(from: "/Users/me/Downloads/IMG_4821.jpg", to: "/Users/me/Downloads/Whiteboard Q4 budget.jpg")
        history.record(from: "/Users/me/Downloads/Whiteboard Q4 budget.jpg", to: "/Users/me/Work/Whiteboard Q4 budget.jpg")
        history.record(from: "/Users/me/Desktop/other.pdf", to: "/Users/me/.Trash/other.pdf")
        let trail = history.trail(for: "/Users/me/Work/Whiteboard Q4 budget.jpg")
        XCTAssertEqual(trail.map(\.text), ["Moved here from Downloads", "Renamed from IMG_4821.jpg"])
        XCTAssertEqual(history.events.last?.kind, .trashed)
        history.markUndone(from: "/Users/me/Downloads/Whiteboard Q4 budget.jpg", to: "/Users/me/Work/Whiteboard Q4 budget.jpg")
        XCTAssertTrue(history.trail(for: "/Users/me/Work/Whiteboard Q4 budget.jpg").isEmpty)
        XCTAssertEqual(history.trail(for: "/Users/me/Downloads/Whiteboard Q4 budget.jpg").map(\.kind), [.renamed])
    }
}
