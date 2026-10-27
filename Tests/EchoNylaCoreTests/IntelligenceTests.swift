import Foundation
import XCTest
@testable import EchoNylaCore

/// The checks around Apple Intelligence. The model itself only runs on a Mac; these tests feed in
/// stand-in answers.
final class IntelligenceTests: XCTestCase {
    private let folders = [
        Destination(id: "bills", name: "Bills", purpose: "Utility and phone bills"),
        Destination(id: "taxes", name: "Taxes", purpose: "  IRS forms\n and tax returns "),
        Destination(id: "shots", name: "Screenshots", purpose: "Screenshots"),
        Destination(id: "work", name: "Work Projects", purpose: "Client project files"),
        Destination(id: "csv", name: "CSV", purpose: "   ")
    ]

    func testFolderAnswerMustBeExactlyOneOfYourFolders() {
        XCTAssertEqual(DecisionCheck.destination(for: "Bills", destinations: folders, locked: [])?.id, "bills")
        XCTAssertEqual(DecisionCheck.destination(for: " \"work projects\". ", destinations: folders, locked: [])?.id, "work")
        XCTAssertNil(DecisionCheck.destination(for: "Receipts", destinations: folders, locked: []))
        XCTAssertNil(DecisionCheck.destination(for: "none", destinations: folders, locked: []))
        XCTAssertNil(DecisionCheck.destination(for: "Bills, Taxes", destinations: folders, locked: []))
        // A folder a rule reserves can't be chosen by Apple Intelligence.
        XCTAssertNil(DecisionCheck.destination(for: "Bills", destinations: folders, locked: ["bills"]))
        // A folder without a note is never chosen by Apple Intelligence.
        XCTAssertNil(DecisionCheck.destination(for: "CSV", destinations: folders, locked: []))
    }

    func testOnlyDescribedFoldersCanBeChosen() {
        XCTAssertEqual(folders[1].purpose, "IRS forms and tax returns")
        XCTAssertNil(folders[4].purpose)
        XCTAssertNil(Destination.cleanPurpose(nil))
        XCTAssertEqual(Destination.cleanPurpose(String(repeating: "a", count: 250))?.count, 200)
        XCTAssertEqual(AIFolders.choosable(folders, locked: ["shots"]).map(\.id), ["bills", "taxes", "work"])
        let undescribed = [Destination(id: "school", name: "School"), Destination(id: "csv", name: "CSV")]
        XCTAssertEqual(AIFolders.choosable(undescribed, locked: []), [])
        let paper = DecisionCheck.check(folder: "School", confidence: "high", reason: "A research paper.", betterName: "", summary: "",
                                        fileName: "paper.pdf", destinations: undescribed, locked: [])
        XCTAssertNil(paper.destinationID)
        XCTAssertFalse(paper.isConfident)
        let prompt = DecisionPrompt.make(facts: FileFacts(fileName: "paper.pdf"), destinations: undescribed, locked: [], examples: [])
        XCTAssertTrue(prompt.contains("There are no folders to choose from. Answer none for the folder."))
        XCTAssertFalse(prompt.contains("School"))
    }

    func testDecisionIsConfidentOnlyWithAFolderAndHighConfidence() {
        let sure = DecisionCheck.check(folder: "Taxes", confidence: "high", reason: "  A 2025 IRS\nform. ", betterName: "2025 tax return",
                                       summary: "A tax return.", fileName: "scan0042.pdf", destinations: folders, locked: [])
        XCTAssertEqual(sure.destinationID, "taxes")
        XCTAssertTrue(sure.isConfident)
        XCTAssertEqual(sure.reason, "A 2025 IRS form.")
        XCTAssertEqual(sure.proposedName, "2025 tax return.pdf")
        let unsure = DecisionCheck.check(folder: "Taxes", confidence: "low", reason: "", betterName: "", summary: "",
                                         fileName: "a.pdf", destinations: folders, locked: [])
        // A guess is not a suggestion.
        XCTAssertNil(unsure.destinationID)
        XCTAssertFalse(unsure.isConfident)
        XCTAssertEqual(unsure.reason, "Apple Intelligence's best match.")
        XCTAssertNil(unsure.proposedName)
        let noFolder = DecisionCheck.check(folder: "Elsewhere", confidence: "high", reason: "x", betterName: "", summary: "",
                                           fileName: "a.pdf", destinations: folders, locked: [])
        XCTAssertNil(noFolder.destinationID)
        XCTAssertFalse(noFolder.isConfident)
    }

