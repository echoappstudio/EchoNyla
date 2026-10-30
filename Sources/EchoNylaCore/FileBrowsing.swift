import Foundation

// MARK: - What the Files area shows

/// One file or folder in a folder, as the Files area shows it.
public struct BrowserItem: Equatable, Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let isFolder: Bool
    public let byteCount: Int64?
    public let modified: Date?
    public let created: Date?
    /// When it arrived in this folder.
    public let added: Date?
    /// When it was last opened, from Spotlight (nil when it never was, or Spotlight doesn't know).
    public let lastOpened: Date?
    /// "PDF document", from macOS.
    public let kindText: String
    public let isScreenshot: Bool

    public init(path: String, name: String? = nil, isFolder: Bool = false, byteCount: Int64? = nil, modified: Date? = nil,
                created: Date? = nil, added: Date? = nil, lastOpened: Date? = nil, kindText: String = "", isScreenshot: Bool = false) {
        self.path = path
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
        self.isFolder = isFolder
        self.byteCount = byteCount
        self.modified = modified
        self.created = created
        self.added = added
        self.lastOpened = lastOpened
        self.kindText = kindText
        self.isScreenshot = isScreenshot
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: isFolder) }
    public var kind: FileKind { FileKind.from(fileExtension: URL(fileURLWithPath: name).pathExtension) }
}

public enum BrowserSortKey: String, CaseIterable, Codable, Sendable {
    case name, kind, size, modified, added

    public var title: String {
        switch self {
        case .name: return "Name"
        case .kind: return "Kind"
        case .size: return "Size"
        case .modified: return "Date Modified"
        case .added: return "Date Added"
        }
    }
}

public struct BrowserSort: Equatable, Codable, Sendable {
    public var key: BrowserSortKey
    public var ascending: Bool

    public init(key: BrowserSortKey = .name, ascending: Bool = true) {
        self.key = key
        self.ascending = ascending
    }

    /// Clicking a column: the same column turns the order around; a new one starts in its usual order
    /// (names A to Z, dates and sizes biggest or newest first).
    public func clicking(_ newKey: BrowserSortKey) -> BrowserSort {
        if newKey == key { return BrowserSort(key: key, ascending: !ascending) }
        return BrowserSort(key: newKey, ascending: newKey == .name || newKey == .kind)
    }

