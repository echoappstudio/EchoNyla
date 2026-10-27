import Foundation

public struct Destination: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    /// Your note on what goes in this folder. Apple Intelligence may only choose folders that have one.
    public var purpose: String?

    public init(id: String, name: String, purpose: String? = nil) {
        self.id = id
        self.name = name
        self.purpose = Self.cleanPurpose(purpose)
    }

    /// One line, at most 200 characters; nil when empty.
    public static func cleanPurpose(_ text: String?) -> String? {
        guard let text else { return nil }
        let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !clean.isEmpty else { return nil }
        return clean.count > 200 ? String(clean.prefix(200)) : clean
    }
}

public struct DestinationRule: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var extensions: Set<String>
    public var keywords: [String]
    public var destinationID: String
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        extensions: Set<String> = [],
        keywords: [String] = [],
        destinationID: String,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.extensions = Set(extensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }.filter { !$0.isEmpty })
        self.keywords = keywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        self.destinationID = destinationID
        self.isEnabled = isEnabled
    }
}

public struct LearningRecord: Codable, Equatable, Identifiable {
    public var id: UUID
    public var fileExtension: String
    public var tokens: Set<String>
    public var destinationID: String
    public var updatedAt: Date
    public var sampleName: String?

    public init(
        id: UUID = UUID(),
        fileExtension: String,
        tokens: Set<String>,
        destinationID: String,
        updatedAt: Date = Date(),
        sampleName: String? = nil
    ) {
        self.id = id
        self.fileExtension = fileExtension.lowercased()
        self.tokens = Set(tokens.map { $0.lowercased() })
        self.destinationID = destinationID
        self.updatedAt = updatedAt
        self.sampleName = sampleName
    }
}

public struct DestinationSuggestion: Equatable {
    public let destinationID: String
    public let reason: String

    public init(destinationID: String, reason: String) {
        self.destinationID = destinationID
        self.reason = reason
    }
}

/// How a local suggestion was found, strongest first. Rules, screenshot detection and learned
/// patterns are "sure"; wording matches alone are only a hint.
public enum SuggestionStrength: String, Codable, Sendable {
    case rule, screenshot, learned, wording

    public var isSure: Bool { self != .wording }
}

public struct RankedSuggestion: Equatable {
    public let suggestion: DestinationSuggestion
    public let strength: SuggestionStrength

    public init(suggestion: DestinationSuggestion, strength: SuggestionStrength) {
        self.suggestion = suggestion
        self.strength = strength
    }
}

public enum SuggestionEngine {
    private static let screenshotImageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff"]
    private static let learningNoise: Set<String> = [
        "the", "and", "for", "from", "with", "your", "copy", "final", "document", "documents",
        "invoice", "invoices", "bill", "bills", "receipt", "receipts", "payment", "statement",
        "screenshot", "screenshots", "screen", "shot", "capture", "image", "photo", "scan",
        "images", "photos", "scans", "picture", "pictures", "media", "video", "videos", "audio",
        "project", "projects", "report", "reports", "annual", "brief", "proposal", "proposals",
        "plan", "plans", "notes", "note", "summary", "summaries", "draft", "drafts", "update", "updates",
        "meeting", "meetings", "export", "exports", "download", "downloads", "file", "files",
        "edited", "edit", "before", "after", "version", "untitled", "recording", "recordings", "clip", "clips", "temp",
        "company", "companies", "corporation", "corp", "inc", "llc", "ltd", "limited", "group",
        "pdf", "png", "jpg", "jpeg", "heic", "tif", "tiff", "doc", "docx", "xls", "xlsx", "csv", "zip",
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "oct", "nov", "dec"
    ]

    public static func suggest(
        fileName: String,
        destinations: [Destination],
        rules: [DestinationRule],
        learning: [LearningRecord],
        isScreenCapture: Bool = false
    ) -> DestinationSuggestion? {
        suggestRanked(fileName: fileName, destinations: destinations, rules: rules, learning: learning,
                      isScreenCapture: isScreenCapture)?.suggestion
    }

    /// Folders that an enabled rule targets. Nothing else (learning, wording, Apple Intelligence)
    /// may send a file there unless that rule itself matches.
    public static func ruleLockedDestinationIDs(rules: [DestinationRule], destinations: [Destination]) -> Set<String> {
        let availableIDs = Set(destinations.map(\.id))
        return Set(rules.filter { $0.isEnabled && availableIDs.contains($0.destinationID) }.map(\.destinationID))
    }

