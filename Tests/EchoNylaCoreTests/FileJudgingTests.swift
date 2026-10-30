import XCTest
@testable import EchoNylaCore

final class FileJudgingTests: XCTestCase {
    // MARK: The question and the answer

    private let folders = [
        Destination(id: "pics", name: "purevopic", purpose: "Pictures and screen recordings for the Purevo app's website"),
        Destination(id: "bills", name: "Bills", purpose: "Utility bills and invoices for the apartment"),
        Destination(id: "loose", name: "Loose", purpose: nil)
    ]

    func testTheFoldersAreInTheInstructionsAndTheFileInTheQuestion() {
        let facts = FileFacts(fileName: "Screenshot 2026-10-27 at 9.41.02 AM.png", isScreenshot: true, text: "Verbyn Settings Signature")
        // The folders sit in the instructions, which are the same for every file of a batch.
        let instructions = ModelPrompt.instructions(destinations: folders, locked: [])
        XCTAssertTrue(instructions.hasPrefix(ModelPrompt.rules))
        XCTAssertTrue(instructions.contains("- purevopic: Pictures and screen recordings for the Purevo app's website"))
        XCTAssertTrue(instructions.contains("- Bills: Utility bills and invoices for the apartment"))
        XCTAssertFalse(instructions.contains("- Loose"))
        XCTAssertTrue(ModelPrompt.instructions(destinations: [], locked: []).hasSuffix("answer none for the folder."))
        // The question is only about the file.
        let question = ModelPrompt.question(facts: facts, currentFolderName: "Bills", hasPicture: true)
        XCTAssertTrue(question.hasPrefix("A picture of the file comes after these facts.\n"))
        XCTAssertFalse(question.contains("purevopic"))
        XCTAssertTrue(question.contains("The file is now in the folder \"Bills\"."))
        XCTAssertFalse(ModelPrompt.question(facts: facts, hasPicture: false).contains("picture"))
    }

    func testSpeechNamesAndLanguageReachTheQuestion() {
        let facts = FileFacts(fileName: "New Recording 12.m4a", speech: "Hi Dana, it's about the Denver lease, call me back.",
                              names: ["Dana", "Denver"], language: "Spanish")
        let text = facts.promptText()
        XCTAssertTrue(text.contains("Names in it: Dana, Denver"))
        XCTAssertTrue(text.contains("Language: Spanish"))
        XCTAssertTrue(text.contains("Spoken in the first minute: Hi Dana, it's about the Denver lease, call me back."))
        XCTAssertTrue(facts.hasContentEvidence)
        // A name built from what was said is grounded.
        XCTAssertTrue(RenameGrounding.isGrounded(title: "Denver lease voicemail", evidence: Evidence(facts: facts, description: "")))
    }

    func testDocumentsWithEnoughTextGoWithoutAPicture() {
        let page = String(repeating: "Acme Plumbing invoice for kitchen sink repair. ", count: 10)
        XCTAssertFalse(PictureNeed.wanted(FileFacts(fileName: "invoice.pdf", text: page)))
        XCTAssertFalse(PictureNeed.wanted(FileFacts(fileName: "letter.docx", text: page)))
        XCTAssertTrue(PictureNeed.wanted(FileFacts(fileName: "scan.pdf", text: "12 / 3")))
        XCTAssertTrue(PictureNeed.wanted(FileFacts(fileName: "Screenshot.png", isScreenshot: true, text: page)))
        XCTAssertTrue(PictureNeed.wanted(FileFacts(fileName: "budget.xlsx", text: page)))
        XCTAssertFalse(PictureNeed.wanted(FileFacts(fileName: "budget.csv", text: page)))
        XCTAssertFalse(PictureNeed.wanted(FileFacts(fileName: "notes.txt", text: "")))
    }

    func testScoresAreKeptInRange() {
        let answer = ModelAnswer(whatItIs: "An invoice", name: "Acme invoice", nameConfidence: 140, folder: "Bills", folderConfidence: -5)
        XCTAssertEqual(answer.nameConfidence, 100)
        XCTAssertEqual(answer.folderConfidence, 0)
    }

    // MARK: The safety net