    /// Folders first, like Finder's "Keep folders on top", then by the chosen column; names break ties.
    public func sorted(_ items: [BrowserItem]) -> [BrowserItem] {
        items.sorted { lhs, rhs in
            if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
            let order = compare(lhs, rhs)
            if order != .orderedSame { return ascending ? order == .orderedAscending : order == .orderedDescending }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func compare(_ lhs: BrowserItem, _ rhs: BrowserItem) -> ComparisonResult {
        switch key {
        case .name: return lhs.name.localizedStandardCompare(rhs.name)
        case .kind: return lhs.kindText.localizedStandardCompare(rhs.kindText)
        case .size: return Self.order(lhs.byteCount ?? -1, rhs.byteCount ?? -1)
        case .modified: return Self.order(lhs.modified ?? .distantPast, rhs.modified ?? .distantPast)
        case .added: return Self.order(lhs.added ?? lhs.created ?? .distantPast, rhs.added ?? rhs.created ?? .distantPast)
        }
    }

    private static func order<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs < rhs ? .orderedAscending : (lhs > rhs ? .orderedDescending : .orderedSame)
    }
}

/// Typing in the Files search box narrows the list to names with those words, before any search runs.
public enum NameFilter {
    public static func matches(_ name: String, _ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return true }
        return words.allSatisfy { name.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

// MARK: - Grouping

public enum BrowserGrouping: String, CaseIterable, Codable, Sendable {
    case none, kind, date, meaning

    public var title: String {
        switch self {
        case .none: return "None"
        case .kind: return "Kind"
        case .date: return "Date Modified"
        case .meaning: return "What It Is"
        }
    }
}

public struct BrowserGroup: Equatable, Identifiable, Sendable {
    public var id: String { title }
    public let title: String
    public let items: [BrowserItem]

    public init(title: String, items: [BrowserItem]) {
        self.title = title
        self.items = items
    }
}

/// What a file is about, from its name, kind and (when Apple Intelligence has looked at it) its
/// description: a PDF receipt and a photo of a receipt end up together.
public enum FileCategory: String, CaseIterable, Codable, Sendable {
    case folders, receipts, bankStatements, taxes, contracts, travel, screenshots, pictures, recordings, installers,
         documents, spreadsheets, presentations, archives, code, other

    public var title: String {
        switch self {
        case .folders: return "Folders"
        case .receipts: return "Receipts"
        case .bankStatements: return "Bank statements"
        case .taxes: return "Taxes"
        case .contracts: return "Contracts"
        case .travel: return "Tickets and travel"
        case .screenshots: return "Screenshots"
        case .pictures: return "Pictures"
        case .recordings: return "Recordings and videos"
        case .installers: return "Installers"
        case .documents: return "Documents"
        case .spreadsheets: return "Spreadsheets"
        case .presentations: return "Presentations"
        case .archives: return "Archives"
        case .code: return "Code"
        case .other: return "Other"
        }
    }

    /// Words that mean a file is one of these, in its name or description.
    static let words: [(FileCategory, Set<String>)] = [
        (.receipts, ["receipt", "receipts", "invoice", "invoices", "bill", "bills", "order", "orders", "payment", "purchase", "refund"]),
        (.bankStatements, ["statement", "statements", "bank", "banking", "checking", "savings"]),
        (.taxes, ["tax", "taxes", "1099", "w2", "w-2", "irs", "1040"]),
        (.contracts, ["contract", "contracts", "agreement", "lease", "nda", "terms", "signed"]),
        (.travel, ["ticket", "tickets", "boarding", "itinerary", "booking", "reservation", "flight", "hotel", "trip"])
    ]

    public static func of(name: String, isFolder: Bool, isScreenshot: Bool, summary: String? = nil) -> FileCategory {
        if isFolder { return .folders }
        let kind = FileKind.from(fileExtension: URL(fileURLWithPath: name).pathExtension)
        if kind == .installer { return .installers }
        if isScreenshot { return .screenshots }
        let stem = (name as NSString).deletingPathExtension
        let nameWords = Set(TextTools.words(stem))
        let summaryWords = Set(TextTools.words(summary ?? ""))
        // A document or picture about a receipt is a receipt; a recording or an archive stays what it is.
        let canBeAbout: [FileKind] = [.pdf, .document, .image, .spreadsheet, .text, .other]
        if canBeAbout.contains(kind) {
            for (category, keys) in Self.words where !nameWords.isDisjoint(with: keys) { return category }
            for (category, keys) in Self.words where !summaryWords.isDisjoint(with: keys) { return category }
        }
        if kind == .image, nameWords.contains("screenshot") || stem.lowercased().hasPrefix("cleanshot") { return .screenshots }
        switch kind {
        case .image: return .pictures
        case .audio, .video: return .recordings
        case .pdf, .document, .text: return .documents
        case .spreadsheet: return .spreadsheets
        case .presentation: return .presentations
        case .archive: return .archives
        case .code: return .code
        case .installer: return .installers
        case .other: return .other
        }
    }
}

public enum BrowserGroups {
    /// Groups for the list, each already in the list's order. `category` says what a file is about.
    public static func make(_ items: [BrowserItem], by grouping: BrowserGrouping, now: Date = Date(), calendar: Calendar = .current,
                            category: (BrowserItem) -> FileCategory = { FileCategory.of(name: $0.name, isFolder: $0.isFolder, isScreenshot: $0.isScreenshot) })
        -> [BrowserGroup] {
        switch grouping {
        case .none:
            return [BrowserGroup(title: "", items: items)]
        case .kind:
            return ordered(items, titles: kindOrder) { $0.isFolder ? "Folders" : kindTitle($0.kind) }
        case .date:
            var titles: [String] = []
            var byTitle: [String: [BrowserItem]] = [:]
            // Newest groups first, whatever the list's order.
            let newestFirst = items.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            for item in newestFirst {
                let title = dateTitle(item.modified, now: now, calendar: calendar)
                if byTitle[title] == nil { titles.append(title) }
                byTitle[title, default: []].append(item)
            }
            let order = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.path, $0) })
            return titles.map { title in
                BrowserGroup(title: title, items: (byTitle[title] ?? []).sorted { (order[$0.path] ?? 0) < (order[$1.path] ?? 0) })
            }
        case .meaning:
            return ordered(items, titles: FileCategory.allCases.map(\.title)) { category($0).title }
        }
    }