    public static func suggestRanked(
        fileName: String,
        destinations: [Destination],
        rules: [DestinationRule],
        learning: [LearningRecord],
        isScreenCapture: Bool = false
    ) -> RankedSuggestion? {
        guard !destinations.isEmpty else { return nil }
        let extensionName = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        let availableIDs = Set(destinations.map(\.id))
        let exactTokens = words(in: fileName)
        let tokens = filenameTokens(fileName)
        let isMetadataScreenshot = isScreenCapture && screenshotImageExtensions.contains(extensionName)
        let isFilenameScreenshot = extensionName == "png" && isScreenshotFilename(fileName)
        let isScreenshot = isMetadataScreenshot || isFilenameScreenshot
        let activeRules = rules.filter { $0.isEnabled && availableIDs.contains($0.destinationID) }

        let matchingRule = activeRules.first { rule in
            let extensionMatches = rule.extensions.isEmpty || rule.extensions.contains(extensionName)
            let keywordMatches = rule.keywords.isEmpty || rule.keywords.contains { keyword in
                let keywordTokens = words(in: keyword)
                guard !keywordTokens.isEmpty else { return false }
                if keywordTokens.isSubset(of: exactTokens) { return true }
                return isMetadataScreenshot && keywordTokens == ["screenshot"]
            }
            return extensionMatches && keywordMatches
        }
        if let matchingRule {
            return RankedSuggestion(
                suggestion: DestinationSuggestion(destinationID: matchingRule.destinationID, reason: "Matches your \(matchingRule.name) rule"),
                strength: .rule)
        }

        // A rule-targeted folder is off-limits to other heuristics when its own rule did not match.
        let lockedDestinationIDs = Set(activeRules.map(\.destinationID))

        let examplesByDestination = Dictionary(grouping: learning.filter { record in
            availableIDs.contains(record.destinationID)
                && !lockedDestinationIDs.contains(record.destinationID)
                && record.sampleName != nil
                && !extensionName.isEmpty
                && record.fileExtension == extensionName
                && !tokens.isDisjoint(with: meaningfulTokens(record.tokens))
        }, by: \.destinationID)
        // The same word has to be in 3 different files you moved there ("Acme" in three Acme files),
        // not 3 files that each share some other word with this one.
        let repeatedPatterns = examplesByDestination.compactMap { destinationID, examples -> (String, Int)? in
            let best = tokens.map { token in
                Set(examples.filter { meaningfulTokens($0.tokens).contains(token) }.compactMap { $0.sampleName?.lowercased() }).count
            }.max() ?? 0
            guard best >= 3 else { return nil }
            return (destinationID, best)
        }
        if let learnedMatch = repeatedPatterns.max(by: { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0 > rhs.0 : lhs.1 < rhs.1
        }) {
            return RankedSuggestion(
                suggestion: DestinationSuggestion(
                    destinationID: learnedMatch.0,
                    reason: "Similar to files you moved before (\(learnedMatch.1) examples)"
                ),
                strength: .learned)
        }

        return builtInSuggestion(
            extensionName: extensionName,
            tokens: exactTokens,
            destinations: destinations.filter { !lockedDestinationIDs.contains($0.id) },
            isScreenshot: isScreenshot,
            isFilenameScreenshot: isFilenameScreenshot
        )
    }

    public static func filenameTokens(_ text: String) -> Set<String> {
        meaningfulTokens(words(in: URL(fileURLWithPath: text).deletingPathExtension().lastPathComponent))
    }

    private static func words(in text: String) -> Set<String> {
        Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
    }

    private static func meaningfulTokens(_ tokens: Set<String>) -> Set<String> {
        Set(tokens.filter { token in
            token.count >= 4 && !learningNoise.contains(token) && Int(token) == nil
        })
    }

    private static func isScreenshotFilename(_ fileName: String) -> Bool {
        let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent.lowercased()
        return stem == "screenshot" || stem.hasPrefix("screenshot ") || stem.hasPrefix("screenshot-")
            || stem == "screen shot" || stem.hasPrefix("screen shot ") || stem.hasPrefix("screen shot-")
    }

    private static func builtInSuggestion(
        extensionName: String,
        tokens: Set<String>,
        destinations: [Destination],
        isScreenshot: Bool,
        isFilenameScreenshot: Bool
    ) -> RankedSuggestion? {
        if isScreenshot,
           let destination = destinations.first(where: { words(in: $0.name).contains("screenshots") || words(in: $0.name).contains("screenshot") }) {
            let reason = isFilenameScreenshot ? "Filename matches macOS screenshot naming" : "macOS marks this as a screen capture"
            return RankedSuggestion(suggestion: DestinationSuggestion(destinationID: destination.id, reason: reason), strength: .screenshot)
        }

        let subjectMatchers: [(Set<String>, Set<String>, Set<String>, String)] = [
            (["pdf", "doc", "docx"], ["bill", "bills", "invoice", "invoices", "receipt", "receipts"], ["bill", "bills", "invoice", "invoices", "receipts", "receipts"], "Matches invoice or bill wording"),
            (["pdf", "doc", "docx"], ["tax", "taxes", "irs"], ["tax", "taxes", "irs"], "Matches tax-document wording"),
            (["pdf", "doc", "docx"], ["car", "vehicle", "automotive", "maintenance", "registration"], ["car", "cars", "vehicle", "vehicles", "automotive"], "Matches vehicle-document wording")
        ]

        for (extensions, filenameTerms, folderTerms, reason) in subjectMatchers
        where extensions.contains(extensionName) && !tokens.isDisjoint(with: filenameTerms) {
            if let destination = destinations.first(where: { !words(in: $0.name).isDisjoint(with: folderTerms) }) {
                return RankedSuggestion(suggestion: DestinationSuggestion(destinationID: destination.id, reason: reason), strength: .wording)
            }
        }
        return nil
    }
}

