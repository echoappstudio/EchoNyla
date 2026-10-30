import Foundation

/// A search described in plain words, after Apple Intelligence (or the simple fallback) turned it
/// into parts Spotlight understands.
public struct FileSearchRequest: Equatable, Sendable {
    public var words: [String]
    public var kinds: [FileKind]
    public var screenshotsOnly: Bool
    /// yyyy-MM-dd, inclusive.
    public var fromDay: String?
    public var toDay: String?
    /// Part of the website the file came from, e.g. "chase".
    public var source: String?

    public init(words: [String] = [], kinds: [FileKind] = [], screenshotsOnly: Bool = false, fromDay: String? = nil,
                toDay: String? = nil, source: String? = nil) {
        self.words = words
        self.kinds = kinds
        self.screenshotsOnly = screenshotsOnly
        self.fromDay = fromDay
        self.toDay = toDay
        self.source = source
    }

    public var isEmpty: Bool {
        words.isEmpty && kinds.isEmpty && !screenshotsOnly && fromDay == nil && toDay == nil && source == nil
    }
}

/// Builds Spotlight queries (the same index Finder search uses), so nothing new is stored.
public enum SpotlightQuery {
    static let stopWords: Set<String> = [
        "the", "a", "an", "my", "me", "i", "of", "to", "from", "for", "in", "on", "at", "and", "or", "with", "that", "this",
        "file", "files", "find", "show", "where", "is", "was", "it", "last", "about", "some", "any", "which", "what"
    ]

    static let contentTypes: [FileKind: [String]] = [
        .pdf: ["com.adobe.pdf"],
        .document: ["org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc", "com.apple.iwork.pages.sffpages",
                    "com.apple.iwork.pages.pages", "public.rtf"],
        .spreadsheet: ["public.spreadsheet", "public.comma-separated-values-text"],
        .presentation: ["public.presentation"],
        .image: ["public.image"],
        .audio: ["public.audio"],
        .video: ["public.movie"],
        .archive: ["public.archive"],
        .installer: ["com.apple.disk-image", "com.apple.installer-package-archive"],
        .text: ["public.plain-text"],
        .code: ["public.source-code"]
    ]

    /// Only letters, digits, spaces, hyphens and apostrophes; nothing that could change the query.
    public static func safeTerm(_ text: String) -> String? {
        let kept = text.lowercased().unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == " " || scalar == "-" || scalar == "'"
        }
        var term = String(String.UnicodeScalarView(kept))
        term = TextTools.collapseWhitespace(term).replacingOccurrences(of: "'", with: "")
        return term.count >= 2 && term.count <= 40 ? term : nil
    }

    /// A real calendar day in yyyy-MM-dd form, or nil.
    public static func validDay(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), text.count == 10 else { return nil }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1900...2200).contains(parts[0]), (1...12).contains(parts[1]), parts[2] >= 1 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        guard let date = Calendar(identifier: .gregorian).date(from: components),
              let days = Calendar(identifier: .gregorian).range(of: .day, in: .month, for: date),
              parts[2] <= days.count else { return nil }
        func pad(_ value: Int, _ width: Int) -> String {
            let digits = String(value)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        return "\(pad(parts[0], 4))-\(pad(parts[1], 2))-\(pad(parts[2], 2))"
    }

    /// The query string for `NSMetadataQuery`/`NSPredicate(fromMetadataQueryString:)`, or nil when there's nothing to search for.
    public static func make(_ request: FileSearchRequest) -> String? {
        var parts: [String] = []
        for word in request.words.compactMap(safeTerm).prefix(6) {
            parts.append("(kMDItemDisplayName == \"*\(word)*\"cd || kMDItemTextContent == \"\(word)*\"cdw)")
        }
        let types = request.kinds.flatMap { contentTypes[$0] ?? [] }
        if !types.isEmpty {
            parts.append("(" + types.map { "kMDItemContentTypeTree == \"\($0)\"" }.joined(separator: " || ") + ")")
        }
        if request.screenshotsOnly { parts.append("kMDItemIsScreenCapture == 1") }
        if let from = validDay(request.fromDay) { parts.append("kMDItemContentModificationDate >= $time.iso(\(from)T00:00:00Z)") }
        if let to = validDay(request.toDay) { parts.append("kMDItemContentModificationDate <= $time.iso(\(to)T23:59:59Z)") }
        if let source = request.source.flatMap(safeTerm) { parts.append("kMDItemWhereFroms == \"*\(source)*\"cd") }
        return parts.isEmpty ? nil : parts.joined(separator: " && ")
    }

    /// True when `date` falls between the request's days (yyyy-MM-dd, inclusive) in this time zone.
    public static func isInRange(_ date: Date?, from: String?, to: String?, calendar: Calendar = .current) -> Bool {
        guard from != nil || to != nil else { return true }
        guard let date else { return false }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        if let from = validDay(from), day < from { return false }
        if let to = validDay(to), day > to { return false }
        return true
    }

    /// Used when Apple Intelligence is off: the meaningful words of the sentence, matched in names and text.
    public static func fallbackRequest(from sentence: String) -> FileSearchRequest {
        var words: [String] = []
        for word in TextTools.words(sentence) where !stopWords.contains(word) && !words.contains(word) {
            words.append(word)
        }
        return FileSearchRequest(words: Array(words.prefix(6)))
    }

    /// Apple Intelligence sometimes adds filters nobody asked for ("rocks" came back as documents from the last
    /// two months), which hides the very files being looked for. Keeps a type, a date range, screenshots or a
    /// website only when the sentence asks for one, and words only when they come from the sentence.
    public static func grounded(_ request: FileSearchRequest, in sentence: String) -> FileSearchRequest {
        let said = TextTools.words(sentence)
        var result = request
        result.words = request.words.filter { word in
            TextTools.words(word).contains { part in said.contains { sharesStem($0, part) } }
        }
        let named = Set(kinds(from: said) + said.map { FileKind.from(fileExtension: $0) }.filter { $0 != .other })
        result.kinds = request.kinds.filter(named.contains)
        result.screenshotsOnly = request.screenshotsOnly && said.contains { $0.hasPrefix("screenshot") || $0 == "screen" }
        if !said.contains(where: isTimeWord) {
            result.fromDay = nil
            result.toDay = nil
        }
        if let source = request.source, !sentence.lowercased().contains(source.lowercased()) { result.source = nil }
        return result.isEmpty ? fallbackRequest(from: sentence) : result
    }

    static let timeWords: Set<String> = [
        "today", "yesterday", "tonight", "day", "days", "week", "weeks", "weekend", "month", "months", "year", "years",
        "ago", "last", "recent", "recently", "latest", "newest", "oldest", "since", "before", "after", "during", "between",
        "spring", "summer", "fall", "autumn", "winter", "morning", "afternoon", "evening", "night",
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november",
        "december", "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"
    ]

    static func isTimeWord(_ word: String) -> Bool {
        if timeWords.contains(word) { return true }
        guard word.count == 4, let year = Int(word) else { return false }
        return (1970...2100).contains(year)
    }

    /// "rock" and "rocks", "photo" and "photographs": the same word for a search.
    static func sharesStem(_ a: String, _ b: String) -> Bool {
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        if short.count >= 2, long.hasPrefix(short) { return true }
        return zip(a, b).prefix { $0 == $1 }.count >= 5
    }

    /// Kind names from the model ("pdf", "photo", "spreadsheet"…), mapped onto known kinds.
    public static func kinds(from names: [String]) -> [FileKind] {
        var result: [FileKind] = []
        for name in names {
            let clean = name.lowercased().trimmingCharacters(in: .whitespaces)
            let kind: FileKind?
            switch clean {
            case "pdf", "pdfs": kind = .pdf
            case "document", "documents", "doc", "word": kind = .document
            case "spreadsheet", "spreadsheets", "excel", "csv": kind = .spreadsheet
            case "presentation", "presentations", "slides", "keynote": kind = .presentation
            case "image", "images", "photo", "photos", "picture", "pictures", "pic", "pics", "screenshot", "screenshots": kind = .image
            case "audio", "music", "song", "recording": kind = .audio
            case "video", "videos", "movie": kind = .video
            case "archive", "zip": kind = .archive
            case "installer", "dmg", "app": kind = .installer
            case "text", "note", "notes": kind = .text
            default: kind = FileKind(rawValue: clean)
            }
            if let kind, kind != .other, !result.contains(kind) { result.append(kind) }
        }
        return result
    }
}