    func testRenamesKeepTheExtensionAndRejectBadNames() {
        let cases: [(String, String, String?)] = [
            ("document (3).pdf", "Lease renewal", "Lease renewal.pdf"),
            ("document (3).pdf", "Lease renewal.PDF", "Lease renewal.pdf"),
            ("IMG_4821.jpg", "\"2026-10 Costco receipt\"", "2026-10 Costco receipt.jpg"),
            ("notes.txt", "Q3 plan: draft/v2", "Q3 plan draftv2.txt"),
            ("report.pdf", "report", nil),
            ("scan.pdf", "Document", nil),
            ("scan.pdf", "12345", nil),
            ("scan.pdf", "two\nlines", nil),
            ("scan.pdf", "", nil),
            ("README", "Project readme", "Project readme"),
            ("a.pdf", String(repeating: "x", count: 81), nil)
        ]
        for (original, proposed, expected) in cases {
            XCTAssertEqual(RenameCheck.acceptedName(original: original, proposed: proposed), expected, "\(original) → \(proposed)")
        }
    }

    func testFolderGroupsAreCheckedAndFilesUsedOnce() {
        let groups = GroupCheck.validate([
            (name: "Kitchen remodel", members: [1, 2, 3, 3, 9]),
            (name: "kitchen REMODEL", members: [4, 5, 6]),
            (name: "Taxes/2026", members: [4, 5, 6]),
            (name: "Trip to Denver", members: [2, 4, 5, 6]),
            (name: "x", members: [7, 8])
        ], fileCount: 8, minimumSize: 3)
        XCTAssertEqual(groups, [FolderGroupProposal(name: "Kitchen remodel", indexes: [0, 1, 2]),
                                FolderGroupProposal(name: "Trip to Denver", indexes: [3, 4, 5])])
        // Broad category names are turned down even when the files would otherwise qualify.
        let broadGroups = GroupCheck.validate([
            (name: "School stuff", members: [1, 2, 3]),
            (name: "Financial Documents 2025", members: [1, 2, 3]),
            (name: "Biology 101 lab", members: [1, 2, 3])
        ], fileCount: 3, minimumSize: 3)
        XCTAssertEqual(broadGroups, [FolderGroupProposal(name: "Biology 101 lab", indexes: [0, 1, 2])])
        // With the files' names and text, a group's name has to be in most of its files.
        let texts = ["Screenshot 2026-10-25 at 12.28.31 AM.png", "IMG_4821.HEIC", "Screenshot 2026-10-25 at 12.33.39 AM.png",
                     "Denver hotel.pdf", "Flight confirmation.pdf Denver International Airport", "Rental car.pdf"]
        let named = GroupCheck.validate([
            (name: "allsame", members: [1, 2, 3]),
            (name: "Denver trip 2026", members: [4, 5, 6])
        ], fileCount: 6, minimumSize: 3, memberTexts: texts)
        XCTAssertEqual(named, [FolderGroupProposal(name: "Denver trip 2026", indexes: [3, 4, 5])])
        for broad in ["School", "Research papers", "CSV files", "Tax Docs", "Bank statements 2025", "Work", "Misc."] {
            XCTAssertFalse(GroupCheck.isSpecific(broad), broad)
        }
        for specific in ["Denver trip 2026", "Biology 101 lab", "Kitchen remodel", "Chase statements", "Lease renewal"] {
            XCTAssertTrue(GroupCheck.isSpecific(specific), specific)
        }
        XCTAssertEqual(GroupCheck.validFolderName("  Tax   Docs. "), "Tax Docs")
        XCTAssertNil(GroupCheck.validFolderName(".."))
        XCTAssertNil(GroupCheck.validFolderName("a:b"))
    }