    static let kindOrder = ["Folders", "PDFs", "Documents", "Spreadsheets", "Presentations", "Pictures", "Audio", "Videos",
                            "Archives", "Installers", "Text", "Code", "Other"]

    static func kindTitle(_ kind: FileKind) -> String {
        switch kind {
        case .pdf: return "PDFs"
        case .document: return "Documents"
        case .spreadsheet: return "Spreadsheets"
        case .presentation: return "Presentations"
        case .image: return "Pictures"
        case .audio: return "Audio"
        case .video: return "Videos"
        case .archive: return "Archives"
        case .installer: return "Installers"
        case .text: return "Text"
        case .code: return "Code"
        case .other: return "Other"
        }
    }

    /// Today, Yesterday, Previous 7 Days, Previous 30 Days, then months of this year, then years (as in Finder).
    public static func dateTitle(_ date: Date?, now: Date, calendar: Calendar) -> String {
        guard let date else { return "No Date" }
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if days <= 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        if days < 7 { return "Previous 7 Days" }
        if days < 30 { return "Previous 30 Days" }
        let year = calendar.component(.year, from: date)
        guard year == calendar.component(.year, from: now) else { return String(year) }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMMM"
        return formatter.string(from: date)
    }

    private static func ordered(_ items: [BrowserItem], titles: [String], title: (BrowserItem) -> String) -> [BrowserGroup] {
        let grouped = Dictionary(grouping: items, by: title)
        return titles.compactMap { name in grouped[name].map { BrowserGroup(title: name, items: $0) } }
    }
}

// MARK: - Clutter

/// Small badges for files you probably don't need. Nothing is ever trashed because of one.
public enum ClutterFlag: String, CaseIterable, Codable, Sendable {
    case copy, usedInstaller, large, untouched

    public var title: String {
        switch self {
        case .copy: return "Copy"
        case .usedInstaller: return "Used installer"
        case .large: return "Large"
        case .untouched: return "Untouched"
        }
    }

    public var explanation: String {
        switch self {
        case .copy: return "An exact copy of another file here (checked byte for byte)."
        case .usedInstaller: return "An installer for an app that's already in Applications."
        case .large: return "Bigger than 500 MB."
        case .untouched: return "Not opened or changed in over a year."
        }
    }
}

public enum ClutterCheck {
    public static let largeBytes: Int64 = 500_000_000
    public static let untouchedDays = 365

    public static func flags(_ item: BrowserItem, isCopy: Bool, isUsedInstaller: Bool, now: Date = Date()) -> [ClutterFlag] {
        guard !item.isFolder else { return [] }
        var flags: [ClutterFlag] = []
        if isCopy { flags.append(.copy) }
        if isUsedInstaller { flags.append(.usedInstaller) }
        if (item.byteCount ?? 0) >= largeBytes { flags.append(.large) }
        if isUntouched(item, now: now) { flags.append(.untouched) }
        return flags
    }

    /// Nobody opened it, changed it or put it here in over a year.
    public static func isUntouched(_ item: BrowserItem, now: Date = Date()) -> Bool {
        let latest = [item.lastOpened, item.modified, item.added].compactMap { $0 }.max()
        guard let latest else { return false }
        return now.timeIntervalSince(latest) > Double(untouchedDays) * 86_400
    }
}

