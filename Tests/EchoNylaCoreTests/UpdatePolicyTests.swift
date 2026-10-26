import Foundation
import XCTest
@testable import EchoNylaCore

final class UpdatePolicyTests: XCTestCase {
    func testInstallsRightAwayWhenIdle() {
        XCTAssertTrue(UpdateInstallPolicy.canInstallNow(isBusy: false))
    }

    func testWaitsWhileAFileIsBeingFiledOrWaitingForAChoice() {
        XCTAssertFalse(UpdateInstallPolicy.canInstallNow(isBusy: true))
    }

    /// The shipped Info.plist turns on hourly checks, automatic installs and signed feeds.
    func testInfoPlistConfiguresUpdates() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])

        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "com.echoapps.echonyla")
        XCTAssertEqual(info["SUFeedURL"] as? String, "https://github.com/echoappstudio/EchoNyla/releases/latest/download/appcast.xml")
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(info["SUAutomaticallyUpdate"] as? Bool, true)
        XCTAssertEqual(info["SUScheduledCheckInterval"] as? Int, 3600)
        XCTAssertEqual(info["SURequireSignedFeed"] as? Bool, true)
        XCTAssertEqual(info["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        XCTAssertNil(info["SUAllowsAutomaticUpdates"])
        let publicKey = try XCTUnwrap(info["SUPublicEDKey"] as? String)
        XCTAssertEqual(Data(base64Encoded: publicKey)?.count, 32, "SUPublicEDKey must be a base64 Ed25519 public key")
        let build = try XCTUnwrap(info["CFBundleVersion"] as? String)
        XCTAssertNotNil(Int(build), "Sparkle compares builds; EchoNyla keeps them whole numbers")
    }
}
