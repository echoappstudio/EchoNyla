import Foundation

public struct Destination: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    /// The note on what goes in this folder (yours, or written by Apple Intelligence from the files in it).
    public var purpose: String?
    /// "Sort into this": the models may file things here. Off means "Just for dragging".
    public var sortsInto: Bool
    /// Stems of the words learned from the files already in the folder.
    public var learnedWords: [String]

    /// `sortsInto` defaults to whether the folder has a note, as it worked before 3.2.0.
    public init(id: String, name: String, purpose: String? = nil, sortsInto: Bool? = nil, learnedWords: [String] = []) {
        self.id = id
        self.name = name
        self.purpose = Self.cleanPurpose(purpose)
        self.sortsInto = sortsInto ?? (Self.cleanPurpose(purpose) != nil)
        self.learnedWords = learnedWords
    }

    enum CodingKeys: String, CodingKey { case id, name, purpose, sortsInto, learnedWords }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let purpose = try container.decodeIfPresent(String.self, forKey: .purpose)
        self.init(id: try container.decode(String.self, forKey: .id), name: try container.decode(String.self, forKey: .name),
                  purpose: purpose, sortsInto: try container.decodeIfPresent(Bool.self, forKey: .sortsInto),
                  learnedWords: try container.decodeIfPresent([String].self, forKey: .learnedWords) ?? [])
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
    /// The website the file was downloaded from ("acme.com"), when macOS recorded one. Saved data
    /// from before 3.6.0 has none.
    public var host: String?

    public init(
        id: UUID = UUID(),
        fileExtension: String,
        tokens: Set<String>,
        destinationID: String,
        updatedAt: Date = Date(),
        sampleName: String? = nil,
        host: String? = nil
    ) {
        self.id = id
        self.fileExtension = fileExtension.lowercased()
        self.tokens = Set(tokens.map { $0.lowercased() })
        self.destinationID = destinationID
        self.updatedAt = updatedAt
        self.sampleName = sampleName
        self.host = host.flatMap(LearnedHost.usable)
    }
}

/// Websites good enough to learn from. Mail, cloud drives and file-sharing sites send all kinds of
/// files, so a download from them says nothing about where it belongs.
public enum LearnedHost {
    static let general = ["google.com", "googleusercontent.com", "dropbox.com", "dropboxusercontent.com", "icloud.com",
                          "icloud-content.com", "wetransfer.com", "we.tl", "live.com", "1drv.ms", "sharepoint.com", "box.com",
                          "github.com", "githubusercontent.com", "amazonaws.com", "cloudfront.net", "slack.com", "slack-edge.com",
                          "discordapp.com", "discordapp.net", "discord.com", "outlook.com", "office.com", "yahoo.com", "proton.me",
                          "mega.nz", "mediafire.com", "apple.com", "akamaihd.net", "fastly.net", "cloudflare.com", "localhost"]

    /// The host if it can be learned from, else nil.
    public static func usable(_ host: String) -> String? {
        let clean = host.lowercased().trimmingCharacters(in: .whitespaces)
        guard clean.contains("."), !clean.isEmpty else { return nil }
        if general.contains(where: { clean == $0 || clean.hasSuffix("." + $0) }) { return nil }
        // An address like 192.168.1.4 isn't a website.
        if clean.allSatisfy({ $0.isNumber || $0 == "." }) { return nil }
        return clean
    }
}

/// "No" to a move EchoNyla made by itself: you undid it. A later file like it (same type and folder,
/// and a shared name word or the same website) isn't moved there by itself again; it waits for you.
public struct LearningNo: Codable, Equatable, Sendable {
    public var destinationID: String
    public var fileExtension: String
    public var tokens: Set<String>
    public var host: String?
    public var date: Date

    public init(destinationID: String, fileName: String, host: String?, date: Date = Date()) {
        self.destinationID = destinationID
        fileExtension = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        tokens = SuggestionEngine.filenameTokens(fileName)
        self.host = host.flatMap(LearnedHost.usable)
        self.date = date
    }

    /// Added to a reason when a "no" holds a move back.
    public static let waitNote = " You undid a move like this before, so it waits for you."

    /// True when one of `nos` says not to move this file to `destinationID` by itself.
    public static func holdsBack(fileName: String, host: String?, destinationID: String, nos: [LearningNo]) -> Bool {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        let tokens = SuggestionEngine.filenameTokens(fileName)
        let site = host.flatMap(LearnedHost.usable)
        return nos.contains { no in
            guard no.destinationID == destinationID, no.fileExtension == ext else { return false }
            if !no.tokens.isDisjoint(with: tokens) { return true }
            if let site, no.host == site { return true }
            // A name with no useful words (IMG_1234, document (3)) is held back only by one like it.
            return tokens.isEmpty && no.tokens.isEmpty && site == nil && no.host == nil
        }
    }

