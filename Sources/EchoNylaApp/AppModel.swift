import AppKit
import CryptoKit
import Foundation
import Observation
import EchoNylaCore

struct FavoriteFolder: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var bookmarkData: Data
    /// "What goes here": yours, or written by Apple Intelligence from the files in it.
    var purpose: String?
    /// "Sort into this" (true) or "Just for dragging" (false). Nil for folders saved before 3.2.0,
    /// where a note meant the models could file into it.
    var sortsInto: Bool?
    /// What was learned from the files already in the folder (word stems), and when.
    var learnedWords: [String]?
    var learnedAt: Date?
    var learnedFrom: Int?
    /// The note was written from the folder's files, so learning again may replace it. Your own notes
    /// are kept. (Saved under this name since 3.2.0, when Bonsai wrote these notes.)
    var noteByBonsai: Bool?

    var isSortTarget: Bool { sortsInto ?? (Destination.cleanPurpose(purpose) != nil) }
}

/// A file Check This Folder wasn't sure about, for you to decide.
struct FolderCheckFinding: Identifiable {
    var id: String { url.path }
    let url: URL
    let folderID: String
    /// Where the model thought it might belong (not sure enough to move it), or nil.
    let suggestedID: String?
    let note: String
}

/// A folder you cleaned, remembered for Clean Up's button and Choose Folder's menu.
struct RecentCleanupFolder: Codable, Equatable {
    var path: String
    var bookmarkData: Data
}

struct CleanupEntry: Identifiable {
    var id: String { url.path }
    var url: URL
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
    /// The new name is sure: it's checked and applied with the sure changes.
    var nameIsSure = false
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
    /// "Sort into this" or "Just for dragging".
    var sortsInto = true
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

    var favoriteFolders: [FavoriteFolder] = [] {
        didSet { favoriteURLCache = nil }
    }
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

    /// How sure Apple Intelligence must be before EchoNyla moves or renames by itself.
    let confidenceBar = ConfidenceBar.standard
    private(set) var folderCheckProgress: String?
    private(set) var folderCheckFindings: [FolderCheckFinding] = []
    /// The folder being learned from its files, and how far it got.
    private(set) var learningFolderID: String?
    private(set) var folderLearnProgress: String?

    // Deep Reorganize.
    private(set) var reorganizeFolders: [ReorganizeFolder] = []
    private(set) var reorganizeSkipFolders: [ReorganizeFolder] = []
    private(set) var reorganizeStatus: ReorganizeStatus = .idle
    private(set) var reorganizeDone = 0
    private(set) var reorganizeTotal = 0
    /// Files the latest run left out because they were already looked at.
    private(set) var reorganizeSkipped = 0
    private(set) var reorganizeCurrent: String?
    private(set) var reorganizeTimeLeft: String?
    private(set) var reorganizeItems: [ReorganizeItem] = []
    /// Files of the run with nothing left to do (named, no folder to suggest), for suggesting new folders.
    @ObservationIgnored private var reorganizeSettled: [ReorganizeItem] = []
    private(set) var reorganizeGroups: [ReorganizeGroup] = []
    private(set) var reorganizeDuplicates: [ReorganizeDuplicate] = []
    /// The latest run's changes, for Undo All (kept on disk).
    private(set) var reorganizeRun: ReorganizeRun?

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
        static let modelChoice = "EchoNyla.ai.model.v1"
        static let confidenceBar = "EchoNyla.ai.bar.v1"
        static let reorganizeFolders = "EchoNyla.reorganize.folders.v1"
        static let reorganizeSkipFolders = "EchoNyla.reorganize.skip.v1"
        static let previewPane = "EchoNyla.previewPane.shown.v1"
        static let trashExactCopies = "EchoNyla.reorganize.trashCopies.v1"
        static let filesSort = "EchoNyla.files.sort.v1"
        static let filesGrouping = "EchoNyla.files.grouping.v1"
        static let filesViewMode = "EchoNyla.files.viewMode.v1"
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let folderGroupingSettings: FolderGroupingSettings
    @ObservationIgnored let fileManager = FileManager.default
    @ObservationIgnored let mover = FileMoveService()
    @ObservationIgnored private var cleanupScopeURL: URL?
    @ObservationIgnored private var cleanupScopeIsActive = false
    @ObservationIgnored private var recentCleanupRecords: [RecentCleanupFolder] = []
    /// The Apple Intelligence review of Clean Up that's running. Each new one replaces the last.
    @ObservationIgnored private var cleanupReview: Task<Void, Never>?
    @ObservationIgnored private var cleanupReviewRun = 0
    @ObservationIgnored private var folderCheckTask: Task<Void, Never>?
    @ObservationIgnored private var folderLearnQueue: [String] = []
    @ObservationIgnored private var folderLearnTask: Task<Void, Never>?
    @ObservationIgnored private var reorganizeQueue: [URL] = []
    @ObservationIgnored private var reorganizeTask: Task<Void, Never>?
    @ObservationIgnored private var reorganizeScopes: [URL] = []
    @ObservationIgnored private var reorganizeSeconds: TimeInterval = 0
    /// Where each file of the run is now, by where it was when the run started (for duplicates).
    @ObservationIgnored private var reorganizeLocations: [String: URL] = [:]
    @ObservationIgnored private var reorganizeUnsaved = 0
    /// Where a moved file started the run, by where it is now.
    @ObservationIgnored private var reorganizeOrigins: [String: String] = [:]
    @ObservationIgnored private var reorganizeStopped = false
    /// Files of the run that share their size with another (only these can be exact copies), and
    /// the contents fingerprints of those done so far, with the first file's name.
    @ObservationIgnored private var reorganizeSameSize: Set<String> = []
    @ObservationIgnored private var reorganizeFingerprints: [String: String] = [:]
    @ObservationIgnored private var watchStates: [String: FolderWatchState] = [:]
    @ObservationIgnored private var watchTimer: Timer?
    @ObservationIgnored private var watchScopes: [URL] = []
    @ObservationIgnored private var watchQueue: [URL] = []
    @ObservationIgnored private var isProcessingQueue = false
    /// The batch the queued files belong to (several files dropped at once), for Undo All.
    @ObservationIgnored private var queueRun: (id: UUID, title: String)?
    /// Files EchoNyla put back or renamed itself; watching never acts on them again.
    @ObservationIgnored var handledPaths: Set<String> = []
    /// Where files EchoNyla itself moved or renamed came from, so their leaving a watched folder is
    /// never mistaken for a move you made in Finder.
    @ObservationIgnored var appMovedPaths: Set<String> = []
    @ObservationIgnored private var tidyTimer: Timer?
    @ObservationIgnored private let searcher = FileSearcher()

    // MARK: Files area and preview pane (set in AppModel+Files.swift)

