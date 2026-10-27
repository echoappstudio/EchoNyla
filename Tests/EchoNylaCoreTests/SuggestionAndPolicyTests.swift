import Foundation
import XCTest
@testable import EchoNylaCore

final class SuggestionAndPolicyTests: XCTestCase {
    func testExplicitRuleRoutesInvoicePDFToBills() {
        let destinations = [Destination(id: "bills", name: "Bills")]
        let rules = [DestinationRule(
            name: "Invoices",
            extensions: ["pdf"],
            keywords: ["bill", "invoice"],
            destinationID: "bills"
        )]

        let suggestion = SuggestionEngine.suggest(
            fileName: "March invoice.pdf",
            destinations: destinations,
            rules: rules,
            learning: []
        )

        XCTAssertEqual(suggestion?.destinationID, "bills")
        XCTAssertTrue(suggestion?.reason.localizedCaseInsensitiveContains("rule") == true)
    }

    func testLearningUsesExtensionAndFilenameTokens() {
        let destinations = [Destination(id: "taxes", name: "Taxes")]
        let learning = [
            LearningRecord(fileExtension: "pdf", tokens: ["acme", "invoice", "jan"], destinationID: "taxes", sampleName: "Acme invoice Jan.pdf"),
            LearningRecord(fileExtension: "pdf", tokens: ["acme", "invoice", "feb"], destinationID: "taxes", sampleName: "Acme invoice Feb.pdf"),
            LearningRecord(fileExtension: "pdf", tokens: ["acme", "invoice", "mar"], destinationID: "taxes", sampleName: "Acme invoice Mar.pdf")
        ]

        let suggestion = SuggestionEngine.suggest(
            fileName: "Acme utility April.pdf",
            destinations: destinations,
            rules: [],
            learning: learning
        )

        XCTAssertEqual(suggestion?.destinationID, "taxes")
        XCTAssertTrue(suggestion?.reason.localizedCaseInsensitiveContains("similar") == true)
    }

    func testLearningCountsDistinctMovedFilenamesEvenWhenTheirSubjectTokensMatch() {
        let destination = [Destination(id: "clients", name: "Client Records")]
        let examples = [
            LearningRecord(fileExtension: "pdf", tokens: ["acme"], destinationID: "clients", sampleName: "Acme invoice Jan.pdf"),
            LearningRecord(fileExtension: "pdf", tokens: ["acme"], destinationID: "clients", sampleName: "Acme invoice Feb.pdf"),
            LearningRecord(fileExtension: "pdf", tokens: ["acme"], destinationID: "clients", sampleName: "Acme invoice Mar.pdf")
        ]

        let twoExamples = SuggestionEngine.suggest(
            fileName: "Acme invoice Apr.pdf",
            destinations: destination,
            rules: [],
            learning: Array(examples.prefix(2))
        )
        let threeExamples = SuggestionEngine.suggest(
            fileName: "Acme invoice Apr.pdf",
            destinations: destination,
            rules: [],
            learning: examples
        )

        XCTAssertNil(twoExamples)
        XCTAssertEqual(threeExamples?.destinationID, "clients")
        XCTAssertTrue(threeExamples?.reason.contains("3 examples") == true)
    }

    func testLearningNeedsTheSameWordInThreeFiles() {
        let destination = [Destination(id: "allsame", name: "allsame")]
        let tokens = { (name: String) in SuggestionEngine.filenameTokens(name) }
        let examples = ["Purevo waveform.png", "Verbyn settings.png", "Scout timeline.png"].map {
            LearningRecord(fileExtension: "png", tokens: tokens($0), destinationID: "allsame", sampleName: $0)
        }
        // One word shared with each of three different files isn't a pattern.
        XCTAssertNil(SuggestionEngine.suggest(fileName: "Purevo Verbyn Scout icons.png", destinations: destination, rules: [], learning: examples))
        // Words like "edited", "before" and "after" don't count either.
        let edited = ["Purevo before.png", "Verbyn before.png", "Scout before.png"].map {
            LearningRecord(fileExtension: "png", tokens: tokens($0), destinationID: "allsame", sampleName: $0)
        }
        XCTAssertNil(SuggestionEngine.suggest(fileName: "Kitchen before.png", destinations: destination, rules: [], learning: edited))
        // The same word in three files is.
        let purevo = ["Purevo waveform.png", "Purevo settings.png", "Purevo skins.png"].map {
            LearningRecord(fileExtension: "png", tokens: tokens($0), destinationID: "allsame", sampleName: $0)
        }
        XCTAssertEqual(SuggestionEngine.suggest(fileName: "Purevo export.png", destinations: destination, rules: [], learning: purevo)?
            .destinationID, "allsame")
    }