    /// A move held back by a "no" waits for you instead; everything else is unchanged.
    public static func apply(_ decision: AutoMoveDecision, fileName: String, host: String?, nos: [LearningNo]) -> AutoMoveDecision {
        guard case .move(let destinationID, let reason) = decision,
              holdsBack(fileName: fileName, host: host, destinationID: destinationID, nos: nos) else { return decision }
        return .suggest(destinationID: destinationID, reason: reason + waitNote)
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
    /// For a learned pattern: how many of your moves it comes from.
    public let examples: Int

    public init(suggestion: DestinationSuggestion, strength: SuggestionStrength, examples: Int = 0) {
        self.suggestion = suggestion
        self.strength = strength
        self.examples = examples
    }

    public var why: SuggestionWhy {
        switch strength {
        case .rule: return SuggestionWhy(label: "Your rule", detail: suggestion.reason)
        case .screenshot: return SuggestionWhy(label: "Screenshot", detail: suggestion.reason)
        case .learned:
            return SuggestionWhy(label: examples > 0 ? "Learned from \(examples) moves" : "Learned", detail: suggestion.reason)
        case .wording: return SuggestionWhy(label: "Name match", detail: suggestion.reason + ". This is only a hint, so EchoNyla never moves the file by itself.")
        }
    }
}

/// A short tag saying where a suggestion came from ("Your rule", "Learned from 4 moves"), with the
/// full reason for its tooltip.
public struct SuggestionWhy: Equatable, Sendable {
    public let label: String
    public let detail: String

    public init(label: String, detail: String) {
        self.label = label
        self.detail = detail
    }

    public static func appleIntelligence(reason: String?, isSure: Bool) -> SuggestionWhy {
        let said = reason.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let base = said.map { "Apple Intelligence: \($0)" } ?? "Apple Intelligence read the file."
        return SuggestionWhy(label: "Apple Intelligence",
                             detail: base + (isSure ? "" : " It isn't sure, so the file waits for you."))
    }

    /// The tag for a reason EchoNyla wrote earlier (Activity, Clean Up, Deep Reorganize). Nil for
    /// reasons that aren't a suggestion (your own choice, a file it couldn't read).
    public static func from(reason: String) -> SuggestionWhy? {
        var text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let held = text.hasSuffix(LearningNo.waitNote.trimmingCharacters(in: .whitespaces))
        if held {
            text = String(text.dropLast(LearningNo.waitNote.trimmingCharacters(in: .whitespaces).count))
                .trimmingCharacters(in: .whitespaces)
        }
        guard let found = plain(text) else { return nil }
        return held ? SuggestionWhy(label: found.label, detail: reason) : found
    }

    private static func plain(_ text: String) -> SuggestionWhy? {
        if text.hasPrefix("Downloaded from "), text.contains(" files you moved there") {
            let count = text.components(separatedBy: "like ").last?.split(whereSeparator: { !$0.isNumber }).first.flatMap { Int($0) }
            return SuggestionWhy(label: count.map { "Learned from \($0) moves" } ?? "Learned", detail: text)
        }
        if text.hasPrefix("Matches your "), text.hasSuffix(" rule") { return SuggestionWhy(label: "Your rule", detail: text) }
        if text.hasPrefix("Similar to files you moved before") {
            let count = text.split(whereSeparator: { !$0.isNumber }).first.flatMap { Int($0) }
            return SuggestionWhy(label: count.map { "Learned from \($0) moves" } ?? "Learned", detail: text)
        }
        if text == "Filename matches macOS screenshot naming" || text == "macOS marks this as a screen capture" {
            return SuggestionWhy(label: "Screenshot", detail: text)
        }
        if text.hasPrefix("Matches "), text.hasSuffix(" wording") { return SuggestionWhy(label: "Name match", detail: text) }
        if text.hasPrefix("Apple Intelligence: ") { return SuggestionWhy(label: "Apple Intelligence", detail: text) }
        return nil
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
        isScreenCapture: Bool = false,
        sourceHost: String? = nil
    ) -> DestinationSuggestion? {
        suggestRanked(fileName: fileName, destinations: destinations, rules: rules, learning: learning,
                      isScreenCapture: isScreenCapture, sourceHost: sourceHost)?.suggestion
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
        isScreenCapture: Bool = false,
        sourceHost: String? = nil
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
                strength: .learned, examples: learnedMatch.1)
        }

        // Files from the same website: 3 different ones you moved to the same folder.
        if let site = sourceHost.flatMap(LearnedHost.usable), !extensionName.isEmpty {
            let fromSite = Dictionary(grouping: learning.filter { record in
                availableIDs.contains(record.destinationID) && !lockedDestinationIDs.contains(record.destinationID)
                    && record.host == site && record.fileExtension == extensionName && record.sampleName != nil
            }, by: \.destinationID).mapValues { Set($0.compactMap { $0.sampleName?.lowercased() }).count }
            // Only when one folder clearly has them: files from one site that went to two folders say nothing.
            let strong = fromSite.filter { $0.value >= 3 }
            if strong.count == 1, fromSite.count == 1, let match = strong.first {
                return RankedSuggestion(
                    suggestion: DestinationSuggestion(destinationID: match.key,
                                                      reason: "Downloaded from \(site), like \(match.value) files you moved there"),
                    strength: .learned, examples: match.value)
            }
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
