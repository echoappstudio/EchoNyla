import AppKit
import EchoNylaCore
import Foundation
import Observation

enum BrowserViewMode: String, CaseIterable {
    case list, icons
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
            if isSplit, sides.count < 2 { sides.append(FileBrowser(start: sides[0].folder)) }
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

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? home
        sides = [FileBrowser(start: downloads)]
        let defaults = UserDefaults.standard
        sort = defaults.data(forKey: AppModel.Keys.filesSort).flatMap { try? JSONDecoder().decode(BrowserSort.self, from: $0) } ?? BrowserSort()
        grouping = defaults.string(forKey: AppModel.Keys.filesGrouping).flatMap(BrowserGrouping.init(rawValue:)) ?? .none
        viewMode = defaults.string(forKey: AppModel.Keys.filesViewMode).flatMap(BrowserViewMode.init(rawValue:)) ?? .list
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
    private(set) var items: [BrowserItem] = []
    private(set) var isLoading = false
    private(set) var loadError: String?
    var selection: Set<String> = []
    /// Where a Shift-click or Shift-arrow selection starts.
    var anchor: String?
    /// The item the keys move from: the one clicked or arrowed to last.
    var cursor: String?
    var filterText = ""
    /// Plain-words search results in this folder; nil when not searching.
    private(set) var searchResults: [BrowserItem]?
    private(set) var isSearching = false
    private(set) var searchNote: String?
    private(set) var folderSizes: [String: Int64] = [:]
    private(set) var copies: [String: String] = [:]
    private(set) var usedInstallers: Set<String> = []
    /// A file being renamed (its path), for the rename box.
    var renaming: String?
    /// How many icons fit across, for the arrow keys.
    @ObservationIgnored var iconColumns = 4

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var extrasTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private let searcher = FileSearcher()
    @ObservationIgnored private var loadedPath: String?

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
        watch(path)
        loadTask = Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { Self.list(path) }.value
            guard !Task.isCancelled, path == history.current else { return }
            isLoading = false
            switch result {
            case .success(let listed):
                items = listed
                // Going up selects the folder you came from; anything that's gone is let go.
                let ids = Set(listed.map(\.id))
                selection = selection.filter { ids.contains($0) }
                if let cursor, !ids.contains(cursor) { self.cursor = nil }
                findExtras(listed, folder: path)
            case .failure(let message):
                items = []
                loadError = message
            }
        }
    }

    enum ListResult: Sendable {
        case success([BrowserItem])
        case failure(String)
    }

    nonisolated static func list(_ path: String) -> ListResult {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey,
                                      .addedToDirectoryDateKey, .localizedTypeDescriptionKey]
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            return .success(urls.map { item(for: $0, keys: keys) })
        } catch {
            let code = (error as NSError).code
            if code == NSFileReadNoPermissionError {
                return .failure("macOS hasn't let EchoNyla look in this folder. Allow it in System Settings › Privacy & Security › Files and Folders.")
            }
            return .failure("EchoNyla can't read this folder: \(error.localizedDescription)")
        }
    }

    nonisolated static func item(for url: URL, keys: [URLResourceKey]? = nil) -> BrowserItem {
        let wanted = keys ?? [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey,
                              .addedToDirectoryDateKey, .localizedTypeDescriptionKey]
        let values = try? url.resourceValues(forKeys: Set(wanted))
        let isFolder = values?.isDirectory == true && values?.isPackage != true
        return BrowserItem(path: url.standardizedFileURL.path, isFolder: isFolder,
                           byteCount: isFolder ? nil : values?.fileSize.map { Int64($0) },
                           modified: values?.contentModificationDate, created: values?.creationDate,
                           added: values?.addedToDirectoryDate, lastOpened: isFolder ? nil : FileDetails.lastOpened(url),
                           kindText: values?.localizedTypeDescription ?? (isFolder ? "Folder" : ""),
                           isScreenshot: !isFolder && ScreenshotMetadata.isScreenCapture(at: url))
    }

    /// In the background, after the list shows: how big each folder inside is, which files are
    /// exact copies of each other (checked byte for byte) and which installers are already installed.
    private func findExtras(_ listed: [BrowserItem], folder path: String) {
        extrasTask?.cancel()
        let files = listed.filter { !$0.isFolder }.map(\.url)
        let installers = listed.filter { $0.url.pathExtension.lowercased() == "dmg" }.map(\.url)
        let folders = listed.filter(\.isFolder).map(\.url)
        extrasTask = Task { @MainActor in
            let found = await Task.detached(priority: .utility) { () -> (copies: [String: String], installers: Set<String>) in
                var copies: [String: String] = [:]
                for group in ExactCopy.groups(files) {
                    let modified = Dictionary(uniqueKeysWithValues: group.map {
                        ($0.path, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
                    })
                    guard let keep = DuplicateFinder.keeper(group.map(\.path), modified: modified) else { continue }
                    let keepName = URL(fileURLWithPath: keep).lastPathComponent
                    for copy in group where copy.path != keep { copies[copy.path] = keepName }
                }
                var used: Set<String> = []
                if !installers.isEmpty {
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
            }.value
            guard !Task.isCancelled, path == history.current else { return }
            copies = found.copies
            usedInstallers = found.installers
            for folder in folders {
                guard !Task.isCancelled, path == history.current else { return }
                if let size = await Task.detached(priority: .utility, operation: { FolderSize.total(of: folder) }).value {
                    guard !Task.isCancelled, path == history.current else { return }
                    folderSizes[folder.standardizedFileURL.path] = size
                }
            }
        }
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
            guard scope == folder else { return }
            let found = await Task.detached(priority: .userInitiated) { results.map { Self.item(for: $0.url) } }.value
            searchResults = found
            isSearching = false
            selection = []
            searchNote = AppModel.describe(request, usedAI: usedAI, count: found.count)
        }
    }

    func clearSearch() {
        searchResults = nil
        searchNote = nil
        isSearching = false
    }
}
