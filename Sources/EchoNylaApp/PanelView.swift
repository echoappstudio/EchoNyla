import AppKit
import EchoNylaCore
import SwiftUI
import UniformTypeIdentifiers

/// The menu-bar panel: drop files on a folder or let EchoNyla sort them, see what happened, open the window.
struct PanelView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(NylaStyle.hairline).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    if let version = UpdateController.shared.updateWaiting {
                        Button {
                            UpdateController.shared.checkForUpdates()
                        } label: {
                            Label("EchoNyla \(version) is ready to install", systemImage: "arrow.down.circle.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(NylaStyle.brass)
                    }
                    folderTiles
                    SortDropZone()
                    if let count = model.tidyReminderCount {
                        tidyReminder(count)
                    }
                    if let pending = model.pending {
                        PendingCard(pending: pending)
                    }
                    if let status = model.statusMessage {
                        Label(status, systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    let waiting = model.openSuggestions
                    if !waiting.isEmpty {
                        SectionLabel("Waiting for you · \(waiting.count)")
                        ForEach(waiting.prefix(3)) { entry in
                            ActivityRow(entry: entry, compact: true)
                        }
                    }
                    let recent = model.activity.filter { $0.kind != .suggested }.prefix(4)
                    if !recent.isEmpty {
                        HStack {
                            SectionLabel("Recent")
                            Spacer()
                            if model.lastMove != nil {
                                Button("Undo Last Move") { model.undoLastMove() }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(NylaStyle.brass)
                            }
                        }
                        ForEach(Array(recent)) { entry in
                            ActivityRow(entry: entry, compact: true)
                        }
                    }
                    IntelligenceStatus()
                }
                .padding(16)
            }
            Rectangle().fill(NylaStyle.hairline).frame(height: 1)
            footer
        }
        .frame(width: 400, height: 600)
        .background(WindowBackground().ignoresSafeArea())
        .nylaChrome()
        .alert("EchoNyla", isPresented: Binding(
            get: { model.userError != nil },
            set: { if !$0 { model.userError = nil } }
        )) {
            Button("OK", role: .cancel) { model.userError = nil }
        } message: {
            Text(model.userError ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: SkinStore.shared.iconImage(for: SkinStore.shared.skin))
                .resizable()
                .interpolation(.high)
                .frame(width: 30, height: 30)
            Text("EchoNyla")
                .font(.system(size: 17, weight: .semibold))
            Spacer()
            Menu {
                Button("Clean Up Downloads…") {
                    model.startDownloadsCleanup()
                    MainWindowController.shared.show(.cleanup)
                }
                Button("Find a File…") { MainWindowController.shared.show(.find) }
                Divider()
                Button("Settings…") { MainWindowController.shared.show(.settings) }
                Button("Folders & Rules…") { MainWindowController.shared.show(.folders) }
                Button("Check for Updates…") { UpdateController.shared.checkForUpdates() }
                    .disabled(!UpdateController.shared.canCheckForUpdates)
                Divider()
                Button("Quit EchoNyla") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button {
                StatusItemController.shared.hidePanel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Close (Esc). The panel stays open until you close it.")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    /// Your favorite folders as drop targets: a file dropped on a tile goes straight there.
    @ViewBuilder
    private var folderTiles: some View {
        SectionLabel("Drop on a folder")
        if model.favoriteFolders.isEmpty {
            HStack(spacing: 8) {
                Caption("No favorite folders yet.")
                Spacer(minLength: 4)
                Button("Suggest Folders…") { MainWindowController.shared.showSetup() }
                    .buttonStyle(.pill)
                Button("Add…") { model.addFavoriteFromPanel() }
                    .buttonStyle(.pill)
            }
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(model.favoriteFolders) { folder in
                    FolderTile(folder: folder)
                }
            }
        }
    }

    private func tidyReminder(_ count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.full")
                .foregroundStyle(NylaStyle.brass)
            Text(TidyReminder.message(count: count))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Review") {
                model.startDownloadsCleanup()
                MainWindowController.shared.show(.cleanup)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .semibold))
            Button {
                model.dismissTidyReminder()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Hide for a week")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(NylaStyle.wash(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    /// One clear action: open the full window, with Quit beside it. Clean Up and Find are in the ⋯ menu.
    private var footer: some View {
        HStack {
            Spacer()
            Button {
                MainWindowController.shared.show(.activity)
            } label: {
                Label("Open EchoNyla", systemImage: "macwindow")
            }
            .buttonStyle(.brass)
            Spacer()
        }
        .overlay(alignment: .trailing) { QuitButton() }
        .padding(12)
    }
}

/// A favorite folder in the panel. Files dropped on it are moved there right away, with Undo.
struct FolderTile: View {
    @Environment(AppModel.self) private var model
    let folder: FavoriteFolder
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(for: .folder))
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
            Text(folder.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(isTargeted ? "Release to move" : FolderTileCaption.text(destinationID: folder.id, activity: model.activity))
                .font(.system(size: 10.5))
                .foregroundStyle(isTargeted ? Color.primary : Color.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: 11, hovering: isTargeted)
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(NylaStyle.brass, lineWidth: isTargeted ? 1.5 : 0)
        )
        .scaleEffect(isTargeted ? 1.03 : 1)
        .animation(.easeOut(duration: 0.12), value: isTargeted)
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            let id = folder.id
            return loadFileURLs(from: providers) { urls in AppModel.shared.receiveDrops(urls, into: id) }
        }
        .help(folder.purpose.map { "\(folder.name): \($0)" } ?? "Drop files here to move them to \(folder.name)")
        .accessibilityLabel("Drop files to move them to \(folder.name)")
    }
}