/// Why a file came up in a search, and the files EchoNyla already looked at that Spotlight can't
/// find by what's in them (a photo of a dog has no text, but EchoNyla described it).
public enum SearchMatch {
    /// Where each word of the search was found: “Name has “dentist” · Text inside has “invoice””.
    /// Words that aren't in the name or in what EchoNyla knows were matched by Spotlight in the text.
    public static func reason(words: [String], name: String, insight: FileInsight?) -> String {
        let nameWords = TextTools.words(name)
        let known = insight.map(knownWords) ?? []
        var inName: [String] = []
        var seen: [String] = []
        var inside: [String] = []
        for word in words {
            if matches(word, nameWords) {
                inName.append(word)
            } else if matches(word, known) {
                seen.append(word)
            } else {
                inside.append(word)
            }
        }
        var parts: [String] = []
        if !inName.isEmpty { parts.append("Name has " + quoted(inName)) }
        if !seen.isEmpty { parts.append("EchoNyla saw " + quoted(seen)) }
        if !inside.isEmpty { parts.append("Text inside has " + quoted(inside)) }
        return parts.joined(separator: " · ")
    }

    /// Files EchoNyla looked at whose name or what it learned about them (description, names in
    /// them, words spoken) has every word of the search, newest first.
    public static func insightPaths(words: [String], in insights: FileInsights) -> [String] {
        guard !words.isEmpty else { return [] }
        var paths: [String] = []
        for key in insights.keys.reversed() {
            guard let insight = insights.insight(for: key), let path = path(fromKey: key), !paths.contains(path) else { continue }
            let known = knownWords(insight) + TextTools.words((path as NSString).lastPathComponent)
            if words.allSatisfy({ matches($0, known) }) { paths.append(path) }
        }
        return paths
    }

    /// The path in an insight key ("path|size|modified").
    public static func path(fromKey key: String) -> String? {
        let parts = key.components(separatedBy: "|")
        guard parts.count >= 3 else { return nil }
        return parts.dropLast(2).joined(separator: "|")
    }

    static func knownWords(_ insight: FileInsight) -> [String] {
        TextTools.words([insight.summary, insight.proposedName ?? "", insight.names.joined(separator: " "), insight.speech]
            .joined(separator: " "))
    }

    /// A search word (or each word of a phrase) starts one of the words, as Spotlight matches them.
    static func matches(_ term: String, _ words: [String]) -> Bool {
        let parts = TextTools.words(term)
        return !parts.isEmpty && parts.allSatisfy { part in words.contains { $0.hasPrefix(part) } }
    }

    static func quoted(_ words: [String]) -> String {
        words.map { "“\($0)”" }.joined(separator: ", ")
    }
}