    func testFilenameScreenshotFallbackIsLimitedToPNG() {
        let destination = [Destination(id: "screenshots", name: "Screenshots")]
        for fileName in ["Screenshot 01.jpg", "Screen Shot 02.heic", "Screenshot 03.pdf"] {
            XCTAssertNil(SuggestionEngine.suggest(fileName: fileName, destinations: destination, rules: [], learning: []))
        }
        XCTAssertEqual(
            SuggestionEngine.suggest(fileName: "Screenshot 04.png", destinations: destination, rules: [], learning: [])?.destinationID,
            "screenshots"
        )
    }

    func testMetadataFlagIdentifiesScreenshotImageWithoutScreenshotFilename() {
        let suggestion = SuggestionEngine.suggest(
            fileName: "capture-2026-04-01.jpg",
            destinations: [Destination(id: "screenshots", name: "Screenshots")],
            rules: [],
            learning: [],
            isScreenCapture: true
        )
        XCTAssertEqual(suggestion?.destinationID, "screenshots")
        XCTAssertEqual(suggestion?.reason, "macOS marks this as a screen capture")
    }

    func testMacScreenshotMetadataMatchesPNGRuleEvenWithoutScreenshotName() {
        let rule = DestinationRule(name: "PNG screenshots", extensions: ["png"], keywords: ["screenshot"], destinationID: "screenshots")
        let suggestion = SuggestionEngine.suggest(
            fileName: "capture-2026-04-01.png",
            destinations: [Destination(id: "screenshots", name: "Screenshots")],
            rules: [rule],
            learning: [],
            isScreenCapture: true
        )
        XCTAssertEqual(suggestion?.destinationID, "screenshots")
        XCTAssertEqual(suggestion?.reason, "Matches your PNG screenshots rule")
    }

    func testBuiltInSuggestionMatchesBillsFolderForInvoicePDF() {
        let suggestion = SuggestionEngine.suggest(
            fileName: "utility-invoice.pdf",
            destinations: [Destination(id: "d1", name: "Bills")],
            rules: [],
            learning: []
        )
        XCTAssertEqual(suggestion?.destinationID, "d1")
    }

    func testPNGOnlyScreenshotRuleDoesNotLeakToOtherImageTypes() {
        let destinations = [Destination(id: "screenshots", name: "Screenshots")]
        let rule = DestinationRule(name: "PNG screenshots", extensions: ["png"], keywords: ["screenshot"], destinationID: "screenshots")

        for fileName in ["Screenshot 01.jpg", "Screenshot 02.heic", "Screenshot 03.webp"] {
            let suggestion = SuggestionEngine.suggest(
                fileName: fileName,
                destinations: destinations,
                rules: [rule],
                learning: [],
                isScreenCapture: true
            )
            XCTAssertNil(suggestion, "A PNG-only Screenshots rule must not suggest \(fileName)")
        }
    }

    func testNonScreenshotPNGDoesNotMatchScreenshotsFolderByTypeAlone() {
        let destinations = [Destination(id: "screenshots", name: "Screenshots")]
        for fileName in ["product-photo.png", "tax-return.pdf", "archive.zip", "vacation.jpg"] {
            XCTAssertNil(SuggestionEngine.suggest(fileName: fileName, destinations: destinations, rules: [], learning: []))
        }
    }

    func testOneLearnedExtensionOrSharedTokenIsNotAConfidentSuggestion() {
        let destinations = [Destination(id: "screenshots", name: "Screenshots")]
        let singleExtensionExample = [LearningRecord(fileExtension: "png", tokens: ["invoice", "acme"], destinationID: "screenshots")]
        let extensionOnly = SuggestionEngine.suggest(
            fileName: "random-photo.png",
            destinations: destinations,
            rules: [],
            learning: singleExtensionExample
        )
        XCTAssertNil(extensionOnly)

        let tokenOnly = SuggestionEngine.suggest(
            fileName: "acme-random.png",
            destinations: destinations,
            rules: [],
            learning: singleExtensionExample
        )
        XCTAssertNil(tokenOnly)
    }

