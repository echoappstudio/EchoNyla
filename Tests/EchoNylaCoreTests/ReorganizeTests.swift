import XCTest
@testable import EchoNylaCore

final class ReorganizeTests: XCTestCase {
    func testDontTouchFoldersAndTheirInsides() {
        let skip = ["/Users/x/Desktop/Keep", "/Users/x/Documents/Taxes/"]
        XCTAssertTrue(ReorganizeScope.isInside("/Users/x/Desktop/Keep", any: skip))
        XCTAssertTrue(ReorganizeScope.isInside("/Users/x/Desktop/Keep/a.png", any: skip))
        XCTAssertTrue(ReorganizeScope.isInside("/Users/x/Documents/Taxes/2025/w2.pdf", any: skip))
        XCTAssertFalse(ReorganizeScope.isInside("/Users/x/Desktop/Keeper/a.png", any: skip))
        XCTAssertFalse(ReorganizeScope.isInside("/Users/x/Desktop/a.png", any: skip))
    }

    func testTimeLeft() {
        XCTAssertNil(ReorganizeTime.remaining(done: 2, total: 70, elapsed: 18))
        XCTAssertEqual(ReorganizeTime.remaining(done: 10, total: 70, elapsed: 90), "About 9 minutes left")
        XCTAssertEqual(ReorganizeTime.remaining(done: 10, total: 610, elapsed: 90), "About 1.5 hours left")
        XCTAssertEqual(ReorganizeTime.remaining(done: 10, total: 11, elapsed: 90), "About a minute left")
        XCTAssertNil(ReorganizeTime.remaining(done: 70, total: 70, elapsed: 600))
    }

    func testNewFoldersComeFromWhatFilesHaveInCommon() {
        let items = [
            (id: "1", text: "A screenshot of the Purevo waveform view. Purevo waveform"),
            (id: "2", text: "Purevo settings window"),
            (id: "3", text: "Purevo Clean audio screen"),
            (id: "4", text: "Kitchen remodel invoice from Acme"),
            (id: "5", text: "Acme quote for kitchen tiles"),
            (id: "6", text: "Acme kitchen photo"),
            (id: "7", text: "A tax return")
        ]
        XCTAssertEqual(ContentGrouping.groups(items), [
            ContentGrouping.Group(name: "Acme kitchen", ids: ["4", "5", "6"]),
            ContentGrouping.Group(name: "Purevo", ids: ["1", "2", "3"])
        ])
        // A subject that already has a folder isn't offered again; neither is a broad word.
        XCTAssertEqual(ContentGrouping.groups(items, existingNames: ["Purevo pics"]).map(\.name), ["Acme kitchen"])
        let invoices = (1...4).map { (id: "\($0)", text: "An invoice") }
        XCTAssertEqual(ContentGrouping.groups(invoices), [])
    }

    func testDuplicatesAreJudgedByContentsNotNames() {
        let files: [(path: String, size: Int64)] = [("/a/Screenshot 1.png", 10), ("/a/Screenshot 1 (2).png", 12),
                                                   ("/b/Beach sunset.png", 30), ("/c/IMG_1.png", 30), ("/c/empty", 0), ("/d/empty", 0)]
        // The two displays' screenshots differ in size, so they're never compared; empty files never count.
        XCTAssertEqual(DuplicateFinder.sameSize(files), [["/b/Beach sunset.png", "/c/IMG_1.png"]])
        let groups = DuplicateFinder.groups([("/b/Beach sunset.png", "h1"), ("/c/IMG_1.png", "h1"), ("/c/Beach sunset 2.png", "h1"),
                                             ("/x.png", "h2")])
        XCTAssertEqual(groups, [["/b/Beach sunset.png", "/c/Beach sunset 2.png", "/c/IMG_1.png"]])
        XCTAssertEqual(DuplicateFinder.keeper(groups[0]), "/b/Beach sunset.png")
        let old = Date(timeIntervalSince1970: 0), new = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(DuplicateFinder.keeper(["/a/Lease.pdf", "/b/Lease.pdf"], modified: ["/a/Lease.pdf": new, "/b/Lease.pdf": old]),
                       "/b/Lease.pdf")
    }

