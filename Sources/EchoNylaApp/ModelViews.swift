import AppKit
import EchoNylaCore
import SwiftUI

/// Settings → On-device model: Bonsai or Apple Intelligence, the download, and Test on My Files.
struct ModelSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        GroupBox("On-device model") {
            VStack(alignment: .leading, spacing: 8) {
                SettingToggle("Use AI on this Mac", isOn: $model.aiEnabled)
                SettingToggle("Look inside files (text, and pictures of screenshots, photos, PDFs and documents)", isOn: $model.readContents)
                    .disabled(!model.aiEnabled)
                Picker("Model", selection: $model.modelChoice) {
                    Text("Ternary Bonsai 2 9B (sees pictures, renames and sorts by itself)").tag(ModelChoice.bonsai)
                    Text("Apple Intelligence").tag(ModelChoice.apple)
                }
                .pickerStyle(.radioGroup)
                .disabled(!model.aiEnabled)
                if model.modelChoice == .bonsai {
                    bonsaiStatus
                } else {
                    IntelligenceStatus()
                }
                Caption("Both run only on this Mac, never in the cloud. Long numbers such as account and card numbers are hidden from them. Everything still works with AI off.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var bonsaiStatus: some View {
        switch model.localModelState {
        case .notInstalled:
            Caption("Bonsai is a one-time download of about 3.2 GB from Hugging Face (PrismML's Ternary Bonsai 2 9B). It runs inside EchoNyla, uses about 3.5 GB of memory only while it's sorting, and lets go of it after a minute. Until it's downloaded, Apple Intelligence is used.")
            Button("Download Bonsai (3.2 GB)", systemImage: "arrow.down.circle") { model.downloadLocalModel() }
                .buttonStyle(.brass)
        case .downloading(let fraction):
            HStack(spacing: 10) {
                ProgressView(value: fraction)
                    .frame(maxWidth: 260)
                Caption("Downloading \(Int(fraction * 100))%…")
                Button("Cancel") { model.cancelLocalModelDownload() }
                    .buttonStyle(.pill)
            }
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again", systemImage: "arrow.clockwise") { model.downloadLocalModel() }
                .buttonStyle(.pill)
        case .installed:
            Label("Bonsai is ready (\(ByteCountFormatter.string(fromByteCount: model.localModelBytesOnDisk, countStyle: .file)) on disk).",
                  systemImage: "checkmark.seal")
                .font(.callout)
            Caption(barText)
            HStack(spacing: 8) {
                if model.modelTestProgress == nil {
                    Button("Test on My Files", systemImage: "checklist") { model.runModelTest() }
                        .buttonStyle(.pill)
                } else {
                    ProgressView().controlSize(.small)
                    Caption(model.modelTestProgress ?? "")
                    Button("Stop") { model.cancelModelTest() }
                        .buttonStyle(.pill)
                }
                Spacer()
                Button("Remove Bonsai", role: .destructive) { model.removeLocalModel() }
                    .buttonStyle(.borderless)
            }
            if let report = model.modelTestReport {
                ModelTestReportView(report: report)
            }
        }
    }

    private var barText: String {
        let bar = model.confidenceBar.folder
        let moves = bar > 100 ? "Folder moves always ask you first (Test on My Files found its sure answers weren't reliable enough)."
            : "It moves a file by itself when it's at least \(bar)% sure and can quote the folder's note."
        return moves + " It renames by itself when it's at least \(model.confidenceBar.name)% sure, the name comes from what's in the file, and the old name said nothing (like \"Screenshot 2026-10-27 at 9.41.02\" or \"IMG_4821\"). Everything else waits for you."
    }
}

struct ModelTestReportView: View {
    let report: ModelTestReport

    var body: some View {
        let summary = report.summary
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Test on My Files")
            Text("\(summary.right) of \(summary.files) files: Bonsai named the folder you chose.")
            if let accuracy = summary.sureAccuracy {
                Text("When it was sure (\(summary.sure) files), it was right \(Int((accuracy * 100).rounded()))% of the time.")
            } else {
                Text("It wasn't sure enough about any of them to move them by itself.")
            }
            Text(barLine)
            Caption(String(format: "About %.1f s per file. Peak memory: %@.", summary.averageSeconds,
                           ByteCountFormatter.string(fromByteCount: Int64(report.peakMemoryBytes), countStyle: .memory)))
            if !report.misses.isEmpty {
                SectionLabel("Where it differed from you")
                ForEach(Array(report.misses.enumerated()), id: \.offset) { _, miss in
                    Caption("\(miss.0): it said \(miss.1), you chose \(miss.2)")
                }
                Caption("If its answer looks right, the file may be in the wrong folder. If not, the folder's note may need clearer words.")
            }
            if !report.renames.isEmpty {
                SectionLabel("Names it would give")
                ForEach(Array(report.renames.enumerated()), id: \.offset) { _, pair in
                    Caption("\(pair.0) → \(pair.1)")
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: 10)
    }

    private var barLine: String {
        if report.barAfter > 100 { return "Its sure answers weren't right often enough, so folder moves will ask you first." }
        if report.barAfter == report.barBefore { return "The bar for moving by itself stays at \(report.barAfter)%." }
        return "The bar for moving by itself is now \(report.barAfter)% (was \(report.barBefore)%), so sure answers stay right at least 95% of the time."
    }
}

/// Folders & Rules: Check All Folders, the check's progress, and the files it wasn't sure about.
struct FolderCheckCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GroupBox("Check folders") {
            VStack(alignment: .leading, spacing: 8) {
                if !model.usesLocalModel {
                    Caption("Download Bonsai in Settings → On-device model to check your folders.")
                }
                Caption("Bonsai looks at every file in a folder with a note. Files that clearly belong in another folder move there by themselves, and files with names that say nothing get a proper name. Anything it isn't sure about is listed here. Undo All is in Activity.")
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
                        .disabled(!model.usesLocalModel || !model.aiReady || model.checkableFolders.isEmpty)
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
