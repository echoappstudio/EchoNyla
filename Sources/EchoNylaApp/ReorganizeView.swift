import AppKit
import EchoNylaCore
import SwiftUI

/// Deep Reorganize: Apple Intelligence goes through whole folders, names files and moves the sure ones
/// into your Sort-into folders. Everything else waits here, with suggested new folders and exact duplicates.
struct ReorganizeTab: View {
    @Environment(AppModel.self) private var model
    @State private var confirmStart = false
    @State private var confirmApply = false
    @State private var confirmUndo = false

    var body: some View {
        Page(title: "Deep Reorganize", subtitle: "Apple Intelligence goes through whole folders. Files it's sure about get a clear name and move into your Sort-into folders by themselves; the rest wait here. Undo All puts everything back.") {
            if let reason = model.aiUnavailableReason {
                Card { Caption("Deep Reorganize needs Apple Intelligence. \(reason)") }
            }
            ReorganizeFoldersCard(skip: false)
            ReorganizeFoldersCard(skip: true)
            targetsNote
            copiesSetting
            controls
            if let run = model.reorganizeRun, run.hasChanges {
                lastRun(run)
            }
            ReorganizeResults(confirmApply: $confirmApply)
        }
    }

    @ViewBuilder
    private var targetsNote: some View {
        let targets = model.checkableFolders.map(\.name)
        if targets.isEmpty {
            Caption("No Sort-into folders yet, so it can only rename files and suggest new folders. Set some up in Folders & Rules.")
        } else {
            Caption("Files go into your Sort-into folders: \(targets.joined(separator: ", ")). Those folders' own files are left alone.")
        }
    }

