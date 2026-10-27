import EchoNylaCore
import Foundation

/// A folder Deep Reorganize goes through, or one it must never touch.
struct ReorganizeFolder: Codable, Equatable, Identifiable {
    var id: String { path }
    let path: String
    let bookmarkData: Data

    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

enum ReorganizeStatus: Equatable {
    case idle, running, paused, finished
}

/// A file Deep Reorganize wasn't sure about, waiting for you.
struct ReorganizeItem: Identifiable {
    var id: String { url.path }
    var url: URL
    /// A Sort-into folder it might belong in, or nil.
    var destinationID: String?
    var proposedName: String?
    /// The name is sure (75 or more, built from what's in the file): it starts checked.
    var nameIsSure = false
    var summary: String
    var reason: String
    var moveSelected = false
    var renameSelected = false
    /// What's known about the file, for suggesting new folders.
    var groupText: String
}

/// A new folder Deep Reorganize suggests for files that are about the same thing.
struct ReorganizeGroup: Identifiable {
    let id: String
    var name: String
    let files: [URL]
    var isSelected = false
    /// Add it to your favorites as a Sort-into folder, learned from these files.
    var makeFavorite = true
    let learnedWords: [String]
}

/// Files with exactly the same contents: the one to keep and its copies.
struct ReorganizeDuplicate: Identifiable {
    var id: String { keep.path }
    let keep: URL
    let copies: [URL]
    var isSelected = false
}

/// One Deep Reorganize run's changes, saved on disk so Undo All works later, even after a relaunch.
/// Activity keeps only the latest 200 entries, so a big run keeps its own list.
struct ReorganizeRun: Codable, Equatable {
    var id = UUID()
    var started = Date()
    var moved = 0
    var renamed = 0
    /// Every move and rename, in the order they happened.
    var changes: [FileMoveReceipt] = []
    var createdFolders: [URL] = []
    var addedFavoriteIDs: [String] = []
    var isUndone = false

    var hasChanges: Bool { !changes.isEmpty && !isUndone }

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("EchoNyla", isDirectory: true).appendingPathComponent("reorganize-run.json")
    }

    static func load() -> ReorganizeRun? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ReorganizeRun.self, from: data)
    }

    func save() {
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
    }
}