    func testFactsForTheModelHideLongNumbers() {
        let facts = FileFacts(fileName: "statement_4417123412341234.pdf", isScreenshot: false, downloadedFrom: ["chase.com"],
                              text: "Account   4417123412341234\n Balance $1,234.56  due 10/12", imageLabels: [], pageCount: 3)
        XCTAssertEqual(facts.kind, .pdf)
        XCTAssertTrue(facts.hasContentEvidence)
        XCTAssertEqual(facts.promptText(), """
            File name: statement_################.pdf
            Kind: PDF
            Pages: 3
            Downloaded from: chase.com
            Text inside the file (start): Account ################ Balance $1,234.56 due 10/12
            """)
        XCTAssertFalse(FileFacts(fileName: "x.png", isScreenshot: true).hasContentEvidence)
        XCTAssertEqual(TextTools.redactLongNumbers("1234 12345 x9999999"), "1234 ##### x#######")
    }

    func testDownloadSourceHosts() throws {
        XCTAssertEqual(DownloadSource.hosts(fromWhereFroms: ["https://www.chase.com/statements?id=1", "https://chase.com/", "ftp://x.org/a",
                                                             "not a url", "http://Docs.Example.org/a"]),
                       ["chase.com", "docs.example.org"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NylaFacts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("statement.pdf")
        try Data("x".utf8).write(to: file)
        XCTAssertEqual(DownloadSource.hosts(at: file), [])
        let plist = try PropertyListSerialization.data(fromPropertyList: ["https://www.irs.gov/pub/f1040.pdf", "https://www.irs.gov/forms"],
                                                       format: .binary, options: 0)
        let result = plist.withUnsafeBytes { buffer in
            file.path.withCString { path in
                DownloadSource.attributeName.withCString { name in setxattr(path, name, buffer.baseAddress, plist.count, 0, 0) }
            }
        }
        XCTAssertEqual(result, 0)
        XCTAssertEqual(DownloadSource.hosts(at: file), ["irs.gov"])
    }

    func testPromptListsOnlyAllowedFoldersAndYourExamples() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let learning = [
            LearningRecord(fileExtension: "pdf", tokens: ["comcast"], destinationID: "bills", updatedAt: now, sampleName: "Comcast 0042.pdf"),
            LearningRecord(fileExtension: "pdf", tokens: ["w2"], destinationID: "taxes", updatedAt: now.addingTimeInterval(10), sampleName: "W2 2025.pdf"),
            LearningRecord(fileExtension: "png", tokens: [], destinationID: "shots", updatedAt: now.addingTimeInterval(5), sampleName: "Shot 123456.png"),
            LearningRecord(fileExtension: "pdf", tokens: [], destinationID: "gone", updatedAt: now, sampleName: "old.pdf")
        ]
        let csvExample = LearningRecord(fileExtension: "csv", tokens: [], destinationID: "csv", updatedAt: now.addingTimeInterval(20),
                                        sampleName: "export.csv")
        let examples = DecisionPrompt.examples(learning: learning + [csvExample], destinations: folders, locked: ["shots"])
        XCTAssertEqual(examples, ["“W2 2025.pdf” → Taxes", "“Comcast 0042.pdf” → Bills"])
        let prompt = DecisionPrompt.make(facts: FileFacts(fileName: "a.pdf"), destinations: folders, locked: ["shots"], examples: examples)
        XCTAssertTrue(prompt.contains("""
            Folders you may choose (exact name: what goes there):
            - Bills: Utility and phone bills
            - Taxes: IRS forms and tax returns
            - Work Projects: Client project files
            """))
        XCTAssertTrue(prompt.contains("- “W2 2025.pdf” → Taxes"))
        XCTAssertFalse(prompt.contains("Screenshots"))
        XCTAssertFalse(prompt.contains("CSV"))
    }

    func testExamplesSkipNamesThatSayNothingAndTheFileBeingTested() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let learning = [
            LearningRecord(fileExtension: "png", tokens: [], destinationID: "bills", updatedAt: now.addingTimeInterval(30),
                           sampleName: "Screenshot 2026-10-25 at 12.33.39 AM.png"),
            LearningRecord(fileExtension: "heic", tokens: [], destinationID: "bills", updatedAt: now.addingTimeInterval(20), sampleName: "IMG_4821.HEIC"),
            LearningRecord(fileExtension: "pdf", tokens: ["comcast"], destinationID: "bills", updatedAt: now.addingTimeInterval(10),
                           sampleName: "Comcast 0042.pdf"),
            LearningRecord(fileExtension: "pdf", tokens: ["w2"], destinationID: "taxes", updatedAt: now, sampleName: "W2 2025.pdf")
        ]
        XCTAssertEqual(DecisionPrompt.examples(learning: learning, destinations: folders, locked: []),
                       ["“Comcast 0042.pdf” → Bills", "“W2 2025.pdf” → Taxes"])
        // Testing "Comcast 0042 (2).pdf": its own past move is left out, copy mark or not.
        XCTAssertEqual(DecisionPrompt.examples(learning: learning, destinations: folders, locked: [], leavingOut: "Comcast 0042 (2).pdf"),
                       ["“W2 2025.pdf” → Taxes"])
    }
}

