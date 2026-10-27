import Foundation

/// What to do with one new or dropped file.
public enum AutoMoveDecision: Equatable, Sendable {
    /// Move it now: the folder is certain.
    case move(destinationID: String, reason: String)
    /// Show a suggestion (or none) and wait for you.
    case suggest(destinationID: String?, reason: String)
    /// Leave it alone (still downloading, hidden, an installer…).
    case skip(reason: String)
}

/// Decides when EchoNyla may move a file by itself.
///
/// Sure: your rules, macOS screenshots, patterns learned from 3+ of your moves, and Apple
/// Intelligence answers for a folder you described, marked confident and backed by more than the
/// file name (text inside the file, what an image shows, or the website it came from) or agreeing
/// with a local hint.
/// Everything else is only a suggestion. Folders reserved by a rule are never chosen by anything
/// but that rule.
public enum AutoMovePolicy {
    /// Partial downloads, temporary files and installers are never moved automatically.
    public static let ignoredExtensions: Set<String> = [
        "download", "crdownload", "part", "partial", "opdownload", "tmp", "icloud", "dmg", "pkg", "mpkg", "app"
    ]

    public static func isIgnored(fileName: String) -> Bool {
        fileName.hasPrefix(".") || ignoredExtensions.contains(URL(fileURLWithPath: fileName).pathExtension.lowercased())
    }

    public static func decide(fileName: String, local: RankedSuggestion?, ai: FileDecision?, aiHadContentEvidence: Bool,
                              autoMoveEnabled: Bool, locked: Set<String>) -> AutoMoveDecision {
        if isIgnored(fileName: fileName) {
            return .skip(reason: "Partial downloads, hidden files and installers are left alone.")
        }
        if let local, local.strength.isSure {
            let suggestion = local.suggestion
            return autoMoveEnabled ? .move(destinationID: suggestion.destinationID, reason: suggestion.reason)
                : .suggest(destinationID: suggestion.destinationID, reason: suggestion.reason)
        }
        if let ai, let destinationID = ai.destinationID, !locked.contains(destinationID) {
            if let local, local.suggestion.destinationID != destinationID {
                // Two different answers: let the person decide.
                return .suggest(destinationID: destinationID, reason: ai.reason)
            }
            let agreesWithLocal = local?.suggestion.destinationID == destinationID
            let backed = aiHadContentEvidence || agreesWithLocal
            if autoMoveEnabled, ai.isConfident, backed {
                return .move(destinationID: destinationID, reason: "Apple Intelligence: \(ai.reason)")
            }
            return .suggest(destinationID: destinationID, reason: ai.reason)
        }
        if let local {
            return .suggest(destinationID: local.suggestion.destinationID, reason: local.suggestion.reason)
        }
        return .suggest(destinationID: nil, reason: "No confident match. Choose a folder.")
    }
}

/// One file in a watched folder at one moment.
public struct FileSnapshot: Equatable, Sendable {
    public var path: String
    public var size: Int64
    public var modified: Date

    public init(path: String, size: Int64, modified: Date) {
        self.path = path
        self.size = size
        self.modified = modified
    }
}

/// Finds files that arrived in a watched folder and have finished arriving. Files that were
/// already there when watching started are never touched.
public struct FolderWatchState: Sendable {
    struct Tracked: Sendable {
        var size: Int64
        var modified: Date
        var stableSince: Date
        var handled: Bool
        /// Already there when watching started.
        var fromBaseline: Bool
    }

    var tracked: [String: Tracked] = [:]
    public private(set) var hasBaseline = false
    /// Files that arrived while watching and have gone again since the last update (moved away in
    /// Finder, renamed, deleted, or filed by EchoNyla itself), as they last looked.
    public private(set) var departed: [FileSnapshot] = []

    public init() {}

    /// The first look at the folder: everything already there counts as handled.
    public mutating func baseline(_ files: [FileSnapshot], now: Date) {
        tracked = [:]
        for file in files {
            tracked[file.path] = Tracked(size: file.size, modified: file.modified, stableSince: now, handled: true, fromBaseline: true)
        }
        departed = []
        hasBaseline = true
    }

    /// Paths of new files whose size and date haven't changed for `settleSeconds`, each reported once.
    public mutating func update(_ files: [FileSnapshot], now: Date, settleSeconds: TimeInterval = 20) -> [String] {
        guard hasBaseline else {
            baseline(files, now: now)
            return []
        }
        var present: Set<String> = []
        var ready: [String] = []
        for file in files {
            present.insert(file.path)
            if var entry = tracked[file.path] {
                if entry.size != file.size || entry.modified != file.modified {
                    entry.size = file.size
                    entry.modified = file.modified
                    entry.stableSince = now
                }
                if !entry.handled, now.timeIntervalSince(entry.stableSince) >= settleSeconds {
                    entry.handled = true
                    ready.append(file.path)
                }
                tracked[file.path] = entry
            } else {
                tracked[file.path] = Tracked(size: file.size, modified: file.modified, stableSince: now, handled: false, fromBaseline: false)
            }
        }
        departed = []
        for (path, entry) in tracked where !present.contains(path) {
            if !entry.fromBaseline { departed.append(FileSnapshot(path: path, size: entry.size, modified: entry.modified)) }
            tracked[path] = nil
        }
        departed.sort { $0.path < $1.path }
        return ready.sorted()
    }

    /// Marks a path as handled (for example a file EchoNyla itself renamed in place).
    public mutating func markHandled(_ path: String) {
        tracked[path]?.handled = true
    }
}

/// One thing EchoNyla did or suggested, shown in Activity with Undo.
public struct ActivityEntry: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case autoMoved, moved, renamed, suggested
        /// You moved a new file into a favorite folder in Finder, and EchoNyla learned from it.
        case learned
    }

    public var id: UUID
    public var date: Date
    public var kind: Kind
    public var fileName: String
    public var detail: String
    public var destinationID: String?
    public var destinationName: String?
    public var receipt: FileMoveReceipt?
    /// Where the file is now (for suggestions: where it was found).
    public var filePath: String
    public var proposedName: String?
    public var summary: String?
    public var isUndone: Bool
    /// The batch this change belongs to (a Clean Up, a folder check, new files sorted together), for Undo All.
    /// Nil for single changes and for everything saved before 3.1.
    public var runID: UUID?
    /// What the batch was, like "Checked Bills"; set on the batch's entries.
    public var runTitle: String?

    public init(id: UUID = UUID(), date: Date = Date(), kind: Kind, fileName: String, detail: String, destinationID: String? = nil,
                destinationName: String? = nil, receipt: FileMoveReceipt? = nil, filePath: String, proposedName: String? = nil,
                summary: String? = nil, isUndone: Bool = false, runID: UUID? = nil, runTitle: String? = nil) {
        self.id = id
        self.date = date
        self.kind = kind
        self.fileName = fileName
        self.detail = detail
        self.destinationID = destinationID
        self.destinationName = destinationName
        self.receipt = receipt
        self.filePath = filePath
        self.proposedName = proposedName
        self.summary = summary
        self.isUndone = isUndone
        self.runID = runID
        self.runTitle = runTitle
    }

    /// Newest first, at most `limit` entries; a new suggestion replaces an older one for the same file.
    public static func adding(_ entry: ActivityEntry, to list: [ActivityEntry], limit: Int = 200) -> [ActivityEntry] {
        var result = list.filter { !(entry.kind == .suggested && $0.kind == .suggested && $0.filePath == entry.filePath) }
        result.insert(entry, at: 0)
        return Array(result.prefix(limit))
    }
}
