import AppKit
import Combine
import EchoNylaCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - The Files area

/// Files: a Finder-like place to go through your files, with what EchoNyla knows about them. Each
/// file can show where it belongs (with Move), a clearer name in grey, and flags for clutter. The
/// 1 to 9 keys send the selected file to your most-used folders. Two folders can sit side by side.
struct FilesTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let area = model.files
        VStack(spacing: 0) {
            FilesToolbar(area: area)
            QuickSortStrip(area: area)
            Rectangle().fill(NylaStyle.hairline).frame(height: 1)
            HStack(spacing: 0) {
                PlacesColumn(area: area)
                    .frame(width: 178)
                Rectangle().fill(NylaStyle.hairline).frame(width: 1)
                ForEach(Array(area.visibleSides.enumerated()), id: \.element.id) { index, side in
                    if index > 0 {
                        Rectangle().fill(NylaStyle.hairline).frame(width: 1)
                    }
                    BrowserSideView(area: area, browser: side, isActive: area.activeIndex == index)
                }
            }
        }
        .background(WindowBackground().ignoresSafeArea())
        .overlay(alignment: .top) { FilesNoteView().padding(.top, 52) }
        .onAppear { FilesKeys.shared.start() }
        .onDisappear { FilesKeys.shared.stop() }
    }
}

/// How the Files area lays out a side's files: the groups in order, and the order the keys move through.
@MainActor
enum FilesLayout {
    static func groups(_ browser: FileBrowser, area: FilesArea, model: AppModel) -> [BrowserGroup] {
        browser.layout(sort: area.sort, grouping: area.grouping, insightsVersion: model.insightsVersion) { item in
            FileCategory.of(name: item.name, isFolder: item.isFolder, isScreenshot: item.isScreenshot,
                            summary: model.insight(for: item)?.summary)
        }
    }

    static func order(_ browser: FileBrowser, area: FilesArea, model: AppModel) -> [String] {
        groups(browser, area: area, model: model).flatMap { $0.items.map(\.id) }
    }
}

// MARK: - Toolbar

