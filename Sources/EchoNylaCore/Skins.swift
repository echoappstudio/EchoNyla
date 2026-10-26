import Foundation

/// A colour as plain numbers (0 to 1), so the skins can be tested without any UI framework.
public struct RGB: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `RGB(hex: 0x86B5F4)`.
    public init(hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    /// WCAG relative luminance.
    public var relativeLuminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// WCAG contrast ratio between two colours (1 to 21).
    public static func contrast(_ first: RGB, _ second: RGB) -> Double {
        let a = first.relativeLuminance
        let b = second.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// This colour moved `amount` (0 to 1) of the way towards `other`.
    public func mixed(with other: RGB, amount: Double) -> RGB {
        RGB(red: red + (other.red - red) * amount, green: green + (other.green - green) * amount, blue: blue + (other.blue - blue) * amount)
    }
}

/// The colours one skin gives EchoNyla in one appearance. Text and secondary text are the system's
/// own, so they always read well on the light or dark background.
public struct SkinPalette: Equatable, Sendable {
    /// Buttons, switches, headings, tags and the selected page.
    public let accent: RGB
    /// Text on an accent button.
    public let onAccent: RGB
    /// The window background behind each screen, faintly tinted with the skin.
    public let window: RGB
    /// Cards and rows.
    public let surface: RGB
    /// The sidebar, a shade away from the window.
    public let sidebar: RGB
}

/// A colour scheme for the whole app. The same six skins as Verbyn, with exactly Verbyn's colours:
/// every skin has a light and a dark version and changes colours and the app icon only. Signature
/// (the Echo App Studio website's black, charcoal and silver) is EchoNyla's own look, and its icon is
/// the app's built-in icon.
public enum Skin: String, CaseIterable, Sendable {
    case signature, sky, green, turquoise, bordeaux, wisteria

    /// The look EchoNyla opens in, whose icon is the app's own built-in icon.
    public static let standard: Skin = .signature

    public var displayName: String {
        switch self {
        case .signature: return "Signature"
        case .sky: return "Sky"
        case .green: return "Green"
        case .turquoise: return "Turquoise"
        case .bordeaux: return "Bordeaux"
        case .wisteria: return "Wisteria"
        }
    }

    public var tagline: String {
        switch self {
        case .signature: return "Black and silver"
        case .sky: return "Classic blue"
        case .green: return "Fresh green"
        case .turquoise: return "Deep teal"
        case .bordeaux: return "Wine red"
        case .wisteria: return "Soft violet"
        }
    }

    public func palette(dark: Bool) -> SkinPalette {
        func make(_ accent: UInt32, _ onAccent: UInt32, _ window: UInt32, _ surface: UInt32, _ sidebar: UInt32) -> SkinPalette {
            SkinPalette(
                accent: RGB(hex: accent),
                onAccent: RGB(hex: onAccent),
                window: RGB(hex: window),
                surface: RGB(hex: surface),
                sidebar: RGB(hex: sidebar)
            )
        }
        switch (self, dark) {
        case (.signature, false): return make(0x1C1D20, 0xFFFFFF, 0xF3F3F4, 0xFFFFFF, 0xE6E6E8)
        case (.signature, true): return make(0xE6E7EA, 0x0B0C0D, 0x0B0C0D, 0x151618, 0x060708)
        case (.sky, false): return make(0x2D64AE, 0xFFFFFF, 0xEEF3FA, 0xFBFCFE, 0xE3EAF5)
        case (.sky, true): return make(0x86B5F4, 0x06142B, 0x08101D, 0x0F1A2C, 0x060C17)
        case (.green, false): return make(0x167A47, 0xFFFFFF, 0xEEF3EF, 0xFBFDFB, 0xE8EFEA)
        case (.green, true): return make(0x7CE2A3, 0x04140A, 0x141A17, 0x1B231F, 0x0F1411)
        case (.turquoise, false): return make(0x1D7470, 0xFFFFFF, 0xEDF5F4, 0xFAFDFC, 0xE1EDEB)
        case (.turquoise, true): return make(0x5FD0C8, 0x04201F, 0x081416, 0x0F2023, 0x061012)
        case (.bordeaux, false): return make(0xA33B4F, 0xFFFFFF, 0xF7F0F1, 0xFDFAFA, 0xEEE3E5)
        case (.bordeaux, true): return make(0xE8909F, 0x2A0A10, 0x160B0E, 0x211216, 0x10080A)
        case (.wisteria, false): return make(0x6352A8, 0xFFFFFF, 0xF3F1F9, 0xFCFBFE, 0xE8E5F3)
        case (.wisteria, true): return make(0xB9A6F2, 0x130C2E, 0x110F1D, 0x1A1729, 0x0C0A16)
        }
    }
}

/// Light or dark: follow the Mac's own setting, or always use one.
public enum AppearanceMode: String, CaseIterable, Sendable {
    case followMac, light, dark

    public var title: String {
        switch self {
        case .followMac: return "Follow my Mac"
        case .light: return "Always light"
        case .dark: return "Always dark"
        }
    }
}

/// The skin, light or dark, and whether the app icon follows the skin. EchoNyla opens in Signature,
/// light or dark with the Mac.
public struct SkinPreference: Equatable, Sendable {
    public var skin: Skin
    public var appearance: AppearanceMode
    public var iconFollowsSkin: Bool

    public init(skin: Skin = .standard, appearance: AppearanceMode = .followMac, iconFollowsSkin: Bool = true) {
        self.skin = skin
        self.appearance = appearance
        self.iconFollowsSkin = iconFollowsSkin
    }

    /// Whether the dark version is drawn, given the Mac's own setting.
    public func isDark(systemIsDark: Bool) -> Bool {
        switch appearance {
        case .followMac: return systemIsDark
        case .light: return false
        case .dark: return true
        }
    }

    /// The skin whose icon the app wears, or nil for the app's own icon (Signature, or the switch off).
    public var iconSkin: Skin? {
        iconFollowsSkin && skin != .standard ? skin : nil
    }

    // MARK: Saving

    public enum Keys {
        public static let skin = "EchoNyla.appearance.skin.v1"
        public static let appearance = "EchoNyla.appearance.mode.v1"
        public static let iconFollowsSkin = "EchoNyla.appearance.iconFollowsSkin.v1"
    }

    /// Unknown or missing values fall back to the defaults.
    public static func load(from defaults: UserDefaults) -> SkinPreference {
        var preference = SkinPreference()
        if let raw = defaults.string(forKey: Keys.skin), let skin = Skin(rawValue: raw) { preference.skin = skin }
        if let raw = defaults.string(forKey: Keys.appearance), let mode = AppearanceMode(rawValue: raw) { preference.appearance = mode }
        preference.iconFollowsSkin = defaults.object(forKey: Keys.iconFollowsSkin) as? Bool ?? true
        return preference
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(skin.rawValue, forKey: Keys.skin)
        defaults.set(appearance.rawValue, forKey: Keys.appearance)
        defaults.set(iconFollowsSkin, forKey: Keys.iconFollowsSkin)
    }
}
