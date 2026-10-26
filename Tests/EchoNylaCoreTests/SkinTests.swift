import Foundation
import XCTest
@testable import EchoNylaCore

final class SkinTests: XCTestCase {
    private func freshDefaults() -> (UserDefaults, String) {
        let name = "EchoNylaTests.skins.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    func testVerbynsSixSkinsWithSignatureAsTheStandard() {
        XCTAssertEqual(Skin.allCases.map(\.rawValue), ["signature", "sky", "green", "turquoise", "bordeaux", "wisteria"])
        XCTAssertEqual(Skin.standard, .signature)
        XCTAssertEqual(Skin.allCases.map(\.displayName), ["Signature", "Sky", "Green", "Turquoise", "Bordeaux", "Wisteria"])
    }

    /// The exact colours Verbyn uses (Verbyn's Skins.swift), so the apps match.
    func testPalettesAreVerbyns() {
        func hexes(_ palette: SkinPalette) -> [RGB] { [palette.accent, palette.onAccent, palette.window, palette.surface, palette.sidebar] }
        let expected: [Skin: (light: [UInt32], dark: [UInt32])] = [
            .signature: ([0x1C1D20, 0xFFFFFF, 0xF3F3F4, 0xFFFFFF, 0xE6E6E8], [0xE6E7EA, 0x0B0C0D, 0x0B0C0D, 0x151618, 0x060708]),
            .sky: ([0x2D64AE, 0xFFFFFF, 0xEEF3FA, 0xFBFCFE, 0xE3EAF5], [0x86B5F4, 0x06142B, 0x08101D, 0x0F1A2C, 0x060C17]),
            .green: ([0x167A47, 0xFFFFFF, 0xEEF3EF, 0xFBFDFB, 0xE8EFEA], [0x7CE2A3, 0x04140A, 0x141A17, 0x1B231F, 0x0F1411]),
            .turquoise: ([0x1D7470, 0xFFFFFF, 0xEDF5F4, 0xFAFDFC, 0xE1EDEB], [0x5FD0C8, 0x04201F, 0x081416, 0x0F2023, 0x061012]),
            .bordeaux: ([0xA33B4F, 0xFFFFFF, 0xF7F0F1, 0xFDFAFA, 0xEEE3E5], [0xE8909F, 0x2A0A10, 0x160B0E, 0x211216, 0x10080A]),
            .wisteria: ([0x6352A8, 0xFFFFFF, 0xF3F1F9, 0xFCFBFE, 0xE8E5F3], [0xB9A6F2, 0x130C2E, 0x110F1D, 0x1A1729, 0x0C0A16])
        ]
        for skin in Skin.allCases {
            XCTAssertEqual(hexes(skin.palette(dark: false)), expected[skin]!.light.map { RGB(hex: $0) }, "\(skin) light")
            XCTAssertEqual(hexes(skin.palette(dark: true)), expected[skin]!.dark.map { RGB(hex: $0) }, "\(skin) dark")
        }
    }

    /// The accent on the window, cards and sidebar, and text on accent buttons, stay readable everywhere.
    func testEverySkinKeepsItsTextReadable() {
        for skin in Skin.allCases {
            for dark in [false, true] {
                let palette = skin.palette(dark: dark)
                let name = "\(skin) \(dark ? "dark" : "light")"
                let minimum = skin == .signature ? 7.0 : 4.5
                XCTAssertGreaterThanOrEqual(RGB.contrast(palette.accent, palette.window), minimum, "\(name) accent on window")
                XCTAssertGreaterThanOrEqual(RGB.contrast(palette.accent, palette.surface), minimum, "\(name) accent on cards")
                XCTAssertGreaterThanOrEqual(RGB.contrast(palette.accent, palette.sidebar), minimum, "\(name) accent on sidebar")
                XCTAssertGreaterThanOrEqual(RGB.contrast(palette.onAccent, palette.accent), minimum, "\(name) button text")
                XCTAssertEqual(palette.window.relativeLuminance < 0.5, dark, "\(name) background")
            }
        }
    }

    func testOpensInSignatureFollowingTheMac() {
        let preference = SkinPreference()
        XCTAssertEqual(preference.skin, .signature)
        XCTAssertEqual(preference.appearance, .followMac)
        XCTAssertTrue(preference.isDark(systemIsDark: true))
        XCTAssertFalse(preference.isDark(systemIsDark: false))
        XCTAssertNil(preference.iconSkin, "Signature is the app's own icon")
    }

    func testAlwaysLightOrDarkIgnoresTheMac() {
        var preference = SkinPreference()
        preference.appearance = .light
        XCTAssertFalse(preference.isDark(systemIsDark: true))
        preference.appearance = .dark
        XCTAssertTrue(preference.isDark(systemIsDark: false))
    }

    func testTheIconFollowsTheSkinUnlessTurnedOff() {
        var preference = SkinPreference(skin: .bordeaux)
        XCTAssertEqual(preference.iconSkin, .bordeaux)
        preference.iconFollowsSkin = false
        XCTAssertNil(preference.iconSkin)
    }

    func testSavingAndLoadingRoundTrips() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let preference = SkinPreference(skin: .turquoise, appearance: .dark, iconFollowsSkin: false)
        preference.save(to: defaults)
        XCTAssertEqual(SkinPreference.load(from: defaults), preference)
    }

    func testMissingOrUnknownValuesFallBackToTheDefaults() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(SkinPreference.load(from: defaults), SkinPreference())
        defaults.set("slate", forKey: SkinPreference.Keys.skin)
        defaults.set("nonsense", forKey: SkinPreference.Keys.appearance)
        XCTAssertEqual(SkinPreference.load(from: defaults), SkinPreference())
    }

    func testSettingsUseTheEchoNylaPrefix() {
        for key in [SkinPreference.Keys.skin, SkinPreference.Keys.appearance, SkinPreference.Keys.iconFollowsSkin] {
            XCTAssertTrue(key.hasPrefix("EchoNyla.appearance."), key)
        }
    }

    func testMixingMovesTowardsTheOtherColour() {
        let mixed = RGB(hex: 0x000000).mixed(with: RGB(hex: 0xFFFFFF), amount: 0.5)
        XCTAssertEqual(mixed.red, 0.5, accuracy: 0.0001)
        XCTAssertEqual(RGB(hex: 0x123456).mixed(with: RGB(hex: 0xFFFFFF), amount: 0), RGB(hex: 0x123456))
    }
}