    private var copiesSetting: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 4) {
            SettingToggle("Move exact copies to Trash by themselves", isOn: $model.trashExactCopies)
            Caption("Only files whose every byte is the same as another file it went through. The one with the clearest name (or the oldest) stays. Undo All brings the copies back. This only happens in Deep Reorganize.")
        }
    }

    @ViewBuilder
    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                switch model.reorganizeStatus {
                case .running:
                    Button("Pause", systemImage: "pause.fill") { model.pauseReorganize() }
                        .buttonStyle(.pill)
                    Button("Stop", systemImage: "stop.fill") { model.stopReorganize() }
                        .buttonStyle(.pill)
                case .paused:
                    Button("Resume", systemImage: "play.fill") { model.resumeReorganize() }
                        .buttonStyle(.brass)
                    Button("Stop", systemImage: "stop.fill") { model.stopReorganize() }
                        .buttonStyle(.pill)
                case .idle, .finished:
                    Button("Start Deep Reorganize", systemImage: "wand.and.stars") { confirmStart = true }
                        .buttonStyle(.brass)
                        .disabled(!model.aiReady || model.reorganizeFolders.isEmpty)
                        .confirmationDialog("Start Deep Reorganize?", isPresented: $confirmStart, titleVisibility: .visible) {
                            Button("Start") { model.startReorganize() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text(startMessage)
                        }
                }
                Spacer()
            }
            if model.reviewedCount > 0 {
                HStack(spacing: 8) {
                    Caption(skippedText)
                    Button("Look at All Files Again") { model.forgetReviewedFiles() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .disabled(model.isReorganizing)
                }
            }
            if model.isReorganizing {
                if model.reorganizeTotal > 0 {
                    ProgressView(value: Double(model.reorganizeDone), total: Double(max(model.reorganizeTotal, 1)))
                }
                Caption(progressText)
            }
        }
    }

    private var startMessage: String {
        var text = model.autoMove
            ? "Sure files are renamed and moved by themselves; everything else waits on this page. You can pause it. Undo All puts everything back."
            : "Moving by itself is off in Settings, so files are only renamed when Apple Intelligence is sure; every move waits on this page. Undo All puts everything back."
        if model.reorganizeRun?.hasChanges == true {
            text += " Starting again replaces the last run's Undo All."
        }
        return text
    }

    private var skippedText: String {
        let skipped = model.reorganizeSkipped
        let base = "Files it already named, or that you approved or left as they are, are skipped until they change."
        return skipped > 0 ? base + " Skipped \(skipped) last run." : base
    }

    private var progressText: String {
        let count = model.reorganizeTotal > 0 ? "\(model.reorganizeDone) of \(model.reorganizeTotal) files" : ""
        let parts = [count, model.reorganizeCurrent ?? "", model.reorganizeTimeLeft ?? "",
                     model.reorganizeStatus == .paused ? "Paused" : ""].filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }

    private func lastRun(_ run: ReorganizeRun) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(NylaStyle.brass)
            VStack(alignment: .leading, spacing: 2) {
                Text("Last run: moved \(run.moved), renamed \(run.renamed)"
                     + ((run.trashed ?? 0) > 0 ? ", \(run.trashed ?? 0) exact cop\((run.trashed ?? 0) == 1 ? "y" : "ies") to Trash" : ""))
                    .font(.callout.weight(.medium))
                Caption("Started \(run.started.formatted(date: .abbreviated, time: .shortened)).")
            }
            Spacer()
            Button("Undo All", systemImage: "arrow.uturn.backward") { confirmUndo = true }
                .buttonStyle(.pill)
                .disabled(model.isReorganizing)
                .confirmationDialog("Put back everything from this run?", isPresented: $confirmUndo, titleVisibility: .visible) {
                    Button("Undo All") { model.undoReorganizeRun() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Every file goes back to where it was, with its old name. Folders it made are removed if they're empty.")
                }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

/// The folders to go through, or the folders to leave alone.
struct ReorganizeFoldersCard: View {
    @Environment(AppModel.self) private var model
    let skip: Bool

    var body: some View {
        let folders = skip ? model.reorganizeSkipFolders : model.reorganizeFolders
        GroupBox(skip ? "Don't touch" : "Go through these folders") {
            VStack(alignment: .leading, spacing: 8) {
                Caption(skip ? "Nothing in these folders, or in folders inside them, is renamed or moved."
                        : "Every file in these folders and the folders inside them, up to \(ReorganizeScope.fileLimit) files a run.")
                ForEach(folders) { folder in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(for: .folder))
                            .resizable()
                            .frame(width: 18, height: 18)
                        Text(folder.name)
                        Caption(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer()
                        Button("Remove") { model.removeReorganizeFolder(path: folder.path, skip: skip) }
                            .buttonStyle(.borderless)
                            .disabled(model.isReorganizing)
                    }
                }
                HStack(spacing: 8) {
                    if !skip {
                        ForEach(quickFolders, id: \.self) { url in
                            Button(url.lastPathComponent, systemImage: "plus") { model.addReorganizeFolder(url, skip: false) }
                        }
                    }
                    Button("Add Folder…", systemImage: "folder.badge.plus") { model.addReorganizeFolder(skip: skip) }
                }
                .buttonStyle(.pill)
                .disabled(model.isReorganizing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    /// Downloads, Desktop and Documents, unless they're already listed.
    private var quickFolders: [URL] {
        let listed = Set(model.reorganizeFolders.map(\.path))
        return [model.downloadsDirectoryURL, model.desktopDirectoryURL, model.documentsDirectoryURL]
            .filter { !listed.contains($0.standardizedFileURL.path) }
    }
}

/// What's waiting for you after a run: files it wasn't sure about, new folders and duplicates.
struct ReorganizeResults: View {
    @Environment(AppModel.self) private var model
    @Binding var confirmApply: Bool
    @State private var confirmSureNames = false
    @State private var confirmUnsureNames = false
    @State private var showNames = true
    /// The list stays quick with hundreds of files; the rest show after these are handled.
    private let shown = 150

    var body: some View {
        let ideas = model.reorganizeItems.filter { $0.destinationID != nil }
        let moved = model.reorganizeItems.filter { $0.destinationID == nil && $0.movedTo != nil }
        let others = model.reorganizeItems.filter { $0.destinationID == nil && $0.movedTo == nil }
        if !model.reorganizeItems.isEmpty || !model.reorganizeGroups.isEmpty || !model.reorganizeDuplicates.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                namesBar
                if !ideas.isEmpty { itemSection("Might belong in a folder · \(ideas.count)", items: ideas) }
                if !moved.isEmpty { itemSection("Moved by itself, new name waiting · \(moved.count)", items: moved) }
                if !model.reorganizeGroups.isEmpty { groupsSection }
                if !model.reorganizeDuplicates.isEmpty { duplicatesSection }
                if !others.isEmpty { itemSection("No folder fits · \(others.count)", items: others) }
                applyBar
            }
        }
    }

    /// Approve All for names: the sure ones, and the ones it isn't sure about once you've looked them over.
    @ViewBuilder
    private var namesBar: some View {
        let sure = model.reorganizeNameCount(sure: true)
        let unsure = model.reorganizeNameCount(sure: false)
        if sure + unsure > 0 {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("New names")
                if sure > 0 {
                    nameRow("\(sure) sure name\(sure == 1 ? "" : "s"), checked below.", button: "Approve All \(sure) Sure Name\(sure == 1 ? "" : "s")",
                            prominent: true, confirm: $confirmSureNames, count: sure) { model.approveReorganizeNames(sure: true) }
                }
                if unsure > 0 {
                    nameRow("\(unsure) name\(unsure == 1 ? "" : "s") it isn't sure about, marked “not sure”. Look them over first.",
                            button: "Approve All \(unsure) Not-Sure Name\(unsure == 1 ? "" : "s")", prominent: false,
                            confirm: $confirmUnsureNames, count: unsure) { model.approveReorganizeNames(sure: false) }
                }
                DisclosureGroup(isExpanded: $showNames) {
                    NameReviewList(entries: model.reorganizeItems.compactMap { item in
                        item.proposedName.map { NameReviewEntry(id: item.id, url: item.url, newName: $0, isSure: item.nameIsSure,
                                                                isOn: item.renameSelected) }
                    }) { id, selected in model.setReorganizeRename(id, selected) }
                } label: {
                    Text(showNames ? "Every new name, old → new" : "Show every new name, old → new")
                        .font(.caption.weight(.medium))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
    }

    private func nameRow(_ text: String, button: String, prominent: Bool, confirm: Binding<Bool>, count: Int,
                         action: @escaping () -> Void) -> some View {
        HStack {
            Caption(text)
            Spacer()
            Group {
                if prominent {
                    Button(button) { confirm.wrappedValue = true }.buttonStyle(.brass)
                } else {
                    Button(button) { confirm.wrappedValue = true }.buttonStyle(.pill)
                }
            }
            .disabled(model.isReorganizing)
            .confirmationDialog("Rename \(count) file\(count == 1 ? "" : "s")?", isPresented: confirm, titleVisibility: .visible) {
                Button("Rename All", action: action)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Each file gets the name shown under it and stays where it is; folders still wait for you. Undo All puts the whole run back.")
            }
        }
    }

    private func itemSection(_ title: String, items: [ReorganizeItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(title)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)
            ForEach(items.prefix(shown)) { item in
                Divider().opacity(0.5)
                ReorganizeItemRow(item: item)
            }
            if items.count > shown {
                Divider().opacity(0.5)
                Caption("And \(items.count - shown) more. They show here once you've handled these.")
                    .padding(14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var groupsSection: some View {
        GroupBox("Suggested new folders") {
            VStack(alignment: .leading, spacing: 10) {
                Caption("Files it couldn't place that are about the same thing. A folder is made next to most of its files only when you check it.")
                ForEach(model.reorganizeGroups) { group in
                    HStack(alignment: .top, spacing: 8) {
                        Toggle("Make this folder", isOn: Binding(
                            get: { group.isSelected },
                            set: { model.setReorganizeGroup(group.id, selected: $0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Folder name", text: Binding(
                                get: { group.name },
                                set: { model.renameReorganizeGroup(group.id, to: $0) }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 320)
                            Text("\(group.files.count) files: " + group.files.prefix(4).map(\.lastPathComponent).joined(separator: ", ")
                                 + (group.files.count > 4 ? "…" : ""))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Toggle("Sort into it from now on", isOn: Binding(
                                get: { group.makeFavorite },
                                set: { model.setReorganizeGroupFavorite(group.id, $0) }
                            ))
                            .toggleStyle(.checkbox)
                            .font(.caption)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var duplicatesSection: some View {
        GroupBox("Exact duplicates") {
            VStack(alignment: .leading, spacing: 10) {
                Caption("Files with exactly the same contents (checked byte for byte), whatever they're called. Checked copies go to the Trash; Undo All brings them back.")
                ForEach(model.reorganizeDuplicates) { duplicate in
                    Toggle(isOn: Binding(
                        get: { duplicate.isSelected },
                        set: { model.setReorganizeDuplicate(duplicate.id, selected: $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Keep \(duplicate.keep.lastPathComponent)")
                            Caption("Copies: " + duplicate.copies.map(\.lastPathComponent).joined(separator: ", "))
                                .lineLimit(2)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var applyBar: some View {
        HStack {
            Caption("\(model.reorganizeChosenCount) checked · Undo All puts the whole run back")
            Spacer()
            Button("Apply Checked", systemImage: "checkmark.circle.fill") { confirmApply = true }
                .buttonStyle(.brass)
                .disabled(model.reorganizeChosenCount == 0 || model.isReorganizing)
                .confirmationDialog("Apply the checked changes?", isPresented: $confirmApply, titleVisibility: .visible) {
                    Button("Apply") { model.applyReorganizeChoices() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Undo All reverses them along with the rest of the run. Copies go to the Trash, which only you can empty.")
                }
        }
    }
}

struct ReorganizeItemRow: View {
    @Environment(AppModel.self) private var model
    let item: ReorganizeItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("Move", isOn: Binding(
                get: { item.moveSelected },
                set: { model.setReorganizeMove(item.id, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(item.destinationID == nil)
            .padding(.top, 6)
            FileTypeIcon(fileName: item.url.lastPathComponent, path: item.url.path, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Caption(item.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .lineLimit(1)
                    .truncationMode(.head)
                if !item.summary.isEmpty { Caption(item.summary) }
                Caption(item.reason)
                if let proposed = item.proposedName {
                    Toggle("Rename to “\(proposed)”" + (item.nameIsSure ? "" : " (not sure)"), isOn: Binding(
                        get: { item.renameSelected },
                        set: { model.setReorganizeRename(item.id, $0) }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 4) {
                Picker("Folder", selection: Binding(
                    get: { item.destinationID ?? "" },
                    set: { model.setReorganizeDestination(item.id, $0) }
                )) {
                    Text("Choose…").tag("")
                    ForEach(model.favoriteFolders) { folder in Text(folder.name).tag(folder.id) }
                }
                .labelsHidden()
                .frame(width: 170)
                HStack(spacing: 10) {
                    Button("Leave As Is") { model.leaveReorganizeItem(item.id) }
                        .help("Keep its name and place; later runs skip it")
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(model.isReorganizing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .filePreview(item.url)
    }
}

/// A name waiting for you: the file, its new name, and whether Apple Intelligence is sure.
struct NameReviewEntry: Identifiable {
    let id: String
    let url: URL
    let newName: String
    let isSure: Bool
    let isOn: Bool
}

/// Every waiting name, old → new, sure ones first, each with its checkbox, so the names it isn't
/// sure about can be read before approving them.
struct NameReviewList: View {
    let entries: [NameReviewEntry]
    let setSelected: (String, Bool) -> Void

    var body: some View {
        let sorted = entries.filter(\.isSure) + entries.filter { !$0.isSure }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(sorted) { entry in
                    NameReviewRow(entry: entry, setSelected: setSelected)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: min(CGFloat(sorted.count) * 30 + 12, 340))
    }
}

struct NameReviewRow: View {
    let entry: NameReviewEntry
    let setSelected: (String, Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("Rename", isOn: Binding(get: { entry.isOn }, set: { setSelected(entry.id, $0) }))
                .labelsHidden()
                .toggleStyle(.checkbox)
            FileTypeIcon(fileName: entry.newName, path: entry.url.path, size: 18, showsTag: false)
            Text(entry.url.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .leading)
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(entry.newName)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if !entry.isSure {
                Text("not sure")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(NylaStyle.wash(0.1), in: Capsule())
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .frame(height: 28)
        .filePreview(entry.url)
    }
}