struct FilesToolbar: View {
    static let tidyHelp = "Clean Up looks at this folder and lists what it would move, rename or put in the Trash, for you to approve"
    @Bindable var area: FilesArea
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var active = area.active
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter, or describe a file and press Return", text: $active.filterText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { active.search(active.filterText, model: model) }
                if !active.filterText.isEmpty || active.searchResults != nil {
                    Button {
                        active.filterText = ""
                        active.clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear")
                }
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(NylaStyle.wash(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(NylaStyle.hairline, lineWidth: 1))
            .frame(minWidth: 110, maxWidth: 320)
            .help("Type to narrow the list by name. Press Return to search this folder in your own words, like “tax PDFs from last spring”.")
            Spacer(minLength: 4)
            Picker("View", selection: $area.viewMode) {
                Image(systemName: "list.bullet").tag(BrowserViewMode.list)
                Image(systemName: "square.grid.2x2").tag(BrowserViewMode.icons)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("List or icons")
            if area.viewMode == .icons {
                Menu {
                    Picker("Icon Size", selection: $area.iconSize) {
                        ForEach(IconSize.allCases, id: \.self) { size in
                            Text(size.title).tag(size)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "photo")
                        .accessibilityLabel("Icon Size")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Icon size: \(area.iconSize.title). Large shows pictures big enough to see without opening them.")
            }
            Menu {
                Picker("Group By", selection: $area.grouping) {
                    ForEach(BrowserGrouping.allCases, id: \.self) { grouping in
                        Text(grouping.title).tag(grouping)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Picker("Sort By", selection: Binding(get: { area.sort.key }, set: { area.sort = BrowserSort(key: $0, ascending: area.sort.ascending) })) {
                    ForEach(BrowserSortKey.allCases, id: \.self) { key in
                        Text(key.title).tag(key)
                    }
                }
                .pickerStyle(.inline)
                Toggle("Ascending", isOn: Binding(get: { area.sort.ascending }, set: { area.sort.ascending = $0 }))
                Divider()
                Toggle("Show Hidden Files (⇧⌘.)", isOn: $area.showsHidden)
            } label: {
                Label(area.grouping == .none ? "Group" : area.grouping.title, systemImage: "rectangle.3.group")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Group the files by kind, date or what they are, and choose the order")
            BarButton(symbol: "folder.badge.plus", help: "New Folder (⇧⌘N)") { FilesActions.newFolder(in: active, model: model) }
            BarButton(symbol: area.isSplit ? "rectangle" : "rectangle.split.2x1",
                      help: area.isSplit ? "One folder" : "Two folders side by side") {
                withAnimation(.easeInOut(duration: 0.2)) { area.isSplit.toggle() }
            }
            // In a narrow window the button keeps only its sparkles, so the toolbar never pushes the window wider.
            ViewThatFits(in: .horizontal) {
                Button("Tidy This Folder", systemImage: "sparkles") { model.tidy(active.folder) }
                    .buttonStyle(.pill)
                    .help(Self.tidyHelp)
                BarButton(symbol: "sparkles", help: "Tidy This Folder: " + Self.tidyHelp) { model.tidy(active.folder) }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .onChange(of: FilesKeys.shared.searchRequests) { searchFocused = true }
    }
}

/// Things the toolbar, the keys and the right-click menu share.
@MainActor
enum FilesActions {
    /// A new folder, named as Finder names them, with its name ready to type over.
    static func newFolder(in browser: FileBrowser, model: AppModel) {
        guard let made = model.makeNewFolder(in: browser.folder) else { return }
        let id = made.standardizedFileURL.path
        browser.selection = [id]
        browser.cursor = id
        browser.anchor = id
        browser.renaming = id
        browser.revealAfterLoad = id
        model.select(made)
    }

    /// Return, or Rename in the menu: the name turns into a text box with the part before the
    /// extension selected.
    static func rename(_ id: String, in browser: FileBrowser) {
        browser.selection = [id]
        browser.cursor = id
        browser.anchor = id
        browser.renaming = id
    }

    /// The text box's answer: a new name renames the file (with Undo); the same name or Esc leaves it.
    static func finishRename(_ item: BrowserItem, newName: String?, browser: FileBrowser, model: AppModel) {
        guard browser.renaming == item.id else { return }
        browser.renaming = nil
        guard let newName, newName.trimmingCharacters(in: .whitespacesAndNewlines) != item.name,
              let renamed = model.renameItem(item.url, to: newName) else { return }
        let id = renamed.standardizedFileURL.path
        browser.selection = [id]
        browser.cursor = id
        browser.anchor = id
        browser.revealAfterLoad = id
        model.select(renamed)
    }
}

/// "1 Receipts  2 Work  3 Photos": press a number to send the selected files there.
struct QuickSortStrip: View {
    let area: FilesArea
    @Environment(AppModel.self) private var model

    var body: some View {
        let folders = model.quickSortFolders
        if !folders.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text("SEND TO")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(1.1)
                        .foregroundStyle(.secondary)
                    ForEach(Array(folders.enumerated()), id: \.element.id) { index, folder in
                        QuickSortChip(number: index + 1, folder: folder, area: area)
                    }
                    Text("↓ next · 0 skip · ⌘Z undo")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 6)
                }
                .padding(.horizontal, 14)
            }
            .frame(height: 34)
        }
    }
}

struct QuickSortChip: View {
    let number: Int
    let folder: FavoriteFolder
    let area: FilesArea
    @Environment(AppModel.self) private var model
    @State private var targeted = false

    var body: some View {
        Button {
            FilesKeys.shared.sendSelection(toFavorite: folder.id)
        } label: {
            HStack(spacing: 5) {
                Text("\(number)")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(NylaStyle.onAccent)
                    .frame(width: 16, height: 16)
                    .background(NylaStyle.brass, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                Text(folder.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            .padding(.leading, 4)
            .padding(.trailing, 9)
            .padding(.vertical, 3)
            .background(targeted ? NylaStyle.brass.opacity(0.25) : NylaStyle.wash(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(NylaStyle.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Press \(number) to send the selected files to \(folder.name). You can also drop files here.")
        .dropDestination(for: URL.self) { urls, _ in
            model.moveItems(FileDragBoard.expand(urls), toFavorite: folder.id)
            return true
        } isTargeted: { targeted = $0 }
    }
}

/// The note at the top after a change: "Moved 3 items to Receipts. Undo".
struct FilesNoteView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let note = model.filesNote {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(NylaStyle.brass)
                Text(note.text)
                    .font(.system(size: 12.5))
                    .lineLimit(2)
                if note.canUndo, model.lastMove != nil {
                    Button("Undo") { model.undoFromNote() }
                        .buttonStyle(.pill)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(NylaStyle.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(NylaStyle.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .transition(.move(edge: .top).combined(with: .opacity))
            .id(note.id)
        }
    }
}

// MARK: - Places

struct PlacesColumn: View {
    let area: FilesArea
    @Environment(AppModel.self) private var model
    @State private var drives: [URL] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                PlacesHeading("Places")
                ForEach(Places.standard, id: \.url) { place in
                    PlaceRow(name: place.name, symbol: place.symbol, url: place.url, area: area)
                }
                if !model.favoriteFolders.isEmpty {
                    PlacesHeading("Your folders")
                    ForEach(model.favoriteFolders) { folder in
                        if let url = model.favoriteURLs[folder.id] {
                            PlaceRow(name: folder.name, symbol: folder.isSortTarget ? "folder.fill" : "folder", url: url, area: area)
                        }
                    }
                }
                if !drives.isEmpty {
                    PlacesHeading("Drives")
                    ForEach(drives, id: \.self) { drive in
                        PlaceRow(name: drive.lastPathComponent, symbol: "externaldrive", url: drive, area: area)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
        .background(NylaStyle.raised(0.015))
        .onAppear { drives = Places.drives() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in drives = Places.drives() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in drives = Places.drives() }
    }
}

enum Places {
    struct Place {
        let name: String
        let symbol: String
        let url: URL
    }

    static var standard: [Place] {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        func folder(_ directory: FileManager.SearchPathDirectory, _ fallback: String) -> URL {
            manager.urls(for: directory, in: .userDomainMask).first ?? home.appendingPathComponent(fallback)
        }
        var places = [
            Place(name: "Home", symbol: "house", url: home),
            Place(name: "Desktop", symbol: "menubar.dock.rectangle", url: folder(.desktopDirectory, "Desktop")),
            Place(name: "Documents", symbol: "doc", url: folder(.documentDirectory, "Documents")),
            Place(name: "Downloads", symbol: "arrow.down.circle", url: folder(.downloadsDirectory, "Downloads"))
        ]
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if manager.fileExists(atPath: iCloud.path) { places.append(Place(name: "iCloud Drive", symbol: "icloud", url: iCloud)) }
        places.append(Place(name: "Applications", symbol: "square.grid.2x2", url: URL(fileURLWithPath: "/Applications", isDirectory: true)))
        return places
    }

    /// Drives you plugged in (not the Mac's own disk).
    static func drives() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsInternalKey, .volumeIsRootFileSystemKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.filter { volume in
            let values = try? volume.resourceValues(forKeys: Set(keys))
            return values?.volumeIsRootFileSystem != true && volume.path.hasPrefix("/Volumes/")
        }
    }
}

struct PlacesHeading: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }
}

struct PlaceRow: View {
    let name: String
    let symbol: String
    let url: URL
    let area: FilesArea
    @Environment(AppModel.self) private var model
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        let isHere = area.active.history.current == url.standardizedFileURL.path
        Button {
            area.active.go(to: url)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .frame(width: 16)
                    .foregroundStyle(isHere ? NylaStyle.brass : Color.secondary)
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12.5, weight: isHere ? .medium : .regular))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(targeted ? NylaStyle.brass.opacity(0.25)
                          : isHere ? NylaStyle.wash(0.1) : (hovering ? NylaStyle.wash(0.05) : Color.clear))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        .dropDestination(for: URL.self) { urls, _ in
            model.moveItems(FileDragBoard.expand(urls), into: url)
            return true
        } isTargeted: { targeted = $0 }
    }
}

// MARK: - One side

struct BrowserSideView: View {
    let area: FilesArea
    let browser: FileBrowser
    let isActive: Bool
    @Environment(AppModel.self) private var model
    @State private var backgroundTargeted = false

    var body: some View {
        let groups = FilesLayout.groups(browser, area: area, model: model)
        let order = groups.flatMap { $0.items.map(\.id) }
        VStack(spacing: 0) {
            SideHeader(browser: browser, isActive: isActive && area.isSplit)
            if browser.isSearching || browser.searchNote != nil {
                searchBanner
            }
            Group {
                if let blocked = browser.blocked {
                    PrivacyBlockedView(folderName: browser.folderName, privacySwitch: blocked) { browser.retryIfBlocked() }
                } else if let error = browser.loadError {
                    message(error, systemImage: "exclamationmark.triangle")
                } else if browser.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if order.isEmpty {
                    message(browser.searchResults != nil ? "Nothing found." : (browser.filterText.isEmpty ? "This folder is empty." : "No names match."),
                            systemImage: "tray")
                } else if area.viewMode == .list {
                    FileListView(area: area, browser: browser, groups: groups, order: order)
                } else {
                    FileIconsView(area: area, browser: browser, groups: groups, order: order)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(backgroundTargeted ? NylaStyle.brass.opacity(0.06) : Color.clear)
            .dropDestination(for: URL.self) { urls, _ in
                model.moveItems(FileDragBoard.expand(urls), into: browser.folder)
                return true
            } isTargeted: { backgroundTargeted = $0 }
            statusBar(count: order.count)
        }
        .overlay {
            if isActive && area.isSplit {
                Rectangle().strokeBorder(NylaStyle.brass.opacity(0.45), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .simultaneousGesture(TapGesture().onEnded { area.activate(browser) })
        .onAppear { browser.loadIfNeeded() }
        // Back from System Settings: show the folder as soon as macOS lets EchoNyla in.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            browser.retryIfBlocked()
        }
    }

    private var searchBanner: some View {
        HStack(spacing: 8) {
            if browser.isSearching {
                ProgressView().controlSize(.mini)
                Caption("Searching \(browser.folderName) and the folders inside it…")
            } else if let note = browser.searchNote {
                Image(systemName: "sparkle.magnifyingglass")
                    .foregroundStyle(NylaStyle.brass)
                Caption(note)
            }
            Spacer()
            Button("Clear Search") {
                browser.filterText = ""
                browser.clearSearch()
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(NylaStyle.brass.opacity(0.06))
    }

    private func message(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusBar(count: Int) -> some View {
        HStack(spacing: 6) {
            Text(Self.countText(count, selected: browser.selection.count))
            Spacer()
            if !browser.copies.isEmpty {
                Text("\(browser.copies.count) exact cop\(browser.copies.count == 1 ? "y" : "ies")")
                    .foregroundStyle(NylaStyle.brass)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 24)
        .overlay(alignment: .top) { Rectangle().fill(NylaStyle.hairline).frame(height: 1) }
    }

    static func countText(_ count: Int, selected: Int) -> String {
        let items = "\(count) item\(count == 1 ? "" : "s")"
        return selected > 0 ? "\(selected) of \(items) selected" : items
    }
}

/// macOS keeps EchoNyla out of a folder until you allow it: which switch to turn on, a button that
/// opens that page of System Settings, and Try Again (it also looks again when you come back).
struct PrivacyBlockedView: View {
    let folderName: String
    let privacySwitch: PrivacySwitch
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 30))
                .foregroundStyle(NylaStyle.brass)
            Text("macOS is keeping EchoNyla out of \(folderName)")
                .font(.system(size: 14, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(privacySwitch.advice)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Open Privacy Settings", systemImage: "gearshape") { PrivacySettings.open(privacySwitch) }
                    .buttonStyle(.brass)
                Button("Try Again", action: retry)
                    .buttonStyle(.pill)
            }
            Text("EchoNyla looks again by itself when you come back. If it still can't, quit and reopen EchoNyla.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 380)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum PrivacySettings {
    /// Opens Privacy & Security at Files & Folders or Full Disk Access.
    static func open(_ privacySwitch: PrivacySwitch) {
        let anchor: String
        switch privacySwitch {
        case .filesAndFolders: anchor = "Privacy_FilesAndFolders"
        case .fullDiskAccess: anchor = "Privacy_AllFiles"
        }
        let page = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        let fallback = URL(string: "x-apple.systempreferences:com.apple.preference.security")
        if let page, NSWorkspace.shared.open(page) { return }
        if let fallback { NSWorkspace.shared.open(fallback) }
    }
}

/// Back, Forward, Up and the path to the folder: click any folder on the way to go there.
struct SideHeader: View {
    let browser: FileBrowser
    let isActive: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 2) {
            BarButton(symbol: "chevron.left", help: "Back (⌘[)") { browser.goBack() }
                .disabled(!browser.history.canGoBack)
                .opacity(browser.history.canGoBack ? 1 : 0.4)
            BarButton(symbol: "chevron.right", help: "Forward (⌘])") { browser.goForward() }
                .disabled(!browser.history.canGoForward)
                .opacity(browser.history.canGoForward ? 1 : 0.4)
            BarButton(symbol: "arrow.up", help: "Enclosing folder (⌘↑)") { browser.goUp() }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    let steps = PathTrail.steps(to: browser.history.current, home: FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path)
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        if index > 0 {
                            Image(systemName: "chevron.compact.right")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        PathStepButton(step: step, isLast: index == steps.count - 1, browser: browser)
                    }
                }
                .padding(.horizontal, 6)
            }
            .defaultScrollAnchor(.trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(isActive ? NylaStyle.brass.opacity(0.05) : Color.clear)
        .overlay(alignment: .bottom) { Rectangle().fill(NylaStyle.hairline).frame(height: 1) }
    }
}

struct PathStepButton: View {
    let step: PathStep
    let isLast: Bool
    let browser: FileBrowser
    @Environment(AppModel.self) private var model
    @State private var targeted = false

    var body: some View {
        Button(step.name) { browser.go(to: URL(fileURLWithPath: step.path, isDirectory: true)) }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: isLast ? .semibold : .regular))
            .foregroundStyle(isLast ? Color.primary : Color.secondary)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(targeted ? NylaStyle.brass.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .dropDestination(for: URL.self) { urls, _ in
                model.moveItems(FileDragBoard.expand(urls), into: URL(fileURLWithPath: step.path, isDirectory: true))
                return true
            } isTargeted: { targeted = $0 }
    }
}

// MARK: - List and icons

/// Clicking, double-clicking and selecting files, the same in the list and in icons.
@MainActor
enum FileClicks {
    static func clicked(_ item: BrowserItem, browser: FileBrowser, area: FilesArea, order: [String], model: AppModel) {
        // A click in the name box being typed in places the cursor; it doesn't select again.
        guard browser.renaming != item.id else { return }
        area.activate(browser)
        if NSApp.keyWindow?.firstResponder is NSText { NSApp.keyWindow?.makeFirstResponder(nil) }
        let event = NSApp.currentEvent
        if (event?.clickCount ?? 1) >= 2 {
            open(item, browser: browser)
            return
        }
        let flags = event?.modifierFlags ?? []
        if flags.contains(.command) {
            if browser.selection.contains(item.id) { browser.selection.remove(item.id) } else { browser.selection.insert(item.id) }
            browser.anchor = item.id
        } else if flags.contains(.shift), let anchor = browser.anchor {
            browser.selection = Set(SelectionRange.between(anchor, item.id, in: order))
        } else {
            browser.selection = [item.id]
            browser.anchor = item.id
        }
        browser.cursor = item.id
        model.select(browser.selection.contains(item.id) ? item.url : nil, count: max(browser.selection.count, 1))
    }

    static func open(_ item: BrowserItem, browser: FileBrowser) {
        if item.isFolder {
            browser.go(to: item.url)
        } else if FileManager.default.fileExists(atPath: item.path) {
            NSWorkspace.shared.open(item.url)
        } else {
            NSSound.beep()
        }
    }

    /// Empty space: nothing selected.
    static func clickedBackground(browser: FileBrowser, area: FilesArea, model: AppModel) {
        area.activate(browser)
        browser.selection = []
        browser.cursor = nil
        model.select(nil)
    }
}

struct FileListView: View {
    let area: FilesArea
    let browser: FileBrowser
    let groups: [BrowserGroup]
    let order: [String]
    @Environment(AppModel.self) private var model
    @State private var width: CGFloat = 600

    private var columns: FileColumns { FileColumns(width: width) }

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader(area: area, columns: columns)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups) { group in
                            Section {
                                ForEach(group.items) { item in
                                    FileRowView(item: item, browser: browser, area: area, order: order, columns: columns)
                                        .id(item.id)
                                }
                            } header: {
                                if !group.title.isEmpty { GroupHeading(title: group.title, count: group.items.count) }
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .fileDragContainer(browser)
                }
                .contentShape(Rectangle())
                .onTapGesture { FileClicks.clickedBackground(browser: browser, area: area, model: model) }
                .onChange(of: browser.cursor) { _, cursor in
                    if let cursor { proxy.scrollTo(cursor) }
                }
                .onChange(of: browser.revealRequests) {
                    if let cursor = browser.cursor { proxy.scrollTo(cursor, anchor: .center) }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// Which columns fit: Date Modified, Size and Kind appear as the list gets wider.
struct FileColumns {
    let width: CGFloat
    var date: Bool { width > 430 }
    var size: Bool { width > 540 }
    var kind: Bool { width > 700 }
}

struct ColumnHeader: View {
    let area: FilesArea
    let columns: FileColumns

    var body: some View {
        HStack(spacing: 8) {
            heading(.name)
                .padding(.leading, 30)
                .frame(maxWidth: .infinity, alignment: .leading)
            if columns.date { heading(.modified).frame(width: 136, alignment: .leading) }
            if columns.size { heading(.size).frame(width: 72, alignment: .trailing) }
            if columns.kind { heading(.kind).frame(width: 128, alignment: .leading) }
        }
        .padding(.horizontal, 16)
        .frame(height: 24)
        .overlay(alignment: .bottom) { Rectangle().fill(NylaStyle.hairline).frame(height: 1) }
    }

    private func heading(_ key: BrowserSortKey) -> some View {
        Button {
            area.sort = area.sort.clicking(key)
        } label: {
            HStack(spacing: 3) {
                Text(key == .modified ? "Modified" : key.title)
                if area.sort.key == key {
                    Image(systemName: area.sort.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .font(.system(size: 11, weight: area.sort.key == key ? .semibold : .regular))
            .foregroundStyle(area.sort.key == key ? Color.primary : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sort by \(key.title.lowercased())")
    }
}

struct GroupHeading: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(NylaStyle.surface.opacity(0.96))
    }
}

/// One file or folder in the list: its name, a clearer name in grey (click to use it), clutter
/// flags, where it belongs (with Move), and its date, size and kind.
struct FileRowView: View {
    let item: BrowserItem
    let browser: FileBrowser
    let area: FilesArea
    let order: [String]
    let columns: FileColumns
    @Environment(AppModel.self) private var model
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        let selected = browser.selection.contains(item.id)
        HStack(spacing: 8) {
            FileGlyph(item: item, size: 20)
                .opacity(item.name.hasPrefix(".") ? 0.5 : 1)
            HStack(spacing: 6) {
                if browser.renaming == item.id {
                    InlineNameField(name: item.name, isFolder: item.isFolder, alignment: .left) { newName in
                        FilesActions.finishRename(item, newName: newName, browser: browser, model: model)
                    }
                    .frame(height: 20)
                    .frame(maxWidth: 420)
                } else {
                    Text(item.name)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .opacity(item.name.hasPrefix(".") ? 0.55 : 1)
                        .layoutPriority(1)
                    TagDots(tags: item.tags)
                    FileSmarts(item: item, browser: browser, compact: false)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if columns.date {
                Text(item.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "--")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 136, alignment: .leading)
            }
            if columns.size {
                Text(sizeText)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: 72, alignment: .trailing)
            }
            if columns.kind {
                Text(item.kindText)
                    .lineLimit(1)
                    .frame(width: 128, alignment: .leading)
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.92))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(targeted ? NylaStyle.brass.opacity(0.3) : selected ? NylaStyle.brass.opacity(0.18) : (hovering ? NylaStyle.wash(0.05) : Color.clear))
        }
        .contentShape(Rectangle())
        .onTapGesture { FileClicks.clicked(item, browser: browser, area: area, order: order, model: model) }
        .onHover { hovering = $0 }
        .fileHoverCard(item.url, isFolder: item.isFolder)
        .fileDragAndDrop(item, browser: browser, targeted: $targeted)
        .contextMenu { FileMenu(item: item, browser: browser, area: area) }
    }

    private var sizeText: String {
        if item.isFolder { return browser.folderSizes[item.id].map { ByteText.text($0) } ?? "--" }
        return item.byteCount.map { ByteText.text($0) } ?? "--"
    }
}

/// A file's icon, or a folder's.
struct FileGlyph: View {
    let item: BrowserItem
    let size: CGFloat

    var body: some View {
        if item.isFolder || item.url.pathExtension.lowercased() == "app" {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            FileTypeIcon(fileName: item.name, path: item.path, size: size, showsTag: size >= 40)
        }
    }
}

/// What EchoNyla adds to a file in the list: a clearer name in grey, clutter flags, and the folder it belongs in.
struct FileSmarts: View {
    let item: BrowserItem
    let browser: FileBrowser
    let compact: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        let insight = item.isFolder ? nil : model.insight(for: item)
        let betterName = insight.flatMap { $0.nameIsSure ? $0.proposedName : nil }.flatMap { $0 == item.name ? nil : $0 }
        let flags = ClutterCheck.flags(item, isCopy: browser.copies[item.id] != nil, isUsedInstaller: browser.usedInstallers.contains(item.id))
        let suggestion = item.isFolder ? nil : model.quickSuggestion(for: item)
        HStack(spacing: 5) {
            if let betterName {
                Button {
                    model.renameItem(item.url, to: betterName)
                } label: {
                    Text(betterName)
                        .font(.system(size: 11.5))
                        .italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .help("A clearer name from Apple Intelligence. Click to rename it to “\(betterName)”.")
            }
            ForEach(flags, id: \.self) { flag in
                Text(flag.title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(flag == .copy || flag == .usedInstaller ? NylaStyle.onAccent : Color.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(flag == .copy || flag == .usedInstaller ? NylaStyle.brass : NylaStyle.wash(0.1), in: Capsule())
                    .help(flag == .copy ? "An exact copy of “\(browser.copies[item.id] ?? "another file")” (checked byte for byte)." : flag.explanation)
            }
            if let suggestion, !compact {
                Button {
                    model.moveItems([item.url], toFavorite: suggestion.destinationID)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text(suggestion.folderName + (suggestion.isSure ? "" : "?"))
                            .lineLimit(1)
                        Text("Move")
                            .fontWeight(.semibold)
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(NylaStyle.brass)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(NylaStyle.brass.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .help(suggestion.isSure ? "Move it to \(suggestion.folderName)" : "It might belong in \(suggestion.folderName). Click to move it there.")
                WhyChip(why: suggestion.why)
            }
        }
    }
}

struct FileIconsView: View {
    let area: FilesArea
    let browser: FileBrowser
    let groups: [BrowserGroup]
    let order: [String]
    @Environment(AppModel.self) private var model

    static let spacing: CGFloat = 10

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: area.iconSize.cellWidth, maximum: area.iconSize.cellWidth + 24), spacing: Self.spacing)],
                          alignment: .leading, spacing: 12, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.items) { item in
                                FileIconCell(item: item, browser: browser, area: area, order: order)
                                    .id(item.id)
                            }
                        } header: {
                            if !group.title.isEmpty { GroupHeading(title: group.title, count: group.items.count) }
                        }
                    }
                }
                .padding(12)
                .fileDragContainer(browser)
            }
            .contentShape(Rectangle())
            .onTapGesture { FileClicks.clickedBackground(browser: browser, area: area, model: model) }
            .onChange(of: browser.cursor) { _, cursor in
                if let cursor { proxy.scrollTo(cursor) }
            }
            .onChange(of: browser.revealRequests) {
                if let cursor = browser.cursor { proxy.scrollTo(cursor, anchor: .center) }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newWidth in
            width = newWidth
            countColumns()
        }
        .onChange(of: area.iconSize) { countColumns() }
    }

    @State private var width: CGFloat = 0

    /// How many icons fit in a row, for the arrow keys.
    private func countColumns() {
        browser.iconColumns = max(1, Int((width - 24 + Self.spacing) / (area.iconSize.cellWidth + Self.spacing)))
    }
}

struct FileIconCell: View {
    let item: BrowserItem
    let browser: FileBrowser
    let area: FilesArea
    let order: [String]
    @Environment(AppModel.self) private var model
    @State private var picture: NSImage?
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        let selected = browser.selection.contains(item.id)
        VStack(spacing: 5) {
            ZStack {
                if let picture {
                    Image(nsImage: picture)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                } else {
                    FileGlyph(item: item, size: area.iconSize.glyph)
                }
            }
            .frame(width: area.iconSize.picture.width, height: area.iconSize.picture.height)
            if browser.renaming == item.id {
                InlineNameField(name: item.name, isFolder: item.isFolder, alignment: .center) { newName in
                    FilesActions.finishRename(item, newName: newName, browser: browser, model: model)
                }
                .frame(height: 20)
                .padding(.horizontal, 4)
            } else {
                Text(item.name)
                    .font(.system(size: 11.5))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(selected ? NylaStyle.brass.opacity(0.3) : Color.clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .opacity(item.name.hasPrefix(".") ? 0.55 : 1)
                TagDots(tags: item.tags)
            }
            FileSmarts(item: item, browser: browser, compact: true)
                .scaleEffect(0.9)
        }
        .frame(width: area.iconSize.cellWidth)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(targeted ? NylaStyle.brass.opacity(0.3) : selected ? NylaStyle.brass.opacity(0.12) : (hovering ? NylaStyle.wash(0.05) : Color.clear))
        }
        .contentShape(Rectangle())
        .onTapGesture { FileClicks.clicked(item, browser: browser, area: area, order: order, model: model) }
        .onHover { hovering = $0 }
        .fileHoverCard(item.url, isFolder: item.isFolder)
        .fileDragAndDrop(item, browser: browser, targeted: $targeted)
        .contextMenu { FileMenu(item: item, browser: browser, area: area) }
        .task(id: "\(item.id)|\(area.iconSize.rawValue)") {
            guard !item.isFolder else { return }
            picture = await FilePeekImages.image(for: item.url, side: area.iconSize.thumbnailSide)
        }
    }
}

// MARK: - Dragging

/// Files dragged inside EchoNyla. The drag itself carries every selected file (to Finder, Mail or any
/// app); this also remembers them for drops whose sender hands over only one.
@MainActor
enum FileDragBoard {
    private static var dragged: [URL] = []

    static func begin(_ urls: [URL]) {
        dragged = urls.map(\.standardizedFileURL)
    }

    /// The files to move for a drop: everything dragged together, or just what arrived.
    static func expand(_ urls: [URL]) -> [URL] {
        let arrived = urls.compactMap(normalize)
        defer { dragged = [] }
        if arrived.count == 1, dragged.contains(arrived[0]) { return dragged }
        return arrived
    }

    /// Finder sometimes hands over a reference ("file:///.file/id=…"); this is the file's real place.
    static func normalize(_ url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        if url.path.hasPrefix("/.file/id=") { return (url as NSURL).filePathURL?.standardizedFileURL }
        return url.standardizedFileURL
    }
}

extension View {
    /// The list or icons of one side: a drag that starts on a selected file carries every selected file.
    func fileDragContainer(_ browser: FileBrowser) -> some View {
        dragContainer(for: URL.self, itemID: \URL.path) { ids in
            let urls = ids.map { URL(fileURLWithPath: $0) }
            FileDragBoard.begin(urls)
            return urls
        }
        .dragContainerSelection(Array(browser.selection))
    }

    /// Drag the file (with the rest of the selection) and, on a folder, drop files into it.
    func fileDragAndDrop(_ item: BrowserItem, browser: FileBrowser, targeted: Binding<Bool>) -> some View {
        modifier(FileDragAndDrop(item: item, browser: browser, targeted: targeted))
    }
}

struct FileDragAndDrop: ViewModifier {
    let item: BrowserItem
    let browser: FileBrowser
    @Binding var targeted: Bool
    @Environment(AppModel.self) private var model

    @ViewBuilder
    func body(content: Content) -> some View {
        // Each file is an item of the list's drag container, so dragging a selected file drags the
        // whole selection, as in Finder.
        let dragging = content.draggable(containerItemID: item.id)
        if item.isFolder {
            dragging.dropDestination(for: URL.self) { urls, _ in
                model.moveItems(FileDragBoard.expand(urls), into: item.url)
                return true
            } isTargeted: { targeted = $0 }
        } else {
            dragging
        }
    }
}

// MARK: - Right-click menu

struct FileMenu: View {
    let item: BrowserItem
    let browser: FileBrowser
    let area: FilesArea
    @Environment(AppModel.self) private var model

    private var targets: [URL] {
        browser.selection.contains(item.id) ? browser.selectedURLs : [item.url]
    }

    var body: some View {
        Button("Open") {
            // A folder opens here, on this side; files open in their apps.
            if item.isFolder, targets.count == 1 {
                browser.go(to: item.url)
            } else {
                for url in targets where !model.isFolder(url) { NSWorkspace.shared.open(url) }
            }
        }
        if !item.isFolder {
            Button("Open With…") { openWith() }
            Button("Quick Look") {
                model.select(item.url)
                model.quickLookSelected()
            }
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(targets) }
        if item.isFolder, area.isSplit {
            Button("Open on the Other Side") {
                if let other = area.visibleSides.first(where: { $0 !== browser }) { other.go(to: item.url) }
            }
        }
        Divider()
        Button("Rename") { FilesActions.rename(item.id, in: browser) }
        Menu("Move To") {
            ForEach(model.favoriteFolders) { folder in
                Button(folder.name) { model.moveItems(targets, toFavorite: folder.id) }
            }
            if !model.favoriteFolders.isEmpty { Divider() }
            Button("Other Folder…") {
                if let folder = model.chooseFolder(title: "Move to…", prompt: "Move Here") { model.moveItems(targets, into: folder) }
            }
        }
        if item.isFolder {
            Button("Tidy This Folder") { model.tidy(item.url) }
            if model.favoriteID(at: item.path) == nil {
                Button("Add to Favorite Folders") { model.addFavorite(item.url) }
            }
        } else if model.aiReady {
            Button("Ask Apple Intelligence What It Is") {
                if !model.previewPaneShown { model.togglePreviewPane() }
                model.select(item.url)
            }
        }
        Divider()
        Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(targets as [NSURL])
        }
        Button("Copy Path") { model.copyPaths(targets) }
        Button("Move to Trash") { model.trashItems(targets) }
    }

    private func openWith() {
        let panel = NSOpenPanel()
        panel.title = "Open \(item.name) with…"
        panel.prompt = "Open"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let app = panel.url else { return }
        NSWorkspace.shared.open(targets, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - Keys

/// The keys in the Files area, as in Finder, plus 1 to 9 to send files to your folders.
@MainActor
@Observable
final class FilesKeys {
    static let shared = FilesKeys()
    /// Bumped to put the cursor in the search box (⌘F).
    var searchRequests = 0
    @ObservationIgnored private var monitor: Any?
    /// Letters typed to jump to a name, and when the last one was typed.
    @ObservationIgnored private var typed = ""
    @ObservationIgnored private var typedAt = Date.distantPast

    /// In the middle of typing a name: Space is part of it, not Quick Look.
    var isTypingName: Bool { !typed.isEmpty && Date().timeIntervalSince(typedAt) < TypeSelect.pause }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated { FilesKeys.shared.handle(event) }
            return handled ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private var model: AppModel { AppModel.shared }

    private func handle(_ event: NSEvent) -> Bool {
        guard model.selectedTab == .files, let window = event.window, !(window is NSPanel), window.attachedSheet == nil,
              NSApp.modalWindow == nil else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let typing = window.firstResponder is NSText
        let area = model.files
        let browser = area.active

        // These work even while typing in the search box.
        if flags == .command, key == "f" {
            searchRequests += 1
            return true
        }
        if flags == [.command, .shift], key == "n" {
            if typing { window.makeFirstResponder(nil) }
            FilesActions.newFolder(in: browser, model: model)
            return true
        }
        if event.keyCode == 53, typing, browser.renaming == nil, !browser.filterText.isEmpty || browser.searchResults != nil {
            browser.filterText = ""
            browser.clearSearch()
            window.makeFirstResponder(nil)
            return true
        }
        guard !typing else { return false }

        if event.keyCode == 49, flags.isEmpty, isTypingName {
            return typeSelect(" ", browser: browser, area: area)
        }
        let order = FilesLayout.order(browser, area: area, model: model)
        let plain = flags.isEmpty
        let shift = flags == [.shift]
        let icons = area.viewMode == .icons
        switch event.keyCode {
        case 125 where plain || shift:
            move(by: icons ? browser.iconColumns : 1, extend: shift, order: order)
        case 126 where plain || shift:
            move(by: icons ? -browser.iconColumns : -1, extend: shift, order: order)
        case 124 where icons && (plain || shift):
            move(by: 1, extend: shift, order: order)
        case 123 where icons && (plain || shift):
            move(by: -1, extend: shift, order: order)
        case 126 where flags == [.command]:
            browser.goUp()
            syncPane()
        case 125 where flags == [.command], 31 where flags == [.command]:
            let all = browser.searchResults ?? browser.items
            for item in all where browser.selection.contains(item.id) { FileClicks.open(item, browser: browser) }
        case 36 where plain, 76 where plain:
            guard browser.selection.count == 1, let id = browser.selection.first else { return false }
            FilesActions.rename(id, in: browser)
        case 47 where flags == [.command, .shift]:
            area.showsHidden.toggle()
            model.note(area.showsHidden ? "Showing hidden files. ⇧⌘. hides them again." : "Hidden files are hidden again.")
        case 51 where flags == [.command], 117 where flags == [.command]:
            let urls = browser.selectedURLs
            guard !urls.isEmpty else { return false }
            let next = nextAfter(Set(browser.selection), order: order)
            model.trashItems(urls)
            select(next)
        case 53 where plain:
            browser.selection = []
            browser.cursor = nil
            model.select(nil)
        case 48 where plain && area.isSplit:
            area.activeIndex = area.activeIndex == 0 ? 1 : 0
            syncPane()
        default:
            return handleCommand(key: key, flags: flags, browser: browser, area: area, order: order)
        }
        return true
    }

    private func handleCommand(key: String, flags: NSEvent.ModifierFlags, browser: FileBrowser, area: FilesArea, order: [String]) -> Bool {
        if flags == .command {
            switch key {
            case "z": model.undoFromNote()
            case "[": browser.goBack(); syncPane()
            case "]": browser.goForward(); syncPane()
            case "a":
                browser.selection = Set(order)
                model.select(browser.cursor.map { URL(fileURLWithPath: $0) }, count: max(order.count, 1))
            case "c":
                let urls = browser.selectedURLs
                guard !urls.isEmpty else { return false }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects(urls as [NSURL])
            case "v": model.pasteFiles(into: browser.folder)
            default: return false
            }
            return true
        }
        if flags == [.command, .option] {
            switch key {
            case "v": model.pasteFiles(into: browser.folder, moving: true)
            case "c": model.copyPaths(browser.selectedURLs)
            default: return false
            }
            return true
        }
        guard flags.isEmpty || flags == [.shift], key.count == 1 else { return false }
        // Typing a name jumps to it. Digits send files to your folders, unless you're already typing a name.
        guard let digit = Int(key), flags.isEmpty, !isTypingName else { return typeSelect(key, browser: browser, area: area) }
        if digit == 0 {
            select(nextAfter(Set(browser.selection), order: order))
            return true
        }
        let folders = model.quickSortFolders
        guard digit >= 1, digit <= folders.count else { return false }
        sendSelection(toFavorite: folders[digit - 1].id)
        return true
    }

    /// Jumps to the first name starting with what was typed (letters typed close together build a word).
    private func typeSelect(_ key: String, browser: FileBrowser, area: FilesArea) -> Bool {
        guard TypeSelect.types(key, continuing: isTypingName) else { return false }
        let now = Date()
        typed = now.timeIntervalSince(typedAt) < TypeSelect.pause ? typed + key : key
        typedAt = now
        let items = FilesLayout.groups(browser, area: area, model: model).flatMap(\.items).map { (id: $0.id, name: $0.name) }
        guard let id = TypeSelect.match(typed, in: items) else { return true }
        select(id)
        return true
    }

    /// Sends the selected files to a favorite folder and moves on to the next file.
    func sendSelection(toFavorite id: String) {
        let area = model.files
        let browser = area.active
        let urls = browser.selectedURLs
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        let order = FilesLayout.order(browser, area: area, model: model)
        let next = nextAfter(Set(browser.selection), order: order)
        model.moveItems(urls, toFavorite: id)
        select(next)
    }

    /// The first item after the selected ones, or the last one before them.
    private func nextAfter(_ selected: Set<String>, order: [String]) -> String? {
        guard let last = order.lastIndex(where: { selected.contains($0) }) else { return order.first }
        if let after = order[(last + 1)...].first(where: { !selected.contains($0) }) { return after }
        return order[..<last].last(where: { !selected.contains($0) })
    }

    private func select(_ id: String?) {
        let browser = model.files.active
        browser.selection = id.map { [$0] } ?? []
        browser.cursor = id
        browser.anchor = id
        model.select(id.map { URL(fileURLWithPath: $0) })
    }

    private func move(by offset: Int, extend: Bool, order: [String]) {
        let browser = model.files.active
        guard let next = SelectionRange.step(from: browser.cursor, by: offset, in: order) else { return }
        browser.cursor = next
        if extend, let anchor = browser.anchor {
            browser.selection = Set(SelectionRange.between(anchor, next, in: order))
        } else {
            browser.selection = [next]
            browser.anchor = next
        }
        model.select(URL(fileURLWithPath: next), count: max(browser.selection.count, 1))
    }

    /// The pane follows the side and the folder you're in.
    private func syncPane() {
        let browser = model.files.active
        model.select(browser.cursor.map { URL(fileURLWithPath: $0) }, count: max(browser.selection.count, 1))
    }
}

// MARK: - Renaming in the list

/// A file's name as a text box, as in Finder: the part before the extension is selected, Return or a
/// click elsewhere keeps the new name, Esc leaves the old one. `done` gets nil for Esc.
struct InlineNameField: NSViewRepresentable {
    let name: String
    let isFolder: Bool
    let alignment: NSTextAlignment
    let done: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: name)
        field.delegate = context.coordinator
        field.font = .systemFont(ofSize: 12.5)
        field.alignment = alignment
        field.isBezeled = false
        field.isBordered = true
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.focusRingType = .exterior
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setAccessibilityLabel("New name")
        let stem = RenameSelection.stemLength(of: name, isFolder: isFolder)
        // After SwiftUI has placed the box: take the typing cursor and select the name before the extension.
        DispatchQueue.main.async {
            guard let window = field.window else { return }
            window.makeFirstResponder(field)
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: stem)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.done = done
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var done: (String?) -> Void
        private var finished = false

        init(done: @escaping (String?) -> Void) {
            self.done = done
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                finish(control.stringValue)
                control.window?.makeFirstResponder(nil)
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                finish(nil)
                control.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }

        /// Clicking somewhere else keeps the new name, as in Finder.
        func controlTextDidEndEditing(_ notification: Notification) {
            finish((notification.object as? NSTextField)?.stringValue)
        }

        private func finish(_ text: String?) {
            guard !finished else { return }
            finished = true
            done(text)
        }
    }
}

// MARK: - Finder tags

/// A file's Finder tags as small dots in its colours (grey for tags without one), as in Finder's list.
struct TagDots: View {
    let tags: [String]

    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: -3) {
                ForEach(Array(tags.prefix(3).enumerated()), id: \.offset) { _, tag in
                    Circle()
                        .fill(FinderTagColor.color(for: tag))
                        .overlay(Circle().strokeBorder(NylaStyle.surface, lineWidth: 1))
                        .frame(width: 9, height: 9)
                }
            }
            .help("Tags: " + tags.joined(separator: ", "))
            .accessibilityLabel("Tags: " + tags.joined(separator: ", "))
        }
    }
}

/// Finder's seven colour tags by name (in your Mac's language); other tags are grey.
@MainActor
enum FinderTagColor {
    private static let byName: [String: NSColor] = {
        var colors: [String: NSColor] = [:]
        let workspace = NSWorkspace.shared
        for (index, label) in workspace.fileLabels.enumerated() where index > 0 && index < workspace.fileLabelColors.count {
            colors[label.lowercased()] = workspace.fileLabelColors[index]
        }
        return colors
    }()

    static func color(for tag: String) -> Color {
        byName[tag.lowercased()].map { Color(nsColor: $0) } ?? Color.secondary.opacity(0.6)
    }
}