/// "Or drop here and let EchoNyla sort it": the files it's sure about are filed, the rest wait for you.
struct SortDropZone: View {
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(NylaStyle.wash(isTargeted ? 0.12 : 0.06))
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(NylaStyle.brass)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(isTargeted ? "Release to sort" : "Or drop here and let EchoNyla sort it")
                    .font(.system(size: 13, weight: .semibold))
                Text(model.autoMove ? "Files it's sure about are filed right away, with Undo. The rest wait for you."
                     : "Nothing moves until you choose a folder.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .cardSurface(radius: 13, hovering: isTargeted)
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(NylaStyle.brass, lineWidth: isTargeted ? 1.5 : 0)
        )
        .animation(.easeOut(duration: 0.12), value: isTargeted)
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            loadFileURLs(from: providers) { urls in AppModel.shared.receiveDrops(urls) }
        }
        .accessibilityLabel("Drop files to sort them")
    }
}

/// Reads the file URLs of one drop, then hands them over together on the main actor.
@MainActor
func loadFileURLs(from providers: [NSItemProvider], then handle: @escaping @MainActor ([URL]) -> Void) -> Bool {
    let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
    guard !fileProviders.isEmpty else { return false }
    let collector = DropCollector(expected: fileProviders.count)
    for provider in fileProviders {
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let value = item as? URL {
                url = value
            } else if let value = item as? NSURL {
                url = value as URL
            } else if let value = item as? String {
                url = URL(string: value)
            } else {
                url = nil
            }
            Task { @MainActor in
                if let urls = collector.add(url) { handle(urls) }
            }
        }
    }
    return true
}

/// Collects the URLs of one multi-file drop, then hands them over together.
@MainActor
final class DropCollector {
    private let expected: Int
    private var received = 0
    private var urls: [URL] = []

    init(expected: Int) {
        self.expected = expected
    }

    func add(_ url: URL?) -> [URL]? {
        received += 1
        if let url { urls.append(url) }
        return received == expected ? urls : nil
    }
}

/// A file dropped on the sort area that's waiting for a decision.
struct PendingCard: View {
    @Environment(AppModel.self) private var model
    let pending: PendingFile

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                FileTypeIcon(fileName: pending.url.lastPathComponent, path: pending.url.path, size: 30)
                    .filePreview(pending.url)
                Text(pending.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.subheadline.weight(.medium))
                    .filePreview(pending.url)
                Spacer(minLength: 6)
                Button { model.cancelPendingDrop() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel")
            }
            if pending.isThinking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Caption("Looking at this file…")
                }
            } else {
                if let reason = pending.reason {
                    let name = model.destinationName(for: pending.suggestionID)
                    Label(name.map { "Suggested: \($0). \(reason)" } ?? reason, systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let summary = pending.summary, !summary.isEmpty {
                    Caption(summary)
                }
                if let proposed = pending.proposedName {
                    Toggle("Rename to “\(proposed)”", isOn: $model.renamePendingFirst)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
                FlowLayout(spacing: 8) {
                    if let suggestion = pending.suggestionID, let name = model.destinationName(for: suggestion) {
                        Button("Move to \(name)") { model.movePending(to: suggestion) }
                            .buttonStyle(.brass)
                    }
                    Menu(pending.suggestionID == nil ? "Move to…" : "Other Folder") {
                        ForEach(model.favoriteFolders) { folder in
                            Button(folder.name) { model.movePending(to: folder.id) }
                        }
                        if !model.favoriteFolders.isEmpty { Divider() }
                        Button("Any Folder…") { model.movePendingToChosenFolder() }
                    }
                    .fixedSize()
                }
                .buttonStyle(.pill)
            }
        }
        .padding(12)
        .cardSurface(radius: 12)
    }
}