final class AutoMoveTests: XCTestCase {
    private func ranked(_ id: String, _ strength: SuggestionStrength) -> RankedSuggestion {
        RankedSuggestion(suggestion: DestinationSuggestion(destinationID: id, reason: "local \(strength.rawValue)"), strength: strength)
    }

    private func ai(_ id: String?, sure: Bool) -> FileDecision {
        FileDecision(destinationID: id, isConfident: sure, reason: "ai reason", proposedName: nil, summary: "")
    }

    func testSureLocalMatchesMoveAndWordingOnlySuggests() {
        XCTAssertEqual(AutoMovePolicy.decide(fileName: "a.pdf", local: ranked("bills", .rule), ai: nil, aiHadContentEvidence: false,
                                             autoMoveEnabled: true, locked: []),
                       .move(destinationID: "bills", reason: "local rule"))
        XCTAssertEqual(AutoMovePolicy.decide(fileName: "a.pdf", local: ranked("bills", .rule), ai: nil, aiHadContentEvidence: false,
                                             autoMoveEnabled: false, locked: []),
                       .suggest(destinationID: "bills", reason: "local rule"))
        XCTAssertEqual(AutoMovePolicy.decide(fileName: "a.pdf", local: ranked("bills", .wording), ai: nil, aiHadContentEvidence: false,
                                             autoMoveEnabled: true, locked: []),
                       .suggest(destinationID: "bills", reason: "local wording"))
    }

