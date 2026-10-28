import Foundation
import XCTest
@testable import EchoNylaCore

final class FileMoveTests: XCTestCase {
    private func makeSandbox() throws -> (root: URL, source: URL, destination: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoNylaTests-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("Source", isDirectory: true)
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, source, destination)
    }

    func testMoveThenUndoRestoresOriginalFile() throws {
        let box = try makeSandbox()
        let original = box.source.appendingPathComponent("report.pdf")
        try Data("private test content".utf8).write(to: original)
        let mover = FileMoveService()

        let receipt = try mover.move(original, to: box.destination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try Data(contentsOf: receipt.movedURL), Data("private test content".utf8))

        try mover.undo(receipt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.movedURL.path))
    }

    func testMoveUsesUniqueNameInsteadOfOverwriting() throws {
        let box = try makeSandbox()
        let original = box.source.appendingPathComponent("report.pdf")
        try Data("new".utf8).write(to: original)
        try Data("existing".utf8).write(to: box.destination.appendingPathComponent("report.pdf"))

        let receipt = try FileMoveService().move(original, to: box.destination)

        XCTAssertEqual(receipt.movedURL.lastPathComponent, "report 2.pdf")
        XCTAssertEqual(try String(contentsOf: box.destination.appendingPathComponent("report.pdf"), encoding: .utf8), "existing")
        XCTAssertEqual(try String(contentsOf: receipt.movedURL, encoding: .utf8), "new")
    }

    func testMoveRejectsDirectoriesAndUndoWillNotOverwriteOriginal() throws {
        let box = try makeSandbox()
        let folder = box.source.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mover = FileMoveService()
        XCTAssertThrowsError(try mover.move(folder, to: box.destination))

        let original = box.source.appendingPathComponent("notes.txt")
        try Data("source".utf8).write(to: original)
        let receipt = try mover.move(original, to: box.destination)
        try Data("replacement".utf8).write(to: original)
        XCTAssertThrowsError(try mover.undo(receipt))
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "replacement")
    }

    func testFilesAreaMovesRenamesAndCopiesFolders() throws {
        let box = try makeSandbox()
        let folder = box.source.appendingPathComponent("Trip", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("ticket".utf8).write(to: folder.appendingPathComponent("ticket.pdf"))
        let mover = FileMoveService()

        let moved = try mover.move(folder, to: box.destination, allowFolders: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.movedURL.appendingPathComponent("ticket.pdf").path))
        // A folder can't go inside itself.
        let inner = moved.movedURL.appendingPathComponent("Inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        XCTAssertThrowsError(try mover.move(moved.movedURL, to: inner, allowFolders: true)) { error in
            XCTAssertEqual(error as? FileMoveError, .destinationInsideSource)
        }
        let renamed = try mover.rename(moved.movedURL, to: "Trip 2026", allowFolders: true)
        XCTAssertEqual(renamed.movedURL.lastPathComponent, "Trip 2026")
        XCTAssertThrowsError(try mover.rename(renamed.movedURL, to: "Other"), "Folders only with allowFolders")

        let copy = try mover.copy(renamed.movedURL, to: box.source)
        XCTAssertEqual(copy.lastPathComponent, "Trip 2026")
        let second = try mover.copy(renamed.movedURL, to: box.source)
        XCTAssertEqual(second.lastPathComponent, "Trip 2026 2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.movedURL.path), "Copying leaves the original")
        XCTAssertThrowsError(try mover.copy(renamed.movedURL, to: renamed.movedURL.appendingPathComponent("Inner")))

        try mover.undo(renamed)
        try mover.undo(moved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("ticket.pdf").path))
    }

    func testUndoBatchRestoresFilesAndRemovesCreatedFolderWhenEmpty() throws {
        let box = try makeSandbox()
        let cleanup = box.source
        let newFolder = cleanup.appendingPathComponent("Acme", isDirectory: true)
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: false)
        let first = cleanup.appendingPathComponent("Acme invoice.pdf")
        let second = cleanup.appendingPathComponent("Acme contract.docx")
        try Data("invoice".utf8).write(to: first)
        try Data("contract".utf8).write(to: second)

        let mover = FileMoveService()
        let receipts = [try mover.move(first, to: newFolder), try mover.move(second, to: newFolder)]
        let batch = MoveBatchReceipt(moves: receipts, createdFolders: [newFolder])
        try mover.undo(batch)

        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newFolder.path))
    }

    func testUndoBatchKeepsCreatedFolderIfItIsNotEmpty() throws {
        let box = try makeSandbox()
        let newFolder = box.source.appendingPathComponent("Acme", isDirectory: true)
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: false)
        let original = box.source.appendingPathComponent("Acme invoice.pdf")
        try Data("invoice".utf8).write(to: original)
        let mover = FileMoveService()
        let receipt = try mover.move(original, to: newFolder)
        try Data("not ours".utf8).write(to: newFolder.appendingPathComponent("keep.txt"))

        try mover.undo(MoveBatchReceipt(moves: [receipt], createdFolders: [newFolder]))

        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newFolder.appendingPathComponent("keep.txt").path))
    }
}
