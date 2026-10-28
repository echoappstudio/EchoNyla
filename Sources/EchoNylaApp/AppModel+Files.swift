import AppKit
import EchoNylaCore
import Foundation

/// A short note at the top of the Files area, like "Moved 3 files to Receipts", with Undo when it can be undone.
struct FilesNote: Equatable, Identifiable {
    let id = UUID()
    let text: String
    var canUndo = false
}

/// The preview pane, what EchoNyla knows about each file, each file's history, and the moves,
/// renames and trips to the Trash the Files area makes. Every one of them can be undone.
extension AppModel {
    // MARK: The preview pane

    /// One click on a file anywhere: it's shown in the preview pane, and Apple Intelligence looks at
    /// it if it hasn't already.
    func select(_ url: URL?, count: Int = 1) {
        previewSelectionCount = count
        guard previewURL?.standardizedFileURL != url?.standardizedFileURL else { return }
        previewURL = url
        FilePreviewKeys.shared.selectionChanged()
        readForPane(url)
    }

    /// Space with nothing under the pointer, or the pane's Quick Look button.
    @discardableResult
    func quickLookSelected() -> Bool {
        guard selectedTab != .settings, let url = previewURL, fileManager.fileExists(atPath: url.path) else { return false }
        quickLookURL = url
        return true
    }

    func togglePreviewPane() {
        previewPaneShown.toggle()
        if previewPaneShown, let previewURL { readForPane(previewURL) }
    }

    /// Reads what's inside the file for the pane (names, spoken words), then asks Apple Intelligence
    /// what it is, unless it already said. Only while the pane is showing; a new click stops the last one.
    private func readForPane(_ url: URL?) {
        paneTask?.cancel()
        paneReading = false
        paneAsking = false
        guard previewPaneShown, let url, !isFolder(url) else {
            paneFacts = nil
            paneFactsPath = nil
            return
        }
        guard paneFactsPath != url.path else { return }
        paneFacts = nil
        paneFactsPath = url.path
        paneReading = true
        paneTask = Task { @MainActor in
            let facts = await FileInspector.facts(for: url, readContents: readContents)
            guard !Task.isCancelled, previewURL == url else { return }
            paneFacts = facts
            paneReading = false
            guard aiReady, insight(for: url) == nil else { return }
            paneAsking = true
            _ = await judge(url, facts: facts)
            guard !Task.isCancelled, previewURL == url else { return }
            paneAsking = false
            if insight(for: url) == nil {
                rememberInsight(summary: "", facts: facts, url: url)
            }
        }
    }

    /// "Ask Again" in the pane: Apple Intelligence looks at the file fresh.
    func askAgainForPane() {
        guard let url = previewURL, aiReady else { return }
        if let key = reviewKey(url) { insights.remove(key) }
        insightsVersion += 1
        paneFactsPath = nil
        readForPane(url)
    }

    func isFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    // MARK: What EchoNyla knows about a file

    func insight(for url: URL) -> FileInsight? {
        _ = insightsVersion
        guard let key = reviewKey(url) else { return nil }
        return insights.insight(for: key)
    }

    /// The same, for a file in a Files list (whose size and date are already known).
    func insight(for item: BrowserItem) -> FileInsight? {
        _ = insightsVersion
        return insights.insight(for: ReviewedFiles.key(path: item.url.standardizedFileURL.path, size: item.byteCount ?? 0,
                                                       modified: item.modified ?? .distantPast))
    }

    /// Keeps what Apple Intelligence said about a file, so lists, cards and the pane can show it.
    func rememberInsight(_ judged: ModelDecision, facts: FileFacts, url: URL) {
        let decision = judged.decision
        let insight = FileInsight(summary: decision.summary, proposedName: decision.proposedName, nameIsSure: judged.nameIsSure,
                                  destinationID: decision.destinationID, folderIsSure: decision.isConfident, reason: decision.reason,
                                  names: facts.names, speech: facts.speech, language: facts.language)
        storeInsight(insight, url: url)
    }

    func rememberInsight(summary: String, facts: FileFacts, url: URL) {
        storeInsight(FileInsight(summary: summary, names: facts.names, speech: facts.speech, language: facts.language), url: url)
    }