    func testAFolderMustMatchWhatsInTheFileBetterThanAnyOther() {
        func words(_ text: String, _ description: String) -> Set<String> {
            FolderMatch.fileWords(evidence: Evidence(facts: FileFacts(fileName: "x", text: text), description: description), title: "")
        }
        let bills = folders[1], pics = folders[0]
        let invoice = words("Acme Plumbing INVOICE #2231 Apartment 4B", "A plumbing invoice.")
        XCTAssertEqual(FolderMatch.check(named: bills, among: folders, fileWords: invoice),
                       FolderMatch.Result(passes: true, shared: ["apartme", "invoice"]))
        // The "2 week notice" mistake: nothing in a resignation letter is about Purevo's pictures.
        let notice = words("Please accept this letter as my two weeks notice", "A formal two-week resignation notice.")
        XCTAssertEqual(FolderMatch.check(named: pics, among: folders, fileWords: notice), FolderMatch.Result(passes: false, shared: []))
        // Words in every screen description ("app", "window", "showing") don't count.
        let verbyn = words("", "A screenshot of the Verbyn app window showing settings.")
        XCTAssertFalse(FolderMatch.check(named: pics, among: folders, fileWords: verbyn).passes)
        // One word no other folder has is enough; a long word matches a glued folder name ("purevo" in "purevopic").
        let purevo = words("", "Purevo's waveform.")
        XCTAssertTrue(FolderMatch.check(named: pics, among: folders, fileWords: purevo).passes)
        XCTAssertTrue(FolderMatch.check(named: Destination(id: "p", name: "purevopic", purpose: "Shots"), among: [],
                                        fileWords: purevo).passes)
        // Two folders about Purevo tie: not sure, so it waits for you.
        let newfo = Destination(id: "newfo", name: "newfo", purpose: "Purevo screenshots")
        let tie = FolderMatch.check(named: pics, among: folders + [newfo], fileWords: purevo)
        XCTAssertFalse(tie.passes)
        XCTAssertEqual(tie.shared, ["purevo"])
        // Learned words count like the note's.
        let learned = Destination(id: "l", name: "Work", sortsInto: true, learnedWords: ["wavefor", "purevo"])
        XCTAssertTrue(FolderMatch.check(named: learned, among: [learned, pics], fileWords: purevo).passes)
        XCTAssertEqual(FolderMatch.spelled(["purevo", "waveform"], in: "Purevo's waveform"), ["Purevo", "waveform"])
    }

    func testFoldersLearnFromTheirFiles() {
        let samples = ["A screenshot of Purevo's waveform view", "Purevo settings window with Clean audio", "Verbyn window"]
        XCTAssertEqual(FolderProfile.words(samples: samples), ["purevo"])
        // Fewer than three files teach nothing: one file put there once isn't what the folder is for.
        XCTAssertEqual(FolderProfile.words(samples: ["Acme plumbing invoice"]), [])
        XCTAssertEqual(FolderProfile.words(samples: ["Acme plumbing invoice", "Acme plumbing estimate"]), [])
        XCTAssertEqual(Set(FolderProfile.words(samples: ["Acme plumbing invoice", "Acme plumbing estimate", "Water heater manual"])),
                       ["acme", "plumbin"])
        let prompt = FolderProfile.notePrompt(folderName: "purevopic", descriptions: ["Purevo's waveform"])
        XCTAssertTrue(prompt.hasPrefix("These files are in the folder \"purevopic\":\n- Purevo's waveform\n"))
    }

