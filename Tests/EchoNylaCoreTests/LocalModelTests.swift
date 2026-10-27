import XCTest
@testable import EchoNylaCore

final class LocalModelTests: XCTestCase {
    private let sha = String(repeating: "ab", count: 32)

    // MARK: The model files

    func testTheOfficialQ2FileAndItsPictureReaderAreChosen() throws {
        let listing = """
        [{"type":"file","path":"README.md","size":900},
         {"type":"file","path":"Ternary-Bonsai-2-9B-PQ2_0.gguf","size":2400000000,"lfs":{"oid":"\(sha)","size":2400000000}},
         {"type":"file","path":"Ternary-Bonsai-2-9B-PTQ1_0.gguf","size":2000000000,"lfs":{"oid":"\(sha)","size":2000000000}},
         {"type":"file","path":"Ternary-Bonsai-2-9B-Q2_0.gguf","size":2560000000,"lfs":{"oid":"\(sha)","size":2560000000}},
         {"type":"file","path":"Ternary-Bonsai-2-9B-mmproj-F16.gguf","size":1100000000,"lfs":{"oid":"\(sha)","size":1100000000}},
         {"type":"file","path":"Ternary-Bonsai-2-9B-mmproj-Q8_0.gguf","size":620000000,"lfs":{"oid":"\(sha)","size":620000000}}]
        """
        let files = ModelFiles.parseListing(Data(listing.utf8))
        XCTAssertEqual(files.count, 5)   // README has no checksum, so it's left out
        let choice = try XCTUnwrap(ModelFiles.choose(files))
        XCTAssertEqual(choice.model.path, "Ternary-Bonsai-2-9B-Q2_0.gguf")
        XCTAssertEqual(choice.model.size, 2_560_000_000)
        XCTAssertEqual(choice.projector.path, "Ternary-Bonsai-2-9B-mmproj-Q8_0.gguf")
        XCTAssertEqual(choice.model.sha256, sha)
    }

    func testTheGroup64FileWinsOnOlderRepositories() throws {
        let files = [HubFile(path: "M-Q2_0.gguf", size: 1, sha256: sha), HubFile(path: "M-Q2_0_g64.gguf", size: 1, sha256: sha),
                     HubFile(path: "M-mmproj-Q8_0.gguf", size: 1, sha256: sha)]
        XCTAssertEqual(ModelFiles.choose(files)?.model.path, "M-Q2_0_g64.gguf")
        XCTAssertNil(ModelFiles.choose([HubFile(path: "M-PQ2_0.gguf", size: 1, sha256: sha),
                                        HubFile(path: "M-mmproj-Q8_0.gguf", size: 1, sha256: sha)]))
        XCTAssertNil(ModelFiles.choose([HubFile(path: "M-Q2_0.gguf", size: 1, sha256: sha)]))
    }

    func testDownloadAddresses() {
        let spec = LocalModelSpec.bonsai9B
        XCTAssertEqual(spec.listingURL.absoluteString, "https://huggingface.co/api/models/prism-ml/Ternary-Bonsai-2-9B-gguf/tree/main")
        XCTAssertEqual(spec.downloadURL(for: HubFile(path: "Ternary-Bonsai-2-9B-Q2_0.gguf", size: 1, sha256: sha)).absoluteString,
                       "https://huggingface.co/prism-ml/Ternary-Bonsai-2-9B-gguf/resolve/main/Ternary-Bonsai-2-9B-Q2_0.gguf")
    }

    // MARK: The question and the answer

    private let folders = [
        Destination(id: "pics", name: "purevopic", purpose: "Pictures and screen recordings for the Purevo app's website"),
        Destination(id: "bills", name: "Bills", purpose: "Utility bills and invoices for the apartment"),
        Destination(id: "loose", name: "Loose", purpose: nil)
    ]

