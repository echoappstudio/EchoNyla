import EchoNylaCore
import Foundation
import XCTest

/// 3.6.0: faster big folders, Finder habits, where suggestions come from, and learning from undo and websites.
final class FinderHabitsTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func day(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)!
    }

    // MARK: Listing a folder

    func testLastOpenedIsOnlyAskedForOldFiles() {
        let now = day("2026-11-15")
        XCTAssertFalse(ListingCheck.needsLastOpened(modified: day("2026-10-01"), added: day("2024-01-01"), now: now))
        XCTAssertFalse(ListingCheck.needsLastOpened(modified: day("2024-01-01"), added: day("2026-11-01"), now: now))
        XCTAssertTrue(ListingCheck.needsLastOpened(modified: day("2024-01-01"), added: day("2025-01-01"), now: now))
        XCTAssertFalse(ListingCheck.needsLastOpened(modified: nil, added: nil, now: now))
    }

    func testOnlyPicturesCanBeScreenshots() {
        XCTAssertTrue(ListingCheck.mayBeScreenshot(fileName: "Screenshot 2026-11-15 at 9.00.png"))
        XCTAssertTrue(ListingCheck.mayBeScreenshot(fileName: "photo.HEIC"))
        XCTAssertFalse(ListingCheck.mayBeScreenshot(fileName: "invoice.pdf"))
        XCTAssertFalse(ListingCheck.mayBeScreenshot(fileName: "notes"))
    }

    func testDateGroupsAndAgesNeedNoFormatter() {
        let now = day("2026-11-15")
        XCTAssertEqual(BrowserGroups.dateTitle(day("2026-03-04"), now: now, calendar: calendar), "March")
        XCTAssertEqual(BrowserGroups.dateTitle(day("2025-03-04"), now: now, calendar: calendar), "2025")
        XCTAssertEqual(FolderPeek.ago(day("2026-10-03"), now: now, calendar: calendar), "Oct 3")
        XCTAssertEqual(FolderPeek.ago(day("2024-10-03"), now: now, calendar: calendar), "2024")
        XCTAssertEqual(FolderPeek.ago(day("2026-11-12"), now: now, calendar: calendar), "3 days ago")
    }

    func testOldListItemsStillLoadWithoutTags() {
        XCTAssertEqual(BrowserItem(path: "/tmp/a.pdf").tags, [])
        XCTAssertEqual(BrowserItem(path: "/tmp/a.pdf", tags: ["Red", "Work"]).tags, ["Red", "Work"])
    }

    func testThousandsOfSameSizeFilesAreSortedByFingerprintFirst() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nyla-copies-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var files: [URL] = []
        for index in 0..<1_500 {
            let url = folder.appendingPathComponent(String(format: "file %05d.txt", index))
            try Data(String(format: "content %05d", index).utf8).write(to: url)
            files.append(url)
        }
        let copy = folder.appendingPathComponent("file 00007 copy.txt")
        try Data("content 00007".utf8).write(to: copy)
        let started = Date()
        let groups = ExactCopy.groups(files + [copy])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].map(\.lastPathComponent)), ["file 00007.txt", "file 00007 copy.txt"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "1,500 same-size files must not be compared pairwise")
        XCTAssertTrue(ExactCopy.groups(files, isCancelled: { true }).isEmpty)
    }

    func testHiddenNumbersNeverComeBackInNamesOrDescriptions() {
        XCTAssertTrue(TextTools.hasNumberMask("acme acme #####"))
        XCTAssertFalse(TextTools.hasNumberMask("Invoice #12"))
        XCTAssertEqual(TextTools.removeNumberMasks("acme acme ##### - spreadsheet with sample data"), "acme acme spreadsheet with sample data")
        XCTAssertEqual(TextTools.removeNumberMasks("A bill for account ######## from Acme."), "A bill for account from Acme.")
    }

    // MARK: Finder habits

    func testNewFoldersGetFinderNames() {
        XCTAssertEqual(UniqueName.make("untitled folder", taken: []), "untitled folder")
        XCTAssertEqual(UniqueName.make("untitled folder", taken: ["Untitled Folder"]), "untitled folder 2")
        XCTAssertEqual(UniqueName.make("untitled folder", taken: ["untitled folder", "untitled folder 2"]), "untitled folder 3")
    }

    func testTypingJumpsToTheFirstMatchingName() {
        let items: [(id: String, name: String)] = [("1", "Zebra.pdf"), ("2", "invoice 2.pdf"), ("3", "Invoice 10.pdf"), ("4", "Écoles.txt"), ("5", "apple.png")]
        XCTAssertEqual(TypeSelect.match("inv", in: items), "2")
        XCTAssertEqual(TypeSelect.match("invoice 1", in: items), "3")
        XCTAssertEqual(TypeSelect.match("invoice ", in: items), "2")
        XCTAssertEqual(TypeSelect.match("eco", in: items), "4")
        // Nothing starts with "m": the next name in A to Z order.
        XCTAssertEqual(TypeSelect.match("m", in: items), "1")
        XCTAssertEqual(TypeSelect.match("zz", in: items), "1")
        XCTAssertNil(TypeSelect.match("", in: items))
    }

    func testOnlyNameKeysTypeANameNotSpace() {
        XCTAssertTrue(TypeSelect.types("a"))
        XCTAssertTrue(TypeSelect.types("7"))
        XCTAssertTrue(TypeSelect.types("-"))
        XCTAssertFalse(TypeSelect.types(" "))
        XCTAssertTrue(TypeSelect.types(" ", continuing: true))
        XCTAssertFalse(TypeSelect.types("\u{7f}"))
        XCTAssertFalse(TypeSelect.types("\u{F700}"))
        XCTAssertFalse(TypeSelect.types("ab"))
    }

    func testRenamingSelectsTheNameBeforeTheExtension() {
        XCTAssertEqual(RenameSelection.stemLength(of: "Invoice March.pdf", isFolder: false), 13)
        XCTAssertEqual(RenameSelection.stemLength(of: "archive.tar.gz", isFolder: false), 11)
        XCTAssertEqual(RenameSelection.stemLength(of: "Photos 2026.2", isFolder: true), 13)
        XCTAssertEqual(RenameSelection.stemLength(of: "README", isFolder: false), 6)
        XCTAssertEqual(RenameSelection.stemLength(of: ".gitignore", isFolder: false), 10)
    }

    // MARK: Watching

    func testWatchingChecksOftenOnlyWhileAFileIsSettling() {
        var state = FolderWatchState()
        let start = Date()
        _ = state.update([], now: start)
        XCTAssertFalse(state.isSettling)
        _ = state.update([FileSnapshot(path: "/w/new.pdf", size: 10, modified: start)], now: start)
        XCTAssertTrue(state.isSettling)
        XCTAssertEqual(WatchPace.nextCheck(isSettling: state.isSettling), WatchPace.settling)
        let ready = state.update([FileSnapshot(path: "/w/new.pdf", size: 10, modified: start)], now: start.addingTimeInterval(21))
        XCTAssertEqual(ready, ["/w/new.pdf"])
        XCTAssertFalse(state.isSettling)
        XCTAssertEqual(WatchPace.nextCheck(isSettling: false), WatchPace.quiet)
    }

    // MARK: Where a suggestion came from

    func testEverySuggestionSaysWhereItCameFrom() {
        let destinations = [Destination(id: "acme", name: "Acme", purpose: "Acme bills")]
        let learning = (1...3).map { LearningRecord(fileExtension: "pdf", tokens: ["acme"], destinationID: "acme", sampleName: "Acme \($0).pdf") }
        let ranked = SuggestionEngine.suggestRanked(fileName: "Acme 9.pdf", destinations: destinations, rules: [], learning: learning)
        XCTAssertEqual(ranked?.why.label, "Learned from 3 moves")
        let rule = DestinationRule(name: "Acme", extensions: ["pdf"], destinationID: "acme")
        XCTAssertEqual(SuggestionEngine.suggestRanked(fileName: "x.pdf", destinations: destinations, rules: [rule], learning: [])?.why.label,
                       "Your rule")
        XCTAssertEqual(SuggestionWhy.appleIntelligence(reason: "A bill from Acme", isSure: true).label, "Apple Intelligence")
    }

    func testOldReasonsGetTheirTagBack() {
        XCTAssertEqual(SuggestionWhy.from(reason: "Matches your Receipts rule")?.label, "Your rule")
        XCTAssertEqual(SuggestionWhy.from(reason: "Similar to files you moved before (4 examples)")?.label, "Learned from 4 moves")
        XCTAssertEqual(SuggestionWhy.from(reason: "macOS marks this as a screen capture")?.label, "Screenshot")
        XCTAssertEqual(SuggestionWhy.from(reason: "Matches tax-document wording")?.label, "Name match")
        XCTAssertEqual(SuggestionWhy.from(reason: "Apple Intelligence: a bill")?.label, "Apple Intelligence")
        XCTAssertEqual(SuggestionWhy.from(reason: "Downloaded from acme.com, like 3 files you moved there")?.label, "Learned from 3 moves")
        XCTAssertEqual(SuggestionWhy.from(reason: "Similar to files you moved before (3 examples)" + LearningNo.waitNote)?.label,
                       "Learned from 3 moves")
        XCTAssertNil(SuggestionWhy.from(reason: "Dropped on Receipts"))
        XCTAssertNil(SuggestionWhy.from(reason: "No confident match. Choose a folder."))
    }

    // MARK: Learning from websites

    func testGeneralWebsitesAreNotLearnedFrom() {
        XCTAssertEqual(LearnedHost.usable("billing.acme.com"), "billing.acme.com")
        XCTAssertNil(LearnedHost.usable("mail.google.com"))
        XCTAssertNil(LearnedHost.usable("dl.dropboxusercontent.com"))
        XCTAssertNil(LearnedHost.usable("192.168.1.4"))
        XCTAssertNil(LearnedHost.usable("intranet"))
    }

    func testThreeFilesFromOneWebsiteTeachAFolder() {
        let destinations = [Destination(id: "power", name: "Power", purpose: "Power bills"), Destination(id: "other", name: "Other")]
        let names = ["document.pdf", "document (1).pdf", "statement-8812.pdf"]
        let learning = names.map { LearningRecord(fileExtension: "pdf", tokens: SuggestionEngine.filenameTokens($0), destinationID: "power",
                                                  sampleName: $0, host: "billing.power.example") }
        let ranked = SuggestionEngine.suggestRanked(fileName: "document (2).pdf", destinations: destinations, rules: [], learning: learning,
                                                    sourceHost: "billing.power.example")
        XCTAssertEqual(ranked?.suggestion.destinationID, "power")
        XCTAssertEqual(ranked?.strength, .learned)
        XCTAssertEqual(ranked?.examples, 3)
        // Two files aren't enough, and another website says nothing.
        XCTAssertNil(SuggestionEngine.suggestRanked(fileName: "document (2).pdf", destinations: destinations, rules: [],
                                                   learning: Array(learning.prefix(2)), sourceHost: "billing.power.example"))
        XCTAssertNil(SuggestionEngine.suggestRanked(fileName: "document (2).pdf", destinations: destinations, rules: [], learning: learning,
                                                   sourceHost: "shop.example"))
        // Files from the site went to two folders: no pattern.
        let split = learning + names.map { LearningRecord(fileExtension: "pdf", tokens: [], destinationID: "other", sampleName: "x " + $0,
                                                          host: "billing.power.example") }
        XCTAssertNil(SuggestionEngine.suggestRanked(fileName: "document (2).pdf", destinations: destinations, rules: [], learning: split,
                                                   sourceHost: "billing.power.example"))
    }

    func testLearningSavedBeforeWebsitesStillLoads() throws {
        let json = #"[{"id":"7F1D6D1C-1B2A-4C3D-9E8F-0A1B2C3D4E5F","fileExtension":"pdf","tokens":["acme"],"destinationID":"a","updatedAt":0,"sampleName":"Acme.pdf"}]"#
        let records = try JSONDecoder().decode([LearningRecord].self, from: Data(json.utf8))
        XCTAssertEqual(records.first?.sampleName, "Acme.pdf")
        XCTAssertNil(records.first?.host)
    }

    // MARK: Undo teaches

    func testAnUndoneMoveWaitsForYouNextTime() {
        let no = LearningNo(destinationID: "acme", fileName: "Acme invoice 3.pdf", host: "acme.com")
        let move = AutoMoveDecision.move(destinationID: "acme", reason: "Similar to files you moved before (3 examples)")
        XCTAssertEqual(LearningNo.apply(move, fileName: "Acme invoice 4.pdf", host: nil, nos: [no]),
                       .suggest(destinationID: "acme", reason: "Similar to files you moved before (3 examples)" + LearningNo.waitNote))
        // Same website, different words.
        XCTAssertTrue(LearningNo.holdsBack(fileName: "statement.pdf", host: "acme.com", destinationID: "acme", nos: [no]))
        // Another folder, another type, or nothing in common: still moves.
        XCTAssertEqual(LearningNo.apply(.move(destinationID: "other", reason: "r"), fileName: "Acme invoice 4.pdf", host: nil, nos: [no]),
                       .move(destinationID: "other", reason: "r"))
        XCTAssertFalse(LearningNo.holdsBack(fileName: "Acme invoice 4.png", host: nil, destinationID: "acme", nos: [no]))
        XCTAssertFalse(LearningNo.holdsBack(fileName: "Globex.pdf", host: "globex.com", destinationID: "acme", nos: [no]))
        // Suggestions are left as they are.
        let suggest = AutoMoveDecision.suggest(destinationID: "acme", reason: "r")
        XCTAssertEqual(LearningNo.apply(suggest, fileName: "Acme invoice 4.pdf", host: nil, nos: [no]), suggest)
    }

    func testNosSurviveASaveAndLoad() throws {
        let no = LearningNo(destinationID: "acme", fileName: "Acme invoice.pdf", host: "mail.google.com", date: Date(timeIntervalSince1970: 0))
        XCTAssertNil(no.host, "a general website isn't kept")
        let loaded = try JSONDecoder().decode(LearningNo.self, from: JSONEncoder().encode(no))
        XCTAssertEqual(loaded, no)
    }
}
