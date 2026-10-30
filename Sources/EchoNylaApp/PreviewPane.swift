import AppKit
import EchoNylaCore
import SwiftUI

/// The preview pane on the right of every page with files: a big picture of the file you clicked,
/// what it is, the people, places and companies in it, the words spoken at the start of a
/// recording, its details, and what EchoNyla did to it (with Undo).
struct PreviewPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("PREVIEW")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Spacer()
                BarButton(symbol: "xmark", help: "Hide the preview pane") { model.togglePreviewPane() }
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .frame(height: 38)
            Rectangle().fill(NylaStyle.hairline).frame(height: 1)
            if let url = model.previewURL, model.previewSelectionCount <= 1 {
                PreviewPaneContent(url: url)
                    .id(url)
            } else if model.previewSelectionCount > 1 {
                placeholder("\(model.previewSelectionCount) items selected", systemImage: "square.stack.3d.up",
                            detail: "Drag them, press 1 to 9 to move them, or right-click for more.")
            } else {
                placeholder("Click a file to see it here", systemImage: "eye",
                            detail: "Space or a firm press opens the full preview. Double-click opens the file.")
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(NylaStyle.raised(0.02))
    }

    private func placeholder(_ title: String, systemImage: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PreviewPaneContent: View {
    let url: URL
    @Environment(AppModel.self) private var model
    @State private var picture: NSImage?
    @State private var details: FileDetails?
    @State private var peek: String?
    @State private var folderSize: Int64?
    @State private var missing = false
    @State private var showAllWords = false

    private var isFolder: Bool { details?.isFolder ?? false }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if missing {
                    Caption("This file isn't here anymore. It may have been moved or renamed.")
                } else {
                    pictureView
                    nameBlock
                    actions
                    if isFolder {
                        folderBlock
                    } else if details != nil {
                        whatItIs
                        suggestions
                        namesInside
                        spokenWords
                    }
                    detailsBlock
                    historyBlock
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: url) {
            guard let read = await FileDetails.read(url) else {
                missing = true
                return
            }
            details = read
            if read.isFolder {
                peek = await FolderPeeks.summary(of: url)
                let folder = url
                folderSize = await Task.detached(priority: .utility) { FolderSize.total(of: folder) }.value
            } else {
                picture = await FilePeekImages.image(for: url, side: 520)
            }
        }
    }

    // MARK: Parts

    private var pictureView: some View {
        Group {
            if let picture {
                Image(nsImage: picture)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
            } else if isFolder {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 96, height: 96)
                    .frame(maxWidth: .infinity)
            } else {
                FileTypeIcon(fileName: url.lastPathComponent, path: url.path, size: 96)
                    .frame(maxWidth: .infinity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.open(url) }
        .help("Double-click to open. Space opens the full preview.")
    }

    private var nameBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(url.lastPathComponent)
                .font(.system(size: 14, weight: .semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let details {
                Text(details.line)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button("Open") { model.open(url) }
            Button("Quick Look", systemImage: "eye") { model.quickLookSelected() }
                .labelStyle(.iconOnly)
                .help("Full preview (Space)")
            Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .labelStyle(.iconOnly)
                .help("Show in Finder")
        }
        .buttonStyle(.pill)
    }

    @ViewBuilder
    private var folderBlock: some View {
        PaneSection("Inside") {
            Text(peek ?? "Looking inside…")
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
            Text(folderSize.map { ByteText.text($0) + " in all" } ?? "Adding up its size…")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            FolderThumbnails(folder: url)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var whatItIs: some View {
        let insight = model.insight(for: url)
        PaneSection("What it is") {
            if let summary = insight?.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.paneReading || model.paneAsking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Caption(model.paneReading ? "Reading the file…" : "Apple Intelligence is looking at it…")
                }
            } else if let reason = model.aiUnavailableReason {
                Caption("Apple Intelligence can describe files once it's on. \(reason)")
            } else {
                Caption("Apple Intelligence couldn't tell what this file is.")
            }
            if model.aiReady, insight != nil, !model.paneAsking {
                Button("Ask Again") { model.askAgainForPane() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var suggestions: some View {
        let insight = model.insight(for: url)
        let suggestion = model.quickSuggestion(for: url)
        let name = insight?.proposedName.flatMap { $0 == url.lastPathComponent ? nil : $0 }
        if name != nil || suggestion != nil {
            PaneSection("Suggestions") {
                if let name, let insight {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name)
                            .font(.system(size: 12.5, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Caption(insight.nameIsSure ? "A sure name" : "A name it isn't sure about")
                            Spacer()
                            Button("Rename") { model.renameItem(url, to: name) }
                                .buttonStyle(.pill)
                        }
                    }
                }
                if let suggestion {
                    HStack(spacing: 8) {
                        Label(suggestion.folderName + (suggestion.isSure ? "" : " (a guess)"), systemImage: "folder")
                            .font(.system(size: 12.5, weight: .medium))
                        Spacer()
                        Button("Move") { model.moveItems([url], toFavorite: suggestion.destinationID) }
                            .buttonStyle(.pill)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var namesInside: some View {
        let names = paneFacts?.names ?? model.insight(for: url)?.names ?? []
        if !names.isEmpty {
            PaneSection("Names in it") {
                Text(names.prefix(12).joined(separator: " · "))
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var spokenWords: some View {
        let kind = FileKind.from(fileExtension: url.pathExtension)
        if kind == .audio || kind == .video {
            let words = paneFacts?.speech ?? model.insight(for: url)?.speech ?? ""
            PaneSection("Spoken in the first minute") {
                if !words.isEmpty {
                    Text(words)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .lineLimit(showAllWords ? nil : 6)
                        .fixedSize(horizontal: false, vertical: true)
                    if words.count > 280 {
                        Button(showAllWords ? "Show Less" : "Show All") { showAllWords.toggle() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                } else if model.paneReading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Caption("Listening…")
                    }
                } else if !model.readContents {
                    Caption("Turn on Look inside files (Settings) to hear what's said.")
                } else {
                    Caption("No words were heard.")
                }
            }
        }
    }

    @ViewBuilder
    private var detailsBlock: some View {
        if let details {
            PaneSection("Details") {
                detailRow("Kind", details.kindText)
                if let size = details.byteCount, !details.isFolder { detailRow("Size", ByteText.text(size)) }
                if let date = details.created { detailRow("Created", date.formatted(date: .abbreviated, time: .shortened)) }
                if let date = details.modified { detailRow("Modified", date.formatted(date: .abbreviated, time: .shortened)) }
                if let date = details.added { detailRow("Added", date.formatted(date: .abbreviated, time: .shortened)) }
                if let date = details.lastOpened { detailRow("Last opened", date.formatted(date: .abbreviated, time: .shortened)) }
                if let pages = paneFacts?.pageCount { detailRow("Pages", "\(pages)") }
                if let sources = paneFacts?.downloadedFrom, !sources.isEmpty { detailRow("From", sources.joined(separator: ", ")) }
                if let language = paneFacts?.language ?? model.insight(for: url)?.language { detailRow("Language", language) }
            }
        }
    }

    @ViewBuilder
    private var historyBlock: some View {
        let trail = model.historyTrail(for: url)
        if !trail.isEmpty {
            PaneSection("History") {
                ForEach(Array(trail.enumerated()), id: \.element.id) { index, event in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.text)
                                .font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(event.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 4)
                        if index == 0 {
                            Button("Undo") { model.undoHistory(event) }
                                .buttonStyle(.borderless)
                                .font(.caption)
                                .help("Put it back where it was, with its old name")
                        }
                    }
                }
            }
        }
    }

    // MARK: Helpers

    /// The facts read for this file, once the pane has read them.
    private var paneFacts: FileFacts? {
        model.paneFactsPath == url.path ? model.paneFacts : nil
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A small heading and what's under it, in the preview pane.
/// The newest files in a folder with real pictures, so you can see what's in it without opening it.
/// One click shows a file big in the pane; a double-click on the folder's picture opens it in Files.
struct FolderThumbnails: View {
    let folder: URL
    @Environment(AppModel.self) private var model
    @State private var files: [URL] = []
    @State private var pictures: [URL: NSImage] = [:]

    static let limit = 12

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 6)], spacing: 6) {
            ForEach(files, id: \.self) { file in
                tile(file)
            }
        }
        .task(id: folder) {
            files = await Task.detached(priority: .userInitiated) { Self.newestFiles(in: folder) }.value
            for file in files {
                if Task.isCancelled { return }
                if let picture = await FilePeekImages.image(for: file, side: 180) { pictures[file] = picture }
            }
        }
    }

    private func tile(_ file: URL) -> some View {
        ZStack {
            if let picture = pictures[file] {
                Image(nsImage: picture)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                FileTypeIcon(fileName: file.lastPathComponent, path: file.path, size: 40)
            }
        }
        .frame(width: 76, height: 76)
        .background(NylaStyle.wash(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { model.select(file) }
        .help(file.lastPathComponent)
    }

    /// The newest files in the folder. A folder holding only folders (like Pictures with an album per trip)
    /// shows the newest files from the folders inside it instead.
    nonisolated static func newestFiles(in folder: URL) -> [URL] {
        let (files, folders) = contents(of: folder)
        if !files.isEmpty { return newest(files) }
        return newest(folders.prefix(40).flatMap { contents(of: $0).files })
    }

    private nonisolated static let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .contentModificationDateKey]

    private nonisolated static func contents(of folder: URL) -> (files: [(URL, Date)], folders: [URL]) {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                          options: [.skipsHiddenFiles]) else { return ([], []) }
        var files: [(URL, Date)] = []
        var folders: [URL] = []
        for url in contents.prefix(5_000) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true {
                files.append((url, values?.contentModificationDate ?? .distantPast))
            } else if values?.isDirectory == true, values?.isPackage != true {
                folders.append(url)
            }
        }
        return (files, folders)
    }

    private nonisolated static func newest(_ files: [(URL, Date)]) -> [URL] {
        files.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}

struct PaneSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
