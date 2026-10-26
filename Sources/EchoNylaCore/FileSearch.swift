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

    /// Used when Apple Intelligence is off: the meaningful words of the sentence, matched in names and text.
    public static func fallbackRequest(from sentence: String) -> FileSearchRequest {
        var words: [String] = []
        for word in TextTools.words(sentence) where !stopWords.contains(word) && !words.contains(word) {
            words.append(word)
        }
        return FileSearchRequest(words: Array(words.prefix(6)))
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
            case "image", "images", "photo", "photos", "picture", "pictures", "screenshot", "screenshots": kind = .image
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