/// Exact copies, checked byte for byte. A matching size or fingerprint is only a reason to look:
/// two files count as copies only when every byte is the same.
public enum ExactCopy {
    /// True only when both are different files with the same bytes (more than zero of them).
    public static func same(_ first: URL, _ second: URL, fileManager: FileManager = .default) -> Bool {
        guard first.standardizedFileURL.path != second.standardizedFileURL.path,
              let left = try? fileManager.attributesOfItem(atPath: first.path),
              let right = try? fileManager.attributesOfItem(atPath: second.path),
              (left[.type] as? FileAttributeType) == .typeRegular, (right[.type] as? FileAttributeType) == .typeRegular,
              let size = (left[.size] as? NSNumber)?.int64Value, size > 0,
              size == (right[.size] as? NSNumber)?.int64Value else { return false }
        // Two names for one file (a hard link) aren't a copy: trashing one would lose nothing, but it frees nothing either.
        if let leftNumber = left[.systemFileNumber] as? NSNumber, let rightNumber = right[.systemFileNumber] as? NSNumber,
           let leftDevice = left[.systemNumber] as? NSNumber, let rightDevice = right[.systemNumber] as? NSNumber,
           leftNumber == rightNumber, leftDevice == rightDevice { return false }
        guard let a = FileHandle(forReadingAtPath: first.path), let b = FileHandle(forReadingAtPath: second.path) else { return false }
        defer {
            try? a.close()
            try? b.close()
        }
        var compared: Int64 = 0
        while true {
            let left = (try? a.read(upToCount: 1 << 20)) ?? Data()
            let right = (try? b.read(upToCount: 1 << 20)) ?? Data()
            guard left == right else { return false }
            if left.isEmpty { return compared == size }
            compared += Int64(left.count)
        }
    }

    /// Groups of exact copies among `files` (same size, then every byte compared), each sorted by path.
    public static func groups(_ files: [URL], fileManager: FileManager = .default) -> [[URL]] {
        let sized = files.compactMap { url -> (path: String, size: Int64)? in
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  (attributes[.type] as? FileAttributeType) == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.int64Value else { return nil }
            return (path: url.path, size: size)
        }
        var result: [[URL]] = []
        for group in DuplicateFinder.sameSize(sized) {
            var left = group.map { URL(fileURLWithPath: $0) }
            while let first = left.first {
                let rest = left.dropFirst()
                let matches = rest.filter { same(first, $0, fileManager: fileManager) }
                if !matches.isEmpty { result.append([first] + matches) }
                let matched = Set(matches.map(\.path))
                left = rest.filter { !matched.contains($0.path) }
            }
        }
        return result.sorted { $0[0].path < $1[0].path }
    }
}

// MARK: - Folder peeks and sizes

public enum FolderPeek {
    /// "38 files: mostly PDFs and screenshots, newest from today". `categories` has one entry per file.
    public static func summary(categories: [FileCategory], folderCount: Int, newest: Date?, now: Date = Date(),
                               calendar: Calendar = .current) -> String {
        let files = categories.filter { $0 != .folders }
        if files.isEmpty && folderCount == 0 { return "Empty folder" }
        var counts: [String] = []
        if !files.isEmpty { counts.append("\(files.count) file\(files.count == 1 ? "" : "s")") }
        if folderCount > 0 { counts.append("\(folderCount) folder\(folderCount == 1 ? "" : "s")") }
        var text = counts.joined(separator: " and ")
        if !files.isEmpty {
            let tally = Dictionary(grouping: files, by: { $0 }).mapValues(\.count)
            let top = tally.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }
            if let first = top.first {
                let name = first.key.title.lowercased()
                if top.count == 1 {
                    text += files.count == 1 ? ": \(singular(first.key))" : ": all \(name)"
                } else if Double(first.value) / Double(files.count) >= 0.6 || top.count < 2 {
                    text += ": mostly \(name)"
                } else {
                    text += ": mostly \(name) and \(top[1].key.title.lowercased())"
                }
            }
        }
        if let newest { text += ", newest from \(ago(newest, now: now, calendar: calendar))" }
        return text
    }

    static func singular(_ category: FileCategory) -> String {
        switch category {
        case .receipts: return "a receipt"
        case .bankStatements: return "a bank statement"
        case .taxes: return "a tax file"
        case .contracts: return "a contract"
        case .travel: return "a ticket or booking"
        case .screenshots: return "a screenshot"
        case .pictures: return "a picture"
        case .recordings: return "a recording or video"
        case .installers: return "an installer"
        case .documents: return "a document"
        case .spreadsheets: return "a spreadsheet"
        case .presentations: return "a presentation"
        case .archives: return "an archive"
        case .code: return "code"
        case .folders, .other: return "a file"
        }
    }

    /// "today", "yesterday", "3 days ago", "Oct 3", "2024".
    public static func ago(_ date: Date, now: Date, calendar: Calendar) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 0 { return "today" }
        if days == 1 { return "yesterday" }
        if days < 7 { return "\(days) days ago" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "MMM d" : "yyyy"
        return formatter.string(from: date)
    }
}

