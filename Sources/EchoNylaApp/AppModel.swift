import AppKit
import Foundation
import Observation
import EchoNylaCore

struct FavoriteFolder: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var bookmarkData: Data
    /// "What goes here". Apple Intelligence only suggests folders that have one.
    var purpose: String?
}

/// A folder you cleaned, remembered for Clean Up's button and Choose Folder's menu.
struct RecentCleanupFolder: Codable, Equatable {
    var path: String
    var bookmarkData: Data
}

struct CleanupEntry: Identifiable {
    var id: String { url.path }
    let url: URL
    var destinationID: String?
    /// A folder picked with Any Folder… (not a favorite); used instead of `destinationID`.
    var chosenFolder: URL?
    var suggestionReason: String?
    var isSelected: Bool
    /// Which part of Clean Up the file is listed in, set by the suggestion it got (your own changes
    /// don't move it, so rows stay put while you work).
    var bucket: CleanupBucket = .none
    /// A clearer name from Apple Intelligence, applied only when `renameSelected` is on.
    var proposedName: String?
    var renameSelected = false
    var summary: String?

    var hasTarget: Bool { destinationID != nil || chosenFolder != nil }
}

/// A folder the setup helper offers as a favorite, with a drafted "What goes here" note.
struct SetupCandidate: Identifiable {
    var id: String { url.path }
    let url: URL
    let fileCount: Int
    var note: String
    var isSelected = false
    var isDrafting = false
}

struct TrashEntry: Identifiable {
    var id: String { url.path }
    let url: URL
    let reason: String
    var isSelected: Bool
}

/// A file dropped on the panel that's waiting for your choice.
struct PendingFile {
    let url: URL
    var suggestionID: String?
    var reason: String?
    var proposedName: String?
    var summary: String?
    var isThinking: Bool
}