    func testAppleIntelligenceMovesOnlyWhenSureAndBacked() {
        func decide(_ local: RankedSuggestion?, _ answer: FileDecision, evidence: Bool, locked: Set<String> = []) -> AutoMoveDecision {
            AutoMovePolicy.decide(fileName: "a.pdf", local: local, ai: answer, aiHadContentEvidence: evidence, autoMoveEnabled: true, locked: locked)
        }
        XCTAssertEqual(decide(nil, ai("taxes", sure: true), evidence: true), .move(destinationID: "taxes", reason: "Apple Intelligence: ai reason"))
        XCTAssertEqual(decide(nil, ai("taxes", sure: true), evidence: false), .suggest(destinationID: "taxes", reason: "ai reason"))
        XCTAssertEqual(decide(nil, ai("taxes", sure: false), evidence: true), .suggest(destinationID: "taxes", reason: "ai reason"))
        XCTAssertEqual(decide(ranked("taxes", .wording), ai("taxes", sure: true), evidence: false),
                       .move(destinationID: "taxes", reason: "Apple Intelligence: ai reason"))
        XCTAssertEqual(decide(ranked("bills", .wording), ai("taxes", sure: true), evidence: true), .suggest(destinationID: "taxes", reason: "ai reason"))
        XCTAssertEqual(decide(nil, ai("taxes", sure: true), evidence: true, locked: ["taxes"]),
                       .suggest(destinationID: nil, reason: "No confident match. Choose a folder."))
        XCTAssertEqual(decide(nil, ai(nil, sure: false), evidence: true), .suggest(destinationID: nil, reason: "No confident match. Choose a folder."))
    }

    func testPartialDownloadsAndInstallersAreLeftAlone() {
        for name in ["movie.mp4.crdownload", "big.zip.download", ".hidden.pdf", "Setup.dmg", "Tool.pkg", "draft.part"] {
            XCTAssertEqual(AutoMovePolicy.decide(fileName: name, local: ranked("bills", .rule), ai: nil, aiHadContentEvidence: true,
                                                 autoMoveEnabled: true, locked: []),
                           .skip(reason: "Partial downloads, hidden files and installers are left alone."), name)
        }
    }

    func testWatcherIgnoresExistingFilesAndWaitsForNewOnesToSettle() {
        var state = FolderWatchState()
        let start = Date(timeIntervalSince1970: 1_000)
        let old = FileSnapshot(path: "/d/old.pdf", size: 10, modified: start)
        XCTAssertEqual(state.update([old], now: start), [])                        // first look = baseline
        let new1 = FileSnapshot(path: "/d/new.pdf", size: 5, modified: start.addingTimeInterval(1))
        XCTAssertEqual(state.update([old, new1], now: start.addingTimeInterval(2)), [])
        let grown = FileSnapshot(path: "/d/new.pdf", size: 50, modified: start.addingTimeInterval(15))
        XCTAssertEqual(state.update([old, grown], now: start.addingTimeInterval(15)), [])   // still changing
        XCTAssertEqual(state.update([old, grown], now: start.addingTimeInterval(34)), [])   // 19 s stable
        XCTAssertEqual(state.update([old, grown], now: start.addingTimeInterval(35)), ["/d/new.pdf"])
        XCTAssertEqual(state.update([old, grown], now: start.addingTimeInterval(90)), [])   // reported once
        // A file that leaves and comes back counts as new again.
        XCTAssertEqual(state.update([old], now: start.addingTimeInterval(91)), [])
        XCTAssertEqual(state.update([old, grown], now: start.addingTimeInterval(92)), [])
        XCTAssertEqual(state.update([old, grown], now: start.addingTimeInterval(112)), ["/d/new.pdf"])
        // Something EchoNyla renamed itself is marked handled.
        let renamed = FileSnapshot(path: "/d/Lease.pdf", size: 50, modified: start)
        XCTAssertEqual(state.update([old, renamed], now: start.addingTimeInterval(113)), [])
        state.markHandled("/d/Lease.pdf")
        XCTAssertEqual(state.update([old, renamed], now: start.addingTimeInterval(200)), [])
    }

    func testActivityKeepsNewestFirstAndReplacesOldSuggestions() {
        let first = ActivityEntry(kind: .suggested, fileName: "a.pdf", detail: "1", filePath: "/d/a.pdf")
        let second = ActivityEntry(kind: .autoMoved, fileName: "b.pdf", detail: "2", filePath: "/x/b.pdf")
        let again = ActivityEntry(kind: .suggested, fileName: "a.pdf", detail: "3", filePath: "/d/a.pdf")
        var list = ActivityEntry.adding(first, to: [])
        list = ActivityEntry.adding(second, to: list)
        list = ActivityEntry.adding(again, to: list)
        XCTAssertEqual(list.map(\.detail), ["3", "2"])
        XCTAssertEqual(ActivityEntry.adding(first, to: list, limit: 2).count, 2)
    }