public enum FolderSize {
    /// Everything inside a folder, added up (hidden files too, as Finder counts them). Stops early
    /// and returns nil when `isCancelled` says so.
    public static func total(of folder: URL, isCancelled: () -> Bool = { false }) -> Int64? {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [],
                                                          errorHandler: { _, _ in true }) else { return nil }
        var total: Int64 = 0
        var seen = 0
        while let url = walker.nextObject() as? URL {
            seen += 1
            if seen % 500 == 0, isCancelled() { return nil }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

// MARK: - Getting around

/// Back and Forward, like a browser.
public struct BrowserHistory: Equatable, Sendable {
    public private(set) var current: String
    public private(set) var back: [String] = []
    public private(set) var forward: [String] = []

    public init(start: String) {
        current = start
    }

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    public mutating func visit(_ path: String) {
        guard path != current else { return }
        back.append(current)
        if back.count > 100 { back.removeFirst() }
        forward = []
        current = path
    }

    public mutating func goBack() {
        guard let previous = back.popLast() else { return }
        forward.append(current)
        current = previous
    }

    public mutating func goForward() {
        guard let next = forward.popLast() else { return }
        back.append(current)
        current = next
    }
}

public struct PathStep: Equatable, Sendable {
    public let name: String
    public let path: String
}

public enum PathTrail {
    /// The folders from your home folder (or the disk) down to `path`, for the path bar.
    public static func steps(to path: String, home: String) -> [PathStep] {
        let clean = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        let homeClean = home.hasSuffix("/") ? String(home.dropLast()) : home
        if clean == homeClean || clean.hasPrefix(homeClean + "/") {
            var steps = [PathStep(name: "Home", path: homeClean)]
            var current = homeClean
            for part in clean.dropFirst(homeClean.count).split(separator: "/") {
                current += "/" + part
                steps.append(PathStep(name: String(part), path: current))
            }
            return steps
        }
        var steps = [PathStep(name: "Computer", path: "/")]
        var current = ""
        for part in clean.split(separator: "/") {
            current += "/" + part
            steps.append(PathStep(name: String(part), path: current))
        }
        return steps
    }

    /// True when `folder` is `other` or inside it.
    public static func isInside(_ folder: String, _ other: String) -> Bool {
        let base = other.hasSuffix("/") ? String(other.dropLast()) : other
        return folder == base || folder.hasPrefix(base + "/")
    }
}

/// The switch in System Settings › Privacy & Security that lets EchoNyla into a folder macOS keeps it out of.
public enum PrivacySwitch: Equatable, Sendable {
    /// A switch under Files & Folders, like "Desktop Folder".
    case filesAndFolders(String)
    case fullDiskAccess

    public static func forFolder(_ path: String, home: String) -> PrivacySwitch {
        let homeClean = home.hasSuffix("/") ? String(home.dropLast()) : home
        let places: [(String, String)] = [("Desktop", "Desktop Folder"), ("Documents", "Documents Folder"),
                                          ("Downloads", "Downloads Folder"), ("Library/Mobile Documents", "iCloud Drive")]
        for (folder, name) in places where PathTrail.isInside(path, homeClean + "/" + folder) {
            return .filesAndFolders(name)
        }
        if path.hasPrefix("/Volumes/") { return .filesAndFolders("Removable Volumes") }
        return .fullDiskAccess
    }

    /// What to do, in words: "Turn on Desktop Folder for EchoNyla in Files & Folders."
    public var advice: String {
        switch self {
        case .filesAndFolders(let name):
            return "Turn on “\(name)” for EchoNyla in Privacy & Security › Files & Folders."
        case .fullDiskAccess:
            return "Turn on EchoNyla in Privacy & Security › Full Disk Access (click + and choose it from Applications if it isn't listed)."
        }
    }
}

/// Selecting with the keyboard and with Shift: the run of items between where you started and where you are.
public enum SelectionRange {
    public static func between(_ anchor: String, _ end: String, in order: [String]) -> [String] {
        guard let start = order.firstIndex(of: anchor), let stop = order.firstIndex(of: end) else { return [end] }
        return Array(order[min(start, stop)...max(start, stop)])
    }

    /// The item `offset` steps from `current` (clamped to the list), or the first one.
    public static func step(from current: String?, by offset: Int, in order: [String]) -> String? {
        guard !order.isEmpty else { return nil }
        guard let current, let index = order.firstIndex(of: current) else { return offset < 0 ? order.last : order.first }
        return order[min(max(index + offset, 0), order.count - 1)]
    }
}

/// The folders numbered 1 to 9 for sorting with the keyboard: the ones you move files into most, then in your order.
public enum QuickSortFolders {
    public static func pick(_ ids: [String], uses: [String: Int], limit: Int = 9) -> [String] {
        let position = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        return Array(ids.sorted { lhs, rhs in
            let left = uses[lhs] ?? 0, right = uses[rhs] ?? 0
            return left != right ? left > right : (position[lhs] ?? 0) < (position[rhs] ?? 0)
        }.prefix(limit))
    }
}

// MARK: - What EchoNyla knows about a file

/// What Apple Intelligence (and the file itself) said about a file, kept so lists and the preview
/// pane can show it without asking again. It belongs to one version of the file (`ReviewedFiles.key`).
public struct FileInsight: Codable, Equatable, Sendable {
    public var summary: String
    public var proposedName: String?
    public var nameIsSure: Bool
    public var destinationID: String?
    public var folderIsSure: Bool
    public var reason: String
    public var names: [String]
    public var speech: String
    public var language: String?

    public init(summary: String, proposedName: String? = nil, nameIsSure: Bool = false, destinationID: String? = nil,
                folderIsSure: Bool = false, reason: String = "", names: [String] = [], speech: String = "", language: String? = nil) {
        self.summary = summary
        self.proposedName = proposedName
        self.nameIsSure = nameIsSure
        self.destinationID = destinationID
        self.folderIsSure = folderIsSure
        self.reason = reason
        self.names = names
        self.speech = speech.count > 600 ? String(speech.prefix(600)) + "…" : speech
        self.language = language
    }
}

public struct FileInsights: Codable, Equatable, Sendable {
    public static let limit = 3_000
    private var entries: [String: FileInsight] = [:]
    private var order: [String] = []

    public init() {}

    public var count: Int { entries.count }

    /// Every key, oldest first.
    public var keys: [String] { order }

    public func insight(for key: String) -> FileInsight? { entries[key] }

    public mutating func remove(_ key: String) {
        entries[key] = nil
        order.removeAll { $0 == key }
    }

    public mutating func set(_ insight: FileInsight, for key: String) {
        if entries[key] == nil { order.append(key) }
        entries[key] = insight
        while order.count > Self.limit {
            entries[order.removeFirst()] = nil
        }
    }

    public static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("EchoNyla", isDirectory: true).appendingPathComponent("file-insights.json")
    }

    public static func load(from url: URL = fileURL) -> FileInsights {
        guard let data = try? Data(contentsOf: url) else { return FileInsights() }
        return (try? JSONDecoder().decode(FileInsights.self, from: data)) ?? FileInsights()
    }

    public func save(to url: URL = fileURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
    }
}

// MARK: - History of each file

public struct FileHistoryEvent: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case moved, renamed, trashed
    }

    public var id: UUID
    public var date: Date
    public var kind: Kind
    public var from: String
    public var to: String
    public var isUndone: Bool

    public init(id: UUID = UUID(), date: Date = Date(), kind: Kind, from: String, to: String, isUndone: Bool = false) {
        self.id = id
        self.date = date
        self.kind = kind
        self.from = from
        self.to = to
        self.isUndone = isUndone
    }

    /// "Moved here from Downloads", "Renamed from IMG_4821.jpg", "Put in Trash from Desktop".
    public var text: String {
        let fromURL = URL(fileURLWithPath: from)
        switch kind {
        case .renamed: return "Renamed from \(fromURL.lastPathComponent)"
        case .moved: return "Moved here from \(fromURL.deletingLastPathComponent().lastPathComponent)"
        case .trashed: return "Moved to Trash from \(fromURL.deletingLastPathComponent().lastPathComponent)"
        }
    }

    public static func kind(from: String, to: String) -> Kind {
        let fromFolder = (from as NSString).deletingLastPathComponent
        let toFolder = (to as NSString).deletingLastPathComponent
        if fromFolder == toFolder { return .renamed }
        if to.contains("/.Trash/") || to.contains("/.Trashes/") { return .trashed }
        return .moved
    }
}

