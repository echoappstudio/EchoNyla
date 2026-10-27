import Foundation

/// The three parts of Clean Up's file list.
public enum CleanupBucket: String, CaseIterable, Sendable {
    /// A rule, a macOS screenshot, your own repeated moves or a confident Apple Intelligence answer. Checked.
    case sure
    /// Only a wording match. Unchecked until you check it.
    case guess
    /// No folder suggested.
    case none

    public static func of(hasDestination: Bool, isSure: Bool) -> CleanupBucket {
        guard hasDestination else { return .none }
        return isSure ? .sure : .guess
    }

    public var title: String {
        switch self {
        case .sure: return "Sure"
        case .guess: return "Guesses"
        case .none: return "No idea"
        }
    }
}

/// Which folder Clean Up works on: the main button's name and the folders in Choose Folder's menu.
public enum CleanupFolders {
    /// Extra folders the menu lists under Downloads, Desktop and Documents.
    public static let menuLimit = 5
    /// How many folders are remembered (enough for `menuLimit` extras plus the three fixed ones).
    public static let storedLimit = menuLimit + 3
    /// Longer folder names are shortened on the button.
    public static let nameLimit = 28

    /// "Clean Downloads", "Clean Documents". A long name ends in "…" so the button stays short.
    public static func buttonTitle(folderName: String) -> String {
        guard folderName.count > nameLimit else { return "Clean \(folderName)" }
        let short = String(folderName.prefix(nameLimit - 1)).trimmingCharacters(in: .whitespaces)
        return "Clean \(short)…"
    }

    /// The remembered folders after cleaning `path`, newest first: it moves to the front, once.
    public static func remembering(_ path: String, in recents: [String]) -> [String] {
        let path = normalized(path)
        let rest = recents.map(normalized).filter { $0 != path }
        var seen: Set<String> = [path]
        return Array(([path] + rest.filter { seen.insert($0).inserted }).prefix(storedLimit))
    }

    /// The remembered folders the menu lists, newest first, leaving out the fixed ones it always shows.
    public static func menuFolders(recents: [String], fixed: [String]) -> [String] {
        let fixed = Set(fixed.map(normalized))
        var seen: Set<String> = []
        let extras = recents.map(normalized).filter { !fixed.contains($0) && seen.insert($0).inserted }
        return Array(extras.prefix(menuLimit))
    }

