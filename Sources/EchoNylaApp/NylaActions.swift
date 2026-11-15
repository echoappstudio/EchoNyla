import AppIntents
import AppKit
import EchoNylaCore
import Foundation
import UniformTypeIdentifiers

// EchoNyla's actions for Shortcuts, Siri and Spotlight, and its items in Finder's Services menu.
// `Scripts/app-intents.sh` puts the actions' description into the app (Metadata.appintents) so macOS
// can find them; keep its list of action names in step with the types here.

struct NylaActionError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

@MainActor
enum NylaActions {
    /// The files themselves (Finder and Shortcuts hand over their places). Copies without a place
    /// can't be filed, so they're refused with a plain reason.
    static func places(of files: [IntentFile]) throws -> [URL] {
        let urls = files.compactMap(\.fileURL)
        guard !urls.isEmpty, urls.count == files.count else {
            throw NylaActionError("EchoNyla needs files that are on this Mac, like files picked in Finder.")
        }
        return urls
    }

    /// Opens the main window on a page.
    static func show(_ tab: MainTab) {
        NSApp.activate()
        MainWindowController.shared.show(tab)
    }

    /// Opens Files at the file's folder with the file selected, so the preview pane shows it.
    static func showInFiles(_ url: URL) {
        let model = AppModel.shared
        let isFolder = model.isFolder(url)
        show(.files)
        let browser = model.files.active
        browser.go(to: isFolder ? url : url.deletingLastPathComponent())
        guard !isFolder else { return }
        let id = url.standardizedFileURL.path
        browser.selection = [id]
        browser.cursor = id
        browser.anchor = id
        model.select(url)
    }

    /// Called once at launch: Siri and Spotlight learn the app's phrases, and Finder learns its Services.
    static func register() {
        LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        NylaShortcuts.updateAppShortcutParameters()
        NSApp.servicesProvider = NylaServices.shared
        NSUpdateDynamicServices()
    }
}

struct SortFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Sort Files"
    static let description = IntentDescription("Sorts files the way EchoNyla sorts new downloads. Files it's sure about go to your folders, and the rest wait for you in Activity.")

    @Parameter(title: "Files", supportedContentTypes: [.item])
    var files: [IntentFile]

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let model = AppModel.shared
        guard !model.destinations.isEmpty else { throw NylaActionError("Add a favorite folder in EchoNyla first (Folders & Rules).") }
        let urls = try NylaActions.places(of: files)
        let count = model.sortInBackground(urls, title: "Sorted \(urls.count) file\(urls.count == 1 ? "" : "s") from Shortcuts")
        return .result(value: count)
    }
}

struct DescribeFileIntent: AppIntent {
    static let title: LocalizedStringResource = "What Is This File?"
    static let description = IntentDescription("Apple Intelligence looks at the file on this Mac and says what it is in one sentence.")

    @Parameter(title: "File", supportedContentTypes: [.item])
    var file: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let url = try NylaActions.places(of: [file]).first else { throw NylaActionError("Pick a file.") }
        let model = AppModel.shared
        if let reason = model.aiUnavailableReason { throw NylaActionError("Apple Intelligence isn't ready. \(reason)") }
        guard let summary = await model.describe(url) else { throw NylaActionError("Apple Intelligence couldn't tell what this file is.") }
        return .result(value: summary)
    }
}

struct FindFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Files"
    static let description = IntentDescription("Finds files you describe in your own words, like “tax PDFs from last spring”. Newest first.")

    @Parameter(title: "Description")
    var words: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let urls = await AppModel.shared.findFiles(words)
        return .result(value: urls.map { IntentFile(fileURL: $0, filename: $0.lastPathComponent) })
    }
}

struct OpenInFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Show in EchoNyla"
    static let description = IntentDescription("Opens EchoNyla's Files page at a folder, or at a file's folder with the file selected.")
    static let openAppWhenRun = true

    @Parameter(title: "File or Folder", supportedContentTypes: [.item])
    var item: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let url = try NylaActions.places(of: [item]).first else { throw NylaActionError("Pick a file or folder.") }
        NylaActions.showInFiles(url)
        return .result()
    }
}

struct CleanUpDownloadsIntent: AppIntent {
    static let title: LocalizedStringResource = "Clean Up Downloads"
    static let description = IntentDescription("Opens Clean Up on your Downloads folder, with everything EchoNyla would move, rename or put in the Trash for you to approve.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NylaActions.show(.cleanup)
        AppModel.shared.startDownloadsCleanup()
        return .result()
    }
}

struct NylaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CleanUpDownloadsIntent(),
            phrases: ["Clean up Downloads in \(.applicationName)", "Tidy my Downloads in \(.applicationName)"],
            shortTitle: "Clean Up Downloads",
            systemImageName: "sparkles"
        )
    }
}

// MARK: - Finder's Services menu

/// Right-click files in Finder → Services (or Quick Actions): "Sort with EchoNyla" and "Show in
/// EchoNyla". Named in Resources/Info.plist (NSServices); macOS calls these by those names.
@MainActor
final class NylaServices: NSObject {
    static let shared = NylaServices()

    private func files(on pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.map(\.standardizedFileURL)
    }

    @objc func sortFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let model = AppModel.shared
        guard !model.destinations.isEmpty else {
            error.pointee = "Add a favorite folder in EchoNyla first (Folders & Rules)." as NSString
            NylaActions.show(.folders)
            return
        }
        let count = model.sortInBackground(files(on: pasteboard), title: "Sorted from Finder")
        if count == 0 { error.pointee = "EchoNyla sorts files, not folders." as NSString }
    }

    @objc func showInFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let url = files(on: pasteboard).first else { return }
        NylaActions.showInFiles(url)
    }
}
