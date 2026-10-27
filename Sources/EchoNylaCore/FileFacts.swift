import Darwin
import Foundation

/// Broad file kinds, from the file extension.
public enum FileKind: String, Codable, Sendable, CaseIterable {
    case pdf, document, spreadsheet, presentation, image, audio, video, archive, installer, text, code, other

    private static let extensions: [FileKind: Set<String>] = [
        .pdf: ["pdf"],
        .document: ["doc", "docx", "pages", "rtf", "rtfd", "odt"],
        .spreadsheet: ["xls", "xlsx", "numbers", "csv", "tsv", "ods"],
        .presentation: ["ppt", "pptx", "key", "odp"],
        .image: ["png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "webp", "bmp", "svg", "raw", "dng"],
        .audio: ["mp3", "m4a", "wav", "aiff", "aif", "flac", "aac", "ogg"],
        .video: ["mov", "mp4", "m4v", "avi", "mkv", "webm"],
        .archive: ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar"],
        .installer: ["dmg", "pkg", "mpkg", "app"],
        .text: ["txt", "md", "markdown", "log"],
        .code: ["swift", "py", "js", "ts", "json", "html", "css", "sh", "yml", "yaml", "xml", "c", "h", "m", "java", "rb", "go", "rs"]
    ]

    public static func from(fileExtension: String) -> FileKind {
        let ext = fileExtension.lowercased()
        for kind in FileKind.allCases where extensions[kind]?.contains(ext) == true { return kind }
        return .other
    }

    public var label: String {
        switch self {
        case .pdf: return "PDF"
        case .document: return "document"
        case .spreadsheet: return "spreadsheet"
        case .presentation: return "presentation"
        case .image: return "image"
        case .audio: return "audio"
        case .video: return "video"
        case .archive: return "archive"
        case .installer: return "installer"
        case .text: return "text file"
        case .code: return "code"
        case .other: return "file"
        }
    }
}

/// What EchoNyla found out about one file, all on this Mac: its name, kind, where it was
/// downloaded from, and (when allowed) text and image labels from inside it.
public struct FileFacts: Equatable, Sendable {
    public var fileName: String
    public var kind: FileKind
    public var byteCount: Int64?
    public var modified: Date?
    public var isScreenshot: Bool
    /// Websites the file was downloaded from (host names, e.g. "chase.com").
    public var downloadedFrom: [String]
    /// Text read from inside the file (PDF, document, text, or recognized in an image). May be empty.
    public var text: String
    /// What an image shows, from Apple's on-device image classification (e.g. "receipt", "document").
    public var imageLabels: [String]
    public var pageCount: Int?
    /// Words spoken at the start of a recording or video (its first minute), from Apple's on-device speech recognition.
    public var speech: String
    /// People, places and companies named in the text, from Apple's Natural Language framework.
    public var names: [String]
    /// The text's language when it isn't English ("French"), from Natural Language.
    public var language: String?

    public init(fileName: String, byteCount: Int64? = nil, modified: Date? = nil, isScreenshot: Bool = false,
                downloadedFrom: [String] = [], text: String = "", imageLabels: [String] = [], pageCount: Int? = nil,
                speech: String = "", names: [String] = [], language: String? = nil) {
        self.fileName = fileName
        self.kind = FileKind.from(fileExtension: URL(fileURLWithPath: fileName).pathExtension)
        self.byteCount = byteCount
        self.modified = modified
        self.isScreenshot = isScreenshot
        self.downloadedFrom = downloadedFrom
        self.text = text
        self.imageLabels = imageLabels
        self.pageCount = pageCount
        self.speech = speech
        self.names = names
        self.language = language
    }

    public var fileExtension: String { URL(fileURLWithPath: fileName).pathExtension.lowercased() }

    /// True when something beyond the file name tells what the file is.
    public var hasContentEvidence: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !speech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !imageLabels.isEmpty || !downloadedFrom.isEmpty
    }

    /// The facts as Apple Intelligence sees them. Long numbers (account, card, order and phone
    /// numbers) are hidden, and the text is shortened.
    public func promptText(textLimit: Int = 1_200) -> String {
        var lines = ["File name: \(TextTools.redactLongNumbers(fileName))", "Kind: \(kind.label)"]
        if isScreenshot { lines.append("macOS marks this as a screenshot.") }
        if let pageCount { lines.append("Pages: \(pageCount)") }
        if !downloadedFrom.isEmpty { lines.append("Downloaded from: \(downloadedFrom.joined(separator: ", "))") }
        if !imageLabels.isEmpty { lines.append("The image shows: \(imageLabels.joined(separator: ", "))") }
        if !names.isEmpty { lines.append("Names in it: \(TextTools.redactLongNumbers(names.joined(separator: ", ")))") }
        if let language { lines.append("Language: \(language)") }
        let cleanText = TextTools.collapseWhitespace(text)
        if !cleanText.isEmpty {
            lines.append("Text inside the file (start): \(TextTools.redactLongNumbers(String(cleanText.prefix(textLimit))))")
        }
        let cleanSpeech = TextTools.collapseWhitespace(speech)
        if !cleanSpeech.isEmpty {
            lines.append("Spoken in the first minute: \(TextTools.redactLongNumbers(String(cleanSpeech.prefix(textLimit))))")
        }
        return lines.joined(separator: "\n")
    }
}

public enum TextTools {
    /// Replaces runs of 5 or more digits with # signs, so account and card numbers never reach the model.
    public static func redactLongNumbers(_ text: String, minimumRun: Int = 5) -> String {
        var result = ""
        var run = ""
        for character in text {
            if character.isASCII, character.isNumber {
                run.append(character)
            } else {
                result += run.count >= minimumRun ? String(repeating: "#", count: run.count) : run
                run = ""
                result.append(character)
            }
        }
        result += run.count >= minimumRun ? String(repeating: "#", count: run.count) : run
        return result
    }

    public static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// "https://www.chase.com/statements?id=1" → "chase.com". Nil for anything that isn't a web address.
    public static func host(fromWhereFrom value: String) -> String? {
        guard let components = URLComponents(string: value.trimmingCharacters(in: .whitespaces)),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = components.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// Lowercased words of 2+ letters or digits.
    public static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 }
    }
}

/// Where macOS recorded a file was downloaded from (Safari, Chrome and others set this).
public enum DownloadSource {
    static let attributeName = "com.apple.metadata:kMDItemWhereFroms"

    public static func hosts(at url: URL) -> [String] {
        hosts(fromWhereFroms: rawWhereFroms(at: url))
    }

    public static func hosts(fromWhereFroms values: [String]) -> [String] {
        var seen: [String] = []
        for value in values {
            guard let host = TextTools.host(fromWhereFrom: value), !seen.contains(host) else { continue }
            seen.append(host)
        }
        return seen
    }

    static func rawWhereFroms(at url: URL) -> [String] {
        let size = url.path.withCString { path in
            attributeName.withCString { name in getxattr(path, name, nil, 0, 0, 0) }
        }
        guard size > 0 else { return [] }
        var data = Data(count: size)
        let readSize = data.withUnsafeMutableBytes { buffer in
            url.path.withCString { path in
                attributeName.withCString { name in getxattr(path, name, buffer.baseAddress, size, 0, 0) }
            }
        }
        guard readSize == size,
              let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return [] }
        return (value as? [Any])?.compactMap { $0 as? String } ?? []
    }
}
