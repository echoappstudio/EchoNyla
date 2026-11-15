import AppKit
import EchoNylaCore
import Foundation
import Observation
import os

/// How long reading and laying out a folder takes (counts and milliseconds only, never names):
/// `log stream --predicate 'subsystem == "com.echoapps.echonyla"'`.
let filesTiming = Logger(subsystem: "com.echoapps.echonyla", category: "files")

enum BrowserViewMode: String, CaseIterable {
    case list, icons
}

/// How big icons and pictures are in icons view. Large makes photos easy to tell apart without
/// opening them.
enum IconSize: String, CaseIterable {
    case small, medium, large

    var title: String { rawValue.capitalized }
    var cellWidth: CGFloat {
        switch self {
        case .small: 112
        case .medium: 168
        case .large: 236
        }
    }
    /// The picture's box inside a cell.
    var picture: CGSize {
        switch self {
        case .small: CGSize(width: 72, height: 64)
        case .medium: CGSize(width: 136, height: 112)
        case .large: CGSize(width: 204, height: 168)
        }
    }
    var glyph: CGFloat {
        switch self {
        case .small: 56
        case .medium: 80
        case .large: 104
        }
    }
    /// The size thumbnails are drawn at, so they stay sharp.
    var thumbnailSide: CGFloat { max(picture.width, picture.height) * 2 }
}