    private func storeInsight(_ insight: FileInsight, url: URL) {
        guard let key = reviewKey(url) else { return }
        insights.set(insight, for: key)
        insightsVersion += 1
        insightsUnsaved += 1
        insightsSaveTask?.cancel()
        if insightsUnsaved >= 25 {
            saveInsights()
        } else {
            insightsSaveTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                saveInsights()
            }
        }
    }

    private func saveInsights() {
        let snapshot = insights
        insightsUnsaved = 0
        Task.detached(priority: .utility) { snapshot.save() }
    }

    /// Where a file belongs, for its row and hover card: what Apple Intelligence said, or else what
    /// your rules and moves say. Nil for files already in one of your favorite folders.
    func quickSuggestion(for url: URL, isScreenshot: Bool = false) -> (destinationID: String, folderName: String, isSure: Bool)? {
        let folder = url.deletingLastPathComponent().standardizedFileURL.path
        guard !destinations.isEmpty, !isInFavorite(folder) else { return nil }
        if let known = insight(for: url), let id = known.destinationID, let name = destinationName(for: id) {
            return (id, name, known.folderIsSure)
        }
        guard let ranked = SuggestionEngine.suggestRanked(fileName: url.lastPathComponent, destinations: destinations, rules: rules,
                                                          learning: learning, isScreenCapture: isScreenshot),
              let name = destinationName(for: ranked.suggestion.destinationID) else { return nil }
        return (ranked.suggestion.destinationID, name, ranked.strength.isSure)
    }

    /// The same, for a file in a Files list.
    func quickSuggestion(for item: BrowserItem) -> (destinationID: String, folderName: String, isSure: Bool)? {
        guard !item.isFolder, !destinations.isEmpty, !isInFavorite(item.url.deletingLastPathComponent().standardizedFileURL.path) else { return nil }
        if let known = insight(for: item), let id = known.destinationID, let name = destinationName(for: id) {
            return (id, name, known.folderIsSure)
        }
        guard let ranked = SuggestionEngine.suggestRanked(fileName: item.name, destinations: destinations, rules: rules,
                                                          learning: learning, isScreenCapture: item.isScreenshot),
              let name = destinationName(for: ranked.suggestion.destinationID) else { return nil }
        return (ranked.suggestion.destinationID, name, ranked.strength.isSure)
    }

    /// Favorite folders by id, where they are now.
    var favoriteURLs: [String: URL] {
        if let favoriteURLCache { return favoriteURLCache }
        var urls: [String: URL] = [:]
        for folder in favoriteFolders {
            if let url = resolve(folder) { urls[folder.id] = url.standardizedFileURL }
        }
        favoriteURLCache = urls
        return urls
    }

    /// True for a favorite folder, or a folder inside one.
    func isInFavorite(_ path: String) -> Bool {
        favoriteURLs.values.contains { PathTrail.isInside(path, $0.path) }
    }

    /// The favorite folder at `path`, if it is one.
    func favoriteID(at path: String) -> String? {
        favoriteURLs.first { $0.value.path == path }?.key
    }

    /// Up to nine favorite folders for the 1 to 9 keys: the ones you move files into most.
    var quickSortFolders: [FavoriteFolder] {
        var uses: [String: Int] = [:]
        for record in learning { uses[record.destinationID, default: 0] += 1 }
        for entry in activity where !entry.isUndone && (entry.kind == .moved || entry.kind == .autoMoved) {
            if let id = entry.destinationID { uses[id, default: 0] += 1 }
        }
        let ids = QuickSortFolders.pick(favoriteFolders.map(\.id), uses: uses)
        return ids.compactMap { id in favoriteFolders.first { $0.id == id } }
    }

    // MARK: History

    func recordHistory(_ receipt: FileMoveReceipt) {
        history.record(from: receipt.originalURL.standardizedFileURL.path, to: receipt.movedURL.standardizedFileURL.path)
        historyChanged()
    }

    func historyUndone(_ receipts: [FileMoveReceipt]) {
        for receipt in receipts {
            history.markUndone(from: receipt.originalURL.standardizedFileURL.path, to: receipt.movedURL.standardizedFileURL.path)
        }
        historyChanged()
    }

    private func historyChanged() {
        historyVersion += 1
        historySaveTask?.cancel()
        historySaveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            let snapshot = history
            Task.detached(priority: .utility) { snapshot.save() }
        }
    }

    /// What EchoNyla did to the file at `url`, newest first.
    func historyTrail(for url: URL) -> [FileHistoryEvent] {
        _ = historyVersion
        return history.trail(for: url.standardizedFileURL.path)
    }

    /// Undo for the newest change in a file's history: it goes back where it was, with its old name.
    func undoHistory(_ event: FileHistoryEvent) {
        let receipt = FileMoveReceipt(originalURL: URL(fileURLWithPath: event.from), movedURL: URL(fileURLWithPath: event.to))
        do {
            try withAccess(to: receipt.movedURL.deletingLastPathComponent()) { try mover.undo(receipt) }
            handledPaths.insert(receipt.originalURL.path)
            markUndone(receipts: [receipt])
            if lastMove?.moves.contains(receipt) == true { saveLastMove(nil) }
            if previewURL?.standardizedFileURL.path == event.to { previewURL = receipt.originalURL }
            note("Put back: \(receipt.originalURL.lastPathComponent).")
            files.reloadAll()
        } catch {
            userError = "Could not undo that: \(error.localizedDescription)"
        }
    }

    // MARK: Moving, renaming and Trash from the Files area

    /// Moves files and folders into `folder`, as one batch (Undo puts them all back). From another
    /// disk they're copied instead, as in Finder. A move into a favorite folder teaches EchoNyla.
    @discardableResult
    func moveItems(_ urls: [URL], into folder: URL) -> [URL] {
        let target = folder.standardizedFileURL
        let destinationID = favoriteID(at: target.path)
        var receipts: [FileMoveReceipt] = []
        var copied = 0
        var placed: [URL] = []
        for url in urls.map(\.standardizedFileURL) {
            guard url.deletingLastPathComponent().path != target.path, !PathTrail.isInside(target.path, url.path) else { continue }
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                if Self.sameDisk(url, target) {
                    appMovedPaths.insert(url.path)
                    let receipt = try withAccess(to: target) { try mover.move(url, to: target, allowFolders: true) }
                    receipts.append(receipt)
                    placed.append(receipt.movedURL)
                    let name = favoriteFolders.first { $0.id == destinationID }?.name ?? target.lastPathComponent
                    addActivity(ActivityEntry(kind: .moved, fileName: url.lastPathComponent, detail: "Moved in Files", destinationID: destinationID,
                                              destinationName: name, receipt: receipt, filePath: receipt.movedURL.path))
                    if let destinationID, !isFolder(receipt.movedURL) { remember(fileName: url.lastPathComponent, destinationID: destinationID) }
                    if previewURL?.standardizedFileURL == url { previewURL = receipt.movedURL }
                } else {
                    let copy = try withAccess(to: target) { try mover.copy(url, to: target) }
                    placed.append(copy)
                    copied += 1
                }
            } catch {
                userError = "Could not move \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        if !receipts.isEmpty { saveLastMove(MoveBatchReceipt(moves: receipts)) }
        let name = destinationID.flatMap { id in favoriteFolders.first { $0.id == id }?.name } ?? target.lastPathComponent
        if !receipts.isEmpty {
            note("Moved \(Self.count(receipts.count, "item")) to \(name).", canUndo: true)
        } else if copied > 0 {
            note("Copied \(Self.count(copied, "item")) to \(name).")
        }
        files.reloadAll()
        return placed
    }

    /// Moves files into a favorite folder (the 1 to 9 keys, a folder menu, a row's Move button).
    @discardableResult
    func moveItems(_ urls: [URL], toFavorite id: String) -> [URL] {
        guard let folder = resolvedURL(for: id) else {
            userError = "That favorite folder can't be found anymore. Add it again in Folders & Rules."
            return []
        }
        return withAccess(to: folder) { moveItems(urls, into: folder) }
    }

    /// Renames a file or folder where it is. Undo puts the old name back.
    @discardableResult
    func renameItem(_ url: URL, to name: String) -> URL? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != url.lastPathComponent else { return nil }
        do {
            appMovedPaths.insert(url.path)
            let receipt = try withAccess(to: url.deletingLastPathComponent()) { try mover.rename(url, to: clean, allowFolders: true) }
            handledPaths.insert(receipt.movedURL.path)
            saveLastMove(MoveBatchReceipt(moves: [receipt]))
            addActivity(ActivityEntry(kind: .renamed, fileName: url.lastPathComponent, detail: "Renamed to " + receipt.movedURL.lastPathComponent,
                                      receipt: receipt, filePath: receipt.movedURL.path))
            if previewURL?.standardizedFileURL == url.standardizedFileURL { previewURL = receipt.movedURL }
            note("Renamed to \(receipt.movedURL.lastPathComponent).", canUndo: true)
            files.reloadAll()
            return receipt.movedURL
        } catch FileMoveError.invalidName {
            userError = "A name can't be empty or contain “/” or “:”."
        } catch {
            userError = "Could not rename \(url.lastPathComponent): \(error.localizedDescription)"
        }
        return nil
    }

    /// Moves files and folders to the Trash, as one batch: Undo (or ⌘Z) brings them back. Only the
    /// Trash empties itself, and only when you empty it.
    func trashItems(_ urls: [URL], detail: String = "Moved to Trash") {
        var receipts: [FileMoveReceipt] = []
        for url in urls where fileManager.fileExists(atPath: url.path) {
            do {
                var result: NSURL?
                appMovedPaths.insert(url.path)
                try withAccess(to: url.deletingLastPathComponent()) { try fileManager.trashItem(at: url, resultingItemURL: &result) }
                let receipt = FileMoveReceipt(originalURL: url, movedURL: (result as URL?) ?? url)
                receipts.append(receipt)
                addActivity(ActivityEntry(kind: .moved, fileName: url.lastPathComponent, detail: detail, destinationName: "Trash",
                                          receipt: receipt, filePath: receipt.movedURL.path))
                if previewURL?.standardizedFileURL == url.standardizedFileURL { previewURL = nil }
            } catch {
                userError = "Could not move \(url.lastPathComponent) to Trash: \(error.localizedDescription)"
            }
        }
        guard !receipts.isEmpty else { return }
        saveLastMove(MoveBatchReceipt(moves: receipts))
        note("Moved \(Self.count(receipts.count, "item")) to Trash.", canUndo: true)
        files.reloadAll()
    }

    /// A new folder inside `parent`; nil when the name can't be used.
    @discardableResult
    func makeFolder(named name: String, in parent: URL) -> URL? {
        guard let clean = validFolderName(name) else {
            userError = "A folder name can't be empty or contain “/” or “:”."
            return nil
        }
        do {
            let (folder, _) = try withAccess(to: parent) { try createOrFindFolder(named: clean, in: parent) }
            files.reloadAll()
            return folder
        } catch {
            userError = "Could not make the folder: \(error.localizedDescription)"
            return nil
        }
    }

    /// Paste (⌘V): copies of the files you copied, in `folder`.
    func pasteFiles(into folder: URL) {
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        var copied = 0
        for url in urls {
            do {
                _ = try withAccess(to: folder) { try mover.copy(url, to: folder) }
                copied += 1
            } catch {
                userError = "Could not copy \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        if copied > 0 { note("Copied \(Self.count(copied, "item")) here.") }
        files.reloadAll()
    }

    /// Adds a folder from the Files area to your favorites.
    func addFavorite(_ url: URL) {
        guard !favoriteURLs.values.contains(url.standardizedFileURL), let bookmark = makeBookmark(url) else { return }
        let favorite = FavoriteFolder(id: UUID().uuidString, name: url.lastPathComponent, bookmarkData: bookmark)
        favoriteFolders.append(favorite)
        persist(favoriteFolders, key: Keys.folders)
        note("Added \(url.lastPathComponent) to your favorite folders. Say what goes there in Folders & Rules.")
    }

    /// Tidy This Folder: Clean Up looks at the folder and lists everything it would change, for you to approve or skip.
    func tidy(_ folder: URL) {
        selectedTab = .cleanup
        startCleanup(at: folder)
    }

    /// Undo on the Files note: the last batch goes back.
    func undoFromNote() {
        undoLastMove()
        filesNote = nil
        files.reloadAll()
    }

    func note(_ text: String, canUndo: Bool = false) {
        filesNote = FilesNote(text: text, canUndo: canUndo)
        filesNoteTask?.cancel()
        filesNoteTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            filesNote = nil
        }
    }

    static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }

    nonisolated static func sameDisk(_ first: URL, _ second: URL) -> Bool {
        let left = try? first.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        let right = try? second.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        guard let left, let right else { return true }
        return left.isEqual(right)
    }
}
