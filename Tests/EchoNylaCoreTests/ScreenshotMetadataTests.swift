import Darwin
import Foundation
import XCTest
@testable import EchoNylaCore

final class ScreenshotMetadataTests: XCTestCase {
    func testReadsTheScreenCaptureExtendedAttribute() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoNyla-screenshot-\(UUID().uuidString).png")
        try Data().write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let data = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
        let result = data.withUnsafeBytes { buffer in
            fileURL.path.withCString { path in
                "com.apple.metadata:kMDItemIsScreenCapture".withCString { name in
                    setxattr(path, name, buffer.baseAddress, data.count, 0, 0)
                }
            }
        }
        XCTAssertEqual(result, 0)
        XCTAssertTrue(ScreenshotMetadata.isScreenCapture(at: fileURL))
    }

    func testOrdinaryFileWithoutScreenCaptureFlagIsNotAScreenshot() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoNyla-ordinary-\(UUID().uuidString).png")
        try Data().write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        XCTAssertFalse(ScreenshotMetadata.isScreenCapture(at: fileURL))
    }
}