/// The Files area: one side, or two side by side, and which one the keys and toolbar work on.
@MainActor
@Observable
final class FilesArea {
    var sides: [FileBrowser]
    var activeIndex = 0
    var isSplit = false {
        didSet {
            if !isSplit { activeIndex = 0 }
            if isSplit, sides.count < 2 {
                let other = FileBrowser(start: sides[0].folder)
                other.showsHidden = showsHidden
                sides.append(other)
            }
        }
    }
    var sort: BrowserSort {
        didSet { save(sort, key: AppModel.Keys.filesSort) }
    }
    var grouping: BrowserGrouping {
        didSet { UserDefaults.standard.set(grouping.rawValue, forKey: AppModel.Keys.filesGrouping) }
    }
    var viewMode: BrowserViewMode {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: AppModel.Keys.filesViewMode) }
    }
    var iconSize: IconSize {
        didSet { UserDefaults.standard.set(iconSize.rawValue, forKey: AppModel.Keys.filesIconSize) }
    }
    /// Files whose names start with a dot, shown dimmed (⇧⌘. as in Finder).
    var showsHidden: Bool {
        didSet {
            UserDefaults.standard.set(showsHidden, forKey: AppModel.Keys.filesShowsHidden)
            for side in sides {
                side.showsHidden = showsHidden
                side.reload()
            }
        }
    }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? home
        sides = [FileBrowser(start: downloads)]
        let defaults = UserDefaults.standard
        sort = defaults.data(forKey: AppModel.Keys.filesSort).flatMap { try? JSONDecoder().decode(BrowserSort.self, from: $0) } ?? BrowserSort()
        grouping = defaults.string(forKey: AppModel.Keys.filesGrouping).flatMap(BrowserGrouping.init(rawValue:)) ?? .none
        viewMode = defaults.string(forKey: AppModel.Keys.filesViewMode).flatMap(BrowserViewMode.init(rawValue:)) ?? .list
        iconSize = defaults.string(forKey: AppModel.Keys.filesIconSize).flatMap(IconSize.init(rawValue:)) ?? .small
        showsHidden = defaults.bool(forKey: AppModel.Keys.filesShowsHidden)
        sides[0].showsHidden = showsHidden
    }

    var active: FileBrowser { sides[min(activeIndex, visibleSides.count - 1)] }
    var visibleSides: [FileBrowser] { isSplit ? Array(sides.prefix(2)) : [sides[0]] }

    func activate(_ browser: FileBrowser) {
        if let index = visibleSides.firstIndex(where: { $0 === browser }) { activeIndex = index }
    }

    /// After a move, rename or Trash: every side shows the change at once.
    func reloadAll() {
        for side in sides { side.reload() }
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// One side of the Files area: the folder it shows, what's in it, what's selected, and what
/// EchoNyla worked out about it (sizes of folders inside, exact copies, used installers).
@MainActor
@Observable
final class FileBrowser: Identifiable {
    let id = UUID()
    private(set) var history: BrowserHistory
    private(set) var items: [BrowserItem] = [] {
        didSet { listVersion &+= 1 }
    }
    private(set) var isLoading = false
    private(set) var loadError: String?
    /// macOS keeps EchoNyla out of this folder; this is the switch that lets it in.
    private(set) var blocked: PrivacySwitch?
    var selection: Set<String> = []
    /// Where a Shift-click or Shift-arrow selection starts.
    var anchor: String?
    /// The item the keys move from: the one clicked or arrowed to last.
    var cursor: String?
    var filterText = ""
    /// Plain-words search results in this folder; nil when not searching.
    private(set) var searchResults: [BrowserItem]? {
        didSet { listVersion &+= 1 }
    }
    private(set) var isSearching = false
    private(set) var searchNote: String?
    private(set) var folderSizes: [String: Int64] = [:]
    private(set) var copies: [String: String] = [:]
    private(set) var usedInstallers: Set<String> = []
    /// A file being renamed (its path): its name turns into a text box in the list.
    var renaming: String?
    /// Hidden files are listed too.
    @ObservationIgnored var showsHidden = false
    /// A file that isn't in the list yet (just made or renamed): once the folder is read again, the
    /// list scrolls to it.
    @ObservationIgnored var revealAfterLoad: String?
    /// Bumped when the list should scroll to the cursor.
    private(set) var revealRequests = 0
    /// How many icons fit across, for the arrow keys.
    @ObservationIgnored var iconColumns = 4

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var extrasTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private let searcher = FileSearcher()
    /// Counts searches, so an older one that finishes late doesn't replace a newer one's results.
    @ObservationIgnored private var searchRun = 0
    @ObservationIgnored private var loadedPath: String?
    /// Bumped whenever the folder's items or the search results change, so the sorted and grouped
    /// list is only worked out again when something it depends on changed.
    @ObservationIgnored private var listVersion = 0
    @ObservationIgnored private var layoutCache: (key: LayoutKey, groups: [BrowserGroup])?

    struct LayoutKey: Equatable {
        let list: Int
        let filter: String
        let sort: BrowserSort
        let grouping: BrowserGrouping
        let insights: Int
    }

    init(start: URL) {
        history = BrowserHistory(start: start.standardizedFileURL.path)
    }

    var folder: URL { URL(fileURLWithPath: history.current, isDirectory: true) }
    var folderName: String {
        let path = history.current
        if path == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path { return "Home" }
        return path == "/" ? "Computer" : folder.lastPathComponent
    }

    /// What the list shows: search results or the folder, narrowed by what's typed, in the chosen order.
    func shown(sort: BrowserSort) -> [BrowserItem] {
        let base = searchResults ?? items
        let filtered = searchResults == nil && !filterText.isEmpty ? base.filter { NameFilter.matches($0.name, filterText) } : base
        return sort.sorted(filtered)
    }

    /// The list as the screen and the keys see it: filtered, sorted and grouped. Worked out once per
    /// change instead of on every redraw and key press (sorting thousands of names took a moment each time).
    func layout(sort: BrowserSort, grouping: BrowserGrouping, insightsVersion: Int,
                category: (BrowserItem) -> FileCategory) -> [BrowserGroup] {
        // Reading these tells SwiftUI the list depends on them.
        _ = items
        _ = searchResults
        let key = LayoutKey(list: listVersion, filter: searchResults == nil ? filterText : "", sort: sort, grouping: grouping,
                            insights: grouping == .meaning ? insightsVersion : 0)
        if let layoutCache, layoutCache.key == key { return layoutCache.groups }
        let started = ContinuousClock.now
        let groups = BrowserGroups.make(shown(sort: sort), by: grouping, category: category)
        layoutCache = (key, groups)
        filesTiming.info("Sorted and grouped \(groups.reduce(0) { $0 + $1.items.count }) items in \(Self.milliseconds(since: started)) ms")
        return groups
    }

    nonisolated static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    var selectedURLs: [URL] {
        let all = searchResults ?? items
        return all.filter { selection.contains($0.id) }.map(\.url)
    }

    // MARK: Going places

    func go(to url: URL) {
        let path = url.standardizedFileURL.path
        guard path != history.current else { return }
        history.visit(path)
        enteredFolder()
    }

    func goBack() {
        guard history.canGoBack else { return }
        history.goBack()
        enteredFolder()
    }

    func goForward() {
        guard history.canGoForward else { return }
        history.goForward()
        enteredFolder()
    }

    func goUp() {
        let parent = folder.deletingLastPathComponent()
        guard parent.path != folder.path else { return }
        let came = history.current
        go(to: parent)
        selection = [came]
        cursor = came
        anchor = came
    }

    private func enteredFolder() {
        selection = []
        cursor = nil
        anchor = nil
        filterText = ""
        renaming = nil
        clearSearch()
        items = []
        folderSizes = [:]
        copies = [:]
        usedInstallers = []
        load()
    }

    // MARK: Reading the folder

    /// Reads the folder (first time it's shown, or after you go somewhere).
    func loadIfNeeded() {
        if loadedPath != history.current { load() }
    }

    func reload() {
        load()
    }

    private func load() {
        let path = history.current
        loadedPath = path
        loadTask?.cancel()
        isLoading = items.isEmpty
        loadError = nil
        blocked = nil
        watch(path)
        let hidden = showsHidden
        loadTask = Task { @MainActor in
            let started = ContinuousClock.now
            let result = await Task.detached(priority: .userInitiated) { Self.list(path, showsHidden: hidden) }.value
            if case .success(let listed) = result {
                filesTiming.info("Read \(listed.count) items in \(Self.milliseconds(since: started)) ms")
            }
            guard !Task.isCancelled, path == history.current else { return }
            isLoading = false
            switch result {
            case .success(let listed):
                items = listed
                // Going up selects the folder you came from; anything that's gone is let go.
                let ids = Set(listed.map(\.id))
                selection = selection.filter { ids.contains($0) }
                if let cursor, !ids.contains(cursor) { self.cursor = nil }
                if let reveal = revealAfterLoad, ids.contains(reveal) {
                    revealAfterLoad = nil
                    revealRequests += 1
                }
                findExtras(listed, folder: path)
            case .failure(let message):
                items = []
                loadError = message
            case .blocked:
                items = []
                blocked = PrivacySwitch.forFolder(path, home: FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path)
            }
        }
    }

    enum ListResult: Sendable {
        case success([BrowserItem])
        case failure(String)
        /// macOS's privacy settings keep EchoNyla out.
        case blocked
    }

    nonisolated static func list(_ path: String, showsHidden: Bool = false) -> ListResult {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let keys = listKeys
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                   options: showsHidden ? [] : [.skipsHiddenFiles])
            return .success(urls.map { item(for: $0, keys: keys) })
        } catch {
            let nsError = error as NSError
            let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            if nsError.code == NSFileReadNoPermissionError || underlying?.code == Int(EPERM) || underlying?.code == Int(EACCES) {
                return .blocked
            }
            return .failure("EchoNyla can't read this folder: \(error.localizedDescription)")
        }
    }

    nonisolated static func item(for url: URL, keys: [URLResourceKey]? = nil) -> BrowserItem {
        let wanted = keys ?? listKeys
        let values = try? url.resourceValues(forKeys: Set(wanted))
        let isFolder = values?.isDirectory == true && values?.isPackage != true
        let name = url.lastPathComponent
        // Spotlight is asked only when it can change what the list shows (one trip per file was the
        // slowest part of opening a big folder).
        let askLastOpened = !isFolder && ListingCheck.needsLastOpened(modified: values?.contentModificationDate,
                                                                        added: values?.addedToDirectoryDate)
        return BrowserItem(path: url.standardizedFileURL.path, isFolder: isFolder,
                           byteCount: isFolder ? nil : values?.fileSize.map { Int64($0) },
                           modified: values?.contentModificationDate, created: values?.creationDate,
                           added: values?.addedToDirectoryDate, lastOpened: askLastOpened ? FileDetails.lastOpened(url) : nil,
                           kindText: values?.localizedTypeDescription ?? (isFolder ? "Folder" : ""),
                           isScreenshot: !isFolder && ListingCheck.mayBeScreenshot(fileName: name) && ScreenshotMetadata.isScreenCapture(at: url),
                           tags: values?.tagNames ?? [])
    }

    /// What listing a folder reads about each item, in one go.
    nonisolated static let listKeys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey,
                                                         .creationDateKey, .addedToDirectoryDateKey, .localizedTypeDescriptionKey,
                                                         .tagNamesKey]

    /// In the background, after the list shows: how big each folder inside is, which files are
    /// exact copies of each other (checked byte for byte) and which installers are already installed.
    private func findExtras(_ listed: [BrowserItem], folder path: String) {
        extrasTask?.cancel()
        let files = listed.filter { !$0.isFolder }.map(\.url)
        let installers = listed.filter { $0.url.pathExtension.lowercased() == "dmg" }.map(\.url)
        let folders = listed.filter(\.isFolder).map(\.url)
        extrasTask = Task { @MainActor in
            let found = await Self.findCopies(files: files, installers: installers)
            guard !Task.isCancelled, path == history.current else { return }
            copies = found.copies
            usedInstallers = found.installers
            // Sizes already worked out show at once; the rest are added up one folder at a time.
            var known: [String: Int64] = [:]
            var unknown: [URL] = []
            for folder in folders {
                if let size = FolderSizeCache.size(of: folder) { known[folder.standardizedFileURL.path] = size } else { unknown.append(folder) }
            }
            if !known.isEmpty { folderSizes.merge(known) { _, new in new } }
            for folder in unknown {
                guard !Task.isCancelled, path == history.current else { return }
                if let size = await Self.addUp(folder) {
                    guard !Task.isCancelled, path == history.current else { return }
                    FolderSizeCache.store(size, for: folder)
                    folderSizes[folder.standardizedFileURL.path] = size
                }
            }
        }
    }

    /// Exact copies (checked byte for byte) and installers of apps already in Applications, away from
    /// the screen's thread. Stops when the folder is left.
    @concurrent
    nonisolated private static func findCopies(files: [URL], installers: [URL]) async -> (copies: [String: String], installers: Set<String>) {
        var copies: [String: String] = [:]
        for group in ExactCopy.groups(files, isCancelled: { Task.isCancelled }) {
            let modified = Dictionary(uniqueKeysWithValues: group.map {
                ($0.path, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
            })
            guard let keep = DuplicateFinder.keeper(group.map(\.path), modified: modified) else { continue }
            let keepName = URL(fileURLWithPath: keep).lastPathComponent
            for copy in group where copy.path != keep { copies[copy.path] = keepName }
        }
        var used: Set<String> = []
        if !installers.isEmpty, !Task.isCancelled {
            let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
            let apps = (try? FileManager.default.contentsOfDirectory(at: applications, includingPropertiesForKeys: nil,
                                                                      options: [.skipsHiddenFiles])) ?? []
            let policy = TrashPolicy()
            for installer in installers where policy.suggestion(for: installer, downloadsFolder: installer.deletingLastPathComponent(),
                                                               applicationsFolder: applications, installedApps: apps) != nil {
                used.insert(installer.standardizedFileURL.path)
            }
        }
        return (copies, used)
    }

    /// Adds up a folder away from the screen's thread, and stops when the folder is left.
    @concurrent
    nonisolated private static func addUp(_ folder: URL) async -> Int64? {
        FolderSize.total(of: folder, isCancelled: { Task.isCancelled })
    }

    // MARK: Watching the folder

    /// Shows files as they arrive or leave, as Finder does.
    private func watch(_ path: String) {
        watcher?.cancel()
        watcher = nil
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.changedOnDisk() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    private func changedOnDisk() {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            reload()
        }
    }

    /// After a visit to System Settings: if macOS kept EchoNyla out, look again.
    func retryIfBlocked() {
        if blocked != nil || loadError != nil { reload() }
    }

    /// Stops watching (the Files area is closed or this side is hidden).
    func stopWatching() {
        watcher?.cancel()
        watcher = nil
        loadedPath = nil
    }

    // MARK: Searching in plain words

    /// "tax PDFs from last spring", searched in this folder and the folders inside it.
    func search(_ sentence: String, model: AppModel) {
        let clean = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            clearSearch()
            return
        }
        isSearching = true
        searchNote = nil
        let scope = folder
        searchRun += 1
        let run = searchRun
        Task { @MainActor in
            var request = SpotlightQuery.fallbackRequest(from: clean)
            var usedAI = false
            if model.aiReady, let understood = try? await OnDeviceModel.search(clean, today: AppModel.todayText()), !understood.isEmpty {
                request = understood
                usedAI = true
            }
            guard let query = SpotlightQuery.make(request) else {
                isSearching = false
                searchResults = []
                searchNote = "Describe the file with a few words, like “tax PDFs from last spring”."
                return
            }
            let results = await searcher.run(query, in: scope, limit: 300)
            guard run == searchRun, scope == folder else { return }
            // Photos and recordings have no words for Spotlight; EchoNyla's own look at them does.
            let spotlightPaths = Set(results.map { $0.url.standardizedFileURL.path })
            let understood = model.understoodFiles(matching: request, besides: spotlightPaths, limit: 300 - results.count, in: scope)
            let urls = results.map(\.url) + understood.map(\.url)
            let found = await Task.detached(priority: .userInitiated) { urls.map { Self.item(for: $0) } }.value
            guard run == searchRun, scope == folder else { return }
            searchResults = found
            isSearching = false
            selection = []
            searchNote = AppModel.describe(request, usedAI: usedAI, count: found.count)
        }
    }

    func clearSearch() {
        searchRun += 1
        searchResults = nil
        searchNote = nil
        isSearching = false
    }
}

/// Folder sizes worked out while EchoNyla runs, so going back to a folder doesn't add everything
/// up again. A size is kept 10 minutes, and only while the folder itself hasn't changed.
@MainActor
enum FolderSizeCache {
    private struct Entry {
        let size: Int64
        let modified: Date?
        let measured: Date
    }

    private static var entries: [String: Entry] = [:]
    static let lifetime: TimeInterval = 600

    static func size(of folder: URL) -> Int64? {
        guard let entry = entries[folder.standardizedFileURL.path], Date().timeIntervalSince(entry.measured) < lifetime,
              entry.modified == modified(folder) else { return nil }
        return entry.size
    }

    static func store(_ size: Int64, for folder: URL) {
        if entries.count > 2_000 { entries = entries.filter { Date().timeIntervalSince($0.value.measured) < lifetime } }
        entries[folder.standardizedFileURL.path] = Entry(size: size, modified: modified(folder), measured: Date())
    }

    private static func modified(_ folder: URL) -> Date? {
        (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