    func testTrashPolicyOnlyAllowsInstalledAppDiskImagesDirectlyInDownloads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let app = applications.appendingPathComponent("Firefox.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let installed = [app]
        let policy = TrashPolicy()

        let eligible = downloads.appendingPathComponent("Firefox 130.dmg")
        let otherDMG = downloads.appendingPathComponent("Unrelated.dmg")
        let outsideDownloads = root.appendingPathComponent("Firefox.dmg")
        let otherType = downloads.appendingPathComponent("Firefox.zip")

        XCTAssertNotNil(policy.suggestion(for: eligible, downloadsFolder: downloads, applicationsFolder: applications, installedApps: installed))
        XCTAssertNil(policy.suggestion(for: otherDMG, downloadsFolder: downloads, applicationsFolder: applications, installedApps: installed))
        XCTAssertNil(policy.suggestion(for: outsideDownloads, downloadsFolder: downloads, applicationsFolder: applications, installedApps: installed))
        XCTAssertNil(policy.suggestion(for: otherType, downloadsFolder: downloads, applicationsFolder: applications, installedApps: installed))

        try FileManager.default.removeItem(at: root)
    }

    func testFolderGroupingDefaultsToFourClearlyRelatedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let threeRelated = [
            root.appendingPathComponent("Acme invoice Jan.pdf"),
            root.appendingPathComponent("Acme invoice Feb.pdf"),
            root.appendingPathComponent("Acme invoice Mar.pdf")
        ]
        let fourRelated = threeRelated + [root.appendingPathComponent("Acme invoice Apr.pdf")]
        for url in fourRelated { try Data().write(to: url) }

        XCTAssertTrue(FolderGrouping.suggest(for: threeRelated).isEmpty)
        XCTAssertEqual(FolderGrouping.suggest(for: fourRelated).first?.files.count, 4)
    }

    func testFolderGroupingHonorsConfiguredMinimum() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = [
            root.appendingPathComponent("Acme invoice Jan.pdf"),
            root.appendingPathComponent("Acme invoice Feb.pdf"),
            root.appendingPathComponent("Acme invoice Mar.pdf")
        ]
        for url in files { try Data().write(to: url) }

        XCTAssertEqual(FolderGrouping.suggest(for: files, minimumGroupSize: 3).first?.files.count, 3)
        XCTAssertTrue(FolderGrouping.suggest(for: files, minimumGroupSize: 4).isEmpty)
    }

    func testFolderGroupingSettingDefaultsPersistsAndClamps() {
        let suiteName = "EchoNylaTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let setting = FolderGroupingSettings(defaults: defaults, key: "minimum-related-files")
        XCTAssertEqual(setting.minimumRelatedFiles, 4)

        setting.minimumRelatedFiles = 6
        XCTAssertEqual(FolderGroupingSettings(defaults: defaults, key: "minimum-related-files").minimumRelatedFiles, 6)

        setting.minimumRelatedFiles = 1
        XCTAssertEqual(setting.minimumRelatedFiles, 2)
        setting.minimumRelatedFiles = 101
        XCTAssertEqual(setting.minimumRelatedFiles, 100)
    }

    func testFolderGroupingRequiresSharedMeaningfulSubjectNotTypeOrDate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let related = [
            root.appendingPathComponent("Acme Invoice Jan.pdf"),
            root.appendingPathComponent("Acme Contract Renewal.docx"),
            root.appendingPathComponent("Acme Receipt Feb.pdf")
        ]
        let unrelated = [
            root.appendingPathComponent("Northstar brief.pdf"),
            root.appendingPathComponent("Contoso proposal.pdf"),
            root.appendingPathComponent("Northstar annual report.pdf"),
            root.appendingPathComponent("Contoso tax report.docx"),
            root.appendingPathComponent("Project plan.pdf"),
            root.appendingPathComponent("Project notes.docx"),
            root.appendingPathComponent("Screenshot 1.png"),
            root.appendingPathComponent("Screen Shot 2.png")
        ]
        for url in related + unrelated { try Data().write(to: url) }

        let groups = FolderGrouping.suggest(for: related + unrelated, minimumGroupSize: 2)
        XCTAssertEqual(groups.map(\.name), ["Acme", "Contoso", "Northstar"])
        let broad = ["School essay draft.pdf", "School lab sheet.pdf", "Research school notes.pdf", "School research outline.pdf"]
            .map { root.appendingPathComponent($0) }
        XCTAssertEqual(FolderGrouping.suggest(for: broad, minimumGroupSize: 2), [])
        XCTAssertEqual(groups.first?.files.count, 3)
        XCTAssertTrue(groups[0].files.allSatisfy { related.contains($0) })
        XCTAssertFalse(groups.map(\.name).contains("Project"))
        XCTAssertFalse(groups.map(\.name).contains("Report"))
        XCTAssertTrue(groups[0].reason.contains("Acme"))
        var editable = groups[0]
        editable.name = "Acme invoices"
        XCTAssertEqual(editable.name, "Acme invoices")

        try FileManager.default.removeItem(at: root)
    }
}
