import Foundation

// Deep Reorganize (3.2.0): the model goes through whole folders, names files and sorts them into your
// "Sort into this" folders. These are the parts that don't need a Mac: which files to skip, new
// folders from what files have in common, exact duplicates, a zip's contents and the time left.

// MARK: - Which files

public enum ReorganizeScope {
    /// The most files one run looks at.
    public static let fileLimit = 3_000

    /// True when `path` is inside (or is) one of `folders`.
    public static func isInside(_ path: String, any folders: [String]) -> Bool {
        let path = CleanupFolders.normalized(path)
        return folders.map(CleanupFolders.normalized).contains { folder in
            path == folder || path.hasPrefix(folder == "/" ? "/" : folder + "/")
        }
    }
}

/// "About 25 minutes left", from how long the files so far took.
public enum ReorganizeTime {
    public static func remaining(done: Int, total: Int, elapsed: TimeInterval) -> String? {
        guard done >= 3, total > done, elapsed > 0 else { return nil }
        let seconds = elapsed / Double(done) * Double(total - done)
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes <= 1 { return "About a minute left" }
        if minutes < 90 { return "About \(minutes) minutes left" }
        let hours = (Double(minutes) / 60 * 2).rounded() / 2
        let text = hours == hours.rounded() ? String(Int(hours)) : String(format: "%.1f", hours)
        return "About \(text) hours left"
    }
}

// MARK: - New folders from what files have in common

/// Files the model couldn't place that are clearly about the same thing (a name, an app, a client, a
/// trip that turns up in what each file is) become a suggested new folder. Judged by content, not
/// by similar file names; broad words like "invoice" or "school" never name a folder.
public enum ContentGrouping {
    public struct Group: Equatable, Sendable {
        public var name: String
        public var ids: [String]
    }

    /// `items`: each file's id and what's known about it (the model's description and new name).
    public static func groups(_ items: [(id: String, text: String)], minimumSize: Int = 3, existingNames: [String] = [],
                              limit: Int = 8) -> [Group] {
        let blocked = Set(GroupCheck.broadWords.map(Words.stem))
            .union(existingNames.flatMap { Words.distinctive($0) })
        var idsByWord: [String: Set<String>] = [:]
        var spellings: [String: [String: Int]] = [:]
        var wordsByID: [String: Set<String>] = [:]
        for item in items {
            var words: Set<String> = []
            for raw in item.text.components(separatedBy: CharacterSet.alphanumerics.inverted) where raw.count >= 3 {
                let lower = raw.lowercased()
                guard !Words.filler.contains(lower), !Words.generic.contains(lower), !lower.allSatisfy(\.isNumber) else { continue }
                let stem = Words.stem(lower)
                guard !blocked.contains(stem) else { continue }
                words.insert(stem)
                spellings[stem, default: [:]][raw, default: 0] += 1
            }
            wordsByID[item.id] = words
            for word in words { idsByWord[word, default: []].insert(item.id) }
        }
        let candidates = idsByWord.sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
        var used: Set<String> = []
        var names: Set<String> = []
        var result: [Group] = []
        for (word, ids) in candidates where result.count < limit {
            let members = ids.subtracting(used)
            guard members.count >= max(2, minimumSize) else { continue }
            var name = display(spellings[word] ?? [:], fallback: word)
            // A second word every member shares makes the name more specific ("Purevo waveform").
            var common: Set<String>?
            for member in members {
                let words = wordsByID[member] ?? []
                common = common.map { $0.intersection(words) } ?? words
            }
            let seconds = (common ?? []).subtracting([word]).sorted { lhs, rhs in
                let left = idsByWord[lhs]?.count ?? 0, right = idsByWord[rhs]?.count ?? 0
                return left != right ? left > right : lhs < rhs
            }
            if let second = seconds.first {
                name += " " + display(spellings[second] ?? [:], fallback: second).lowercased()
            }
            guard let valid = GroupCheck.validFolderName(name), names.insert(valid.lowercased()).inserted else { continue }
            used.formUnion(members)
            result.append(Group(name: valid, ids: members.sorted()))
        }
        return result
    }

    /// The spelling used most ("Purevo", not "purevo"), with a capital first letter.
    static func display(_ spellings: [String: Int], fallback: String) -> String {
        let best = spellings.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? fallback
        guard let first = best.first, first.isLowercase else { return best }
        return first.uppercased() + best.dropFirst()
    }
}

// MARK: - Exact duplicates

/// Files with exactly the same contents, whatever they're called. A "(2)" in a name means nothing
/// on its own: two screenshots taken at once on two displays are different pictures.
public enum DuplicateFinder {
    /// Groups of paths that share a size (more than zero bytes): only these need their contents compared.
    public static func sameSize(_ files: [(path: String, size: Int64)]) -> [[String]] {
        let bySize = Dictionary(grouping: files.filter { $0.size > 0 }, by: \.size)
        return bySize.values.filter { $0.count >= 2 }.map { $0.map(\.path).sorted() }.sorted { $0[0] < $1[0] }
    }

