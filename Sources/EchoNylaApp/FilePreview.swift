import AppKit
import EchoNylaCore
import QuickLook
import QuickLookThumbnailing
import SwiftUI

extension View {
    /// The same on every file EchoNyla shows: one click selects the file and shows it in the preview
    /// pane, a double-click opens it in its app, resting the pointer shows a small card about it, and
    /// Space (or a firm press on the trackpad) opens Quick Look. Controls in the row keep working.
    /// `highlights` lights the row under the pointer (off for rows that already do). In the menu-bar
    /// panel, which has no preview pane, `clickQuickLooks` makes one click open Quick Look instead.
    func filePreview(_ url: URL, highlights: Bool = true, clickQuickLooks: Bool = false) -> some View {
        modifier(FilePreviewModifier(url: url, highlights: highlights, clickQuickLooks: clickQuickLooks))
    }

    /// The hover card, Space and the firm press for one file or folder, without the clicks (the Files
    /// area handles its own clicks for selecting several files).
    func fileHoverCard(_ url: URL, isFolder: Bool = false) -> some View {
        modifier(FileHoverCardModifier(url: url, isFolder: isFolder))
    }
}

struct FilePreviewModifier: ViewModifier {
    let url: URL
    let highlights: Bool
    let clickQuickLooks: Bool
    @Environment(AppModel.self) private var model
    @State private var hovering = false
    @State private var quickLook: URL?

    func body(content: Content) -> some View {
        let selected = !clickQuickLooks && model.previewURL?.standardizedFileURL == url.standardizedFileURL
        content
            .contentShape(Rectangle())
            .background {
                if highlights || selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? NylaStyle.brass.opacity(0.14) : Color.primary.opacity(hovering ? 0.06 : 0))
                        .padding(-2)
                }
            }
            // One tap gesture, not a single and a double one: SwiftUI would hold every single click
            // back to see whether a second follows. The click count tells them apart.
            .onTapGesture { clicked() }
            .onHover { hovering = $0 }
            .fileHoverCard(url)
            .quickLookPreview($quickLook)
            .help(clickQuickLooks ? "Click to preview · Double-click to open" : "Click to select · Space to preview · Double-click to open")
            .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private func clicked() {
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSSound.beep()
            return
        }
        // A click in a list puts the typing cursor away, so the arrow keys and Space reach the files.
        if NSApp.keyWindow?.firstResponder is NSText { NSApp.keyWindow?.makeFirstResponder(nil) }
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
            quickLook = nil
            NSWorkspace.shared.open(url)
        } else if clickQuickLooks {
            quickLook = url
        } else {
            model.select(url)
        }
    }
}

struct FileHoverCardModifier: ViewModifier {
    let url: URL
    let isFolder: Bool
    /// How long the pointer rests before the card shows. Its picture is made from the moment the
    /// pointer arrives, so it's usually ready by then.
    static let restBeforeCard: Duration = .milliseconds(500)

    @State private var quickLook: URL?
    @State private var showing = false
    @State private var waiting: Task<Void, Never>?
    @State private var token = UUID()
    @State private var hovering = false
    @State private var width: CGFloat = 1
    @State private var pointerX: CGFloat = 0
    /// Where along the row the card points (where the pointer was when it showed).
    @State private var cardX: CGFloat = 0.5

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max($0, 1) }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    pointerX = location.x
                    if !hovering { pointerArrived() }
                case .ended:
                    pointerLeft()
                }
            }
            .onDisappear { pointerLeft() }
            .popover(isPresented: $showing, attachmentAnchor: .point(UnitPoint(x: cardX, y: 0)), arrowEdge: .top) {
                FileHoverCard(url: url, isFolder: isFolder)
            }
            .quickLookPreview($quickLook)
    }

    private func showQuickLook() {
        closeCard()
        if FileManager.default.fileExists(atPath: url.path) { quickLook = url } else { NSSound.beep() }
    }

    /// The card waits for a short rest, so moving the pointer down a list doesn't flash one for every file.
    private func pointerArrived() {
        hovering = true
        FilePreviewKeys.shared.hovering(token) { showQuickLook() }
        waiting?.cancel()
        let url = url
        if !isFolder { Task { @MainActor in _ = await FilePeekImages.image(for: url) } }
        waiting = Task { @MainActor in
            try? await Task.sleep(for: Self.restBeforeCard)
            guard !Task.isCancelled, quickLook == nil, FilePreviewKeys.shared.isPointerStill else { return }
            cardX = min(max(pointerX / width, 0.05), 0.95)
            showing = true
        }
    }

    private func pointerLeft() {
        hovering = false
        FilePreviewKeys.shared.left(token)
        closeCard()
    }

    private func closeCard() {
        waiting?.cancel()
        waiting = nil
        showing = false
    }
}

