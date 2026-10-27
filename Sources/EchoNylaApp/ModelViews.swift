import AppKit
import EchoNylaCore
import SwiftUI

/// Settings → Apple Intelligence: on or off, reading inside files, and how sure it must be.
struct ModelSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        GroupBox("Apple Intelligence") {
            VStack(alignment: .leading, spacing: 8) {
                SettingToggle("Use Apple Intelligence on this Mac", isOn: $model.aiEnabled)
                SettingToggle("Look inside files (text, the first minute of recordings and videos, and pictures of screenshots, photos, PDFs and documents)",
                              isOn: $model.readContents)
                    .disabled(!model.aiEnabled)
                IntelligenceStatus()
                Caption(barText)
                if !OnDeviceModel.seesPictures {
                    Caption("Looking at pictures of files needs macOS 27. Until then it reads their text and what Apple's image recognition sees.")
                }
                Caption("It runs only on this Mac, never in the cloud. Long numbers such as account and card numbers are hidden from it. Everything still works with it off.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var barText: String {
        "It moves a file by itself when it's at least \(model.confidenceBar.folder)% sure and what's in the file matches that Sort-into folder better than any other. A new name is sure at \(model.confidenceBar.name)% when it comes from what's in the file: it's checked for you and applied by itself when the old name said nothing (like \"Screenshot 2026-10-27 at 9.41.02\" or \"IMG_4821\"). Names from \(model.confidenceBar.nameShown)% are listed as not sure. Everything else waits for you."
    }
}

/// Folders & Rules: Check All Folders, the check's progress, and the files it wasn't sure about.
struct FolderCheckCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GroupBox("Check folders") {
            VStack(alignment: .leading, spacing: 8) {
                Caption("Apple Intelligence looks at every file in a Sort-into folder. Files that clearly belong in another folder move there by themselves, and files with names that say nothing get a proper name. Anything it isn't sure about is listed here. Files it checked before and left alone aren't checked again until they change. Undo All is in Activity.")
                if let progress = model.folderCheckProgress {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Caption(progress)
                        Button("Stop") { model.cancelFolderCheck() }
                            .buttonStyle(.pill)
                    }
                } else {
                    Button("Check All Folders", systemImage: "wand.and.stars") { model.checkAllFolders() }
                        .buttonStyle(.brass)
                        .disabled(!model.aiReady || model.checkableFolders.isEmpty)
                }
                if !model.folderCheckFindings.isEmpty {
                    SectionLabel("Not sure about these")
                    ForEach(model.folderCheckFindings) { finding in
                        findingRow(finding)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func findingRow(_ finding: FolderCheckFinding) -> some View {
        HStack(alignment: .top, spacing: 10) {
            FileTypeIcon(fileName: finding.url.lastPathComponent, path: finding.url.path, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Caption("In \(model.destinationName(for: finding.folderID) ?? "a folder"). \(finding.note)")
            }
            Spacer()
            if let suggested = finding.suggestedID, let name = model.destinationName(for: suggested) {
                Button("Move to \(name)") { model.moveFinding(finding.id, to: suggested) }
                    .buttonStyle(.pill)
            }
            Menu("Other Folder") {
                ForEach(model.favoriteFolders.filter { $0.id != finding.folderID }) { folder in
                    Button(folder.name) { model.moveFinding(finding.id, to: folder.id) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button("Leave It") { model.dismissFinding(finding.id) }
                .buttonStyle(.pill)
        }
        .filePreview(finding.url)
    }
}

/// Activity: recent batches of changes, each with Undo All.
struct ActivityRunsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let runs = Array(model.activityRuns.prefix(3))
        if !runs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(runs) { run in
                    HStack(spacing: 10) {
                        Image(systemName: "wand.and.stars")
                            .foregroundStyle(NylaStyle.brass)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(run.title)
                                .font(.callout.weight(.medium))
                            Caption(detail(run))
                        }
                        Spacer()
                        Button("Undo All", systemImage: "arrow.uturn.backward") { model.undoRun(run.id) }
                            .buttonStyle(.pill)
                    }
                    .padding(10)
                    .cardSurface(radius: 10)
                }
            }
        }
    }

    private func detail(_ run: ActivityRunSummary) -> String {
        var parts: [String] = []
        if run.moved > 0 { parts.append("moved \(run.moved)") }
        if run.renamed > 0 { parts.append("renamed \(run.renamed)") }
        let when = run.date.formatted(date: .abbreviated, time: .shortened)
        return (parts.isEmpty ? "" : parts.joined(separator: ", ").capitalizedFirst + " · ") + when
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
