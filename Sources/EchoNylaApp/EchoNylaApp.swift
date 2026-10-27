import AppKit
import EchoNylaCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct EchoNylaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        FinderIcon.runTestCommandIfAsked()
    }

    var body: some Scene {
        Settings {
            SettingsTab()
                .environment(AppModel.shared)
                .nylaChrome()
                .frame(width: 640, height: 720)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { UpdateController.shared.checkForUpdates() }
                    .disabled(!UpdateController.shared.canCheckForUpdates)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        SkinStore.shared.start()
        StatusItemController.shared.install()
        AppModel.shared.start()
        UpdateController.shared.start()
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: AppModel.Keys.hasLaunched) {
            defaults.set(true, forKey: AppModel.Keys.hasLaunched)
            MainWindowController.shared.show(.activity)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// The tabs of the main window.
enum MainTab: String, CaseIterable, Identifiable {
    case activity, cleanup, reorganize, find, folders, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activity: return "Activity"
        case .cleanup: return "Clean Up"
        case .reorganize: return "Reorganize"
        case .find: return "Find"
        case .folders: return "Folders & Rules"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .activity: return "clock.arrow.circlepath"
        case .cleanup: return "sparkles.rectangle.stack"
        case .reorganize: return "wand.and.stars"
        case .find: return "magnifyingglass"
        case .folders: return "folder.badge.gearshape"
        case .settings: return "gearshape"
        }
    }
}

/// A floating panel that stays open until you close it (× button, Esc, or the menu-bar icon), so
/// clicking a Finder window to pick up a file no longer closes it.
final class DropPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        StatusItemController.shared.hidePanel()
    }
}

@MainActor
final class StatusItemController: NSObject, NSWindowDelegate, NSDraggingDestination {
    static let shared = StatusItemController()

    private var statusItem: NSStatusItem?
    private var panel: DropPanel?
    private let panelSize = NSSize(width: 400, height: 600)

    var isPanelVisible: Bool { panel?.isVisible == true }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = MenuBarGlyph.image()
            button.toolTip = "EchoNyla — click to open, or drop files here"
            button.target = self
            button.action = #selector(togglePanel)
            // Files can be dropped straight onto the menu-bar icon.
            button.window?.registerForDraggedTypes([.fileURL])
            button.window?.delegate = self
        }
        statusItem = item
    }

    @objc func togglePanel() {
        if isPanelVisible { hidePanel() } else { showPanel() }
    }

    func showPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func hidePanel() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> DropPanel {
        let panel = DropPanel(contentRect: NSRect(origin: .zero, size: panelSize),
                              styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: SkinStore.shared.isDark ? .darkAqua : .aqua)
        panel.backgroundColor = NylaStyle.windowBackgroundNS
        panel.contentView = NSHostingView(rootView: PanelView().environment(AppModel.shared))
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let buttonWindow = statusItem?.button?.window, let screen = buttonWindow.screen ?? NSScreen.main else {
            panel.center()
            return
        }
        let anchor = buttonWindow.frame
        let visible = screen.visibleFrame
        var x = anchor.midX - panelSize.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - panelSize.width - 8)
        let y = anchor.minY - panelSize.height - 6
        panel.setFrame(NSRect(x: x, y: max(y, visible.minY + 8), width: panelSize.width, height: panelSize.height), display: true)
    }

    // Dropping files on the menu-bar icon (the status item's window forwards drags to its delegate).

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .move : []
    }

    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        AppModel.shared.receiveDrops(urls)
        showPanel()
        return true
    }
}

/// The main window, opened from the panel. EchoNyla shows a Dock icon only while it's open.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()
    private var window: NSWindow?

    func show(_ tab: MainTab) {
        AppModel.shared.selectedTab = tab
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Opens Folders & Rules with the setup helper on top.
    func showSetup() {
        show(.folders)
        AppModel.shared.isSetupOpen = true
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "EchoNyla"
        // The sidebar runs up under the window's buttons; the name and icon are drawn in the sidebar.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 840, height: 580)
        window.appearance = NSAppearance(named: SkinStore.shared.isDark ? .darkAqua : .aqua)
        window.backgroundColor = NylaStyle.windowBackgroundNS
        window.contentViewController = NSHostingController(rootView: MainWindowView().environment(AppModel.shared))
        window.setContentSize(NSSize(width: 920, height: 760))
        window.center()
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