/// The small card that shows after the pointer rests on a file: its picture, name, kind, size and
/// date, what Apple Intelligence said it is (if it already looked), and where it belongs. On a
/// folder: what's inside it.
struct FileHoverCard: View {
    let url: URL
    let isFolder: Bool
    @Environment(AppModel.self) private var model
    @State private var picture: NSImage?
    @State private var details: FileDetails?
    @State private var peek: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let picture {
                    Image(nsImage: picture)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 236, maxHeight: 170)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else if isFolder {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 56, height: 56)
                } else {
                    FileTypeIcon(fileName: url.lastPathComponent, path: url.path, size: 56)
                }
            }
            .frame(maxWidth: .infinity)
            Text(url.lastPathComponent)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .truncationMode(.middle)
            if let details {
                Text(details.line)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if isFolder {
                Text(peek ?? "Looking inside…")
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            } else if let summary = model.insight(for: url)?.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 12))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !isFolder, let suggestion = model.quickSuggestion(for: url) {
                Label("Belongs in \(suggestion.folderName)" + (suggestion.isSure ? "" : "?"), systemImage: "folder")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(NylaStyle.brass)
            }
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
        .task(id: url) {
            details = await FileDetails.read(url)
            if isFolder {
                peek = await FolderPeeks.summary(of: url)
            } else {
                picture = await FilePeekImages.image(for: url)
            }
        }
    }
}

/// Size, kind and dates of a file, read away from the screen's thread.
struct FileDetails: Equatable, Sendable {
    var kindText: String
    var byteCount: Int64?
    var created: Date?
    var modified: Date?
    var added: Date?
    var lastOpened: Date?
    var isFolder: Bool

