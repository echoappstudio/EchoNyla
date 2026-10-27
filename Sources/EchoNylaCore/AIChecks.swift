import Foundation

/// Apple Intelligence's checked answer about one file.
public struct FileDecision: Equatable, Sendable {
    /// One of your folders, or nil when it had no good match.
    public var destinationID: String?
    public var isConfident: Bool
    public var reason: String
    /// A clearer file name (already checked), or nil.
    public var proposedName: String?
    /// One or two sentences on what the file is.
    public var summary: String

    public init(destinationID: String?, isConfident: Bool, reason: String, proposedName: String?, summary: String) {
        self.destinationID = destinationID
        self.isConfident = isConfident
        self.reason = reason
        self.proposedName = proposedName
        self.summary = summary
    }
}

/// Which of your folders Apple Intelligence may choose.
public enum AIFolders {
    /// Folders you described ("What goes here") that no rule reserves. Folders without a note are
    /// only for drag and drop, your rules and your own moves.
    public static func choosable(_ destinations: [Destination], locked: Set<String>) -> [Destination] {
        destinations.filter { !locked.contains($0.id) && Destination.cleanPurpose($0.purpose) != nil }
    }
}

/// Turns raw model answers into safe values. Anything that doesn't fit is dropped, so a confused
/// answer can never send a file somewhere unexpected or give it a strange name.
public enum DecisionCheck {
    /// The folder the model named, if it's exactly one of the folders it may choose.
    public static func destination(for answer: String, destinations: [Destination], locked: Set<String>) -> Destination? {
        let clean = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`“”‘’."))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.lowercased() != "none", clean.lowercased() != "unknown" else { return nil }
        let matches = AIFolders.choosable(destinations, locked: locked)
            .filter { $0.name.compare(clean, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        guard matches.count == 1, let match = matches.first else { return nil }
        return match
    }

    public static func check(folder: String, confidence: String, reason: String, betterName: String, summary: String,
                             fileName: String, destinations: [Destination], locked: Set<String>) -> FileDecision {
        // A folder is kept only when the model is sure; a guess is no suggestion at all.
        let sure = confidence.lowercased().contains("high")
        let match = sure ? Self.destination(for: folder, destinations: destinations, locked: locked) : nil
        return FileDecision(destinationID: match?.id, isConfident: match != nil,
                            reason: oneLine(reason, limit: 160, fallback: "Apple Intelligence's best match."),
                            proposedName: RenameCheck.acceptedName(original: fileName, proposed: betterName),
                            summary: oneLine(summary, limit: 300, fallback: ""))
    }

    public static func oneLine(_ text: String, limit: Int, fallback: String) -> String {
        let clean = TextTools.collapseWhitespace(text)
        guard !clean.isEmpty else { return fallback }
        return clean.count > limit ? String(clean.prefix(limit - 1)) + "…" : clean
    }
}

public enum RenameCheck {
    private static let forbidden = CharacterSet(charactersIn: "/\\:")
    private static let generic: Set<String> = ["document", "file", "untitled", "image", "photo", "screenshot", "scan", "download", "new file", "copy"]

    /// A safe new name that keeps the original extension, or nil when the proposal is unusable or
    /// the same as the current name.
    public static func acceptedName(original: String, proposed: String) -> String? {
        let originalExtension = URL(fileURLWithPath: original).pathExtension
        var stem = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`“”‘’"))
        guard !stem.contains("\n"), !stem.contains("\r") else { return nil }
        if !originalExtension.isEmpty, stem.lowercased().hasSuffix("." + originalExtension.lowercased()) {
            stem = String(stem.dropLast(originalExtension.count + 1))
        }
        var kept = String.UnicodeScalarView()
        for scalar in stem.unicodeScalars where !CharacterSet.controlCharacters.contains(scalar) && !forbidden.contains(scalar) {
            kept.append(scalar)
        }
        stem = String(kept)
        stem = TextTools.collapseWhitespace(stem).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        guard (2...80).contains(stem.count), stem.filter(\.isLetter).count >= 2,
              !generic.contains(stem.lowercased()) else { return nil }
        let name = originalExtension.isEmpty ? stem : stem + "." + originalExtension
        return name == original ? nil : name
    }
}

/// A new folder Apple Intelligence proposed for a cleanup, after checking.
public struct FolderGroupProposal: Equatable, Sendable {
    public var name: String
    /// Positions in the file list given to the model (0-based).
    public var indexes: [Int]

    public init(name: String, indexes: [Int]) {
        self.name = name
        self.indexes = indexes
    }
}

public enum GroupCheck {
    /// Words that only name a broad category. A group name made only of these (and numbers) is too
    /// general: groups must be one specific project, trip, class, event or case.
    static let broadWords: Set<String> = [
        "school", "schoolwork", "class", "classes", "course", "courses", "college", "university", "homework", "study", "studies",
        "research", "paper", "papers", "essay", "essays", "academic", "academics", "education",
        "finance", "finances", "financial", "money", "bank", "banking", "budget", "statement", "statements", "bill", "bills",
        "invoice", "invoices", "receipt", "receipts", "tax", "taxes", "payment", "payments", "expense", "expenses",
        "work", "job", "jobs", "business", "office", "personal", "private", "home", "family", "health", "medical", "legal",
        "travel", "shopping", "misc", "miscellaneous", "other", "others", "random", "stuff", "things", "general", "various",
        "mixed", "important", "old", "new", "archive", "archives", "backup", "backups", "document", "documents", "docs", "doc",
        "file", "files", "folder", "folders", "record", "records", "note", "notes", "data", "report", "reports", "form", "forms",
        "project", "projects", "image", "images", "photo", "photos", "picture", "pictures", "pics", "screenshot", "screenshots",
        "video", "videos", "audio", "music", "media", "pdf", "pdfs", "spreadsheet", "spreadsheets", "csv", "csvs", "text",
        "download", "downloads", "and", "the", "of", "for", "my", "to", "in", "from", "a", "an"
    ]