    func testFilesAlreadyLookedAtAreRememberedUntilTheyChange() throws {
        let day = Date(timeIntervalSince1970: 1_793_000_000)
        var reviewed = ReviewedFiles()
        let key = ReviewedFiles.key(path: "/Users/x/Downloads/Acme invoice.pdf", size: 1200, modified: day)
        reviewed.insert(key)
        XCTAssertTrue(reviewed.contains(key))
        // Edited, moved or renamed since: looked at again.
        XCTAssertFalse(reviewed.contains(ReviewedFiles.key(path: "/Users/x/Downloads/Acme invoice.pdf", size: 1300, modified: day)))
        XCTAssertFalse(reviewed.contains(ReviewedFiles.key(path: "/Users/x/Downloads/Acme invoice.pdf", size: 1200,
                                                           modified: day.addingTimeInterval(60))))
        XCTAssertFalse(reviewed.contains(ReviewedFiles.key(path: "/Users/x/Desktop/Acme invoice.pdf", size: 1200, modified: day)))
        // Saved and read back.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("reviewed-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        reviewed.save(to: file)
        XCTAssertEqual(ReviewedFiles.load(from: file), reviewed)
        XCTAssertEqual(ReviewedFiles.load(from: file.appendingPathExtension("missing")).count, 0)
        // The oldest go first past the limit.
        var full = ReviewedFiles()
        for number in 0...ReviewedFiles.limit { full.insert("k\(number)", at: day.addingTimeInterval(Double(number))) }
        XCTAssertEqual(full.count, ReviewedFiles.limit)
        XCTAssertFalse(full.contains("k0"))
        XCTAssertTrue(full.contains("k\(ReviewedFiles.limit)"))
    }

    func testAZipsContentsAreReadFromItsTableOfContents() throws {
        let zip = Self.zip(["newfo/", "newfo/Screenshot 2026-10-25 at 12.33.07 AM (2).png", "__MACOSX/newfo/._x.png",
                            "newfo/2-send-to-hermes-readmes.md", "newfo/.DS_Store"])
        let names = try XCTUnwrap(ZipListing.names(tail: zip, fileSize: Int64(zip.count)))
        XCTAssertEqual(names, ["Screenshot 2026-10-25 at 12.33.07 AM (2).png", "2-send-to-hermes-readmes.md"])
        // Only the end of a big file was read: the table of contents is still in it.
        let padded = Data(repeating: 0, count: 5_000) + Self.zip(["a/b.png"], directoryOffset: 5_000)
        XCTAssertEqual(ZipListing.names(tail: Data(padded.suffix(100)), fileSize: Int64(padded.count)), ["b.png"])
        // The table of contents starts before the part that was read: no answer rather than a wrong one.
        XCTAssertNil(ZipListing.names(tail: Data(padded.suffix(30)), fileSize: Int64(padded.count)))
        XCTAssertNil(ZipListing.names(tail: Data("not a zip at all, just text".utf8), fileSize: 27))
        XCTAssertEqual(ZipListing.summary(names), "2 files inside: Screenshot 2026-10-25 at 12.33.07 AM (2).png, 2-send-to-hermes-readmes.md")
        XCTAssertEqual(ZipListing.summary([]), "An empty archive.")
    }

    /// A zip with no file data: local entries are left out, which the reader never looks at.
    static func zip(_ paths: [String], directoryOffset: Int = 0) -> Data {
        func le16(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)] }
        func le32(_ value: Int) -> [UInt8] { le16(value & 0xFFFF) + le16((value >> 16) & 0xFFFF) }
        var directory: [UInt8] = []
        for path in paths {
            let name = [UInt8](path.utf8)
            directory += [0x50, 0x4B, 0x01, 0x02] + [UInt8](repeating: 0, count: 24)
            directory += le16(name.count) + le16(0) + le16(0) + [UInt8](repeating: 0, count: 12) + name
        }
        var end: [UInt8] = [0x50, 0x4B, 0x05, 0x06, 0, 0, 0, 0]
        end += le16(paths.count) + le16(paths.count) + le32(directory.count) + le32(directoryOffset) + le16(0)
        return Data(directory + end)
    }
}