/// Everything EchoNyla does. Moves are always undoable; nothing is ever deleted.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var favoriteFolders: [FavoriteFolder] = []
    private(set) var rules: [DestinationRule] = []
    private(set) var learning: [LearningRecord] = []
    var pending: PendingFile?
    var selectedTab: MainTab = .activity
    var lastMove: MoveBatchReceipt?
    var statusMessage: String?
    var userError: String?
    private(set) var activity: [ActivityEntry] = []

    private(set) var cleanupFolder: URL?
    private(set) var cleanupRows: [CleanupEntry] = []
    private(set) var trashRows: [TrashEntry] = []
    private(set) var folderGroups: [FolderGroup] = []
    var selectedGroupIDs: Set<String> = []
    private(set) var minimumRelatedFileCount: Int = FolderGroupingSettings.defaultMinimumRelatedFiles
    private(set) var cleanupProgress: String?
    private var aiGroups: [FolderGroup] = []
    /// Folders you cleaned, newest first; the first is where Clean Up starts after a relaunch.
    private(set) var recentCleanupFolders: [URL] = []

    private(set) var watchedFolders: [FavoriteFolder] = []
    private(set) var setupCandidates: [SetupCandidate] = []
    /// The setup helper sheet in the main window.
    var isSetupOpen = false {
        didSet { if isSetupOpen && !oldValue { prepareSetup() } }
    }
    private(set) var isPreparingSetup = false
    /// Loose files in Downloads for the weekly reminder in the panel, or nil when it's hidden.
    private(set) var tidyReminderCount: Int?
    private(set) var searchResults: [SearchResult] = []
    private(set) var searchNote: String?
    private(set) var isSearching = false
    private(set) var explaining: Set<String> = []
    private(set) var explanations: [String: String] = [:]

    // Settings (saved as they change).
    private var storedAIEnabled: Bool
    private var storedReadContents: Bool
    private var storedAutoMove: Bool
    private var storedNotifications: Bool
    private var storedWatchDownloads: Bool
    private var storedWatchDesktop: Bool
    private var storedAIGroups: Bool
    private var storedTidyReminder: Bool

    var aiEnabled: Bool {
        get { storedAIEnabled }
        set { storedAIEnabled = newValue; defaults.set(newValue, forKey: Keys.aiEnabled) }
    }
    var readContents: Bool {
        get { storedReadContents }
        set { storedReadContents = newValue; defaults.set(newValue, forKey: Keys.readContents) }
    }
    var autoMove: Bool {
        get { storedAutoMove }
        set { storedAutoMove = newValue; defaults.set(newValue, forKey: Keys.autoMove) }
    }
    var notificationsEnabled: Bool {
        get { storedNotifications }
        set { storedNotifications = newValue; defaults.set(newValue, forKey: Keys.notifications) }
    }
    var watchDownloads: Bool {
        get { storedWatchDownloads }
        set { storedWatchDownloads = newValue; defaults.set(newValue, forKey: Keys.watchDownloads); restartWatching() }
    }
    var watchDesktop: Bool {
        get { storedWatchDesktop }
        set { storedWatchDesktop = newValue; defaults.set(newValue, forKey: Keys.watchDesktop); restartWatching() }
    }
    /// The weekly Downloads reminder in the panel.
    var tidyReminderEnabled: Bool {
        get { storedTidyReminder }
        set { storedTidyReminder = newValue; defaults.set(newValue, forKey: Keys.tidyReminder); refreshTidyReminder() }
    }
    /// Apple Intelligence's new-folder suggestions in Clean Up. Off unless you turn it on.
    var aiGroupsEnabled: Bool {
        get { storedAIGroups }
        set { storedAIGroups = newValue; defaults.set(newValue, forKey: Keys.aiGroups); if !newValue { aiGroups = []; refreshFolderGroups() } }
    }

    enum Keys {
        static let folders = "EchoNyla.favoriteFolders.v1"
        static let rules = "EchoNyla.destinationRules.v1"
        static let learning = "EchoNyla.learning.v1"
        static let lastMove = "EchoNyla.lastMove.v1"
        static let activity = "EchoNyla.activity.v1"
        static let watchedFolders = "EchoNyla.watchedFolders.v1"
        static let aiEnabled = "EchoNyla.ai.enabled"
        static let readContents = "EchoNyla.ai.readContents"
        static let autoMove = "EchoNyla.autoMove"
        static let notifications = "EchoNyla.notifications"
        static let watchDownloads = "EchoNyla.watch.downloads"
        static let watchDesktop = "EchoNyla.watch.desktop"
        static let aiGroups = "EchoNyla.ai.groups"
        static let hasLaunched = "EchoNyla.hasLaunched.v1"
        static let tidyReminder = "EchoNyla.tidyReminder.enabled.v1"
        static let tidyReminderDismissed = "EchoNyla.tidyReminder.dismissed.v1"
        static let renameFirst = "EchoNyla.panel.renameFirst.v1"
        static let recentCleanupFolders = "EchoNyla.cleanup.recentFolders.v1"
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let folderGroupingSettings: FolderGroupingSettings
    @ObservationIgnored private let fileManager = FileManager.default
    @ObservationIgnored private let mover = FileMoveService()
    @ObservationIgnored private var cleanupScopeURL: URL?
    @ObservationIgnored private var cleanupScopeIsActive = false
    @ObservationIgnored private var recentCleanupRecords: [RecentCleanupFolder] = []
    /// The Apple Intelligence review of Clean Up that's running. Each new one replaces the last.
    @ObservationIgnored private var cleanupReview: Task<Void, Never>?
    @ObservationIgnored private var cleanupReviewRun = 0
    @ObservationIgnored private var watchStates: [String: FolderWatchState] = [:]
    @ObservationIgnored private var watchTimer: Timer?
    @ObservationIgnored private var watchScopes: [URL] = []
    @ObservationIgnored private var watchQueue: [URL] = []
    @ObservationIgnored private var isProcessingQueue = false
    /// Files EchoNyla put back or renamed itself; watching never acts on them again.
    @ObservationIgnored private var handledPaths: Set<String> = []
    /// Where files EchoNyla itself moved or renamed came from, so their leaving a watched folder is
    /// never mistaken for a move you made in Finder.
    @ObservationIgnored private var appMovedPaths: Set<String> = []
    @ObservationIgnored private var tidyTimer: Timer?
    @ObservationIgnored private let searcher = FileSearcher()

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let groupingSettings = FolderGroupingSettings(defaults: defaults)
        folderGroupingSettings = groupingSettings
        func flag(_ key: String) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
        storedAIEnabled = flag(Keys.aiEnabled)
        storedReadContents = flag(Keys.readContents)
        storedAutoMove = flag(Keys.autoMove)
        storedNotifications = flag(Keys.notifications)
        storedWatchDownloads = flag(Keys.watchDownloads)
        storedWatchDesktop = flag(Keys.watchDesktop)
        storedAIGroups = defaults.object(forKey: Keys.aiGroups) as? Bool ?? false
        storedTidyReminder = flag(Keys.tidyReminder)
        renamePendingFirst = defaults.bool(forKey: Keys.renameFirst)
        minimumRelatedFileCount = groupingSettings.minimumRelatedFiles
        favoriteFolders = Self.decode([FavoriteFolder].self, key: Keys.folders, defaults: defaults) ?? []
        rules = Self.decode([DestinationRule].self, key: Keys.rules, defaults: defaults) ?? []
        learning = Self.decode([LearningRecord].self, key: Keys.learning, defaults: defaults) ?? []
        lastMove = Self.decode(MoveBatchReceipt.self, key: Keys.lastMove, defaults: defaults)
            ?? Self.decode(FileMoveReceipt.self, key: Keys.lastMove, defaults: defaults).map { MoveBatchReceipt(moves: [$0]) }
        activity = Self.decode([ActivityEntry].self, key: Keys.activity, defaults: defaults) ?? []
        watchedFolders = Self.decode([FavoriteFolder].self, key: Keys.watchedFolders, defaults: defaults) ?? []
        loadRecentCleanupFolders()
    }

    func start() {
        restartWatching()
        refreshTidyReminder()
        tidyTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.refreshTidyReminder() }
        }
    }

    var destinations: [Destination] {
        favoriteFolders.map { Destination(id: $0.id, name: $0.name, purpose: $0.purpose) }
    }

    /// True when Apple Intelligence has at least one described folder it may choose.
    var hasDescribedFolders: Bool {
        !AIFolders.choosable(destinations, locked: lockedDestinationIDs).isEmpty
    }

    /// AI-proposed new folders need at least 4 files, or more if you set a higher minimum.
    var aiGroupMinimum: Int { max(4, minimumRelatedFileCount) }

    var lockedDestinationIDs: Set<String> {
        SuggestionEngine.ruleLockedDestinationIDs(rules: rules, destinations: destinations)
    }

    /// nil when Apple Intelligence can be used; otherwise why not.
    var aiUnavailableReason: String? {
        if !aiEnabled { return "Apple Intelligence is turned off in EchoNyla's settings." }
        return OnDeviceModel.unavailableReason
    }

    var aiReady: Bool { aiUnavailableReason == nil }

    var cleanupTitle: String {
        cleanupFolder?.lastPathComponent ?? "Choose a folder"
    }

    /// The folder Clean Up's main button cleans: the one on screen, else the last one you cleaned, else Downloads.
    var cleanupTarget: URL {
        cleanupFolder ?? recentCleanupFolders.first ?? downloadsDirectoryURL
    }

    /// "Clean Downloads", "Clean Documents"…
    var cleanupButtonTitle: String {
        CleanupFolders.buttonTitle(folderName: cleanupTarget.lastPathComponent)
    }

    /// Choose Folder's menu: Downloads, Desktop and Documents, then up to five other folders you cleaned.
    var cleanupMenuFixedFolders: [URL] {
        [downloadsDirectoryURL, desktopDirectoryURL, documentsDirectoryURL]
    }

    var cleanupMenuRecentFolders: [URL] {
        let paths = CleanupFolders.menuFolders(recents: recentCleanupFolders.map { $0.standardizedFileURL.path },
                                               fixed: cleanupMenuFixedFolders.map { $0.standardizedFileURL.path })
        return paths.compactMap { path in recentCleanupFolders.first { $0.standardizedFileURL.path == path } }
    }

    var selectedMoveCount: Int {
        cleanupRows.filter { $0.isSelected && $0.hasTarget }.count
            + folderGroups.filter { selectedGroupIDs.contains($0.id) && validFolderName($0.name) != nil }.reduce(0) { $0 + $1.files.count }
    }

    /// Checked files in the Sure part, for its own Approve button.
    var selectedSureCount: Int {
        cleanupRows.filter { $0.bucket == .sure && $0.isSelected && $0.hasTarget }.count
    }

    func cleanupRows(in bucket: CleanupBucket) -> [CleanupEntry] {
        cleanupRows.filter { $0.bucket == bucket }
    }

    var selectedRenameCount: Int {
        cleanupRows.filter { $0.renameSelected && $0.proposedName != nil }.count
    }

    var selectedTrashCount: Int {
        trashRows.filter(\.isSelected).count
    }

    var openSuggestions: [ActivityEntry] {
        activity.filter { $0.kind == .suggested && !$0.isUndone }
    }

    // MARK: Favorites and rules

    func addFavoriteFromPanel() {
        guard let url = chooseFolder(title: "Add a favorite folder", prompt: "Add Folder") else { return }
        do {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            if favoriteFolders.contains(where: { resolve($0)?.standardizedFileURL == url.standardizedFileURL }) {
                statusMessage = "That folder is already a favorite."
                return
            }
            favoriteFolders.append(FavoriteFolder(id: UUID().uuidString, name: url.lastPathComponent, bookmarkData: bookmark))
            persist(favoriteFolders, key: Keys.folders)
            statusMessage = "Added \(url.lastPathComponent)."
        } catch {
            userError = "Could not save that folder bookmark: \(error.localizedDescription)"
        }
    }

    func setFolderPurpose(id: String, to text: String) {
        guard let index = favoriteFolders.firstIndex(where: { $0.id == id }) else { return }
        favoriteFolders[index].purpose = text.isEmpty ? nil : String(text.prefix(200))
        persist(favoriteFolders, key: Keys.folders)
    }

    func removeFavorite(id: String) {
        favoriteFolders.removeAll { $0.id == id }
        rules.removeAll { $0.destinationID == id }
        learning.removeAll { $0.destinationID == id }
        persist(favoriteFolders, key: Keys.folders)
        persist(rules, key: Keys.rules)
        persist(learning, key: Keys.learning)
    }

    func saveRule(id: UUID?, name: String, extensions: Set<String>, keywords: [String], destinationID: String) {
        guard favoriteFolders.contains(where: { $0.id == destinationID }) else { return }
        let rule = DestinationRule(
            id: id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Custom rule" : name,
            extensions: extensions,
            keywords: keywords,
            destinationID: destinationID
        )
        if let existingIndex = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[existingIndex] = rule
        } else {
            rules.append(rule)
        }
        persist(rules, key: Keys.rules)
    }

    func removeRule(id: UUID) {
        rules.removeAll { $0.id == id }
        persist(rules, key: Keys.rules)
    }

    func destinationName(for id: String?) -> String? {
        guard let id else { return nil }
        return favoriteFolders.first(where: { $0.id == id })?.name
    }

    // MARK: Dropped files

    func receiveDrop(_ url: URL) {
        guard url.isFileURL else { return }
        statusMessage = nil
        pending = PendingFile(url: url, isThinking: true)
        Task { await handleDrop(url) }
    }

    private func handleDrop(_ url: URL) async {
        let result = await evaluate(url)
        guard pending?.url == url else { return }
        switch result.decision {
        case .move(let destinationID, let reason):
            pending = nil
            performMove(url, to: destinationID, kind: .autoMoved, detail: reason, ai: result.ai, enrich: result.ai == nil)
        case .suggest(let destinationID, let reason):
            pending = PendingFile(url: url, suggestionID: destinationID, reason: reason, proposedName: result.ai?.proposedName,
                                  summary: result.ai?.summary, isThinking: false)
        case .skip(let reason):
            pending = PendingFile(url: url, suggestionID: nil, reason: reason, proposedName: nil, summary: nil, isThinking: false)
        }
    }

    /// Several files at once (or files dropped on the menu-bar icon): each one is handled like a new
    /// file in a watched folder, so the ones it's sure about move and the rest get suggestions in Activity.
    func receiveDrops(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        if files.count == 1, let only = files.first {
            receiveDrop(only)
            return
        }
        guard !destinations.isEmpty else {
            userError = "Add a favorite folder first (Folders & Rules)."
            return
        }
        for url in files {
            handledPaths.insert(url.path)
            watchQueue.append(url)
        }
        statusMessage = "Sorting \(files.count) files. Results appear in Activity."
        processWatchQueue()
    }

    /// Files dropped on a folder's tile in the panel go straight there: your own choice, with Undo,
    /// and EchoNyla learns from it.
    func receiveDrops(_ urls: [URL], into destinationID: String) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty, let name = destinationName(for: destinationID) else { return }
        statusMessage = nil
        for url in files {
            handledPaths.insert(url.path)
            if pending?.url == url { pending = nil }
            performMove(url, to: destinationID, kind: .moved, detail: "Dropped on \(name)", ai: nil, enrich: true)
            remember(fileName: url.lastPathComponent, destinationID: destinationID)
        }
        if files.count > 1 { statusMessage = "Moved \(files.count) files to \(name)." }
    }

    func cancelPendingDrop() {
        pending = nil
    }

    /// Moves the dropped file into any folder you pick (not only a favorite).
    func movePendingToChosenFolder() {
        guard let current = pending, let folder = chooseFolder(title: "Move \(current.url.lastPathComponent) to…", prompt: "Move Here") else { return }
        pending = nil
        moveToChosenFolder(current.url, folder: folder, detail: "Your choice")
    }

    func movePending(to destinationID: String) {
        guard let current = pending else { return }
        var source = current.url
        if let name = current.proposedName, renamePendingFirst {
            if let renamed = try? mover.rename(source, to: name) {
                appMovedPaths.insert(source.path)
                addActivity(ActivityEntry(kind: .renamed, fileName: source.lastPathComponent,
                                          detail: "Renamed to \(renamed.movedURL.lastPathComponent)", receipt: renamed,
                                          filePath: renamed.movedURL.path))
                source = renamed.movedURL
            }
        }
        let wasSuggested = current.suggestionID == destinationID
        pending = nil
        performMove(source, to: destinationID, kind: .moved,
                    detail: wasSuggested ? (current.reason ?? "Your choice") : "Your choice", ai: nil, enrich: false)
        remember(fileName: source.lastPathComponent, destinationID: destinationID)
    }

    /// Set from the panel's "Rename" checkbox; remembered until you change it.
    var renamePendingFirst = false {
        didSet { defaults.set(renamePendingFirst, forKey: Keys.renameFirst) }
    }

    // MARK: Moving, renaming and undo

    private func performMove(_ source: URL, to destinationID: String, kind: ActivityEntry.Kind, detail: String,
                             ai: FileDecision?, enrich: Bool, notify: Bool = false) {
        guard let destination = resolvedURL(for: destinationID) else {
            userError = "That favorite folder can't be found anymore. Add it again in Folders & Rules."
            return
        }
        do {
            let receipt = try move(source, into: destination)
            saveLastMove(MoveBatchReceipt(moves: [receipt]))
            let name = destinationName(for: destinationID) ?? destination.lastPathComponent
            let entry = ActivityEntry(kind: kind, fileName: source.lastPathComponent, detail: detail, destinationID: destinationID,
                                      destinationName: name, receipt: receipt, filePath: receipt.movedURL.path,
                                      proposedName: ai?.proposedName, summary: ai?.summary)
            addActivity(entry)
            statusMessage = kind == .autoMoved ? "Moved \(source.lastPathComponent) to \(name) automatically." : "Moved to \(name)."
            if notify { Notifier.shared.post(entry, enabled: notificationsEnabled) }
            if enrich, aiReady { Task { await enrichAfterMove(entry.id, url: receipt.movedURL, destinationID: destinationID) } }
        } catch {
            userError = "Could not move \(source.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// After a rule or learned pattern moved a file, Apple Intelligence still offers a clearer name.
    private func enrichAfterMove(_ entryID: UUID, url: URL, destinationID: String) async {
        let facts = await FileInspector.facts(for: url, readContents: readContents)
        guard let decision = await askModel(facts: facts) else { return }
        guard let index = activity.firstIndex(where: { $0.id == entryID }) else { return }
        activity[index].proposedName = decision.proposedName
        activity[index].summary = decision.summary.isEmpty ? nil : decision.summary
        persist(activity, key: Keys.activity)
    }

    func undoLastMove() {
        guard let receipt = lastMove else { return }
        do {
            try mover.undo(receipt)
            for move in receipt.moves { handledPaths.insert(move.originalURL.path) }
            markUndone(receipts: receipt.moves)
            saveLastMove(nil)
            statusMessage = "Move undone."
        } catch {
            userError = "Could not undo the last move: \(error.localizedDescription)"
        }
    }

    func undo(_ entryID: UUID) {
        guard let entry = activity.first(where: { $0.id == entryID }), let receipt = entry.receipt, !entry.isUndone else { return }
        do {
            try mover.undo(receipt)
            handledPaths.insert(receipt.originalURL.path)
            markUndone(receipts: [receipt])
            if lastMove?.moves == [receipt] { saveLastMove(nil) }
            statusMessage = entry.kind == .renamed ? "Name put back." : "Moved \(entry.fileName) back."
        } catch {
            userError = "Could not undo that: \(error.localizedDescription)"
        }
    }

    private func markUndone(receipts: [FileMoveReceipt]) {
        let movedPaths = Set(receipts.map { $0.movedURL.path })
        for index in activity.indices {
            guard let receipt = activity[index].receipt else { continue }
            // A rename made after the move is undone together with the move.
            let renamedAfterMove = activity[index].kind == .renamed && movedPaths.contains(receipt.movedURL.path)
            if receipts.contains(receipt) || renamedAfterMove { activity[index].isUndone = true }
        }
        persist(activity, key: Keys.activity)
    }

    /// Applies Apple Intelligence's proposed name to a file in Activity.
    func applyProposedName(_ entryID: UUID) {
        guard let index = activity.firstIndex(where: { $0.id == entryID }), let name = activity[index].proposedName else { return }
        let url = URL(fileURLWithPath: activity[index].filePath)
        do {
            let receipt = try withAccess(to: url.deletingLastPathComponent()) { try mover.rename(url, to: name) }
            handledPaths.insert(receipt.movedURL.path)
            appMovedPaths.insert(url.path)
            activity[index].filePath = receipt.movedURL.path
            activity[index].proposedName = nil
            // Undo of the earlier move now brings the renamed file back (under its old name).
            if let moveReceipt = activity[index].receipt, activity[index].kind != .renamed {
                let updated = FileMoveReceipt(originalURL: moveReceipt.originalURL, movedURL: receipt.movedURL)
                activity[index].receipt = updated
                if lastMove?.moves == [moveReceipt] { saveLastMove(MoveBatchReceipt(moves: [updated])) }
            }
            addActivity(ActivityEntry(kind: .renamed, fileName: url.lastPathComponent, detail: "Renamed to \(receipt.movedURL.lastPathComponent)",
                                      receipt: receipt, filePath: receipt.movedURL.path))
            statusMessage = "Renamed to \(receipt.movedURL.lastPathComponent)."
        } catch {
            userError = "Could not rename \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Moves a file from a watched folder where Apple Intelligence suggested.
    func acceptSuggestion(_ entryID: UUID, destinationID: String? = nil) {
        guard let index = activity.firstIndex(where: { $0.id == entryID }),
              let target = destinationID ?? activity[index].destinationID else { return }
        let entry = activity[index]
        activity.remove(at: index)
        persist(activity, key: Keys.activity)
        let url = URL(fileURLWithPath: entry.filePath)
        performMove(url, to: target, kind: .moved, detail: entry.detail, ai: nil, enrich: false)
        if let moved = activity.first, moved.kind == .moved, moved.fileName == entry.fileName {
            activity[0].proposedName = entry.proposedName
            activity[0].summary = entry.summary
            persist(activity, key: Keys.activity)
        }
        remember(fileName: url.lastPathComponent, destinationID: target)
    }

    /// Moves a suggested file into any folder you pick.
    func acceptSuggestionInChosenFolder(_ entryID: UUID) {
        guard let entry = activity.first(where: { $0.id == entryID }),
              let folder = chooseFolder(title: "Move \(entry.fileName) to…", prompt: "Move Here") else { return }
        activity.removeAll { $0.id == entryID }
        persist(activity, key: Keys.activity)
        moveToChosenFolder(URL(fileURLWithPath: entry.filePath), folder: folder, detail: entry.detail)
    }

    /// One move into a folder that isn't a favorite. Undoable like any other; nothing is learned,
    /// since the folder isn't one EchoNyla may suggest.
    private func moveToChosenFolder(_ source: URL, folder: URL, detail: String) {
        do {
            let receipt = try move(source, into: folder)
            saveLastMove(MoveBatchReceipt(moves: [receipt]))
            addActivity(ActivityEntry(kind: .moved, fileName: source.lastPathComponent, detail: detail,
                                      destinationName: folder.lastPathComponent, receipt: receipt, filePath: receipt.movedURL.path))
            statusMessage = "Moved to \(folder.lastPathComponent)."
        } catch {
            userError = "Could not move \(source.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func dismiss(_ entryID: UUID) {
        activity.removeAll { $0.id == entryID }
        persist(activity, key: Keys.activity)
    }

    func clearActivity() {
        activity.removeAll { $0.kind != .suggested }
        persist(activity, key: Keys.activity)
    }

    private func addActivity(_ entry: ActivityEntry) {
        activity = ActivityEntry.adding(entry, to: activity)
        persist(activity, key: Keys.activity)
    }

    // MARK: Apple Intelligence

    struct Evaluation {
        let decision: AutoMoveDecision
        let ai: FileDecision?
    }

    private func evaluate(_ url: URL) async -> Evaluation {
        let fileName = url.lastPathComponent
        let local = SuggestionEngine.suggestRanked(fileName: fileName, destinations: destinations, rules: rules, learning: learning,
                                                   isScreenCapture: ScreenshotMetadata.isScreenCapture(at: url))
        let locked = lockedDestinationIDs
        if AutoMovePolicy.isIgnored(fileName: fileName) || local?.strength.isSure == true || !aiReady || destinations.isEmpty {
            let decision = AutoMovePolicy.decide(fileName: fileName, local: local, ai: nil, aiHadContentEvidence: false,
                                                 autoMoveEnabled: autoMove, locked: locked)
            return Evaluation(decision: decision, ai: nil)
        }
        let facts = await FileInspector.facts(for: url, readContents: readContents)
        let answer = await askModel(facts: facts)
        let decision = AutoMovePolicy.decide(fileName: fileName, local: local, ai: answer, aiHadContentEvidence: facts.hasContentEvidence,
                                             autoMoveEnabled: autoMove, locked: locked)
        return Evaluation(decision: decision, ai: answer)
    }

    /// Apple Intelligence's answer: a folder only when it's sure about one you described, plus a
    /// clearer name and a summary (those work even without any described folder).
    private func askModel(facts: FileFacts) async -> FileDecision? {
        guard aiReady else { return nil }
        let locked = lockedDestinationIDs
        let examples = DecisionPrompt.examples(learning: learning, destinations: destinations, locked: locked)
        let prompt = DecisionPrompt.make(facts: facts, destinations: destinations, locked: locked, examples: examples)
        guard let answer = try? await OnDeviceModel.decide(prompt) else { return nil }
        return DecisionCheck.check(folder: answer.folder, confidence: answer.confidence, reason: answer.reason, betterName: answer.betterName,
                                   summary: answer.summary, fileName: facts.fileName, destinations: destinations, locked: locked)
    }

    /// "What is this file?" for any file.
    func explain(_ url: URL) {
        let key = url.path
        guard aiReady, !explaining.contains(key) else { return }
        explaining.insert(key)
        Task {
            let facts = await FileInspector.facts(for: url, readContents: readContents)
            let answer = await askModel(facts: facts)
            explaining.remove(key)
            if let summary = answer?.summary, !summary.isEmpty {
                explanations[key] = summary
            } else {
                explanations[key] = "Apple Intelligence couldn't tell what this file is."
            }
        }
    }

    // MARK: Watching Downloads, Desktop and your folders

    var downloadsDirectoryURL: URL {
        fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Downloads", isDirectory: true)
    }

    var desktopDirectoryURL: URL {
        fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Desktop", isDirectory: true)
    }

    var documentsDirectoryURL: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Documents", isDirectory: true)
    }

    var isWatching: Bool { watchDownloads || watchDesktop || !watchedFolders.isEmpty }

    /// A file is waiting for a choice, being filed, searched for, or queued from watching. An update waits for this.
    var isBusyWithFiles: Bool {
        pending != nil || isProcessingQueue || !watchQueue.isEmpty || isSearching
    }

    func addWatchedFolder() {
        guard let url = chooseFolder(title: "Watch a folder", prompt: "Watch Folder") else { return }
        guard let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            userError = "Could not save that folder."
            return
        }
        guard !watchedFolders.contains(where: { resolve($0)?.standardizedFileURL == url.standardizedFileURL }) else { return }
        watchedFolders.append(FavoriteFolder(id: UUID().uuidString, name: url.lastPathComponent, bookmarkData: bookmark))
        persist(watchedFolders, key: Keys.watchedFolders)
        restartWatching()
    }

    func removeWatchedFolder(id: String) {
        watchedFolders.removeAll { $0.id == id }
        persist(watchedFolders, key: Keys.watchedFolders)
        restartWatching()
    }

    func restartWatching() {
        watchTimer?.invalidate()
        watchTimer = nil
        for url in watchScopes { url.stopAccessingSecurityScopedResource() }
        watchScopes = []
        watchStates = [:]
        guard isWatching else { return }
        Notifier.shared.requestPermissionIfNeeded(enabled: notificationsEnabled)
        pollWatchedFolders()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.pollWatchedFolders() }
        }
    }

    private func watchedFolderURLs() -> [URL] {
        var urls: [URL] = []
        if watchDownloads { urls.append(downloadsDirectoryURL) }
        if watchDesktop { urls.append(desktopDirectoryURL) }
        for folder in watchedFolders {
            guard let url = resolve(folder) else { continue }
            if !watchScopes.contains(url), url.startAccessingSecurityScopedResource() { watchScopes.append(url) }
            urls.append(url)
        }
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func pollWatchedFolders() {
        let now = Date()
        for folder in watchedFolderURLs() {
            var state = watchStates[folder.path] ?? FolderWatchState()
            let ready = state.update(snapshots(of: folder), now: now)
            watchStates[folder.path] = state
            learnFromFinderMoves(state.departed)
            for path in ready where !handledPaths.contains(path) {
                handledPaths.insert(path)
                watchQueue.append(URL(fileURLWithPath: path))
            }
        }
        processWatchQueue()
    }

    /// A new file that left a watched folder without EchoNyla moving it: if the same file (name and
    /// size) is now in exactly one favorite folder, you moved it there in Finder. That counts as your
    /// choice, as a click on "Move to" does.
    private func learnFromFinderMoves(_ departed: [FileSnapshot]) {
        let candidates = departed.filter { !appMovedPaths.contains($0.path) }
        guard !candidates.isEmpty, !favoriteFolders.isEmpty else { return }
        var inFavorites: [FinderMoveMatcher.Candidate] = []
        for folder in favoriteFolders {
            guard let url = resolve(folder) else { continue }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            for file in snapshots(of: url) where candidates.contains(where: {
                URL(fileURLWithPath: $0.path).lastPathComponent == URL(fileURLWithPath: file.path).lastPathComponent
            }) {
                inFavorites.append(.init(destinationID: folder.id, file: file))
            }
        }
        for file in candidates {
            guard let destinationID = FinderMoveMatcher.destination(for: file, among: inFavorites) else { continue }
            let name = URL(fileURLWithPath: file.path).lastPathComponent
            remember(fileName: name, destinationID: destinationID)
            activity.removeAll { $0.kind == .suggested && $0.filePath == file.path }
            let movedPath = inFavorites.first { $0.destinationID == destinationID
                && URL(fileURLWithPath: $0.file.path).lastPathComponent == name }?.file.path ?? file.path
            addActivity(ActivityEntry(kind: .learned, fileName: name, detail: "You moved it in Finder, so EchoNyla learned from it",
                                      destinationID: destinationID, destinationName: destinationName(for: destinationID),
                                      filePath: movedPath))
        }
    }

    private func snapshots(of folder: URL) -> [FileSnapshot] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return FileSnapshot(path: url.path, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast)
        }
    }

    private func processWatchQueue() {
        guard !isProcessingQueue, !watchQueue.isEmpty else { return }
        isProcessingQueue = true
        Task {
            while !watchQueue.isEmpty {
                let url = watchQueue.removeFirst()
                guard fileManager.fileExists(atPath: url.path) else { continue }
                await handleNewFile(url)
            }
            isProcessingQueue = false
        }
    }

    private func handleNewFile(_ url: URL) async {
        guard !destinations.isEmpty else { return }
        let result = await evaluate(url)
        switch result.decision {
        case .move(let destinationID, let reason):
            performMove(url, to: destinationID, kind: .autoMoved, detail: reason, ai: result.ai, enrich: result.ai == nil, notify: true)
        case .suggest(let destinationID, let reason):
            guard destinationID != nil || result.ai?.proposedName != nil else { return }
            let entry = ActivityEntry(kind: .suggested, fileName: url.lastPathComponent, detail: reason, destinationID: destinationID,
                                      destinationName: destinationName(for: destinationID), filePath: url.path,
                                      proposedName: result.ai?.proposedName, summary: result.ai?.summary)
            addActivity(entry)
            Notifier.shared.post(entry, enabled: notificationsEnabled)
        case .skip:
            break
        }
    }

    // MARK: Clean up a folder

    func startDownloadsCleanup() {
        beginCleanup(at: downloadsDirectoryURL)
    }

    /// The main button: looks at the chosen folder again.
    func cleanChosenFolder() {
        beginCleanup(at: cleanupTarget)
    }

    /// A folder from Choose Folder's menu.
    func startCleanup(at folder: URL) {
        beginCleanup(at: folder)
    }

    func chooseCleanupFolder() {
        guard let url = chooseFolder(title: "Choose a folder to clean up", prompt: "Choose Folder") else { return }
        beginCleanup(at: url)
    }

    func setCleanupDestination(entryID: String, destinationID: String) {
        guard let index = cleanupRows.firstIndex(where: { $0.id == entryID }) else { return }
        cleanupRows[index].destinationID = destinationID.isEmpty ? nil : destinationID
        cleanupRows[index].chosenFolder = nil
        cleanupRows[index].suggestionReason = nil
        cleanupRows[index].isSelected = !destinationID.isEmpty
        refreshFolderGroups()
    }

    /// Any Folder…: a folder that isn't a favorite, picked in a Finder window.
    func chooseCleanupFolder(entryID: String) {
        guard let index = cleanupRows.firstIndex(where: { $0.id == entryID }),
              let folder = chooseFolder(title: "Move \(cleanupRows[index].url.lastPathComponent) to…", prompt: "Choose") else { return }
        cleanupRows[index].chosenFolder = folder
        cleanupRows[index].destinationID = nil
        cleanupRows[index].suggestionReason = nil
        cleanupRows[index].isSelected = true
        refreshFolderGroups()
    }

    func setCleanupSelected(entryID: String, selected: Bool) {
        guard let index = cleanupRows.firstIndex(where: { $0.id == entryID }) else { return }
        cleanupRows[index].isSelected = selected
    }

    func setRenameSelected(entryID: String, selected: Bool) {
        guard let index = cleanupRows.firstIndex(where: { $0.id == entryID }) else { return }
        cleanupRows[index].renameSelected = selected && cleanupRows[index].proposedName != nil
    }

    func setTrashSelected(entryID: String, selected: Bool) {
        guard let index = trashRows.firstIndex(where: { $0.id == entryID }) else { return }
        trashRows[index].isSelected = selected
    }

    func setFolderGroupSelected(id: String, selected: Bool) {
        if selected { selectedGroupIDs.insert(id) } else { selectedGroupIDs.remove(id) }
    }

    func renameFolderGroup(id: String, to name: String) {
        guard let index = folderGroups.firstIndex(where: { $0.id == id }) else { return }
        folderGroups[index].name = name
        if let aiIndex = aiGroups.firstIndex(where: { $0.id == id }) { aiGroups[aiIndex].name = name }
    }

    func setMinimumRelatedFileCount(_ count: Int) {
        folderGroupingSettings.minimumRelatedFiles = count
        minimumRelatedFileCount = folderGroupingSettings.minimumRelatedFiles
        refreshFolderGroups()
    }

    /// Applies the checked moves and renames (only the Sure part's moves when `onlySure`).
    func moveSelectedCleanupItems(onlySure: Bool = false) {
        var movedCount = 0
        var renamedCount = 0
        var receipts: [FileMoveReceipt] = []
        var createdFolders: [URL] = []
        var learned: [(String, String)] = []

        for row in cleanupRows where (row.isSelected || row.renameSelected) && (!onlySure || row.bucket == .sure) {
            var source = row.url
            if row.renameSelected, let name = row.proposedName {
                do {
                    let receipt = try withAccess(to: source.deletingLastPathComponent()) { try mover.rename(source, to: name) }
                    receipts.append(receipt)
                    handledPaths.insert(receipt.movedURL.path)
                    appMovedPaths.insert(source.path)
                    source = receipt.movedURL
                    renamedCount += 1
                } catch {
                    userError = "Could not rename \(row.url.lastPathComponent): \(error.localizedDescription)"
                }
            }
            guard row.isSelected else { continue }
            let favoriteID = row.destinationID
            guard let destination = row.chosenFolder ?? favoriteID.flatMap({ resolvedURL(for: $0) }) else { continue }
            do {
                let receipt = try move(source, into: destination)
                receipts.append(receipt)
                if let favoriteID, row.chosenFolder == nil { learned.append((source.lastPathComponent, favoriteID)) }
                movedCount += 1
            } catch {
                userError = "Could not move \(source.lastPathComponent): \(error.localizedDescription)"
            }
        }

        if !onlySure, !selectedGroupIDs.isEmpty, let parent = cleanupFolder {
            for group in folderGroups where selectedGroupIDs.contains(group.id) {
                guard let safeName = validFolderName(group.name) else {
                    userError = "Enter a valid name for the \(group.name) folder."
                    continue
                }
                var createdFolderURL: URL?
                var folderWasCreated = false
                var groupReceipts: [FileMoveReceipt] = []
                do {
                    let (newFolder, wasCreated) = try createOrFindFolder(named: safeName, in: parent)
                    createdFolderURL = newFolder
                    folderWasCreated = wasCreated
                    for file in group.files where fileManager.fileExists(atPath: file.path) {
                        let receipt = try move(file, into: newFolder)
                        groupReceipts.append(receipt)
                        receipts.append(receipt)
                        movedCount += 1
                    }
                    if wasCreated && !groupReceipts.isEmpty { createdFolders.append(newFolder) }
                } catch {
                    if folderWasCreated, let createdFolderURL {
                        if groupReceipts.isEmpty { removeFolderIfEmpty(createdFolderURL) } else { createdFolders.append(createdFolderURL) }
                    }
                    userError = "Could not organize the \(group.name) group: \(error.localizedDescription)"
                }
            }
        }

        if !receipts.isEmpty {
            saveLastMove(MoveBatchReceipt(moves: receipts, createdFolders: createdFolders))
        }
        for (name, destinationID) in learned { remember(fileName: name, destinationID: destinationID) }
        selectedGroupIDs.removeAll()
        aiGroups = []
        if let cleanupFolder { beginCleanup(at: cleanupFolder, askAI: false) }
        var parts: [String] = []
        if movedCount > 0 { parts.append("Moved \(movedCount) item\(movedCount == 1 ? "" : "s")") }
        if renamedCount > 0 { parts.append("renamed \(renamedCount)") }
        statusMessage = parts.isEmpty ? "Nothing was changed." : parts.joined(separator: ", ") + ". Undo Last Move reverses all of it."
    }

    /// The only app path that sends an item to Trash. The UI calls it only after an explicit, separate confirmation.
    func moveSelectedInstallersToTrash() {
        var trashedCount = 0
        var receipts: [FileMoveReceipt] = []
        for entry in trashRows where entry.isSelected {
            var result: NSURL?
            let sourceScope = entry.url.startAccessingSecurityScopedResource()
            do {
                defer { if sourceScope { entry.url.stopAccessingSecurityScopedResource() } }
                appMovedPaths.insert(entry.url.path)
                try fileManager.trashItem(at: entry.url, resultingItemURL: &result)
                let movedURL = (result as URL?) ?? entry.url
                receipts.append(FileMoveReceipt(originalURL: entry.url, movedURL: movedURL))
                trashedCount += 1
            } catch {
                userError = "Could not move \(entry.url.lastPathComponent) to Trash: \(error.localizedDescription)"
            }
        }
        if !receipts.isEmpty { saveLastMove(MoveBatchReceipt(moves: receipts)) }
        if let cleanupFolder { beginCleanup(at: cleanupFolder, askAI: false) }
        statusMessage = trashedCount == 0 ? "No installers were moved to Trash." : "Moved \(trashedCount) installer(s) to Trash."
    }

    private func beginCleanup(at folder: URL, askAI: Bool = true) {
        // A new look at a folder stops Apple Intelligence's review of the last one, so the new one gets its own.
        if askAI || cleanupFolder?.standardizedFileURL != folder.standardizedFileURL { stopCleanupReview() }
        if askAI { rememberCleanupFolder(folder) }
        if cleanupScopeURL?.standardizedFileURL != folder.standardizedFileURL {
            if cleanupScopeIsActive { cleanupScopeURL?.stopAccessingSecurityScopedResource() }
            cleanupScopeURL = folder
            cleanupScopeIsActive = folder.startAccessingSecurityScopedResource()
        }
        cleanupFolder = folder
        cleanupRows = []
        trashRows = []
        folderGroups = []
        aiGroups = []
        selectedGroupIDs = []

        do {
            let urls = try fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            let isDownloads = folder.standardizedFileURL == downloadsDirectoryURL.standardizedFileURL
            let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
            let installedApps = isDownloads ? installedApplications(in: applicationsURL) : []
            let policy = TrashPolicy()

            for url in urls {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true else { continue }

                if isDownloads,
                   let trashSuggestion = policy.suggestion(
                       for: url,
                       downloadsFolder: downloadsDirectoryURL,
                       applicationsFolder: applicationsURL,
                       installedApps: installedApps
                   ) {
                    trashRows.append(TrashEntry(url: trashSuggestion.fileURL, reason: trashSuggestion.reason, isSelected: false))
                    continue
                }

                let ranked = SuggestionEngine.suggestRanked(
                    fileName: url.lastPathComponent,
                    destinations: destinations,
                    rules: rules,
                    learning: learning,
                    isScreenCapture: ScreenshotMetadata.isScreenCapture(at: url)
                )
                // Rules, screenshots and your own repeated moves start checked; a wording match is only a hint.
                cleanupRows.append(CleanupEntry(
                    url: url,
                    destinationID: ranked?.suggestion.destinationID,
                    suggestionReason: ranked.map { $0.strength.isSure ? $0.suggestion.reason : $0.suggestion.reason + " (a guess; check it)" },
                    isSelected: ranked?.strength.isSure == true,
                    bucket: CleanupBucket.of(hasDestination: ranked != nil, isSure: ranked?.strength.isSure == true)
                ))
            }
            cleanupRows.sort { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
            trashRows.sort { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
            refreshFolderGroups()
            if askAI, aiReady, !cleanupRows.isEmpty { askAIAboutCleanup() }
        } catch {
            userError = "Could not read that folder: \(error.localizedDescription)"
        }
    }

    /// Starts Apple Intelligence on the files on screen, replacing any review still running.
    func askAIAboutCleanup() {
        stopCleanupReview()
        let run = cleanupReviewRun
        cleanupReview = Task { await reviewCleanupWithAI(run: run) }
    }

    private func stopCleanupReview() {
        cleanupReview?.cancel()
        cleanupReview = nil
        cleanupReviewRun += 1
        cleanupProgress = nil
    }

    /// Apple Intelligence looks at the files the local rules couldn't place (up to 40). It suggests one
    /// of your described folders only when it's sure, a clearer name (unchecked), and, when you've
    /// turned them on, specific new-folder groups. It stops as soon as a newer review replaces it.
    private func reviewCleanupWithAI(run: Int) async {
        guard aiReady, let folder = cleanupFolder else { return }
        let candidates = Array(cleanupRows.filter { !$0.hasTarget }.prefix(40))
        var factsByPath: [String: FileFacts] = [:]
        for (number, row) in candidates.enumerated() {
            guard cleanupReviewRun == run else { return }
            cleanupProgress = "Apple Intelligence is looking at \(number + 1) of \(candidates.count)…"
            let facts = await FileInspector.facts(for: row.url, readContents: readContents)
            factsByPath[row.id] = facts
            let answer = await askModel(facts: facts)
            guard cleanupReviewRun == run else { return }
            guard let decision = answer,
                  let index = cleanupRows.firstIndex(where: { $0.id == row.id }), !cleanupRows[index].hasTarget else { continue }
            if let destinationID = decision.destinationID, decision.isConfident {
                cleanupRows[index].destinationID = destinationID
                cleanupRows[index].suggestionReason = "Apple Intelligence: \(decision.reason)"
                cleanupRows[index].isSelected = true
                cleanupRows[index].bucket = .sure
            }
            cleanupRows[index].proposedName = decision.proposedName
            cleanupRows[index].summary = decision.summary.isEmpty ? nil : decision.summary
        }
        if aiGroupsEnabled {
            cleanupProgress = "Apple Intelligence is looking for files that belong together…"
            await groupWithAI(factsByPath: factsByPath, folder: folder, run: run)
        }
        guard cleanupReviewRun == run else { return }
        cleanupProgress = nil
        cleanupReview = nil
    }

    private func groupWithAI(factsByPath: [String: FileFacts], folder: URL, run: Int) async {
        let unassigned = cleanupRows.filter { !$0.hasTarget }.map(\.url)
        guard unassigned.count >= aiGroupMinimum, cleanupReviewRun == run, cleanupFolder == folder else {
            refreshFolderGroups()
            return
        }
        let files = Array(unassigned.prefix(40))
        var lines: [String] = []
        for (number, url) in files.enumerated() {
            let facts = factsByPath[url.path] ?? FileFacts(fileName: url.lastPathComponent)
            var line = "\(number + 1). \(TextTools.redactLongNumbers(url.lastPathComponent)) (\(facts.kind.label))"
            if let host = facts.downloadedFrom.first { line += ", from \(host)" }
            let text = TextTools.collapseWhitespace(facts.text)
            if !text.isEmpty { line += ": " + TextTools.redactLongNumbers(String(text.prefix(140))) }
            lines.append(line)
        }
        let prompt = "Files:\n" + lines.joined(separator: "\n")
            + "\n\nGroup only files that belong to one specific, named thing: one trip, one class or course project, one event, "
            + "one move, one case. Never group by a broad category like school, finance, work, documents or receipts, and never "
            + "by file type or date. Each group needs at least \(aiGroupMinimum) files. Most files belong to no group; leave them out."
        if let answer = try? await OnDeviceModel.groups(prompt), cleanupReviewRun == run, cleanupFolder == folder {
            let checked = GroupCheck.validate(answer.map { (name: $0.name, members: $0.files) }, fileCount: files.count,
                                              minimumSize: aiGroupMinimum)
            aiGroups = checked.map { proposal in
                let members = proposal.indexes.map { files[$0] }
                return FolderGroup(id: "ai-" + proposal.name.lowercased(), name: proposal.name,
                                   reason: "Apple Intelligence sees these \(members.count) files as one project.", files: members)
            }
        }
        refreshFolderGroups()
    }

    private func refreshFolderGroups() {
        let unassigned = Set(cleanupRows.filter { !$0.hasTarget }.map(\.url))
        var groups: [FolderGroup] = []
        var used: Set<URL> = []
        for group in aiGroups where aiGroupsEnabled {
            let files = group.files.filter { unassigned.contains($0) && !used.contains($0) }
            guard files.count >= aiGroupMinimum else { continue }
            used.formUnion(files)
            groups.append(FolderGroup(id: group.id, name: group.name, reason: group.reason, files: files))
        }
        let rest = cleanupRows.filter { !$0.hasTarget && !used.contains($0.url) }.map(\.url)
        groups += FolderGrouping.suggest(for: rest, minimumGroupSize: minimumRelatedFileCount)
        folderGroups = groups
        selectedGroupIDs = selectedGroupIDs.intersection(Set(groups.map(\.id)))
    }

    // MARK: Find files in plain words

    func search(_ sentence: String) {
        let clean = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        isSearching = true
        searchNote = nil
        Task {
            var request = SpotlightQuery.fallbackRequest(from: clean)
            var usedAI = false
            if aiReady, let understood = try? await OnDeviceModel.search(clean, today: Self.todayText()), !understood.isEmpty {
                request = understood
                usedAI = true
            }
            guard let query = SpotlightQuery.make(request) else {
                isSearching = false
                searchResults = []
                searchNote = "Describe the file with a few words, like “the PDF from the dentist last month”."
                return
            }
            let results = await searcher.run(query)
            searchResults = results
            isSearching = false
            searchNote = Self.describe(request, usedAI: usedAI, count: results.count)
        }
    }

    static func todayText() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd (EEEE)"
        return formatter.string(from: Date())
    }

    static func describe(_ request: FileSearchRequest, usedAI: Bool, count: Int) -> String {
        var parts: [String] = []
        if !request.words.isEmpty { parts.append("words: " + request.words.joined(separator: ", ")) }
        if request.screenshotsOnly { parts.append("screenshots") }
        if !request.kinds.isEmpty { parts.append("type: " + request.kinds.map(\.label).joined(separator: ", ")) }
        if let from = request.fromDay { parts.append("from \(from)") }
        if let to = request.toDay { parts.append("to \(to)") }
        if let source = request.source { parts.append("downloaded from “\(source)”") }
        let found = count == 0 ? "Nothing found" : "\(count) file\(count == 1 ? "" : "s")"
        let how = usedAI ? "Apple Intelligence searched for" : "Searched for"
        return "\(found). \(how) \(parts.joined(separator: " · "))."
    }

    // MARK: Set up in a minute

    /// Looks at the folders in Documents and on the Desktop and offers the ones you keep files in as
    /// favorites, each with a "What goes here" note drafted by Apple Intelligence from the files
    /// already inside. Nothing is added until you tick a folder and click Add.
    func prepareSetup() {
        guard !isPreparingSetup else { return }
        isPreparingSetup = true
        let homes = [fileManager.urls(for: .documentDirectory, in: .userDomainMask).first, desktopDirectoryURL].compactMap { $0 }
        var folders: [SetupSuggestions.Folder] = []
        var counts: [String: Int] = [:]
        for parent in homes {
            let children = (try? fileManager.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                                 options: [.skipsHiddenFiles])) ?? []
            for child in children {
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
                      values.isDirectory == true, values.isPackage != true else { continue }
                let files = snapshots(of: child)
                counts[child.path] = files.count
                folders.append(SetupSuggestions.Folder(path: child.path, name: child.lastPathComponent, fileCount: files.count,
                                                       newestFile: files.map(\.modified).max()))
            }
        }
        let existing = Set(favoriteFolders.compactMap { resolve($0)?.standardizedFileURL.path })
        let ranked = SetupSuggestions.rank(folders, existing: existing)
        setupCandidates = ranked.map { folder in
            SetupCandidate(url: URL(fileURLWithPath: folder.path, isDirectory: true), fileCount: counts[folder.path] ?? folder.fileCount,
                           note: "", isDrafting: aiReady)
        }
        isPreparingSetup = false
        guard aiReady else { return }
        Task { await draftSetupNotes() }
    }

    private func draftSetupNotes() async {
        for candidate in setupCandidates {
            let names = snapshots(of: candidate.url).map { URL(fileURLWithPath: $0.path).lastPathComponent }
            let prompt = SetupSuggestions.notePrompt(folderName: candidate.url.lastPathComponent, fileNames: names)
            let draft = try? await OnDeviceModel.folderNote(prompt)
            guard let index = setupCandidates.firstIndex(where: { $0.id == candidate.id }) else { continue }
            setupCandidates[index].isDrafting = false
            if setupCandidates[index].note.isEmpty, let note = draft.flatMap(SetupSuggestions.cleanNote) {
                setupCandidates[index].note = note
            }
        }
    }

    func setSetupCandidate(id: String, selected: Bool) {
        guard let index = setupCandidates.firstIndex(where: { $0.id == id }) else { return }
        setupCandidates[index].isSelected = selected
    }

    func setSetupNote(id: String, to note: String) {
        guard let index = setupCandidates.firstIndex(where: { $0.id == id }) else { return }
        setupCandidates[index].note = note
        setupCandidates[index].isDrafting = false
    }

    /// Adds the ticked folders as favorites with their notes.
    func addChosenSetupFolders() {
        var added = 0
        for candidate in setupCandidates where candidate.isSelected {
            guard let bookmark = makeBookmark(candidate.url),
                  !favoriteFolders.contains(where: { resolve($0)?.standardizedFileURL == candidate.url.standardizedFileURL }) else { continue }
            let note = Destination.cleanPurpose(candidate.note)
            favoriteFolders.append(FavoriteFolder(id: UUID().uuidString, name: candidate.url.lastPathComponent, bookmarkData: bookmark, purpose: note))
            added += 1
        }
        persist(favoriteFolders, key: Keys.folders)
        setupCandidates = []
        isSetupOpen = false
        statusMessage = added == 0 ? nil : "Added \(added) favorite folder\(added == 1 ? "" : "s")."
    }

    func cancelSetup() {
        setupCandidates = []
        isSetupOpen = false
    }

    // MARK: Weekly Downloads reminder

    func refreshTidyReminder() {
        let dismissed = defaults.object(forKey: Keys.tidyReminderDismissed) as? Date
        guard tidyReminderEnabled else {
            tidyReminderCount = nil
            return
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .addedToDirectoryDateKey, .creationDateKey]
        let urls = (try? fileManager.contentsOfDirectory(at: downloadsDirectoryURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let dates = urls.compactMap { url -> Date? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return values.addedToDirectoryDate ?? values.creationDate
        }
        tidyReminderCount = TidyReminder.count(addedDates: dates, now: Date(), lastDismissed: dismissed, enabled: true)
    }

    /// Hides the reminder for a week.
    func dismissTidyReminder() {
        defaults.set(Date(), forKey: Keys.tidyReminderDismissed)
        tidyReminderCount = nil
    }

    // MARK: Helpers

    /// A bookmark that keeps working after the folder is renamed or moved.
    private func makeBookmark(_ url: URL) -> Data? {
        (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData())
    }

    private func installedApplications(in folder: URL) -> [URL] {
        guard let contents = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return contents.filter { url in
            guard url.pathExtension.lowercased() == "app",
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) else { return false }
            return values.isDirectory == true
        }
    }

    private func chooseFolder(title: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        NSApp.activate()
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func createOrFindFolder(named name: String, in parent: URL) throws -> (URL, Bool) {
        var candidate = parent.appendingPathComponent(name, isDirectory: true)
        if fileManager.fileExists(atPath: candidate.path) {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue { return (candidate, false) }
            var suffix = 2
            repeat {
                candidate = parent.appendingPathComponent("\(name) \(suffix)", isDirectory: true)
                suffix += 1
            } while fileManager.fileExists(atPath: candidate.path)
        }
        try fileManager.createDirectory(at: candidate, withIntermediateDirectories: false)
        return (candidate, true)
    }

    private func validFolderName(_ value: String) -> String? {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"), !name.contains(":") else { return nil }
        return name
    }

    private func removeFolderIfEmpty(_ url: URL) {
        guard let contents = try? fileManager.contentsOfDirectory(atPath: url.path), contents.isEmpty else { return }
        try? fileManager.removeItem(at: url)
    }

    private func withAccess<T>(to url: URL, _ work: () throws -> T) rethrows -> T {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        return try work()
    }

    private func move(_ source: URL, into destination: URL) throws -> FileMoveReceipt {
        appMovedPaths.insert(source.path)
        let sourceAccess = source.startAccessingSecurityScopedResource()
        let destinationAccess = destination.startAccessingSecurityScopedResource()
        defer {
            if sourceAccess { source.stopAccessingSecurityScopedResource() }
            if destinationAccess { destination.stopAccessingSecurityScopedResource() }
        }
        return try mover.move(source, to: destination)
    }

    private func remember(fileName: String, destinationID: String) {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        let tokens = SuggestionEngine.filenameTokens(fileName)
        let entry = LearningRecord(fileExtension: ext, tokens: tokens, destinationID: destinationID, sampleName: fileName)
        learning.removeAll {
            $0.fileExtension == ext && $0.destinationID == destinationID && $0.sampleName == fileName
        }
        learning.insert(entry, at: 0)
        if learning.count > 300 { learning = Array(learning.prefix(300)) }
        persist(learning, key: Keys.learning)
    }

    private func saveLastMove(_ receipt: MoveBatchReceipt?) {
        lastMove = receipt
        guard let receipt else {
            defaults.removeObject(forKey: Keys.lastMove)
            return
        }
        persist(receipt, key: Keys.lastMove)
    }

    /// Reads the folders you cleaned, dropping any that no longer exist.
    private func loadRecentCleanupFolders() {
        let saved = Self.decode([RecentCleanupFolder].self, key: Keys.recentCleanupFolders, defaults: defaults) ?? []
        var records: [RecentCleanupFolder] = []
        var urls: [URL] = []
        for record in saved {
            let (resolved, stale) = resolveBookmark(record.bookmarkData)
            guard let url = resolved, fileManager.fileExists(atPath: url.path) else { continue }
            let path = url.standardizedFileURL.path
            guard !records.contains(where: { $0.path == path }) else { continue }
            let bookmark = stale ? (makeBookmark(url) ?? record.bookmarkData) : record.bookmarkData
            records.append(RecentCleanupFolder(path: path, bookmarkData: bookmark))
            urls.append(url)
        }
        recentCleanupRecords = records
        recentCleanupFolders = urls
        if records != saved { persist(records, key: Keys.recentCleanupFolders) }
    }

    /// Puts a folder you cleaned at the front of the remembered ones.
    private func rememberCleanupFolder(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        guard let bookmark = recentCleanupRecords.first(where: { $0.path == path })?.bookmarkData ?? makeBookmark(folder) else { return }
        var known: [String: (record: RecentCleanupFolder, url: URL)] = [:]
        for (record, url) in zip(recentCleanupRecords, recentCleanupFolders) { known[record.path] = (record, url) }
        known[path] = (RecentCleanupFolder(path: path, bookmarkData: bookmark), folder)
        let kept = CleanupFolders.remembering(path, in: recentCleanupRecords.map { $0.path }).compactMap { known[$0] }
        recentCleanupRecords = kept.map { $0.record }
        recentCleanupFolders = kept.map { $0.url }
        persist(recentCleanupRecords, key: Keys.recentCleanupFolders)
    }

    private func resolve(_ folder: FavoriteFolder) -> URL? {
        resolveBookmark(folder.bookmarkData).url
    }

    /// Security-scoped bookmarks (from a Finder window) first, then plain ones (from the setup helper).
    private func resolveBookmark(_ data: Data) -> (url: URL?, stale: Bool) {
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
            return (url, stale)
        }
        stale = false
        let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }

    private func resolvedURL(for id: String) -> URL? {
        guard let index = favoriteFolders.firstIndex(where: { $0.id == id }) else { return nil }
        let folder = favoriteFolders[index]
        let (resolved, stale) = resolveBookmark(folder.bookmarkData)
        guard let url = resolved else { return nil }
        if stale, let updated = makeBookmark(url) {
            favoriteFolders[index].bookmarkData = updated
            persist(favoriteFolders, key: Keys.folders)
        }
        return url
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func decode<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