/// Every move, rename and trip to the Trash EchoNyla made, so the preview pane can say where a file
/// came from and what it used to be called. Activity keeps 200 entries; this keeps far more.
public struct FileHistory: Codable, Equatable, Sendable {
    public static let limit = 10_000
    public private(set) var events: [FileHistoryEvent] = []

    public init() {}

    public mutating func record(from: String, to: String, date: Date = Date()) {
        guard from != to else { return }
        events.append(FileHistoryEvent(date: date, kind: FileHistoryEvent.kind(from: from, to: to), from: from, to: to))
        if events.count > Self.limit { events.removeFirst(events.count - Self.limit) }
    }

    /// Marks the newest matching change as undone.
    public mutating func markUndone(from: String, to: String) {
        guard let index = events.lastIndex(where: { $0.from == from && $0.to == to && !$0.isUndone }) else { return }
        events[index].isUndone = true
    }

    /// What happened to the file now at `path`, newest first: each step leads to the one before.
    public func trail(for path: String, limit: Int = 20) -> [FileHistoryEvent] {
        var result: [FileHistoryEvent] = []
        var current = path
        var before = events.count
        while result.count < limit {
            guard let index = events[..<before].lastIndex(where: { $0.to == current && !$0.isUndone }) else { break }
            result.append(events[index])
            current = events[index].from
            before = index
        }
        return result
    }

    public static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("EchoNyla", isDirectory: true).appendingPathComponent("file-history.json")
    }

    public static func load(from url: URL = fileURL) -> FileHistory {
        guard let data = try? Data(contentsOf: url) else { return FileHistory() }
        return (try? JSONDecoder().decode(FileHistory.self, from: data)) ?? FileHistory()
    }

    public func save(to url: URL = fileURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
    }
}

// MARK: - Sizes in words

public enum ByteText {
    /// "12 KB", "3.4 MB", "1.2 GB" (decimal, as Finder shows them).
    public static func text(_ bytes: Int64) -> String {
        if bytes < 1_000 { return "\(bytes) bytes" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(bytes) / 1_000
        var unit = 0
        while value >= 1_000, unit < units.count - 1 {
            value /= 1_000
            unit += 1
        }
        let rounded = value >= 100 || unit == 0 ? String(format: "%.0f", value) : String(format: "%.1f", value)
        return "\(rounded) \(units[unit])"
    }
}