    /// Groups of paths with the same contents fingerprint.
    public static func groups(_ fingerprints: [(path: String, fingerprint: String)]) -> [[String]] {
        let byPrint = Dictionary(grouping: fingerprints, by: \.fingerprint)
        return byPrint.values.filter { $0.count >= 2 }.map { $0.map(\.path).sorted() }.sorted { $0[0] < $1[0] }
    }

    /// The copy to keep: one whose name says something, then one without a copy mark, then the oldest.
    public static func keeper(_ paths: [String], modified: [String: Date] = [:]) -> String? {
        paths.min { lhs, rhs in
            let left = rank(lhs, modified: modified), right = rank(rhs, modified: modified)
            if left.0 != right.0 { return left.0 < right.0 }
            if left.1 != right.1 { return left.1 < right.1 }
            if left.2 != right.2 { return left.2 < right.2 }
            return lhs < rhs
        }
    }

    private static func rank(_ path: String, modified: [String: Date]) -> (Int, Int, Date) {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let saysNothing = NameQuality.isUnhelpful(name) ? 1 : 0
        let copyMark = NameQuality.withoutCopyMark(name) == name.lowercased() ? 0 : 1
        return (saysNothing, copyMark, modified[path] ?? .distantFuture)
    }
}

// MARK: - What's inside a zip

/// The names of the files in a zip, read from its table of contents at the end of the file, so
/// The model can name an archive after what's in it. Nothing is unpacked.
public enum ZipListing {
    /// How much of the end of a zip to read.
    public static let tailBytes = 2 * 1024 * 1024

    /// File names (without folders), or nil when `tail` (the last bytes of a file of `fileSize`
    /// bytes) doesn't hold a zip's table of contents.
    public static func names(tail: Data, fileSize: Int64, limit: Int = 300) -> [String]? {
        let bytes = [UInt8](tail)
        guard bytes.count >= 22 else { return nil }
        var end = -1
        var index = bytes.count - 22
        let earliest = max(0, bytes.count - 22 - 65_535)
        while index >= earliest {
            if bytes[index] == 0x50, bytes[index + 1] == 0x4B, bytes[index + 2] == 0x05, bytes[index + 3] == 0x06 { end = index; break }
            index -= 1
        }
        guard end >= 0 else { return nil }
        let count = Int(uint16(bytes, end + 10))
        let directoryOffset = Int64(uint32(bytes, end + 16))
        let tailStart = fileSize - Int64(bytes.count)
        guard directoryOffset != 0xFFFF_FFFF, directoryOffset >= tailStart else { return nil }
        var position = Int(directoryOffset - tailStart)
        var names: [String] = []
        for _ in 0..<count {
            guard position + 46 <= bytes.count, uint32(bytes, position) == 0x0201_4B50 else { break }
            let nameLength = Int(uint16(bytes, position + 28))
            let extraLength = Int(uint16(bytes, position + 30))
            let commentLength = Int(uint16(bytes, position + 32))
            guard position + 46 + nameLength <= bytes.count else { break }
            let path = String(decoding: bytes[(position + 46)..<(position + 46 + nameLength)], as: UTF8.self)
            position += 46 + nameLength + extraLength + commentLength
            let name = (path as NSString).lastPathComponent
            guard !path.hasSuffix("/"), !path.hasPrefix("__MACOSX/"), !name.hasPrefix("."), !name.isEmpty else { continue }
            names.append(name)
            if names.count >= limit { break }
        }
        return names
    }

    /// "8 files inside: a.png, b.md, …" for the model.
    public static func summary(_ names: [String], shown: Int = 25) -> String {
        guard !names.isEmpty else { return "An empty archive." }
        let list = names.prefix(shown).joined(separator: ", ") + (names.count > shown ? ", …" : "")
        return "\(names.count) file\(names.count == 1 ? "" : "s") inside: \(list)"
    }

    private static func uint16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    private static func uint32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
}

/// Files Apple Intelligence already named, or that you approved or left as they are, so Deep
/// Reorganize and Check This Folder don't look at them again. A file counts as the same while its
/// place, size and modification date stay the same; when it changes, it's looked at again.
public struct ReviewedFiles: Codable, Equatable, Sendable {
    /// The most kept; the oldest go first.
    public static let limit = 20_000
    private var added: [String: Date] = [:]

    public init() {}

    public static func key(path: String, size: Int64, modified: Date) -> String {
        "\(path)|\(size)|\(Int(modified.timeIntervalSince1970))"
    }

    public var count: Int { added.count }

    public func contains(_ key: String) -> Bool { added[key] != nil }

    public mutating func insert(_ key: String, at date: Date = Date()) {
        added[key] = date
        guard added.count > Self.limit else { return }
        let oldest = added.sorted { $0.value < $1.value }.prefix(added.count - Self.limit)
        for (old, _) in oldest { added[old] = nil }
    }

    public static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("EchoNyla", isDirectory: true).appendingPathComponent("reviewed-files.json")
    }

    public static func load(from url: URL = fileURL) -> ReviewedFiles {
        guard let data = try? Data(contentsOf: url) else { return ReviewedFiles() }
        return (try? JSONDecoder().decode(ReviewedFiles.self, from: data)) ?? ReviewedFiles()
    }

    public func save(to url: URL = fileURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
    }
}
