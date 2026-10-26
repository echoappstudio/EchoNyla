import AppKit
import EchoNylaCore

/// Puts the skin's icon on the app itself, as seen in Finder, Launchpad and Spotlight. The Dock
/// icon is set separately while the app runs. It is the same custom icon Get Info can paste on an
/// app. An update replaces the whole app, which brings back the app's own icon, so this runs at
/// every launch.
@MainActor
enum FinderIcon {
    /// The skin last put on the app, so a launch with nothing to change writes nothing.
    static let shownKey = "EchoNyla.appearance.finderIconShown.v1"

    /// Shows the skin's icon, or the app's own icon for nil. Returns false if the app couldn't
    /// change it (for example an app it may not write to); the app's own icon then stays.
    @discardableResult
    static func show(_ skin: Skin?, defaults: UserDefaults = .standard) -> Bool {
        let appPath = Bundle.main.bundlePath
        let hasCustomIcon = FileManager.default.fileExists(atPath: appPath + "/Icon\r")
        guard let skin else {
            defaults.removeObject(forKey: shownKey)
            return !hasCustomIcon || NSWorkspace.shared.setIcon(nil, forFile: appPath, options: [])
        }
        if hasCustomIcon, defaults.string(forKey: shownKey) == skin.rawValue { return true }
        guard let url = Bundle.main.url(forResource: "icon-\(skin.rawValue)", withExtension: "png", subdirectory: "SkinIcons"),
              let image = NSImage(contentsOf: url),
              NSWorkspace.shared.setIcon(image, forFile: appPath, options: []) else {
            return false
        }
        defaults.set(skin.rawValue, forKey: shownKey)
        return true
    }

    /// Used by Scripts/finder-icon-test.sh: `--show-finder-icon <skin|none>` shows that icon on
    /// this copy of the app through the same code the app uses, then exits.
    static func runTestCommandIfAsked() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--show-finder-icon"), index + 1 < arguments.count else { return }
        let name = arguments[index + 1]
        let skin = name == "none" ? nil : Skin(rawValue: name)
        guard name == "none" || skin != nil else {
            fputs("Unknown skin \(name)\n", stderr)
            exit(2)
        }
        exit(show(skin) ? 0 : 1)
    }
}