    /// The file in the preview pane: the one you clicked last.
    var previewURL: URL?
    /// How many files are selected in the Files area; the pane says so when it's more than one.
    var previewSelectionCount = 1
    /// Quick Look for the selected file (Space, or the pane's Quick Look button).
    var quickLookURL: URL?
    var previewPaneShown: Bool {
        didSet { defaults.set(previewPaneShown, forKey: Keys.previewPane) }
    }
    /// What was read from inside the file in the preview pane, and whether Apple Intelligence is still at it.
    var paneFacts: FileFacts?
    var paneFactsPath: String?
    var paneReading = false
    var paneAsking = false
    /// Changes whenever something is learned about a file, so lists and the pane show it.
    var insightsVersion = 0
    @ObservationIgnored var insights = FileInsights.load()
    @ObservationIgnored var insightsUnsaved = 0
    @ObservationIgnored var insightsSaveTask: Task<Void, Never>?
    @ObservationIgnored var paneTask: Task<Void, Never>?
    /// Every move, rename and trip to the Trash, for each file's history.
    var historyVersion = 0
    @ObservationIgnored var history = FileHistory.load()
    @ObservationIgnored var historySaveTask: Task<Void, Never>?
    /// A short note at the top of the Files area ("Moved 3 files to Receipts"), with Undo.
    var filesNote: FilesNote?
    @ObservationIgnored var filesNoteTask: Task<Void, Never>?
    /// The two sides of the Files area; they keep their place while you visit other pages.
    @ObservationIgnored let files = FilesArea()
    /// Favorite folders' places on disk, worked out once per change of favorites.
    @ObservationIgnored var favoriteURLCache: [String: URL]?
    /// Deep Reorganize moves exact copies (checked byte for byte) to Trash by itself. On unless you turn it off.
    var trashExactCopies: Bool {
        didSet { defaults.set(trashExactCopies, forKey: Keys.trashExactCopies) }
    }

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
        previewPaneShown = flag(Keys.previewPane)
        trashExactCopies = flag(Keys.trashExactCopies)
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
        // Test on My Files used to change the bar; it's fixed again now that the test is gone.
        defaults.removeObject(forKey: Keys.confidenceBar)
        reorganizeFolders = Self.decode([ReorganizeFolder].self, key: Keys.reorganizeFolders, defaults: defaults) ?? []
        reorganizeSkipFolders = Self.decode([ReorganizeFolder].self, key: Keys.reorganizeSkipFolders, defaults: defaults) ?? []
        reorganizeRun = ReorganizeRun.load()
        reviewedFiles = ReviewedFiles.load()
        reviewedCount = reviewedFiles.count
        defaults.removeObject(forKey: Keys.modelChoice)
        Self.removeBonsaiDownload()
    }

    /// EchoNyla used to run Bonsai, a 3.2 GB download; since 3.3.0 it uses Apple Intelligence only,
    /// so the download is deleted. Only EchoNyla's own Models folder is touched.
    private static func removeBonsaiDownload() {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let models = support.appendingPathComponent("EchoNyla/Models", isDirectory: true)
        guard FileManager.default.fileExists(atPath: models.path) else { return }
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: models) }
    }

    func start() {
        restartWatching()
        refreshTidyReminder()
        tidyTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.refreshTidyReminder() }
        }
    }

    var destinations: [Destination] {
        favoriteFolders.map {
            Destination(id: $0.id, name: $0.name, purpose: $0.purpose, sortsInto: $0.isSortTarget, learnedWords: $0.learnedWords ?? [])
        }
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
        if !aiEnabled { return "AI is turned off in EchoNyla's settings." }
        return OnDeviceModel.unavailableReason
    }

    /// The model's name, for reasons and status lines.
    let modelName = "Apple Intelligence"

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

    /// Checked sure changes, for the Sure part's Approve button: moves in the Sure part, plus
    /// sure renames (anywhere in Clean Up).
    var selectedSureCount: Int {
        cleanupRows.filter { ($0.bucket == .sure && $0.isSelected && $0.hasTarget) || ($0.nameIsSure && $0.renameSelected) }.count
    }

    /// Names in Clean Up that Apple Intelligence isn't sure about (50 to 74), for their Approve All.
    var unsureCleanupNameCount: Int {
        cleanupRows.filter { $0.proposedName != nil && !$0.nameIsSure }.count
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
        favoriteFolders[index].noteByBonsai = false
        persist(favoriteFolders, key: Keys.folders)
    }

    /// "Sort into this" or "Just for dragging". A new Sort-into folder is learned from its files right away.
    func setFolderSortsInto(id: String, _ sortsInto: Bool) {
        guard let index = favoriteFolders.firstIndex(where: { $0.id == id }) else { return }
        favoriteFolders[index].sortsInto = sortsInto
        persist(favoriteFolders, key: Keys.folders)
        if sortsInto, favoriteFolders[index].learnedAt == nil, aiReady { learnFolder(id: id) }
    }

    // MARK: Learning a folder from its files

    /// Apple Intelligence looks at up to 12 files already in the folder and writes down what they
    /// are: words it matches new files against, and a note (unless you wrote your own).
    func learnFolder(id: String) {
        guard aiReady, !folderLearnQueue.contains(id), learningFolderID != id else { return }
        folderLearnQueue.append(id)
        guard folderLearnTask == nil else { return }
        folderLearnTask = Task {
            while !folderLearnQueue.isEmpty {
                let next = folderLearnQueue.removeFirst()
                learningFolderID = next
                await learn(folderID: next)
            }
            learningFolderID = nil
            folderLearnProgress = nil
            folderLearnTask = nil
        }
    }

    func cancelFolderLearning() {
        folderLearnQueue = []
        folderLearnTask?.cancel()
        folderLearnTask = nil
        learningFolderID = nil
        folderLearnProgress = nil
    }

    private func learn(folderID id: String) async {
        guard let folder = favoriteFolders.first(where: { $0.id == id }), let url = resolvedURL(for: id) else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let files = looseFiles(in: url, limit: FolderProfile.sampleSize)
        guard !files.isEmpty else {
            statusMessage = "\(folder.name) has no files to learn from yet."
            return
        }
        var descriptions: [String] = []
        var samples: [String] = []
        let preparer = FilePreparer(readContents: readContents)
        let instructions = ModelPrompt.instructions(destinations: [], locked: [])
        let warm = OnDeviceModel.warmUp(instructions: instructions)
        for (number, file) in files.enumerated() {
            if Task.isCancelled { return }
            folderLearnProgress = "Learning \(folder.name): \(number + 1) of \(files.count)…"
            let prepared = await preparer.prepare(file, next: files.indices.contains(number + 1) ? files[number + 1] : nil)
            let question = OnDeviceModel.FileQuestion(facts: prepared.facts, picture: prepared.picture, instructions: instructions,
                                                      folderNames: [], currentFolderName: nil, examples: [])
            guard let answer = try? await OnDeviceModel.ask(question) else { continue }
            descriptions.append(answer.whatItIs)
            samples.append(answer.whatItIs + " " + answer.name)
        }
        withExtendedLifetime(warm) {}
        guard !Task.isCancelled, !descriptions.isEmpty else { return }
        folderLearnProgress = "Writing a note for \(folder.name)…"
        let prompt = FolderProfile.notePrompt(folderName: folder.name, descriptions: descriptions)
        let reply = try? await OnDeviceModel.learnedNote(prompt)
        guard let index = favoriteFolders.firstIndex(where: { $0.id == id }) else { return }
        favoriteFolders[index].learnedWords = FolderProfile.words(samples: samples)
        favoriteFolders[index].learnedAt = Date()
        favoriteFolders[index].learnedFrom = descriptions.count
        let ownNote = favoriteFolders[index].noteByBonsai != true && Destination.cleanPurpose(favoriteFolders[index].purpose) != nil
        if !ownNote, let note = reply.flatMap({ SetupSuggestions.cleanNote($0) }) {
            favoriteFolders[index].purpose = note
            favoriteFolders[index].noteByBonsai = true
        }
        persist(favoriteFolders, key: Keys.folders)
        statusMessage = "Learned \(folder.name) from \(descriptions.count) file\(descriptions.count == 1 ? "" : "s")."
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
        queueRun = (UUID(), "Sorted \(files.count) dropped files")
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

    @discardableResult
    private func performMove(_ source: URL, to destinationID: String, kind: ActivityEntry.Kind, detail: String,
                             ai: FileDecision?, enrich: Bool, notify: Bool = false, runID: UUID? = nil, runTitle: String? = nil) -> UUID? {
        guard let destination = resolvedURL(for: destinationID) else {
            userError = "That favorite folder can't be found anymore. Add it again in Folders & Rules."
            return nil
        }
        do {
            let receipt = try move(source, into: destination)
            saveLastMove(MoveBatchReceipt(moves: [receipt]))
            let name = destinationName(for: destinationID) ?? destination.lastPathComponent
            let entry = ActivityEntry(kind: kind, fileName: source.lastPathComponent, detail: detail, destinationID: destinationID,
                                      destinationName: name, receipt: receipt, filePath: receipt.movedURL.path,
                                      proposedName: ai?.proposedName, summary: ai?.summary, runID: runID, runTitle: runTitle)
            addActivity(entry)
            statusMessage = kind == .autoMoved ? "Moved \(source.lastPathComponent) to \(name) automatically." : "Moved to \(name)."
            if notify { Notifier.shared.post(entry, enabled: notificationsEnabled) }
            if enrich, aiReady { Task { await enrichAfterMove(entry.id, url: receipt.movedURL, destinationID: destinationID) } }
            return entry.id
        } catch {
            userError = "Could not move \(source.lastPathComponent): \(error.localizedDescription)"
            return nil
        }
    }

    /// Renames a file where it is (one that isn't being moved), with Undo. Returns its new address.
    @discardableResult
    private func renameInPlace(_ url: URL, to name: String, automatic: Bool, runID: UUID? = nil, runTitle: String? = nil) -> URL? {
        do {
            let receipt = try withAccess(to: url.deletingLastPathComponent()) { try mover.rename(url, to: name) }
            handledPaths.insert(receipt.movedURL.path)
            appMovedPaths.insert(url.path)
            let detail = (automatic ? "Renamed by itself to " : "Renamed to ") + receipt.movedURL.lastPathComponent
            addActivity(ActivityEntry(kind: .renamed, fileName: url.lastPathComponent, detail: detail, receipt: receipt,
                                      filePath: receipt.movedURL.path, runID: runID, runTitle: runTitle))
            return receipt.movedURL
        } catch {
            userError = "Could not rename \(url.lastPathComponent): \(error.localizedDescription)"
            return nil
        }
    }

    /// After a rule or learned pattern moved a file, the model still offers a clearer name, and
    /// applies it by itself when it's sure and the old name said nothing.
    private func enrichAfterMove(_ entryID: UUID, url: URL, destinationID: String) async {
        let facts = await FileInspector.facts(for: url, readContents: readContents)
        guard let judged = await judge(url, facts: facts) else { return }
        let decision = judged.decision
        guard let index = activity.firstIndex(where: { $0.id == entryID }), !activity[index].isUndone else { return }
        activity[index].proposedName = decision.proposedName
        activity[index].summary = decision.summary.isEmpty ? nil : decision.summary
        persist(activity, key: Keys.activity)
        if judged.renamesByItself, decision.proposedName != nil { applyProposedName(entryID, automatic: true) }
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

    func markUndone(receipts: [FileMoveReceipt]) {
        historyUndone(receipts)
        let movedPaths = Set(receipts.map { $0.movedURL.path })
        for index in activity.indices {
            guard let receipt = activity[index].receipt else { continue }
            // A rename made after the move is undone together with the move.
            let renamedAfterMove = activity[index].kind == .renamed && movedPaths.contains(receipt.movedURL.path)
            if receipts.contains(receipt) || renamedAfterMove { activity[index].isUndone = true }
        }
        persist(activity, key: Keys.activity)
    }

    /// Waiting files in Activity that have a suggested name.
    var waitingNameCount: Int {
        openSuggestions.filter { $0.proposedName != nil }.count
    }

    /// Approve All for the waiting names in Activity: each file is renamed where it is; its folder still waits.
    func applyAllWaitingNames() {
        let ids = openSuggestions.filter { $0.proposedName != nil }.map(\.id)
        for id in ids { applyProposedName(id) }
        if ids.count > 1 { statusMessage = "Renamed \(ids.count) files." }
    }

    /// Applies the proposed name to a file in Activity (by itself when `automatic`).
    func applyProposedName(_ entryID: UUID, automatic: Bool = false) {
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
            let run = activity[index]
            addActivity(ActivityEntry(kind: .renamed, fileName: url.lastPathComponent,
                                      detail: (automatic ? "Renamed by itself to " : "Renamed to ") + receipt.movedURL.lastPathComponent,
                                      receipt: receipt, filePath: receipt.movedURL.path, runID: run.runID, runTitle: run.runTitle))
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

    func addActivity(_ entry: ActivityEntry) {
        activity = ActivityEntry.adding(entry, to: activity)
        persist(activity, key: Keys.activity)
        if let receipt = entry.receipt { recordHistory(receipt) }
    }

    // MARK: Apple Intelligence

    struct Evaluation {
        let decision: AutoMoveDecision
        let ai: FileDecision?
        /// The new name is sure and the old one said nothing, so it's applied without asking.
        var renamesByItself = false
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
        let judged = await judge(url, facts: facts)
        let backed = facts.hasContentEvidence || judged?.matchesFolder == true
        let decision = AutoMovePolicy.decide(fileName: fileName, local: local, ai: judged?.decision, aiHadContentEvidence: backed,
                                             autoMoveEnabled: autoMove, locked: locked)
        return Evaluation(decision: decision, ai: judged?.decision, renamesByItself: judged?.renamesByItself == true)
    }

    /// Apple Intelligence's checked answer about one file: a folder only when it's sure about one you
    /// described and the safety net passes, a clearer name, and a summary. On macOS 27 it also looks
    /// at a picture of the file when its words don't say enough. `currentFolderName` is for Check This Folder.
    func judge(_ url: URL, facts: FileFacts, currentFolderName: String? = nil) async -> ModelDecision? {
        let picture = OnDeviceModel.seesPictures && PictureNeed.wanted(facts) ? await FileInspector.picture(for: url, readContents: readContents) : nil
        let prepared = PreparedFile(facts: facts, picture: picture, captured: FileInspector.creationDate(of: url))
        return await judge(url, prepared: prepared, currentFolderName: currentFolderName)
    }

    /// `judge` for a file whose facts and picture were read ahead (`FilePreparer`).
    private func judge(_ url: URL, prepared: PreparedFile, currentFolderName: String? = nil) async -> ModelDecision? {
        guard aiReady else { return nil }
        let facts = prepared.facts
        let locked = lockedDestinationIDs
        let examples = DecisionPrompt.examples(learning: learning, destinations: destinations, locked: locked, leavingOut: facts.fileName)
        let question = OnDeviceModel.FileQuestion(facts: facts, picture: prepared.picture, instructions: batchInstructions,
                                                  folderNames: AIFolders.choosable(destinations, locked: locked).map(\.name),
                                                  currentFolderName: currentFolderName, examples: examples)
        guard let answer = try? await OnDeviceModel.ask(question) else { return nil }
        let checked = ModelDecisionCheck.check(answer, facts: facts, destinations: destinations, locked: locked, bar: confidenceBar,
                                               captured: prepared.captured)
        rememberInsight(checked, facts: facts, url: url)
        return checked
    }

    /// The rules and the folders: the same for every file until a folder changes.
    private var batchInstructions: String {
        ModelPrompt.instructions(destinations: destinations, locked: lockedDestinationIDs)
    }

    /// Loads Apple Intelligence before a batch of files. Keep it until the batch is done.
    private func warmUpModel() -> AnyObject? {
        guard aiReady else { return nil }
        return OnDeviceModel.warmUp(instructions: batchInstructions)
    }

    /// "What is this file?" for any file.
    func explain(_ url: URL) {
        let key = url.path
        guard aiReady, !explaining.contains(key) else { return }
        explaining.insert(key)
        Task {
            let facts = await FileInspector.facts(for: url, readContents: readContents)
            let answer = await judge(url, facts: facts)?.decision
            explaining.remove(key)
            if let summary = answer?.summary, !summary.isEmpty {
                explanations[key] = summary
            } else {
                explanations[key] = "\(modelName) couldn't tell what this file is."
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
            queueRun = nil
            isProcessingQueue = false
        }
    }

    private func handleNewFile(_ url: URL) async {
        guard !destinations.isEmpty else { return }
        let result = await evaluate(url)
        let run = queueRun
        switch result.decision {
        case .move(let destinationID, let reason):
            let entryID = performMove(url, to: destinationID, kind: .autoMoved, detail: reason, ai: result.ai, enrich: result.ai == nil,
                                      notify: true, runID: run?.id, runTitle: run?.title)
            if let entryID, result.renamesByItself, result.ai?.proposedName != nil { applyProposedName(entryID, automatic: true) }
        case .suggest(let destinationID, let reason):
            // A sure name is applied right away; the folder still waits for you.
            var file = url
            var renamed = false
            if result.renamesByItself, let name = result.ai?.proposedName,
               let newURL = renameInPlace(url, to: name, automatic: true, runID: run?.id, runTitle: run?.title) {
                file = newURL
                renamed = true
            }
            guard destinationID != nil || (!renamed && result.ai?.proposedName != nil) else { return }
            let entry = ActivityEntry(kind: .suggested, fileName: file.lastPathComponent, detail: reason, destinationID: destinationID,
                                      destinationName: destinationName(for: destinationID), filePath: file.path,
                                      proposedName: renamed ? nil : result.ai?.proposedName, summary: result.ai?.summary)
            addActivity(entry)
            Notifier.shared.post(entry, enabled: notificationsEnabled)
        case .skip:
            break
        }
    }

    // MARK: Check This Folder

    /// Folders that can be checked: Sort-into favorites with a note or learned words.
    var checkableFolders: [FavoriteFolder] {
        let allowed = Set(AIFolders.choosable(destinations, locked: lockedDestinationIDs).map(\.id))
        return favoriteFolders.filter { allowed.contains($0.id) }
    }

    func checkFolder(id: String) { startFolderCheck(ids: [id]) }

    func checkAllFolders() { startFolderCheck(ids: checkableFolders.map(\.id)) }

    func cancelFolderCheck() {
        folderCheckTask?.cancel()
        folderCheckTask = nil
        folderCheckProgress = nil
    }

    private func startFolderCheck(ids: [String]) {
        guard folderCheckTask == nil, aiReady, !ids.isEmpty else { return }
        folderCheckFindings = []
        folderCheckTask = Task { await runFolderCheck(ids: ids) }
    }

    /// Looks at every file in each folder (up to 60, newest first). Files that clearly belong in
    /// another folder move there by themselves; files with unhelpful names get a sure new name;
    /// files it isn't sure about are listed for you. Everything is one batch with Undo All.
    private func runFolderCheck(ids: [String]) async {
        let runID = UUID()
        let title = ids.count == 1 ? "Checked \(destinationName(for: ids[0]) ?? "a folder")" : "Checked your folders"
        var moved = 0
        var renamed = 0
        for id in ids {
            guard let folder = favoriteFolders.first(where: { $0.id == id }), let folderURL = resolvedURL(for: id) else { continue }
            let access = folderURL.startAccessingSecurityScopedResource()
            defer { if access { folderURL.stopAccessingSecurityScopedResource() } }
            // Files checked before that belong where they are and kept their name aren't checked again.
            let files = looseFiles(in: folderURL, limit: 60).filter { !wasReviewed($0) }
            let preparer = FilePreparer(readContents: readContents)
            let warm = warmUpModel()
            defer { withExtendedLifetime(warm) {} }
            for (number, file) in files.enumerated() {
                if Task.isCancelled { break }
                folderCheckProgress = "Checking \(folder.name): \(number + 1) of \(files.count)…"
                let prepared = await preparer.prepare(file, next: files.indices.contains(number + 1) ? files[number + 1] : nil)
                guard !Task.isCancelled, let judged = await judge(file, prepared: prepared, currentFolderName: folder.name) else { continue }
                switch FolderCheck.verdict(currentFolderID: id, decision: judged) {
                case .move(let target):
                    let detail = "Didn't fit \(folder.name). \(judged.decision.reason)"
                    if let entryID = performMove(file, to: target, kind: .autoMoved, detail: detail, ai: judged.decision, enrich: false,
                                                 runID: runID, runTitle: title) {
                        moved += 1
                        if judged.renamesByItself, judged.decision.proposedName != nil {
                            applyProposedName(entryID, automatic: true)
                            renamed += 1
                        }
                    }
                case .belongs:
                    if judged.renamesByItself, let name = judged.decision.proposedName,
                       let newURL = renameInPlace(file, to: name, automatic: true, runID: runID, runTitle: title) {
                        renamed += 1
                        markReviewed(newURL)
                    } else if judged.decision.proposedName == nil {
                        markReviewed(file)
                    }
                case .maybe(let target):
                    folderCheckFindings.append(FolderCheckFinding(url: file, folderID: id, suggestedID: target,
                        note: "Might belong in \(destinationName(for: target) ?? "another folder"). \(judged.decision.summary)"))
                case .fitsNothing:
                    folderCheckFindings.append(FolderCheckFinding(url: file, folderID: id, suggestedID: nil,
                        note: "Doesn't seem to match \(folder.name)'s note. \(judged.decision.summary)"))
                }
            }
            if Task.isCancelled { break }
        }
        folderCheckProgress = nil
        folderCheckTask = nil
        saveReviewedFiles()
        var parts = ["\(title): moved \(moved), renamed \(renamed)"]
        if !folderCheckFindings.isEmpty { parts.append("\(folderCheckFindings.count) to look at in Folders & Rules") }
        statusMessage = parts.joined(separator: "; ") + "." + (moved + renamed > 0 ? " Undo All is in Activity." : "")
    }

    /// Moves a file Check This Folder wasn't sure about: your choice, so EchoNyla learns from it.
    func moveFinding(_ findingID: String, to destinationID: String) {
        guard let finding = folderCheckFindings.first(where: { $0.id == findingID }) else { return }
        folderCheckFindings.removeAll { $0.id == findingID }
        guard let folderURL = resolvedURL(for: finding.folderID) else { return }
        let access = folderURL.startAccessingSecurityScopedResource()
        defer { if access { folderURL.stopAccessingSecurityScopedResource() } }
        performMove(finding.url, to: destinationID, kind: .moved, detail: "Your choice after a folder check", ai: nil, enrich: false)
        remember(fileName: finding.url.lastPathComponent, destinationID: destinationID)
    }

    /// Leave It: the file stays, and later checks skip it.
    func dismissFinding(_ findingID: String) {
        guard let finding = folderCheckFindings.first(where: { $0.id == findingID }) else { return }
        folderCheckFindings.removeAll { $0.id == findingID }
        markReviewed(finding.url)
    }

    // MARK: Files already looked at

    /// Files Apple Intelligence already named, or that you approved or left as they are. Deep
    /// Reorganize and Check This Folder skip them until they change.
    @ObservationIgnored private var reviewedFiles = ReviewedFiles()
    @ObservationIgnored private var reviewedUnsaved = 0
    private(set) var reviewedCount = 0

    func reviewKey(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        return ReviewedFiles.key(path: url.standardizedFileURL.path, size: Int64(values.fileSize ?? 0),
                                 modified: values.contentModificationDate ?? .distantPast)
    }

    private func wasReviewed(_ url: URL) -> Bool {
        reviewKey(url).map { reviewedFiles.contains($0) } ?? false
    }

    func markReviewed(_ url: URL) {
        guard let key = reviewKey(url) else { return }
        reviewedFiles.insert(key)
        reviewedCount = reviewedFiles.count
        reviewedUnsaved += 1
        if reviewedUnsaved >= 20 { saveReviewedFiles() }
    }

    func saveReviewedFiles() {
        reviewedFiles.save()
        reviewedUnsaved = 0
    }

    /// Look at every file again, including the ones already named.
    func forgetReviewedFiles() {
        reviewedFiles = ReviewedFiles()
        reviewedCount = 0
        saveReviewedFiles()
        statusMessage = "Deep Reorganize and folder checks will look at every file again."
    }

    /// Regular files directly in a folder, newest first, skipping hidden files, partial downloads and installers.
    private func looseFiles(in folder: URL, limit: Int) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        let urls = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let files = urls.filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                && !AutoMovePolicy.isIgnored(fileName: url.lastPathComponent)
        }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
        return dated.sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
    }

    // MARK: Undo All

    /// Batches with something left to undo, newest first.
    var activityRuns: [ActivityRunSummary] { ActivityRuns.summaries(activity) }

    /// Undoes every change in one batch. A rename made after a move goes back with the move.
    func undoRun(_ runID: UUID) {
        let entries = activity.filter { $0.runID == runID && !$0.isUndone && $0.receipt != nil && $0.kind != .suggested }
        let movedTo = Set(entries.filter { $0.kind != .renamed }.compactMap { $0.receipt?.movedURL.path })
        var undone = 0
        for entry in entries {
            if entry.kind == .renamed, let path = entry.receipt?.movedURL.path, movedTo.contains(path) { continue }
            guard let current = activity.first(where: { $0.id == entry.id }), !current.isUndone else { continue }
            undo(entry.id)
            if activity.first(where: { $0.id == entry.id })?.isUndone == true { undone += 1 }
        }
        statusMessage = undone == 0 ? "Nothing in that batch could be undone." : "Undid \(undone) change\(undone == 1 ? "" : "s")."
    }

    // MARK: Deep Reorganize

    /// Adds a folder to go through, or (with `skip`) one Deep Reorganize must never touch.
    func addReorganizeFolder(skip: Bool) {
        let title = skip ? "Choose a folder Deep Reorganize must leave alone" : "Choose a folder for Deep Reorganize"
        guard let url = chooseFolder(title: title, prompt: skip ? "Leave Alone" : "Add Folder") else { return }
        addReorganizeFolder(url, skip: skip)
    }

    func addReorganizeFolder(_ url: URL, skip: Bool) {
        guard let bookmark = makeBookmark(url) else {
            userError = "Could not save that folder."
            return
        }
        let folder = ReorganizeFolder(path: url.standardizedFileURL.path, bookmarkData: bookmark)
        if skip {
            guard !reorganizeSkipFolders.contains(where: { $0.path == folder.path }) else { return }
            reorganizeSkipFolders.append(folder)
            persist(reorganizeSkipFolders, key: Keys.reorganizeSkipFolders)
        } else {
            guard !reorganizeFolders.contains(where: { $0.path == folder.path }) else { return }
            reorganizeFolders.append(folder)
            persist(reorganizeFolders, key: Keys.reorganizeFolders)
        }
    }

    func removeReorganizeFolder(path: String, skip: Bool) {
        if skip {
            reorganizeSkipFolders.removeAll { $0.path == path }
            persist(reorganizeSkipFolders, key: Keys.reorganizeSkipFolders)
        } else {
            reorganizeFolders.removeAll { $0.path == path }
            persist(reorganizeFolders, key: Keys.reorganizeFolders)
        }
    }

    var isReorganizing: Bool { reorganizeStatus == .running || reorganizeStatus == .paused }

    /// Goes through every file in the chosen folders (and the folders inside them), except the ones
    /// to leave alone and your Sort-into folders. Sure files are renamed and moved by themselves;
    /// the rest wait on the Reorganize page. Everything can be put back with Undo All.
    func startReorganize() {
        guard aiReady, !isReorganizing else { return }
        guard !reorganizeFolders.isEmpty else {
            userError = "Add a folder for Deep Reorganize to go through first."
            return
        }
        for url in reorganizeScopes { url.stopAccessingSecurityScopedResource() }
        reorganizeScopes = []
        func startAccess(_ folder: ReorganizeFolder) -> URL {
            let url = resolveBookmark(folder.bookmarkData).url ?? URL(fileURLWithPath: folder.path, isDirectory: true)
            if url.startAccessingSecurityScopedResource() { reorganizeScopes.append(url) }
            return url
        }
        let sources = reorganizeFolders.map(startAccess)
        let skips = reorganizeSkipFolders.map(startAccess).map { $0.standardizedFileURL.path }
        // Sort-into folders are where files go, so the files already in them are left alone.
        let targets = favoriteFolders.filter(\.isSortTarget).compactMap { resolve($0)?.standardizedFileURL.path }
        reorganizeItems = []
        reorganizeSettled = []
        reorganizeGroups = []
        reorganizeDuplicates = []
        reorganizeDone = 0
        reorganizeTotal = 0
        reorganizeSeconds = 0
        reorganizeTimeLeft = nil
        reorganizeStopped = false
        reorganizeCurrent = "Looking through the folders…"
        reorganizeStatus = .running
        reorganizeRun = ReorganizeRun()
        saveReorganizeRun()
        reorganizeTask = Task {
            let found = await Task.detached(priority: .utility) {
                Self.reorganizeFiles(sources: sources, skip: skips, targets: targets)
            }.value
            // Files it already named, or that you approved or left as they are, aren't looked at again.
            let files = found.filter { !wasReviewed($0) }
            reorganizeSkipped = found.count - files.count
            reorganizeQueue = reorganizeStopped ? [] : files
            reorganizeTotal = reorganizeQueue.count
            reorganizeSameSize = await Task.detached(priority: .utility) { Self.sharingSize(files) }.value
            reorganizeFingerprints = [:]
            reorganizeLocations = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            reorganizeOrigins = [:]
            await runReorganizeQueue()
        }
    }

    func pauseReorganize() {
        guard reorganizeStatus == .running else { return }
        reorganizeStatus = .paused
        reorganizeCurrent = "Pausing after this file…"
    }

    func resumeReorganize() {
        guard reorganizeStatus == .paused else { return }
        reorganizeStatus = .running
        if reorganizeTask == nil { reorganizeTask = Task { await runReorganizeQueue() } }
    }

    /// Stops going through files; what's done stays done, and the rest of the page fills in.
    func stopReorganize() {
        guard isReorganizing else { return }
        reorganizeStopped = true
        reorganizeQueue = []
        if reorganizeStatus == .paused, reorganizeTask == nil {
            reorganizeStatus = .running
            reorganizeTask = Task { await runReorganizeQueue() }
        } else {
            reorganizeStatus = .running
        }
    }

    private func runReorganizeQueue() async {
        let preparer = FilePreparer(readContents: readContents)
        let warm = warmUpModel()
        defer { withExtendedLifetime(warm) {} }
        while reorganizeStatus == .running, !reorganizeQueue.isEmpty {
            let file = reorganizeQueue.removeFirst()
            reorganizeCurrent = file.lastPathComponent
            let started = Date()
            if fileManager.fileExists(atPath: file.path) {
                await reorganize(file, prepared: await preparer.prepare(file, next: reorganizeQueue.first))
            }
            reorganizeSeconds += Date().timeIntervalSince(started)
            reorganizeDone += 1
            reorganizeTimeLeft = ReorganizeTime.remaining(done: reorganizeDone, total: reorganizeTotal, elapsed: reorganizeSeconds)
        }
        saveReorganizeRun()
        saveReviewedFiles()
        if reorganizeStatus == .paused {
            reorganizeCurrent = nil
            reorganizeTask = nil
            return
        }
        await finishReorganize()
        reorganizeTask = nil
    }

    /// One file: moved when sure (and renamed when the name is sure and the old one said nothing),
    /// renamed when only the name is sure, otherwise left for you. A file whose name is already
    /// good and that fits no folder is done.
    /// An exact copy of a file already done isn't asked about again; it's listed with the duplicates.
    private func reorganize(_ file: URL, prepared: PreparedFile) async {
        if reorganizeSameSize.contains(file.path) {
            let path = file.path
            if let print = await Task.detached(priority: .utility, operation: { Self.fingerprint(path) }).value {
                if let first = reorganizeFingerprints[print] {
                    reorganizeItems.append(ReorganizeItem(url: file, summary: "",
                                                          reason: "Same contents as “\(first)”, so it's listed with the duplicates.",
                                                          groupText: ""))
                    return
                }
                reorganizeFingerprints[print] = file.lastPathComponent
            }
        }
        guard let judged = await judge(file, prepared: prepared) else {
            reorganizeItems.append(ReorganizeItem(url: file, summary: "", reason: "\(modelName) couldn't read this file.", groupText: ""))
            return
        }
        let decision = judged.decision
        var current = file
        if autoMove, decision.isConfident, let id = decision.destinationID, let folder = resolvedURL(for: id),
           let moved = reorganizeMove(current, into: folder) {
            current = moved
            if judged.renamesByItself, let name = decision.proposedName, let newURL = reorganizeRename(current, to: name) {
                markReviewed(newURL)
                return
            }
            if let name = decision.proposedName, name != current.lastPathComponent {
                // It moved by itself, but its new name waits for you, so you can see it and approve it.
                let folderName = destinationName(for: id) ?? folder.lastPathComponent
                reorganizeItems.append(ReorganizeItem(url: current, proposedName: name, nameIsSure: judged.nameIsSure,
                                                      summary: decision.summary, reason: "Moved to \(folderName) by itself.",
                                                      renameSelected: judged.nameIsSure, groupText: "", movedTo: folderName))
                return
            }
            markReviewed(current)
            return
        }
        var renamed = false
        if judged.renamesByItself, let name = decision.proposedName, let newURL = reorganizeRename(current, to: name) {
            current = newURL
            renamed = true
        }
        let proposed = renamed ? nil : decision.proposedName
        if proposed == nil, decision.destinationID == nil {
            // A good name and no folder to suggest: nothing waits for you, but it can still join a suggested new folder.
            markReviewed(current)
            reorganizeSettled.append(ReorganizeItem(url: current, summary: decision.summary, reason: decision.reason,
                                                    groupText: [decision.summary, current.deletingPathExtension().lastPathComponent]
                                                        .joined(separator: " ")))
            return
        }
        let sure = autoMove == false && decision.isConfident
        reorganizeItems.append(ReorganizeItem(url: current, destinationID: decision.destinationID,
                                              proposedName: proposed, nameIsSure: proposed != nil && judged.nameIsSure,
                                              summary: decision.summary, reason: decision.reason,
                                              moveSelected: sure && decision.destinationID != nil,
                                              renameSelected: proposed != nil && judged.nameIsSure,
                                              groupText: [decision.summary, decision.proposedName ?? ""].joined(separator: " ")))
    }

    private func reorganizeMove(_ file: URL, into folder: URL) -> URL? {
        guard let receipt = try? move(file, into: folder) else { return nil }
        recordReorganize(receipt, renamed: false)
        return receipt.movedURL
    }

    private func reorganizeRename(_ file: URL, to name: String) -> URL? {
        guard let receipt = try? withAccess(to: file.deletingLastPathComponent(), { try mover.rename(file, to: name) }) else { return nil }
        recordReorganize(receipt, renamed: true)
        return receipt.movedURL
    }

    private func recordReorganize(_ receipt: FileMoveReceipt, renamed: Bool, trashed: Bool = false) {
        recordHistory(receipt)
        handledPaths.insert(receipt.movedURL.path)
        appMovedPaths.insert(receipt.originalURL.path)
        let origin = reorganizeOrigins[receipt.originalURL.path] ?? receipt.originalURL.path
        if reorganizeLocations[origin] != nil { reorganizeLocations[origin] = receipt.movedURL }
        reorganizeOrigins[receipt.movedURL.path] = origin
        if reorganizeRun == nil || reorganizeRun?.isUndone == true { reorganizeRun = ReorganizeRun() }
        reorganizeRun?.changes.append(receipt)
        if trashed {
            reorganizeRun?.trashed = (reorganizeRun?.trashed ?? 0) + 1
        } else if renamed {
            reorganizeRun?.renamed += 1
        } else {
            reorganizeRun?.moved += 1
        }
        reorganizeUnsaved += 1
        if reorganizeUnsaved >= 20 { saveReorganizeRun() }
    }

    /// Puts an exact copy in the Trash as part of the run, so Undo All brings it back. Checked byte
    /// for byte against the file that's kept, right before.
    private func reorganizeTrash(_ copy: URL, keeping keep: URL) -> Bool {
        guard fileManager.fileExists(atPath: copy.path), fileManager.fileExists(atPath: keep.path), ExactCopy.same(keep, copy) else { return false }
        var result: NSURL?
        appMovedPaths.insert(copy.path)
        guard (try? withAccess(to: copy.deletingLastPathComponent(), { try fileManager.trashItem(at: copy, resultingItemURL: &result) })) != nil,
              let trashed = result as URL? else { return false }
        recordReorganize(FileMoveReceipt(originalURL: copy, movedURL: trashed), renamed: false, trashed: true)
        return true
    }

    private func saveReorganizeRun() {
        reorganizeRun?.save()
        reorganizeUnsaved = 0
    }

    /// After the last file: suggested new folders for files about the same thing, and exact duplicates.
    private func finishReorganize() async {
        reorganizeCurrent = "Looking for duplicates and new folders…"
        let unplaced = (reorganizeItems + reorganizeSettled).filter { $0.destinationID == nil && !$0.groupText.isEmpty }
        let groups = ContentGrouping.groups(unplaced.map { (id: $0.id, text: $0.groupText) }, minimumSize: max(3, minimumRelatedFileCount),
                                            existingNames: favoriteFolders.map(\.name))
        reorganizeGroups = groups.map { group in
            let members = unplaced.filter { group.ids.contains($0.id) }
            return ReorganizeGroup(id: group.name.lowercased(), name: group.name, files: members.map(\.url),
                                   learnedWords: FolderProfile.words(samples: members.map(\.groupText)))
        }
        let locations = Array(reorganizeLocations.values)
        let found = await Task.detached(priority: .utility) { () -> [(keep: URL, copies: [URL])] in
            // A matching fingerprint is only a reason to look: every byte is compared before a file counts as a copy.
            Self.duplicates(among: locations).compactMap { group in
                let copies = group.copies.filter { ExactCopy.same(group.keep, $0) }
                return copies.isEmpty ? nil : (keep: group.keep, copies: copies)
            }
        }.value
        if trashExactCopies {
            var gone: Set<String> = []
            for group in found {
                for copy in group.copies where reorganizeTrash(copy, keeping: group.keep) { gone.insert(copy.path) }
            }
            reorganizeItems.removeAll { gone.contains($0.id) }
            reorganizeDuplicates = []
        } else {
            reorganizeDuplicates = found.map { ReorganizeDuplicate(keep: $0.keep, copies: $0.copies) }
        }
        reorganizeCurrent = nil
        reorganizeTimeLeft = nil
        reorganizeStatus = .finished
        saveReorganizeRun()
        let run = reorganizeRun
        let trashed = run?.trashed ?? 0
        statusMessage = "Deep Reorganize: moved \(run?.moved ?? 0), renamed \(run?.renamed ?? 0)"
            + (trashed > 0 ? ", put \(trashed) exact cop\(trashed == 1 ? "y" : "ies") in the Trash" : "")
            + "; \(reorganizeItems.count) waiting for you."
    }

    func setReorganizeMove(_ id: String, _ selected: Bool) {
        guard let index = reorganizeItems.firstIndex(where: { $0.id == id }) else { return }
        reorganizeItems[index].moveSelected = selected && reorganizeItems[index].destinationID != nil
    }

    func setReorganizeRename(_ id: String, _ selected: Bool) {
        guard let index = reorganizeItems.firstIndex(where: { $0.id == id }) else { return }
        reorganizeItems[index].renameSelected = selected && reorganizeItems[index].proposedName != nil
    }

    func setReorganizeDestination(_ id: String, _ destinationID: String) {
        guard let index = reorganizeItems.firstIndex(where: { $0.id == id }) else { return }
        reorganizeItems[index].destinationID = destinationID.isEmpty ? nil : destinationID
        reorganizeItems[index].moveSelected = !destinationID.isEmpty
    }

    /// Names waiting on the Reorganize page: sure ones (75 or more, from the file) or the ones it isn't sure about.
    func reorganizeNameCount(sure: Bool) -> Int {
        reorganizeItems.filter { $0.proposedName != nil && $0.nameIsSure == sure }.count
    }

    /// Approve All for names: renames every waiting file whose name is sure (or, with `sure` false,
    /// every one it isn't sure about). Folders still wait. It joins the run, so Undo All covers it.
    func approveReorganizeNames(sure: Bool) {
        guard !isReorganizing else { return }
        var renamed = 0
        for index in reorganizeItems.indices {
            let item = reorganizeItems[index]
            guard let name = item.proposedName, item.nameIsSure == sure, let newURL = reorganizeRename(item.url, to: name) else { continue }
            reorganizeItems[index].url = newURL
            reorganizeItems[index].proposedName = nil
            reorganizeItems[index].renameSelected = false
            renamed += 1
            if item.destinationID == nil { markReviewed(newURL) }
        }
        // Renamed files with no folder to suggest are done.
        reorganizeItems.removeAll { $0.proposedName == nil && $0.destinationID == nil }
        saveReorganizeRun()
        saveReviewedFiles()
        statusMessage = "Renamed \(renamed) file\(renamed == 1 ? "" : "s"). Undo All puts the whole run back."
    }

    /// Leave As Is: the file keeps its name and place, and later runs skip it.
    func leaveReorganizeItem(_ id: String) {
        guard let item = reorganizeItems.first(where: { $0.id == id }) else { return }
        reorganizeItems.removeAll { $0.id == id }
        markReviewed(item.url)
        saveReviewedFiles()
    }

    func setReorganizeGroup(_ id: String, selected: Bool) {
        guard let index = reorganizeGroups.firstIndex(where: { $0.id == id }) else { return }
        reorganizeGroups[index].isSelected = selected
    }

    func renameReorganizeGroup(_ id: String, to name: String) {
        guard let index = reorganizeGroups.firstIndex(where: { $0.id == id }) else { return }
        reorganizeGroups[index].name = name
    }

    func setReorganizeGroupFavorite(_ id: String, _ makeFavorite: Bool) {
        guard let index = reorganizeGroups.firstIndex(where: { $0.id == id }) else { return }
        reorganizeGroups[index].makeFavorite = makeFavorite
    }

    func setReorganizeDuplicate(_ id: String, selected: Bool) {
        guard let index = reorganizeDuplicates.firstIndex(where: { $0.id == id }) else { return }
        reorganizeDuplicates[index].isSelected = selected
    }

    var reorganizeChosenCount: Int {
        reorganizeItems.filter { ($0.moveSelected && $0.destinationID != nil) || ($0.renameSelected && $0.proposedName != nil) }.count
            + reorganizeGroups.filter(\.isSelected).count + reorganizeDuplicates.filter(\.isSelected).count
    }

    /// Applies what you checked on the Reorganize page. It joins the run, so Undo All covers it too.
    func applyReorganizeChoices() {
        guard !isReorganizing else { return }
        var moved = 0
        var renamed = 0
        var done: Set<String> = []
        for item in reorganizeItems where item.moveSelected || item.renameSelected {
            var current = item.url
            if item.renameSelected, let name = item.proposedName, let newURL = reorganizeRename(current, to: name) {
                current = newURL
                renamed += 1
            }
            if item.moveSelected, let id = item.destinationID, let folder = resolvedURL(for: id),
               let newURL = reorganizeMove(current, into: folder) {
                current = newURL
                moved += 1
                remember(fileName: newURL.lastPathComponent, destinationID: id)
            }
            markReviewed(current)
            done.insert(item.id)
        }
        reorganizeItems.removeAll { done.contains($0.id) }

        var newFavorites: [String] = []
        for group in reorganizeGroups where group.isSelected {
            guard let name = validFolderName(group.name) else {
                userError = "Enter a valid name for the \(group.name) folder."
                continue
            }
            let files = group.files.filter { fileManager.fileExists(atPath: $0.path) }
            guard let parent = Self.mostCommonParent(files) else { continue }
            do {
                let (folder, created) = try withAccess(to: parent) { try createOrFindFolder(named: name, in: parent) }
                if created { reorganizeRun?.createdFolders.append(folder) }
                for file in files where reorganizeMove(file, into: folder) != nil { moved += 1 }
                if group.makeFavorite, let bookmark = makeBookmark(folder),
                   !favoriteFolders.contains(where: { resolve($0)?.standardizedFileURL == folder.standardizedFileURL }) {
                    let favorite = FavoriteFolder(id: UUID().uuidString, name: folder.lastPathComponent, bookmarkData: bookmark,
                                                  sortsInto: true, learnedWords: group.learnedWords)
                    favoriteFolders.append(favorite)
                    reorganizeRun?.addedFavoriteIDs.append(favorite.id)
                    newFavorites.append(favorite.id)
                }
            } catch {
                userError = "Could not make the \(name) folder: \(error.localizedDescription)"
            }
            let paths = Set(group.files.map(\.path))
            reorganizeItems.removeAll { paths.contains($0.id) }
        }
        reorganizeGroups.removeAll(where: \.isSelected)
        persist(favoriteFolders, key: Keys.folders)

        var trashed = 0
        for duplicate in reorganizeDuplicates where duplicate.isSelected {
            for copy in duplicate.copies where reorganizeTrash(copy, keeping: duplicate.keep) {
                trashed += 1
                done.insert(copy.path)
            }
        }
        reorganizeItems.removeAll { done.contains($0.id) }
        reorganizeDuplicates.removeAll(where: \.isSelected)
        saveReorganizeRun()
        saveReviewedFiles()
        if aiReady { for id in newFavorites { learnFolder(id: id) } }
        statusMessage = "Moved \(moved), renamed \(renamed)" + (trashed > 0 ? ", put \(trashed) in the Trash" : "") + ". Undo All puts the whole run back."
    }

    /// Puts back every move and rename of the latest run, newest first. Folders it made go if
    /// they're empty, and favorites it added are removed.
    func undoReorganizeRun() {
        guard var run = reorganizeRun, run.hasChanges, !isReorganizing else { return }
        var undone = 0
        var failed = 0
        for receipt in run.changes.reversed() {
            do {
                try mover.undo(receipt)
                handledPaths.insert(receipt.originalURL.path)
                historyUndone([receipt])
                undone += 1
            } catch {
                failed += 1
            }
        }
        for folder in run.createdFolders.reversed() { removeFolderIfEmpty(folder) }
        let added = Set(run.addedFavoriteIDs)
        if !added.isEmpty {
            favoriteFolders.removeAll { added.contains($0.id) }
            persist(favoriteFolders, key: Keys.folders)
        }
        run.isUndone = true
        run.save()
        reorganizeRun = run
        reorganizeItems = []
        reorganizeGroups = []
        reorganizeDuplicates = []
        reorganizeStatus = .idle
        statusMessage = failed == 0 ? "Put back \(undone) changes."
            : "Put back \(undone) changes. \(failed) couldn't be put back: those files had been moved or replaced since."
    }

    /// Every file under `sources`, leaving out folders to skip, Sort-into folders (`targets`) inside
    /// them, hidden files, app bundles, partial downloads and installers. At most `ReorganizeScope.fileLimit`.
    nonisolated private static func reorganizeFiles(sources: [URL], skip: [String], targets: [String]) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        var result: [URL] = []
        var seen: Set<String> = []
        for source in sources {
            let sourcePath = source.standardizedFileURL.path
            guard !ReorganizeScope.isInside(sourcePath, any: skip),
                  let walker = FileManager.default.enumerator(at: source, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let url = walker.nextObject() as? URL {
                let path = url.standardizedFileURL.path
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    if ReorganizeScope.isInside(path, any: skip) || (path != sourcePath && targets.contains(path)) { walker.skipDescendants() }
                    continue
                }
                guard values?.isRegularFile == true, !AutoMovePolicy.isIgnored(fileName: url.lastPathComponent),
                      seen.insert(path).inserted else { continue }
                result.append(url.standardizedFileURL)
                if result.count >= ReorganizeScope.fileLimit { return result }
            }
        }
        return result
    }

    nonisolated private static func mostCommonParent(_ files: [URL]) -> URL? {
        let parents = Dictionary(grouping: files) { $0.deletingLastPathComponent().standardizedFileURL }
        return parents.max { $0.value.count != $1.value.count ? $0.value.count < $1.value.count : $0.key.path > $1.key.path }?.key
    }

    /// Exact duplicates among `files`: same size first, then the same SHA-256 of the contents.
    /// Paths among `files` whose size matches another file's.
    nonisolated private static func sharingSize(_ files: [URL]) -> Set<String> {
        let sized = files.compactMap { url -> (path: String, size: Int64)? in
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
            return (path: url.path, size: Int64(size))
        }
        return Set(DuplicateFinder.sameSize(sized).joined())
    }

    nonisolated private static func duplicates(among files: [URL]) -> [(keep: URL, copies: [URL])] {
        var sized: [(path: String, size: Int64)] = []
        var modified: [String: Date] = [:]
        for url in files {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true, let size = values.fileSize else { continue }
            sized.append((path: url.path, size: Int64(size)))
            modified[url.path] = values.contentModificationDate
        }
        var prints: [(path: String, fingerprint: String)] = []
        for group in DuplicateFinder.sameSize(sized) {
            for path in group {
                if let print = fingerprint(path) { prints.append((path: path, fingerprint: print)) }
            }
        }
        return DuplicateFinder.groups(prints).compactMap { paths in
            guard let keep = DuplicateFinder.keeper(paths, modified: modified) else { return nil }
            return (keep: URL(fileURLWithPath: keep), copies: paths.filter { $0 != keep }.map { URL(fileURLWithPath: $0) })
        }
    }

    nonisolated private static func fingerprint(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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

    /// Approve All for the names Apple Intelligence isn't sure about (50 to 74): renames them all where they are.
    func approveUnsureCleanupNames() {
        var receipts: [FileMoveReceipt] = []
        for index in cleanupRows.indices {
            let row = cleanupRows[index]
            guard let name = row.proposedName, !row.nameIsSure else { continue }
            do {
                let receipt = try withAccess(to: row.url.deletingLastPathComponent()) { try mover.rename(row.url, to: name) }
                receipts.append(receipt)
                handledPaths.insert(receipt.movedURL.path)
                appMovedPaths.insert(row.url.path)
                addActivity(ActivityEntry(kind: .renamed, fileName: row.url.lastPathComponent,
                                          detail: "Renamed to \(receipt.movedURL.lastPathComponent)", receipt: receipt,
                                          filePath: receipt.movedURL.path))
                // The row stays, under its new name, so its folder can still be approved.
                cleanupRows[index].url = receipt.movedURL
                cleanupRows[index].proposedName = nil
                cleanupRows[index].renameSelected = false
            } catch {
                userError = "Could not rename \(row.url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        guard !receipts.isEmpty else { return }
        saveLastMove(MoveBatchReceipt(moves: receipts))
        statusMessage = "Renamed \(receipts.count) file\(receipts.count == 1 ? "" : "s"). Undo Last Move puts the names back."
    }

    /// Applies the checked moves and renames (only the Sure part's moves when `onlySure`).
    func moveSelectedCleanupItems(onlySure: Bool = false) {
        var movedCount = 0
        var renamedCount = 0
        var receipts: [FileMoveReceipt] = []
        var createdFolders: [URL] = []
        var learned: [(String, String)] = []

        for row in cleanupRows where (row.isSelected || row.renameSelected) && (!onlySure || row.bucket == .sure || row.nameIsSure) {
            var source = row.url
            if row.renameSelected, let name = row.proposedName, !onlySure || row.bucket == .sure || row.nameIsSure {
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
            guard row.isSelected, !onlySure || row.bucket == .sure else { continue }
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

    /// Clean Up's clutter goes to the Trash only after an explicit, separate confirmation. Undo Last Move brings it back.
    func moveSelectedInstallersToTrash() {
        let urls = trashRows.filter(\.isSelected).map(\.url)
        trashItems(urls, detail: "Moved to Trash from Clean Up")
        if let cleanupFolder { beginCleanup(at: cleanupFolder, askAI: false) }
        statusMessage = urls.isEmpty ? "Nothing was moved to Trash." : "Moved \(Self.count(urls.count, "file")) to Trash. Undo Last Move brings them back."
    }

    /// Clutter in a folder you clean up: files over 500 MB, files nobody opened or changed in a year, and
    /// (found in the background, checked byte for byte) exact copies of another file there. Always unchecked.
    private func findCleanupClutter(in folder: URL) {
        let listed = Set(trashRows.map(\.id))
        for row in cleanupRows where !listed.contains(row.id) {
            let item = FileBrowser.item(for: row.url)
            let flags = ClutterCheck.flags(item, isCopy: false, isUsedInstaller: false)
            if flags.contains(.large) {
                trashRows.append(TrashEntry(url: row.url, reason: "Large: \(ByteText.text(item.byteCount ?? 0))", isSelected: false))
            } else if flags.contains(.untouched) {
                trashRows.append(TrashEntry(url: row.url, reason: "Nobody opened or changed it in over a year", isSelected: false))
            }
        }
        let files = cleanupRows.map(\.url)
        Task { @MainActor in
            let groups = await Task.detached(priority: .utility) { ExactCopy.groups(files) }.value
            guard cleanupFolder?.standardizedFileURL == folder.standardizedFileURL else { return }
            for group in groups {
                let modified = Dictionary(uniqueKeysWithValues: group.map {
                    ($0.path, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
                })
                guard let keep = DuplicateFinder.keeper(group.map(\.path), modified: modified) else { continue }
                let keepName = URL(fileURLWithPath: keep).lastPathComponent
                for copy in group where copy.path != keep {
                    trashRows.removeAll { $0.id == copy.path }
                    trashRows.append(TrashEntry(url: copy, reason: "Exact copy of “\(keepName)” (checked byte for byte)", isSelected: false))
                }
            }
            trashRows.sort { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        }
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
            findCleanupClutter(in: folder)
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
        // Files without a folder first, then the rest, for better names.
        let unplaced = cleanupRows.filter { !$0.hasTarget }
        let placed = cleanupRows.filter(\.hasTarget)
        let candidates = Array((unplaced + placed).prefix(40))
        let label = modelName
        var factsByPath: [String: FileFacts] = [:]
        for (number, row) in candidates.enumerated() {
            guard cleanupReviewRun == run else { return }
            cleanupProgress = "\(label) is looking at \(number + 1) of \(candidates.count)…"
            let facts = await FileInspector.facts(for: row.url, readContents: readContents)
            factsByPath[row.id] = facts
            let answer = await judge(row.url, facts: facts)
            guard cleanupReviewRun == run else { return }
            guard let judged = answer, let index = cleanupRows.firstIndex(where: { $0.id == row.id }) else { continue }
            let decision = judged.decision
            if !cleanupRows[index].hasTarget, let destinationID = decision.destinationID {
                cleanupRows[index].destinationID = destinationID
                cleanupRows[index].suggestionReason = "\(label): \(decision.reason)" + (decision.isConfident ? "" : " (a guess; check it)")
                cleanupRows[index].isSelected = decision.isConfident
                cleanupRows[index].bucket = decision.isConfident ? .sure : .guess
            }
            cleanupRows[index].proposedName = decision.proposedName
            cleanupRows[index].nameIsSure = decision.proposedName != nil && judged.nameIsSure
            cleanupRows[index].renameSelected = decision.proposedName != nil && judged.nameIsSure
            cleanupRows[index].summary = decision.summary.isEmpty ? nil : decision.summary
        }
        if aiGroupsEnabled {
            cleanupProgress = "Looking for files that belong together…"
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
            let texts = files.map { url in url.lastPathComponent + " " + (factsByPath[url.path]?.text ?? "") }
            let checked = GroupCheck.validate(answer.map { (name: $0.name, members: $0.files) }, fileCount: files.count,
                                              minimumSize: aiGroupMinimum, memberTexts: texts)
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
        // Notes are drafted from the folders' file names; each Sort-into folder is also learned from its files once added.
        let drafts = aiReady
        setupCandidates = ranked.map { folder in
            SetupCandidate(url: URL(fileURLWithPath: folder.path, isDirectory: true), fileCount: counts[folder.path] ?? folder.fileCount,
                           note: "", isDrafting: drafts)
        }
        isPreparingSetup = false
        guard drafts else { return }
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

    func setSetupSortsInto(id: String, _ sortsInto: Bool) {
        guard let index = setupCandidates.firstIndex(where: { $0.id == id }) else { return }
        setupCandidates[index].sortsInto = sortsInto
    }

    func setSetupNote(id: String, to note: String) {
        guard let index = setupCandidates.firstIndex(where: { $0.id == id }) else { return }
        setupCandidates[index].note = note
        setupCandidates[index].isDrafting = false
    }

    /// Adds the ticked folders as favorites with their notes.
    func addChosenSetupFolders() {
        var added = 0
        var toLearn: [String] = []
        for candidate in setupCandidates where candidate.isSelected {
            guard let bookmark = makeBookmark(candidate.url),
                  !favoriteFolders.contains(where: { resolve($0)?.standardizedFileURL == candidate.url.standardizedFileURL }) else { continue }
            let note = Destination.cleanPurpose(candidate.note)
            let folder = FavoriteFolder(id: UUID().uuidString, name: candidate.url.lastPathComponent, bookmarkData: bookmark, purpose: note,
                                        sortsInto: candidate.sortsInto)
            favoriteFolders.append(folder)
            if candidate.sortsInto { toLearn.append(folder.id) }
            added += 1
        }
        persist(favoriteFolders, key: Keys.folders)
        if aiReady { for id in toLearn { learnFolder(id: id) } }
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
    func makeBookmark(_ url: URL) -> Data? {
        (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData())
    }

    func installedApplications(in folder: URL) -> [URL] {
        guard let contents = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return contents.filter { url in
            guard url.pathExtension.lowercased() == "app",
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) else { return false }
            return values.isDirectory == true
        }
    }

    func chooseFolder(title: String, prompt: String) -> URL? {
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

    func createOrFindFolder(named name: String, in parent: URL) throws -> (URL, Bool) {
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

    func validFolderName(_ value: String) -> String? {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"), !name.contains(":") else { return nil }
        return name
    }

    private func removeFolderIfEmpty(_ url: URL) {
        guard let contents = try? fileManager.contentsOfDirectory(atPath: url.path), contents.isEmpty else { return }
        try? fileManager.removeItem(at: url)
    }

    func withAccess<T>(to url: URL, _ work: () throws -> T) rethrows -> T {
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

    func remember(fileName: String, destinationID: String) {
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

    func saveLastMove(_ receipt: MoveBatchReceipt?) {
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

    func resolve(_ folder: FavoriteFolder) -> URL? {
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

    func resolvedURL(for id: String) -> URL? {
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

    func persist<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func decode<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// Lets download progress through about every half percent, so the screen isn't redrawn thousands of times.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1.0

    func shouldReport(_ fraction: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard fraction - last >= 0.005 || fraction >= 1 else { return false }
        last = fraction
        return true
    }
}