    func testTheQuestionListsOnlyDescribedFoldersAndThePicture() {
        let facts = FileFacts(fileName: "Screenshot 2026-10-27 at 9.41.02 AM.png", isScreenshot: true, text: "Verbyn Settings Signature")
        let question = LocalPrompt.question(facts: facts, destinations: folders, locked: [], currentFolderName: "Bills", imageMarker: "<__media__>")
        XCTAssertTrue(question.hasPrefix("Picture of the file:\n<__media__>\n"))
        XCTAssertTrue(question.contains("- purevopic: Pictures and screen recordings for the Purevo app's website"))
        XCTAssertTrue(question.contains("- Bills: Utility bills and invoices for the apartment"))
        XCTAssertFalse(question.contains("- Loose"))
        XCTAssertTrue(question.contains("The file is now in the folder \"Bills\"."))
        let chat = LocalPrompt.conversation(question: "Q")
        XCTAssertTrue(chat.hasPrefix("<|im_start|>system\n"))
        XCTAssertTrue(chat.hasSuffix("<|im_start|>user\nQ<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"))
    }

    func testTheGrammarOffersOnlyNoneAndTheFolders() {
        let grammar = LocalPrompt.grammar(folderNames: ["purevopic", "Sam's \"Q\" folder"])
        XCTAssertTrue(grammar.contains(#"folder ::= "\"none\"" | "\"purevopic\"" | "\"Sam's \\\"Q\\\" folder\"""#))
        XCTAssertTrue(grammar.contains(#"score ::= "100" | [1-9] [0-9] | [0-9]"#))
        XCTAssertTrue(grammar.hasPrefix("root ::= \"{\""))
    }

    func testAnswersAreReadAndScoresKeptInRange() throws {
        let text = #"ok {"what_it_is": "An invoice", "name": "Acme invoice", "name_confidence": 140, "folder": "Bills", "note_words": "invoices", "folder_confidence": 90} done"#
        let answer = try XCTUnwrap(LocalAnswer.parse(text))
        XCTAssertEqual(answer.name, "Acme invoice")
        XCTAssertEqual(answer.nameConfidence, 100)
        XCTAssertEqual(answer.folderConfidence, 90)
        XCTAssertNil(LocalAnswer.parse("no json here"))
    }

    // MARK: The safety net

    func testAFolderNeedsATrueQuoteThatDescribesTheFile() {
        let invoice = Evidence(facts: FileFacts(fileName: "scan.pdf", text: "Acme Plumbing INVOICE #2231 Apartment 4B"), description: "A plumbing invoice.")
        let note = "Utility bills and invoices for the apartment"
        XCTAssertTrue(NoteQuoteCheck.passes(quote: "invoices for the apartment", note: note, evidence: invoice))
        // Words that aren't in the note are a made-up quote.
        XCTAssertFalse(NoteQuoteCheck.passes(quote: "plumbing invoices", note: note, evidence: invoice))
        // Only filler quoted.
        XCTAssertFalse(NoteQuoteCheck.passes(quote: "for the", note: note, evidence: invoice))
        // The "2 week notice" mistake: the note's words don't describe the file.
        let notice = Evidence(facts: FileFacts(fileName: "2 week notice.pages", text: "Please accept this letter as my two weeks notice"),
                              description: "A formal two-week resignation notice.")
        XCTAssertFalse(NoteQuoteCheck.passes(quote: "Pictures and screen recordings for the Purevo app's website",
                                             note: "Pictures and screen recordings for the Purevo app's website", evidence: notice))
    }

    func testTheCheckedDecision() {
        let facts = FileFacts(fileName: "Screenshot 2026-10-27 at 9.41.02 AM.png", isScreenshot: true,
                              text: "Purevo Clean audio Before After", imageLabels: ["screenshot"])
        let answer = LocalAnswer(whatItIs: "A screenshot of the Purevo app's Clean audio screen.", name: "Purevo Clean audio screen",
                                 nameConfidence: 88, folder: "purevopic", noteWords: "Purevo app's website", folderConfidence: 91)
        let result = LocalDecisionCheck.check(answer, facts: facts, destinations: folders, locked: [])
        XCTAssertEqual(result.decision.destinationID, "pics")
        XCTAssertTrue(result.decision.isConfident)
        XCTAssertTrue(result.quotePassed)
        XCTAssertEqual(result.decision.proposedName, "2026-10-27 Purevo Clean audio screen.png")
        XCTAssertTrue(result.renameIsSure)
        XCTAssertEqual(result.decision.reason, "Matches \"Purevo app's website\" in purevopic's note.")

        // Below the bar: still a suggestion, not a move.
        var lower = answer
        lower.folderConfidence = 70
        lower.nameConfidence = 60
        let unsure = LocalDecisionCheck.check(lower, facts: facts, destinations: folders, locked: [])
        XCTAssertEqual(unsure.decision.destinationID, "pics")
        XCTAssertFalse(unsure.decision.isConfident)
        XCTAssertFalse(unsure.renameIsSure)
        XCTAssertEqual(unsure.decision.proposedName, "2026-10-27 Purevo Clean audio screen.png")

        // A failed quote drops the folder entirely.
        var wrong = answer
        wrong.noteWords = "utility bills"
        let dropped = LocalDecisionCheck.check(wrong, facts: facts, destinations: folders, locked: [])
        XCTAssertNil(dropped.decision.destinationID)
        XCTAssertEqual(dropped.namedFolderID, "pics")
        XCTAssertFalse(dropped.decision.isConfident)
    }

    // MARK: Renames

    func testUnhelpfulNames() {
        XCTAssertTrue(NameQuality.isUnhelpful("Screenshot 2026-10-27 at 9.41.02 AM.png"))
        XCTAssertTrue(NameQuality.isUnhelpful("IMG_4821.HEIC"))
        XCTAssertTrue(NameQuality.isUnhelpful("Untitled 3.pages"))
        XCTAssertTrue(NameQuality.isUnhelpful("Document (2).docx"))
        XCTAssertTrue(NameQuality.isUnhelpful("a3f9c2e81b7d4c55.pdf"))
        XCTAssertTrue(NameQuality.isUnhelpful("allsame.zip"))
        XCTAssertFalse(NameQuality.isUnhelpful("2 week notice.pages"))
        XCTAssertFalse(NameQuality.isUnhelpful("Acme Plumbing invoice.pdf"))
    }

    func testRenamesMustComeFromTheFile() {
        let withText = Evidence(facts: FileFacts(fileName: "x.png", text: "Verbyn Settings Signature skin"), description: "Verbyn's settings.")
        XCTAssertTrue(RenameGrounding.isGrounded(title: "Verbyn settings - Signature skin", evidence: withText))
        XCTAssertFalse(RenameGrounding.isGrounded(title: "Tax return 2025", evidence: withText))
        // A photo with no text: the model's description must back at least two words.
        let photo = Evidence(facts: FileFacts(fileName: "IMG_1.HEIC"), description: "A golden retriever on a beach at sunset.")
        XCTAssertTrue(RenameGrounding.isGrounded(title: "Golden retriever on the beach", evidence: photo))
        XCTAssertFalse(RenameGrounding.isGrounded(title: "Dog photo", evidence: photo))
        // Image labels count as the file's own words.
        let labelled = Evidence(facts: FileFacts(fileName: "IMG_2.HEIC", imageLabels: ["dog", "beach"]), description: "")
        XCTAssertTrue(RenameGrounding.isGrounded(title: "Dog at the beach", evidence: labelled))
    }

    func testPicturesKeepTheirDateFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let captured = Date(timeIntervalSince1970: 1_793_000_000)   // 2026-10-26 UTC
        XCTAssertEqual(SmartName.make(title: "Verbyn settings - Signature skin", original: "Screenshot 2026-10-27 at 9.41.02 AM.png",
                                      kind: .image, captured: captured, calendar: calendar),
                       "2026-10-27 Verbyn settings - Signature skin.png")
        XCTAssertEqual(SmartName.make(title: "2026-10-27 Golden retriever on the beach", original: "IMG_1.HEIC", kind: .image,
                                      captured: captured, calendar: calendar),
                       "2026-10-26 Golden retriever on the beach.HEIC")
        XCTAssertEqual(SmartName.make(title: "Acme Plumbing invoice", original: "scan.pdf", kind: .pdf, captured: captured, calendar: calendar),
                       "Acme Plumbing invoice.pdf")
        XCTAssertNil(SmartName.make(title: "Screenshot", original: "IMG_1.png", kind: .pdf, captured: nil, calendar: calendar))
    }

    // MARK: Test on My Files

    private func trial(_ expected: String, _ named: String?, _ score: Int, quote: Bool = true) -> ModelTrial {
        ModelTrial(expectedFolderID: expected, namedFolderID: named, folderConfidence: score, quotePassed: quote, seconds: 2)
    }

    func testTheBarIsSetFromYourFiles() {
        // Wrong answers only at 80-84: at bar 85 and above every sure answer is right.
        var trials = (0..<6).map { _ in trial("a", "a", 90) }
        trials += [trial("a", "b", 82), trial("a", "b", 81), trial("b", "b", 75, quote: false)]
        XCTAssertEqual(ModelTest.recommendedBar(trials), 85)
        let summary = ModelTest.summarize(trials, bar: 80)
        XCTAssertEqual(summary.files, 9)
        XCTAssertEqual(summary.right, 7)
        XCTAssertEqual(summary.sure, 8)
        XCTAssertEqual(summary.sureRight, 6)
        XCTAssertEqual(summary.averageSeconds, 2)
        XCTAssertEqual(summary.recommendedBar, 85)
        // Too few sure answers to tell: no recommendation.
        XCTAssertNil(ModelTest.recommendedBar([trial("a", "a", 99)]))
    }

    // MARK: Check This Folder and Undo All

    func testFolderCheckVerdicts() {
        func decision(_ named: String?, confident: Bool) -> LocalDecision {
            LocalDecision(decision: FileDecision(destinationID: named, isConfident: confident, reason: "", proposedName: nil, summary: ""),
                          namedFolderID: named, folderConfidence: confident ? 95 : 50, quotePassed: named != nil, renameIsSure: false)
        }
        XCTAssertEqual(FolderCheck.verdict(currentFolderID: "a", decision: decision("a", confident: true)), .belongs)
        XCTAssertEqual(FolderCheck.verdict(currentFolderID: "a", decision: decision("b", confident: true)), .move(to: "b"))
        XCTAssertEqual(FolderCheck.verdict(currentFolderID: "a", decision: decision("b", confident: false)), .maybe(to: "b"))
        XCTAssertEqual(FolderCheck.verdict(currentFolderID: "a", decision: decision(nil, confident: false)), .fitsNothing)
    }

    func testRunsGroupChangesForUndoAll() {
        let run = UUID()
        let receipt = FileMoveReceipt(originalURL: URL(fileURLWithPath: "/a/x"), movedURL: URL(fileURLWithPath: "/b/x"))
        let activity = [
            ActivityEntry(kind: .renamed, fileName: "x", detail: "", receipt: receipt, filePath: "/b/x", runID: run, runTitle: "Checked Bills"),
            ActivityEntry(kind: .autoMoved, fileName: "y", detail: "", receipt: receipt, filePath: "/b/y", runID: run, runTitle: "Checked Bills"),
            ActivityEntry(kind: .autoMoved, fileName: "z", detail: "", receipt: receipt, filePath: "/b/z", isUndone: true, runID: run),
            ActivityEntry(kind: .moved, fileName: "w", detail: "", receipt: receipt, filePath: "/b/w")
        ]
        let runs = ActivityRuns.summaries(activity)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.title, "Checked Bills")
        XCTAssertEqual(runs.first?.moved, 2)
        XCTAssertEqual(runs.first?.renamed, 1)
        XCTAssertEqual(runs.first?.undoable, 2)
        XCTAssertTrue(ActivityRuns.summaries(activity.map { var e = $0; e.isUndone = true; return e }).isEmpty)
    }

    func testOlderActivityStillLoads() throws {
        // Saved by 3.0.x: no run fields.
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","date":0,"kind":"moved","fileName":"a.pdf","detail":"d","filePath":"/x/a.pdf","isUndone":false}]"#
        let entries = try JSONDecoder().decode([ActivityEntry].self, from: Data(json.utf8))
        XCTAssertEqual(entries.first?.fileName, "a.pdf")
        XCTAssertNil(entries.first?.runID)
        XCTAssertNil(entries.first?.runTitle)
    }
}
