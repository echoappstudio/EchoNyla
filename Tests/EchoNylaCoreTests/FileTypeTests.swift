import XCTest
@testable import EchoNylaCore

final class FileTypeTests: XCTestCase {
    func testKnownTypesGetTheirOwnIcons() {
        XCTAssertEqual(FileTypeCatalog.info(forFileName: "Lease.docx"),
                       FileTypeInfo(artwork: .bundled(name: "word", hasLightVersion: false), label: "Word", tag: "DOCX"))
        XCTAssertEqual(FileTypeCatalog.info(forFileName: "invoice-1043.PDF").artwork, .bundled(name: "pdf", hasLightVersion: false))
        XCTAssertEqual(FileTypeCatalog.info(forFileName: "budget.xlsx").label, "Excel")
        XCTAssertEqual(FileTypeCatalog.info(forFileName: "setup.msi").label, "Windows installer")
    }

    func testRelatedTypesShareACategoryIcon() {
        for name in ["a.jpg", "b.heic", "c.png", "d.tiff"] {
            XCTAssertEqual(FileTypeCatalog.info(forFileName: name).artwork, .bundled(name: "image", hasLightVersion: false), name)
        }
        for name in ["a.mp3", "b.m4a", "c.flac"] {
            XCTAssertEqual(FileTypeCatalog.info(forFileName: name).artwork, .bundled(name: "audio", hasLightVersion: false), name)
        }
        for name in ["a.mov", "b.mp4", "c.mkv"] {
            XCTAssertEqual(FileTypeCatalog.info(forFileName: name).artwork, .bundled(name: "video", hasLightVersion: false), name)
        }
        for name in ["a.zip", "b.tar.gz", "c.7z"] {
            XCTAssertEqual(FileTypeCatalog.info(forFileName: name).artwork, .bundled(name: "zip", hasLightVersion: false), name)
        }
    }

    func testPaleIconsHaveALightSkinVersion() {
        XCTAssertEqual(FileTypeCatalog.info(forFileName: "notes.yaml").artwork, .bundled(name: "yaml", hasLightVersion: true))
        XCTAssertEqual(FileTypeCatalog.info(forFileName: "Inter.woff2").artwork, .bundled(name: "font", hasLightVersion: true))
        XCTAssertTrue(FileTypeCatalog.lightVersions.isSubset(of: FileTypeCatalog.bundledIconNames))
    }

    func testMacTypesUseMacOSArtwork() {
        XCTAssertEqual(FileTypeCatalog.info(forFileName: "Report.pages").artwork, .system(.pages))
        XCTAssertEqual(FileTypeCatalog.info(forFileName: "Deck.key").artwork, .system(.keynote))
        XCTAssertEqual(FileTypeCatalog.info(forFileName: "invite.ics").label, "Calendar event")
        XCTAssertEqual(SystemFileArtwork.pages.appBundleIDs, ["com.apple.iWork.Pages"])
        XCTAssertEqual(SystemFileArtwork.macIcon.appBundleIDs, ["com.apple.Preview"])
    }

    func testUnknownTypesShowTheirLetters() {
        XCTAssertEqual(FileTypeCatalog.info(forFileName: "firmware.bin"),
                       FileTypeInfo(artwork: .letters("BIN"), label: "BIN file", tag: "BIN"))
        XCTAssertEqual(FileTypeCatalog.letters(forFileName: "scan.abcdef"), "ABCD")
        XCTAssertEqual(FileTypeCatalog.letters(forFileName: "README"), "RE")
        XCTAssertEqual(FileTypeCatalog.letters(forFileName: "___"), "?")
        let noExtension = FileTypeCatalog.info(forFileName: "Makefile")
        XCTAssertEqual(noExtension.artwork, .letters("MA"))
        XCTAssertNil(noExtension.tag)
        XCTAssertEqual(noExtension.label, "File")
    }

    /// The chosen reference sheet has 100 types; all of them, plus the 9 Mac types, are covered.
    func testTheReferenceSheetIsCovered() {
        let sheet = ["pdf", "docx", "doc", "txt", "rtf", "odt", "md", "tex", "epub", "msg", "xlsx", "xls", "csv", "tsv", "ods", "pptx",
                     "ppt", "odp", "json", "xml", "jpg", "png", "gif", "webp", "svg", "heic", "avif", "tiff", "bmp", "ico", "psd", "ai",
                     "eps", "sketch", "blend", "fbx", "gltf", "xcf", "pub", "one", "mp3", "wav", "aac", "m4a", "flac", "ogg", "opus",
                     "aiff", "wma", "mid", "mp4", "mov", "avi", "mkv", "webm", "wmv", "mpeg", "m4v", "3gp", "srt", "zip", "rar", "7z",
                     "tar", "gz", "bz2", "xz", "iso", "dmg", "pkg", "html", "css", "js", "ts", "jsx", "tsx", "scss", "yaml", "sql", "db",
                     "py", "java", "c", "cpp", "h", "cs", "go", "rs", "php", "rb", "exe", "msi", "dll", "bat", "sh", "ps1", "ini", "log",
                     "ttf", "woff2"]
        XCTAssertEqual(sheet.count, 100)
        for ext in sheet {
            guard case .bundled = FileTypeCatalog.info(forFileName: "x.\(ext)").artwork else { return XCTFail(ext) }
        }
        for ext in ["pages", "numbers", "key", "eml", "ics", "vcf", "app", "icns", "plist"] {
            guard case .system = FileTypeCatalog.info(forFileName: "x.\(ext)").artwork else { return XCTFail(ext) }
        }
    }
}