    func testRankedSuggestionsReportTheirStrength() {
        let folders = [Destination(id: "bills", name: "Bills"), Destination(id: "shots", name: "Screenshots")]
        let rule = DestinationRule(name: "Invoices", extensions: ["pdf"], keywords: ["invoice"], destinationID: "bills")
        XCTAssertEqual(SuggestionEngine.suggestRanked(fileName: "invoice-12.pdf", destinations: folders, rules: [rule], learning: [])?.strength, .rule)
        XCTAssertEqual(SuggestionEngine.suggestRanked(fileName: "Screenshot 2026-10-12 at 9.41.03 PM.png", destinations: folders, rules: [],
                                                      learning: [])?.strength, .screenshot)
        XCTAssertEqual(SuggestionEngine.suggestRanked(fileName: "march-bill.pdf", destinations: folders, rules: [], learning: [])?.strength, .wording)
        XCTAssertEqual(SuggestionEngine.ruleLockedDestinationIDs(rules: [rule], destinations: folders), ["bills"])
        XCTAssertEqual(SuggestionEngine.suggest(fileName: "invoice-12.pdf", destinations: folders, rules: [rule], learning: [])?.destinationID, "bills")
    }
}

final class SearchAndRenameTests: XCTestCase {
    func testSpotlightQueryFromARequest() {
        let request = FileSearchRequest(words: ["Dentist", "x", "\"cleaning*\""], kinds: [.pdf], fromDay: "2026-09-01", toDay: "2026-09-31",
                                        source: "Delta Dental")
        XCTAssertEqual(SpotlightQuery.make(request),
                       "(kMDItemDisplayName == \"*dentist*\"cd || kMDItemTextContent == \"dentist*\"cdw)"
                       + " && (kMDItemDisplayName == \"*cleaning*\"cd || kMDItemTextContent == \"cleaning*\"cdw)"
                       + " && (kMDItemContentTypeTree == \"com.adobe.pdf\")"
                       + " && kMDItemContentModificationDate >= $time.iso(2026-09-01T00:00:00Z)"
                       + " && kMDItemWhereFroms == \"*delta dental*\"cd")
        XCTAssertNil(SpotlightQuery.make(FileSearchRequest()))
        XCTAssertEqual(SpotlightQuery.make(FileSearchRequest(screenshotsOnly: true)), "kMDItemIsScreenCapture == 1")
        XCTAssertEqual(SpotlightQuery.validDay("2028-02-29"), "2028-02-29")
        XCTAssertNil(SpotlightQuery.validDay("2026-02-29"))
        XCTAssertNil(SpotlightQuery.validDay("last month"))
    }

    func testFallbackSearchUsesTheMeaningfulWords() {
        XCTAssertEqual(SpotlightQuery.fallbackRequest(from: "Find the PDF from the dentist, last month!").words, ["pdf", "dentist", "month"])
        XCTAssertEqual(SpotlightQuery.kinds(from: ["Photos", "pdf", "screenshot", "banana", "image"]), [.image, .pdf])
    }

    func testApprovedRenameUndoes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NylaRename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("document (3).pdf")
        try Data("a".utf8).write(to: original)
        try Data("b".utf8).write(to: folder.appendingPathComponent("Lease renewal.pdf"))
        let mover = FileMoveService()
        let receipt = try mover.rename(original, to: "Lease renewal.pdf")
        XCTAssertEqual(receipt.movedURL.lastPathComponent, "Lease renewal 2.pdf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        try mover.undo(receipt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertThrowsError(try mover.rename(original, to: "a/b.pdf"))
        XCTAssertThrowsError(try mover.rename(original, to: "document (3).pdf"))
    }
}