    /// "PDF document · 2.3 MB · Oct 3, 2026".
    var line: String {
        var parts = [kindText]
        if let byteCount, !isFolder { parts.append(ByteText.text(byteCount)) }
        if let modified { parts.append(modified.formatted(date: .abbreviated, time: .omitted)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func read(_ url: URL) async -> FileDetails? {
        await Task.detached(priority: .userInitiated) { readNow(url) }.value
    }

    static func readNow(_ url: URL) -> FileDetails? {
        let keys: Set<URLResourceKey> = [.localizedTypeDescriptionKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey,
                                         .addedToDirectoryDateKey, .isDirectoryKey, .isPackageKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        return FileDetails(kindText: values.localizedTypeDescription ?? "", byteCount: values.fileSize.map { Int64($0) },
                           created: values.creationDate, modified: values.contentModificationDate, added: values.addedToDirectoryDate,
                           lastOpened: lastOpened(url), isFolder: values.isDirectory == true && values.isPackage != true)
    }

    /// When the file was last opened, from Spotlight.
    static func lastOpened(_ url: URL) -> Date? {
        NSMetadataItem(url: url)?.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date
    }
}

/// "38 files: mostly PDFs and screenshots, newest from today", kept while EchoNyla runs.
@MainActor
enum FolderPeeks {
    private static var cache: [String: String] = [:]

    static func summary(of folder: URL) async -> String {
        let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = folder.path + "|" + String(modified?.timeIntervalSince1970 ?? 0)
        if let cached = cache[key] { return cached }
        let text = await Task.detached(priority: .userInitiated) { summaryNow(folder) }.value
        if cache.count >= 200 { cache.removeAll() }
        cache[key] = text
        return text
    }

    nonisolated static func summaryNow(_ folder: URL) -> String {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                          options: [.skipsHiddenFiles]) else {
            return "EchoNyla can't look inside this folder."
        }
        var categories: [FileCategory] = []
        var folders = 0
        var newest: Date?
        for url in contents.prefix(5_000) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true && values?.isPackage != true {
                folders += 1
                continue
            }
            let name = url.lastPathComponent
            let looksLikeScreenshot = name.lowercased().hasPrefix("screenshot") || name.lowercased().hasPrefix("screen shot")
            categories.append(FileCategory.of(name: name, isFolder: false, isScreenshot: looksLikeScreenshot))
            if let date = values?.contentModificationDate, date > (newest ?? .distantPast) { newest = date }
        }
        return FolderPeek.summary(categories: categories, folderCount: folders, newest: newest)
    }
}

/// Space opens Quick Look, as in Finder (unless you're typing): for the file under the pointer when
/// you moved there last, otherwise for the selected file. A firm press on the trackpad does the same.
@MainActor
final class FilePreviewKeys {
    static let shared = FilePreviewKeys()
    private var hovered: (token: UUID, open: () -> Void)?
    private var hoveredAt = Date.distantPast
    private var selectedAt = Date.distantPast
    private var keyMonitor: Any?
    private var pressureMonitor: Any?
    private var mouseMonitor: Any?
    private var lastStage = 0
    private var lastMove = Date.distantPast
    /// Opens Quick Look for the selected file; false when there's none.
    var openSelected: (() -> Bool)?

    /// True once the pointer has stayed put a moment (scrolling a list moves rows, not the pointer,
    /// so the card still waits for a real rest).
    var isPointerStill: Bool { Date().timeIntervalSince(lastMove) > 0.12 }

    func hovering(_ token: UUID, open: @escaping () -> Void) {
        hovered = (token, open)
        hoveredAt = Date()
        installMonitors()
    }

    func left(_ token: UUID) {
        if hovered?.token == token { hovered = nil }
    }

    /// Called when a file is selected, so Space then previews it rather than one the pointer rested on earlier.
    func selectionChanged() {
        selectedAt = Date()
        installMonitors()
    }

    private func installMonitors() {
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let isSpace = event.keyCode == 49 && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
                guard isSpace, !event.isARepeat else { return event }
                let opened = MainActor.assumeIsolated { FilePreviewKeys.shared.openPreview() }
                return opened ? nil : event
            }
        }
        if pressureMonitor == nil {
            pressureMonitor = NSEvent.addLocalMonitorForEvents(matching: .pressure) { event in
                let stage = event.stage
                MainActor.assumeIsolated {
                    let keys = FilePreviewKeys.shared
                    if stage >= 2, keys.lastStage < 2 { _ = keys.openPreview(fromPress: true) }
                    keys.lastStage = stage
                }
                return event
            }
        }
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
                MainActor.assumeIsolated { FilePreviewKeys.shared.lastMove = Date() }
                return event
            }
        }
    }

    /// Opens Quick Look; false when there's nothing to preview or you're typing. A firm press always
    /// means the file under the pointer.
    private func openPreview(fromPress: Bool = false) -> Bool {
        guard !(NSApp.keyWindow?.firstResponder is NSText) else { return false }
        if let hovered, fromPress || hoveredAt >= selectedAt {
            hovered.open()
            return true
        }
        guard !fromPress else { return false }
        return openSelected?() ?? false
    }
}

/// Pictures of files for the hover card and the preview pane, from Quick Look, kept while EchoNyla runs.
@MainActor
enum FilePeekImages {
    static let side: CGFloat = 260
    private static var cache: [String: NSImage] = [:]

    /// Nil for files Quick Look can't draw (their icon already says what they are).
    static func image(for url: URL, side: CGFloat = side) async -> NSImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = url.path + "|" + String(modified?.timeIntervalSince1970 ?? 0) + "|" + String(Int(side))
        if let cached = cache[key] { return cached }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        guard let picture = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        if cache.count >= 300 { cache.removeAll() }
        cache[key] = picture.nsImage
        return picture.nsImage
    }
}