public struct TrashSuggestion: Equatable {
    public let fileURL: URL
    public let reason: String

    public init(fileURL: URL, reason: String) {
        self.fileURL = fileURL
        self.reason = reason
    }
}

/// This is intentionally narrow: only an installed app's matching .dmg directly in Downloads qualifies.
public struct TrashPolicy {
    public init() {}

    public func suggestion(
        for fileURL: URL,
        downloadsFolder: URL,
        applicationsFolder: URL,
        installedApps: [URL]
    ) -> TrashSuggestion? {
        guard fileURL.pathExtension.lowercased() == "dmg" else { return nil }
        guard fileURL.deletingLastPathComponent().standardizedFileURL == downloadsFolder.standardizedFileURL else { return nil }

        let installerName = fileURL.deletingPathExtension().lastPathComponent.lowercased()
        guard let app = installedApps.first(where: { appURL in
            guard appURL.pathExtension.lowercased() == "app",
                  appURL.deletingLastPathComponent().standardizedFileURL == applicationsFolder.standardizedFileURL else { return false }
            let appName = appURL.deletingPathExtension().lastPathComponent.lowercased()
            guard installerName.hasPrefix(appName) else { return false }
            let remainder = installerName.dropFirst(appName.count)
            guard let first = remainder.first else { return true }
            return first.isWhitespace || first == "-" || first == "_" || first == "." || first == "(" || first.isNumber
        }) else { return nil }

        let installedName = app.deletingPathExtension().lastPathComponent
        return TrashSuggestion(fileURL: fileURL, reason: "\(installedName) is already installed in Applications")
    }
}

public struct FolderGroup: Equatable, Identifiable {
    public let id: String
    public var name: String
    public let reason: String
    public let files: [URL]

    public init(id: String, name: String, reason: String, files: [URL]) {
        self.id = id
        self.name = name
        self.reason = reason
        self.files = files
    }
}

public struct FolderGroupingSettings {
    public static let defaultMinimumRelatedFiles = 4
    public static let minimumAllowed = 2
    public static let maximumAllowed = 100

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "EchoNyla.minimumRelatedFiles.v1") {
        self.defaults = defaults
        self.key = key
    }

    public var minimumRelatedFiles: Int {
        get {
            guard defaults.object(forKey: key) != nil else { return Self.defaultMinimumRelatedFiles }
            return Self.clamped(defaults.integer(forKey: key))
        }
        nonmutating set {
            defaults.set(Self.clamped(newValue), forKey: key)
        }
    }

    private static func clamped(_ value: Int) -> Int {
        min(max(value, minimumAllowed), maximumAllowed)
    }
}

public enum FolderGrouping {
    public static func suggest(for files: [URL], minimumGroupSize: Int = FolderGroupingSettings.defaultMinimumRelatedFiles) -> [FolderGroup] {
        var filesBySubject: [String: [URL]] = [:]
        for file in files {
            for subject in SuggestionEngine.filenameTokens(file.lastPathComponent) {
                filesBySubject[subject, default: []].append(file)
            }
        }

        var usedFiles = Set<URL>()
        let minimum = max(2, minimumGroupSize)
        var candidates: [(subject: String, files: [URL])] = []
        for (subject, subjectFiles) in filesBySubject {
            candidates.append((subject: subject, files: Array(Set(subjectFiles))))
        }
        candidates.sort { lhs, rhs in
            if lhs.files.count == rhs.files.count { return lhs.subject < rhs.subject }
            return lhs.files.count > rhs.files.count
        }

        var groups: [FolderGroup] = []
        // A shared broad word (school, research, finance…) isn't a reason for a new folder.
        for candidate in candidates where GroupCheck.isSpecific(candidate.subject) {
            let remaining = candidate.files.filter { !usedFiles.contains($0) }
            guard remaining.count >= minimum else { continue }
            for file in remaining { usedFiles.insert(file) }

            let firstCharacter = String(candidate.subject.prefix(1)).uppercased()
            let remainingCharacters = String(candidate.subject.dropFirst())
            let displayName = firstCharacter + remainingCharacters
            let reason = "These \(remaining.count) files share the subject “\(displayName)” in their filenames."
            let sortedFiles = remaining.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
            groups.append(FolderGroup(id: candidate.subject, name: displayName, reason: reason, files: sortedFiles))
        }
        return groups
    }
}