    /// True when the name says something specific, like Denver trip or Biology 101 lab, rather than
    /// a category like School stuff or Financial documents.
    public static func isSpecific(_ name: String) -> Bool {
        let words = name.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count >= 2 }
        return words.contains { !broadWords.contains($0) }
    }

    public static func validFolderName(_ value: String) -> String? {
        let name = TextTools.collapseWhitespace(value).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        guard (2...40).contains(name.count), name != ".", name != "..", name.filter(\.isLetter).count >= 2,
              !name.contains("/"), !name.contains("\\"), !name.contains(":") else { return nil }
        return name
    }

    /// Keeps only groups with a valid, specific name and at least `minimumSize` files. File numbers
    /// from the model start at 1; each file can be in one group only (the first one that claims it),
    /// unknown numbers are ignored, and two groups can't share a name. At most 8 groups.
    /// With `memberTexts` (each file's name and text, by position), the group's name must also appear
    /// in most of its files: a made-up name like "allsame" for files that only look alike is dropped.
    public static func validate(_ groups: [(name: String, members: [Int])], fileCount: Int, minimumSize: Int,
                                memberTexts: [String]? = nil) -> [FolderGroupProposal] {
        var used: Set<Int> = []
        var names: Set<String> = []
        var result: [FolderGroupProposal] = []
        for group in groups {
            guard result.count < 8, let name = validFolderName(group.name), isSpecific(name), !names.contains(name.lowercased()) else { continue }
            var indexes: [Int] = []
            for member in group.members where member >= 1 && member <= fileCount {
                let index = member - 1
                if !used.contains(index), !indexes.contains(index) { indexes.append(index) }
            }
            guard indexes.count >= max(2, minimumSize) else { continue }
            if let memberTexts, !nameIsInFiles(name, texts: indexes.map { $0 < memberTexts.count ? memberTexts[$0] : "" }) { continue }
            used.formUnion(indexes)
            names.insert(name.lowercased())
            result.append(FolderGroupProposal(name: name, indexes: indexes.sorted()))
        }
        return result
    }

    /// True when a specific word of the group's name ("Denver" in "Denver trip") is in at least half
    /// of the files' names or text.
    static func nameIsInFiles(_ name: String, texts: [String]) -> Bool {
        let words = name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !broadWords.contains($0) && !$0.allSatisfy(\.isNumber) }
        guard !words.isEmpty, !texts.isEmpty else { return false }
        let matching = texts.filter { text in
            let lower = text.lowercased()
            return words.contains { lower.contains($0) }
        }
        return matching.count * 2 >= texts.count
    }
}

/// The prompt for one file: its facts, the folders you described, and how you filed similar files before.
public enum DecisionPrompt {
    /// Your latest moves as examples. Names that say nothing ("Screenshot 2026-10-25 at 12.33.39 AM")
    /// are left out: they only teach "screenshots went there", which pulled every screenshot into one
    /// folder. `leavingOut` drops the file being tested and its copies ("… (2).png").
    public static func examples(learning: [LearningRecord], destinations: [Destination], locked: Set<String>, limit: Int = 8,
                                leavingOut fileName: String? = nil) -> [String] {
        let allowed = AIFolders.choosable(destinations, locked: locked)
        var seen: Set<String> = []
        var lines: [String] = []
        for record in learning.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            guard lines.count < limit, let sample = record.sampleName, !NameQuality.saysNothing(sample),
                  !(fileName.map { NameQuality.isSameName($0, sample) } ?? false),
                  let folder = allowed.first(where: { $0.id == record.destinationID }) else { continue }
            let key = sample.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            lines.append("“\(TextTools.redactLongNumbers(sample))” → \(folder.name)")
        }
        return lines
    }

    public static func make(facts: FileFacts, destinations: [Destination], locked: Set<String>, examples: [String]) -> String {
        let allowed = AIFolders.choosable(destinations, locked: locked)
        var lines = ["Decide whether this file belongs in one of the person's folders.", facts.promptText()]
        if allowed.isEmpty {
            lines.append("There are no folders to choose from. Answer none for the folder.")
        } else {
            lines.append("Folders you may choose (exact name: what goes there):")
            lines += allowed.map { "- \($0.name): \(Destination.cleanPurpose($0.purpose) ?? "")" }
            if !examples.isEmpty {
                lines.append("How this person filed files before:")
                lines += examples.map { "- " + $0 }
            }
            lines.append("Choose a folder only if this file is plainly what that folder's description says. Being about a similar "
                         + "subject is not enough. Most files fit no folder: then answer none.")
        }
        return lines.joined(separator: "\n")
    }
}