    func testOnlySortIntoFoldersAreChoosable() throws {
        let learnedOnly = Destination(id: "a", name: "A", sortsInto: true, learnedWords: ["purevo"])
        let draggingOnly = Destination(id: "b", name: "B", purpose: "Receipts", sortsInto: false)
        let nothingKnown = Destination(id: "c", name: "C", sortsInto: true)
        XCTAssertEqual(AIFolders.choosable([learnedOnly, draggingOnly, nothingKnown], locked: []).map(\.id), ["a"])
        XCTAssertEqual(AIFolders.line(learnedOnly), "- A: (no note)")
        // Saved before 3.2.0: no sortsInto or learnedWords; a note still means "Sort into this".
        let old = try JSONDecoder().decode(Destination.self, from: Data(#"{"id":"x","name":"Bills","purpose":"Utility bills"}"#.utf8))
        XCTAssertTrue(old.sortsInto)
        XCTAssertEqual(old.learnedWords, [])
    }

    func testTheCheckedDecision() {
        let facts = FileFacts(fileName: "Screenshot 2026-10-27 at 9.41.02 AM.png", isScreenshot: true,
                              text: "Purevo Clean audio Before After", imageLabels: ["screenshot"])
        let answer = ModelAnswer(whatItIs: "A screenshot of the Purevo app's Clean audio screen.", name: "Purevo Clean audio screen",
                                 nameConfidence: 88, folder: "purevopic", folderConfidence: 91)
        let result = ModelDecisionCheck.check(answer, facts: facts, destinations: folders, locked: [])
        XCTAssertEqual(result.decision.destinationID, "pics")
        XCTAssertTrue(result.decision.isConfident)
        XCTAssertTrue(result.matchesFolder)
        XCTAssertEqual(result.decision.proposedName, "2026-10-27 Purevo Clean audio screen.png")
        XCTAssertTrue(result.nameIsSure)
        XCTAssertTrue(result.renamesByItself)
        XCTAssertEqual(result.decision.reason, "Matches Purevo in purevopic.")

        // 75 is sure for a name; an old name that already says something is only renamed when you approve.
        var named = answer
        named.nameConfidence = 75
        let kept = ModelDecisionCheck.check(named, facts: FileFacts(fileName: "Purevo audio notes.png", text: facts.text), destinations: folders, locked: [])
        XCTAssertTrue(kept.nameIsSure)
        XCTAssertFalse(kept.renamesByItself)

        // Below the bar: still a suggestion, not a move.
        var lower = answer
        lower.folderConfidence = 70
        lower.nameConfidence = 60
        let unsure = ModelDecisionCheck.check(lower, facts: facts, destinations: folders, locked: [])
        XCTAssertEqual(unsure.decision.destinationID, "pics")
        XCTAssertFalse(unsure.decision.isConfident)
        XCTAssertFalse(unsure.nameIsSure)
        XCTAssertFalse(unsure.renamesByItself)
        XCTAssertEqual(unsure.decision.proposedName, "2026-10-27 Purevo Clean audio screen.png")
        // Under 50 the name isn't offered at all.
        lower.nameConfidence = 49
        XCTAssertNil(ModelDecisionCheck.check(lower, facts: facts, destinations: folders, locked: []).decision.proposedName)

        // A folder that shares nothing with the file is dropped entirely, however sure the model is.
        var wrong = answer
        wrong.folder = "Bills"
        wrong.folderConfidence = 99
        let dropped = ModelDecisionCheck.check(wrong, facts: facts, destinations: folders, locked: [])
        XCTAssertNil(dropped.decision.destinationID)
        XCTAssertEqual(dropped.namedFolderID, "bills")
        XCTAssertFalse(dropped.decision.isConfident)
        XCTAssertFalse(dropped.matchesFolder)
        XCTAssertEqual(dropped.decision.reason, "No folder fits this file.")
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
        // Names with no word at all can't teach the model where things go.
        XCTAssertTrue(NameQuality.saysNothing("Screenshot 2026-10-25 at 12.33.39 AM (2).png"))
        XCTAssertTrue(NameQuality.saysNothing("IMG_4821.HEIC"))
        XCTAssertTrue(NameQuality.saysNothing("DSC01234.JPG"))
        XCTAssertFalse(NameQuality.saysNothing("W2 2025.pdf"))
        XCTAssertFalse(NameQuality.saysNothing("Comcast 0042.pdf"))
    }

    func testCopiesHaveTheSameName() {
        XCTAssertTrue(NameQuality.isSameName("Screenshot 2026-10-25 at 12.33.39 AM (2).png", "Screenshot 2026-10-25 at 12.33.39 AM.png"))
        XCTAssertTrue(NameQuality.isSameName("Report 2.pdf", "report.PDF"))
        XCTAssertTrue(NameQuality.isSameName("Report copy 3.pdf", "Report.pdf"))
        XCTAssertTrue(NameQuality.isSameName("Report copy (2).pdf", "Report.pdf"))
        XCTAssertFalse(NameQuality.isSameName("Report.pdf", "Report.png"))
        XCTAssertFalse(NameQuality.isSameName("Comcast 0042.pdf", "Comcast.pdf"))
        XCTAssertFalse(NameQuality.isSameName("Invoice 2231.pdf", "Invoice 2232.pdf"))
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

    func testOneMatchingWordDoesNotGroundAName() {
        let invoice = Evidence(facts: FileFacts(fileName: "document (3).pdf", text: "Acme Plumbing Invoice 2231 kitchen sink repair"),
                               description: "")
        XCTAssertTrue(RenameGrounding.isGrounded(title: "Acme Plumbing invoice", evidence: invoice))
        XCTAssertTrue(RenameGrounding.isGrounded(title: "Acme kitchen sink repair estimate", evidence: invoice))
        // The right company with the wrong subject: only one of four words is in the file.
        XCTAssertFalse(RenameGrounding.isGrounded(title: "Acme roofing warranty contract", evidence: invoice))
        // Words every screen description has ("app", "window") don't count either way.
        XCTAssertFalse(RenameGrounding.isGrounded(title: "App window", evidence: invoice))
    }

    func testTheModelIsNotToldToScoreHigh() {
        XCTAssertFalse(ModelPrompt.rules.contains("85 or more"))
        XCTAssertTrue(ModelPrompt.rules.contains("Answer below 50 when the name is a guess"))
    }

    func testNamesAreTidied() {
        let vocabulary = ["purevopic", "Pictures and screen recordings for the Purevo app's website", "Utility bills and invoices"]
        // File names read inside a screenshot lose their extension.
        XCTAssertEqual(SmartName.clean("Congrats (Purevo).wav analysis", vocabulary: vocabulary), "Congrats (Purevo) analysis")
        XCTAssertEqual(SmartName.clean("Purevo interface - Congrats (Purevo).wav", vocabulary: vocabulary), "Purevo interface - Congrats (Purevo)")
        // Slug names become words; video tags go; one-letter misspellings of known words are fixed.
        XCTAssertEqual(SmartName.clean("Purvo-with-hvac-1080p", vocabulary: vocabulary), "Purevo with hvac")
        XCTAssertEqual(SmartName.clean("Pureo fan hvac", vocabulary: vocabulary), "Purevo fan hvac")
        // Real words and plurals are left alone.
        XCTAssertEqual(SmartName.clean("Acme Plumbing invoice", vocabulary: vocabulary), "Acme Plumbing invoice")
        XCTAssertEqual(SmartName.clean("Water bill", vocabulary: vocabulary), "Water bill")
        XCTAssertEqual(SmartName.clean("Purevo Audio Analysis", vocabulary: vocabulary), "Purevo Audio Analysis")
        XCTAssertEqual(SmartName.clean("Verbyn settings - Signature skin"), "Verbyn settings - Signature skin")
        // The checked decision uses the tidied name.
        let facts = FileFacts(fileName: "Screenshot 2026-10-25 at 12.33.33 AM (2).png", isScreenshot: true,
                              text: "Purevo Congrats (Purevo).wav Clean audio")
        let answer = ModelAnswer(whatItIs: "Purevo's window with a file loaded.", name: "Purevo interface - Congrats (Purevo).wav",
                                 nameConfidence: 90, folder: "none", folderConfidence: 0)
        let result = ModelDecisionCheck.check(answer, facts: facts, destinations: folders, locked: [])
        XCTAssertEqual(result.decision.proposedName, "2026-10-25 Purevo interface - Congrats (Purevo).png")
        XCTAssertTrue(result.renamesByItself)
    }

    func testTheQuestionCarriesPastFilingExamples() {
        let facts = FileFacts(fileName: "a.png")
        let question = ModelPrompt.question(facts: facts, examples: ["“Purevo before-after.png” → purevopic"], hasPicture: false)
        XCTAssertTrue(question.contains("How this person filed similar files before:\n- “Purevo before-after.png” → purevopic"))
        XCTAssertFalse(ModelPrompt.question(facts: facts, hasPicture: false).contains("filed similar"))
        XCTAssertEqual(ConfidenceBar.standard, ConfidenceBar(folder: 80, name: 75, nameShown: 50))
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

    func testRecordingsAndDocumentsGetADateToo() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let captured = Date(timeIntervalSince1970: 1_793_000_000)   // 2026-10-26 UTC
        let now = Date(timeIntervalSince1970: 1_793_100_000)
        // A recording sorts by the day it was made, like a photo.
        XCTAssertEqual(SmartName.make(title: "Denver lease voicemail", original: "New Recording 12.m4a", kind: .audio,
                                      captured: captured, calendar: calendar, now: now),
                       "2026-10-26 Denver lease voicemail.m4a")
        // A document gets the month written in it, not the day it was downloaded.
        XCTAssertEqual(SmartName.make(title: "Acme Plumbing invoice", original: "document (3).pdf", kind: .pdf, captured: captured,
                                      text: "ACME PLUMBING\nInvoice 2231\nDate: March 12, 2026\nKitchen sink repair", calendar: calendar, now: now),
                       "2026-03 Acme Plumbing invoice.pdf")
        XCTAssertEqual(SmartName.monthWritten(in: "Statement period 2025-11-01 to 2025-11-30", calendar: calendar, now: now), "2025-11")
        // No year written, or nothing that looks like a date: no date in the name.
        XCTAssertNil(SmartName.monthWritten(in: "See you on March 12 at noon", calendar: calendar, now: now))
        XCTAssertNil(SmartName.monthWritten(in: "Kitchen sink repair, 2 hours", calendar: calendar, now: now))
        // A date years ahead (an expiry, a lease end) isn't the document's date.
        XCTAssertNil(SmartName.monthWritten(in: "Valid until January 1, 2031", calendar: calendar, now: now))
    }

    // MARK: Check This Folder and Undo All

    func testFolderCheckVerdicts() {
        func decision(_ named: String?, confident: Bool) -> ModelDecision {
            ModelDecision(decision: FileDecision(destinationID: named, isConfident: confident, reason: "", proposedName: nil, summary: ""),
                          namedFolderID: named, folderConfidence: confident ? 95 : 50, matchesFolder: named != nil, nameIsSure: false,
                          renamesByItself: false)
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
