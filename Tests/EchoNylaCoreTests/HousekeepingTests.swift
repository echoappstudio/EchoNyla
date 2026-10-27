import XCTest
@testable import EchoNylaCore

final class HousekeepingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)
    private let day: TimeInterval = 24 * 3600

    // MARK: Clean Up parts

    func testCleanUpSortsFilesBySureGuessAndNone() {
        XCTAssertEqual(CleanupBucket.of(hasDestination: true, isSure: true), .sure)
        XCTAssertEqual(CleanupBucket.of(hasDestination: true, isSure: false), .guess)
        XCTAssertEqual(CleanupBucket.of(hasDestination: false, isSure: true), .none)
        XCTAssertEqual(CleanupBucket.allCases.map(\.title), ["Sure", "Guesses", "No idea"])
    }

    // MARK: Which folder Clean Up works on

    func testTheMainButtonIsNamedAfterTheFolder() {
        XCTAssertEqual(CleanupFolders.buttonTitle(folderName: "Downloads"), "Clean Downloads")
        XCTAssertEqual(CleanupFolders.buttonTitle(folderName: "Documents"), "Clean Documents")
        XCTAssertEqual(CleanupFolders.buttonTitle(folderName: String(repeating: "a", count: 28)), "Clean " + String(repeating: "a", count: 28))
        XCTAssertEqual(CleanupFolders.buttonTitle(folderName: "Sam's very long project folder name 2026"), "Clean Sam's very long project fol…")
    }

    func testTheFolderYouCleanMovesToTheFrontOnce() {
        let recents = ["/Users/sam/Documents", "/Users/sam/Projects/Trip", "/Users/sam/Downloads"]
        XCTAssertEqual(CleanupFolders.remembering("/Users/sam/Downloads/", in: recents),
                       ["/Users/sam/Downloads", "/Users/sam/Documents", "/Users/sam/Projects/Trip"])
        XCTAssertEqual(CleanupFolders.remembering("/Users/sam/Music", in: []), ["/Users/sam/Music"])
        let many = (1...10).map { "/Users/sam/F\($0)" }
        let kept = CleanupFolders.remembering("/Users/sam/New", in: many)
        XCTAssertEqual(kept.count, CleanupFolders.storedLimit)
        XCTAssertEqual(kept.first, "/Users/sam/New")
        XCTAssertEqual(kept.last, "/Users/sam/F7")
    }

    func testTheMenuListsOtherRecentFoldersButNotTheFixedOnes() {
        let fixed = ["/Users/sam/Downloads", "/Users/sam/Desktop", "/Users/sam/Documents"]
        let recents = ["/Users/sam/Documents", "/Users/sam/A", "/Users/sam/Downloads/", "/Users/sam/B", "/Users/sam/C",
                       "/Users/sam/Desktop", "/Users/sam/D", "/Users/sam/E", "/Users/sam/F"]
        XCTAssertEqual(CleanupFolders.menuFolders(recents: recents, fixed: fixed),
                       ["/Users/sam/A", "/Users/sam/B", "/Users/sam/C", "/Users/sam/D", "/Users/sam/E"])
        XCTAssertEqual(CleanupFolders.menuFolders(recents: [], fixed: fixed), [])
    }

    // MARK: Moves made in Finder

    private func snapshot(_ path: String, _ size: Int64) -> FileSnapshot {
        FileSnapshot(path: path, size: size, modified: now)
    }

    func testAMoveInFinderIsRecognisedByNameAndSize() {
        let gone = snapshot("/Users/sam/Downloads/statement-oct.pdf", 48_000)
        let candidates = [
            FinderMoveMatcher.Candidate(destinationID: "bank", file: snapshot("/Users/sam/Bank/statement-oct.pdf", 48_000)),
            FinderMoveMatcher.Candidate(destinationID: "bank", file: snapshot("/Users/sam/Bank/statement-sep.pdf", 47_000)),
            FinderMoveMatcher.Candidate(destinationID: "home", file: snapshot("/Users/sam/Home/lease.pdf", 48_000))
        ]
        XCTAssertEqual(FinderMoveMatcher.destination(for: gone, among: candidates), "bank")
    }

    func testADifferentSizeOrTwoPossibleFoldersTeachesNothing() {
        let gone = snapshot("/Users/sam/Downloads/notes.txt", 100)
        XCTAssertNil(FinderMoveMatcher.destination(for: gone, among: [
            .init(destinationID: "a", file: snapshot("/Users/sam/A/notes.txt", 101))
        ]))
        XCTAssertNil(FinderMoveMatcher.destination(for: gone, among: [
            .init(destinationID: "a", file: snapshot("/Users/sam/A/notes.txt", 100)),
            .init(destinationID: "b", file: snapshot("/Users/sam/B/notes.txt", 100))
        ]))
        XCTAssertNil(FinderMoveMatcher.destination(for: gone, among: []))
    }

    func testTheWatcherReportsNewFilesThatLeaveButNotOldOnes() {
        var state = FolderWatchState()
        let start = now
        _ = state.update([snapshot("/d/old.pdf", 1)], now: start)                      // baseline
        _ = state.update([snapshot("/d/old.pdf", 1), snapshot("/d/new.pdf", 5)], now: start + 4)
        XCTAssertTrue(state.departed.isEmpty)
        _ = state.update([], now: start + 8)                                            // both gone
        XCTAssertEqual(state.departed.map(\.path), ["/d/new.pdf"])
        XCTAssertEqual(state.departed.first?.size, 5)
        _ = state.update([], now: start + 12)
        XCTAssertTrue(state.departed.isEmpty, "each departure is reported once")
    }

    // MARK: Weekly Downloads reminder

    func testTheReminderNeedsFiveOldFiles() {
        let old = Array(repeating: now - 20 * day, count: 5)
        let fresh = Array(repeating: now - 2 * day, count: 30)
        XCTAssertEqual(TidyReminder.count(addedDates: old + fresh, now: now, lastDismissed: nil, enabled: true), 5)
        XCTAssertNil(TidyReminder.count(addedDates: Array(old.prefix(4)) + fresh, now: now, lastDismissed: nil, enabled: true))
        XCTAssertNil(TidyReminder.count(addedDates: old, now: now, lastDismissed: nil, enabled: false))
    }

    func testDismissingKeepsItAwayForAWeek() {
        let old = Array(repeating: now - 30 * day, count: 9)
        XCTAssertNil(TidyReminder.count(addedDates: old, now: now, lastDismissed: now - 6 * day, enabled: true))
        XCTAssertEqual(TidyReminder.count(addedDates: old, now: now, lastDismissed: now - 7 * day, enabled: true), 9)
        XCTAssertEqual(TidyReminder.message(count: 9), "9 loose files in Downloads are over two weeks old.")
    }

    func testAFileExactlyTwoWeeksOldCounts() {
        let dates = Array(repeating: now - TidyReminder.minimumAge, count: 5)
        XCTAssertEqual(TidyReminder.count(addedDates: dates, now: now, lastDismissed: nil, enabled: true), 5)
    }

    // MARK: Setup helper

    func testSetupOffersUsedSpecificFoldersNewestFirst() {
        let folders = [
            SetupSuggestions.Folder(path: "/D/Taxes", name: "Taxes", fileCount: 12, newestFile: now - 40 * day),
            SetupSuggestions.Folder(path: "/D/Home Papers", name: "Home Papers", fileCount: 6, newestFile: now - 2 * day),
            SetupSuggestions.Folder(path: "/D/Misc", name: "Misc", fileCount: 50, newestFile: now),
            SetupSuggestions.Folder(path: "/D/.git", name: ".git", fileCount: 50, newestFile: now),
            SetupSuggestions.Folder(path: "/D/Two", name: "Two", fileCount: 2, newestFile: now),
            SetupSuggestions.Folder(path: "/D/Travel", name: "Travel", fileCount: 4, newestFile: now - 2 * day),
            SetupSuggestions.Folder(path: "/D/Invoices", name: "Invoices", fileCount: 30, newestFile: now - day)
        ]
        let ranked = SetupSuggestions.rank(folders, existing: ["/D/Invoices"])
        XCTAssertEqual(ranked.map(\.name), ["Home Papers", "Travel", "Taxes"])
        XCTAssertEqual(SetupSuggestions.rank(folders, existing: [], limit: 1).map(\.name), ["Invoices"])
    }

    func testDraftedNotesAreCleanedOrDropped() {
        XCTAssertEqual(SetupSuggestions.cleanNote("  \"Lease, utility bills and renters insurance.\" "), "Lease, utility bills and renters insurance")
        XCTAssertEqual(SetupSuggestions.cleanNote("Note: tax returns\nand W-2 forms"), "tax returns and W-2 forms")
        XCTAssertNil(SetupSuggestions.cleanNote("none"))
        XCTAssertNil(SetupSuggestions.cleanNote(" . "))
        XCTAssertEqual(SetupSuggestions.cleanNote(String(repeating: "a", count: 300))?.count, 120)
    }

    func testTheNotePromptHidesLongNumbers() {
        let prompt = SetupSuggestions.notePrompt(folderName: "Bank", fileNames: ["statement 4417123456.pdf"])
        XCTAssertFalse(prompt.contains("4417123456"))
        XCTAssertTrue(prompt.hasPrefix("Folder: Bank\nFiles in it:\n- statement "))
    }

    // MARK: Panel tiles

    func testTileCaptions() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func entry(_ kind: ActivityEntry.Kind, _ destination: String, _ date: Date, undone: Bool = false) -> ActivityEntry {
            ActivityEntry(date: date, kind: kind, fileName: "f", detail: "", destinationID: destination, filePath: "/f", isUndone: undone)
        }
        let activity = [
            entry(.autoMoved, "shots", now - 60),
            entry(.moved, "shots", now - 120),
            entry(.moved, "bills", now - 3 * day),
            entry(.suggested, "home", now - 30),
            entry(.moved, "travel", now - 60, undone: true)
        ]
        XCTAssertEqual(FolderTileCaption.text(destinationID: "shots", activity: activity, now: now, calendar: calendar), "2 today")
        XCTAssertEqual(FolderTileCaption.text(destinationID: "home", activity: activity, now: now, calendar: calendar), "1 waiting")
        XCTAssertEqual(FolderTileCaption.text(destinationID: "bills", activity: activity, now: now, calendar: calendar), "3 days ago")
        XCTAssertEqual(FolderTileCaption.text(destinationID: "travel", activity: activity, now: now, calendar: calendar), "Drop here")
    }
}