    /// The same folder always compares equal, with or without a trailing slash.
    static func normalized(_ path: String) -> String {
        var path = path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// Recognises a file you moved yourself, in Finder, from a watched folder into one of your favorite
/// folders: the same name and size turning up there. That move counts as your choice, so EchoNyla
/// learns from it as it does from a click on "Move to".
public enum FinderMoveMatcher {
    public struct Candidate: Equatable, Sendable {
        public let destinationID: String
        public let file: FileSnapshot

        public init(destinationID: String, file: FileSnapshot) {
            self.destinationID = destinationID
            self.file = file
        }
    }

    /// The favorite folder the file went to, or nil when no folder or more than one folder has a match.
    public static func destination(for departed: FileSnapshot, among candidates: [Candidate]) -> String? {
        let name = URL(fileURLWithPath: departed.path).lastPathComponent
        let matches = Set(candidates.filter { candidate in
            URL(fileURLWithPath: candidate.file.path).lastPathComponent == name && candidate.file.size == departed.size
        }.map(\.destinationID))
        return matches.count == 1 ? matches.first : nil
    }
}

/// A quiet weekly nudge in the panel when Downloads has loose files that have sat there a while.
public enum TidyReminder {
    /// Files count when they have been in Downloads at least this long.
    public static let minimumAge: TimeInterval = 14 * 24 * 3600
    /// Fewer than this and there is nothing worth a reminder.
    public static let minimumCount = 5
    /// After a dismissal the reminder stays away this long.
    public static let quietPeriod: TimeInterval = 7 * 24 * 3600

    /// How many files to mention, or nil when the reminder shouldn't show.
    public static func count(addedDates: [Date], now: Date, lastDismissed: Date?, enabled: Bool) -> Int? {
        guard enabled else { return nil }
        if let lastDismissed, now.timeIntervalSince(lastDismissed) < quietPeriod { return nil }
        let old = addedDates.filter { now.timeIntervalSince($0) >= minimumAge }.count
        return old >= minimumCount ? old : nil
    }

    /// "23 loose files in Downloads are over two weeks old."
    public static func message(count: Int) -> String {
        "\(count) loose files in Downloads are over two weeks old."
    }
}

/// The setup helper: folders you already keep files in, offered as favorites.
public enum SetupSuggestions {
    public struct Folder: Equatable, Sendable {
        public let path: String
        public let name: String
        /// Files directly inside it.
        public let fileCount: Int
        /// The newest of those files' dates.
        public let newestFile: Date?

        public init(path: String, name: String, fileCount: Int, newestFile: Date?) {
            self.path = path
            self.name = name
            self.fileCount = fileCount
            self.newestFile = newestFile
        }
    }

    /// Names that hold everything rather than one kind of file, so they make poor targets.
    static let tooBroad: Set<String> = ["documents", "downloads", "desktop", "misc", "miscellaneous", "stuff", "other", "temp", "tmp",
                                        "untitled folder", "new folder", "archive", "old", "inbox"]

    /// Up to `limit` folders with at least `minimumFiles` files, used most recently first. Folders
    /// that are already favorites, hidden or too broad are left out.
    public static func rank(_ folders: [Folder], existing: Set<String>, minimumFiles: Int = 3, limit: Int = 8) -> [Folder] {
        let usable = folders.filter { folder in
            !existing.contains(folder.path)
                && !folder.name.hasPrefix(".")
                && !tooBroad.contains(folder.name.lowercased())
                && folder.fileCount >= minimumFiles
        }
        let sorted = usable.sorted { lhs, rhs in
            let left = lhs.newestFile ?? .distantPast
            let right = rhs.newestFile ?? .distantPast
            if left != right { return left > right }
            if lhs.fileCount != rhs.fileCount { return lhs.fileCount > rhs.fileCount }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return Array(sorted.prefix(limit))
    }

    /// The prompt for a drafted "What goes here" note: the folder's name and some of its file names.
    public static func notePrompt(folderName: String, fileNames: [String]) -> String {
        let names = fileNames.prefix(15).map { "- " + TextTools.redactLongNumbers($0) }.joined(separator: "\n")
        return "Folder: \(TextTools.redactLongNumbers(folderName))\nFiles in it:\n\(names)"
    }

    /// A drafted note made safe to show: one line, no quotes, at most 120 characters, ending without
    /// a full stop. Nil when nothing useful is left.
    public static func cleanNote(_ text: String) -> String? {
        var line = TextTools.collapseWhitespace(text)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’ ").union(.whitespacesAndNewlines))
        if line.lowercased().hasPrefix("note:") { line = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        while line.hasSuffix(".") { line.removeLast() }
        guard line.count >= 3, line.lowercased() != "none", line.lowercased() != "unknown" else { return nil }
        return line.count > 120 ? String(line.prefix(120)).trimmingCharacters(in: .whitespaces) : line
    }
}

/// What a favorite folder's tile in the panel says underneath its name.
public enum FolderTileCaption {
    /// "1 waiting" takes priority, then "3 today", then the last day something went there.
    public static func text(destinationID: String, activity: [ActivityEntry], now: Date = Date(), calendar: Calendar = .current) -> String {
        let waiting = activity.filter { $0.kind == .suggested && !$0.isUndone && $0.destinationID == destinationID }.count
        if waiting > 0 { return "\(waiting) waiting" }
        let filed = activity.filter {
            ($0.kind == .moved || $0.kind == .autoMoved || $0.kind == .learned) && !$0.isUndone && $0.destinationID == destinationID
        }
        let today = filed.filter { calendar.isDate($0.date, inSameDayAs: now) }.count
        if today > 0 { return "\(today) today" }
        guard let latest = filed.map(\.date).max() else { return "Drop here" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: latest), to: calendar.startOfDay(for: now)).day ?? 0
        return days <= 1 ? "Yesterday" : "\(days) days ago"
    }
}
