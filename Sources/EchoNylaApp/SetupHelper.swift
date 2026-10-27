import AppKit
import EchoNylaCore
import SwiftUI
import UniformTypeIdentifiers

/// Shown on Activity while there are no favorite folders yet.
struct SetupPromptCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(for: .folder))
                .resizable()
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up EchoNyla in a minute")
                    .font(.system(size: 14, weight: .semibold))
                Caption("EchoNyla files things into your favorite folders. It can suggest some from the folders you already use, each with a note saying what goes there.")
            }
            Spacer(minLength: 10)
            Button("Suggest Folders…") { model.isSetupOpen = true }
                .buttonStyle(.brass)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

/// The setup helper: folders from Documents and the Desktop, unchecked, each with a drafted note to edit.
struct SetupHelperView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                PageTitle("Suggested folders")
                Caption("Folders in Documents and on your Desktop that you keep files in. Tick the ones to add. \"Sort into this\" folders get files from Apple Intelligence when they plainly match the note, and it learns what goes in each from the files already there. Edit the notes freely. \"Just for dragging\" folders are quick places to drop things.")
            }
            if model.isPreparingSetup {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Caption("Looking at your folders…")
                }
            } else if model.setupCandidates.isEmpty {
                Card { Caption("No folders to suggest: none in Documents or on your Desktop has at least 3 files, or they're already favorites. Add folders yourself in Folders & Rules.") }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.setupCandidates) { candidate in
                            SetupCandidateRow(candidate: candidate)
                        }
                    }
                }
                .frame(minHeight: 220, maxHeight: 420)
            }
            if !model.aiReady {
                Caption("Apple Intelligence isn't available, so the notes start empty. Folders without a note still get files from drag and drop, your rules and your own moves.")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancelSetup() }
                    .buttonStyle(.pill)
                    .keyboardShortcut(.cancelAction)
                let count = model.setupCandidates.filter(\.isSelected).count
                Button(count == 0 ? "Add Folders" : "Add \(count) Folder\(count == 1 ? "" : "s")") { model.addChosenSetupFolders() }
                    .buttonStyle(.brass)
                    .disabled(count == 0)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 360, idealHeight: 520)
        .background(WindowBackground())
    }
}

struct SetupCandidateRow: View {
    @Environment(AppModel.self) private var model
    let candidate: SetupCandidate

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("Add", isOn: Binding(
                get: { candidate.isSelected },
                set: { model.setSetupCandidate(id: candidate.id, selected: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .padding(.top, 4)
            Image(nsImage: NSWorkspace.shared.icon(forFile: candidate.url.path))
                .resizable()
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(candidate.url.lastPathComponent)
                        .font(.callout.weight(.semibold))
                    Text("\(candidate.fileCount) files · \(candidate.url.deletingLastPathComponent().lastPathComponent)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Picker("Use", selection: Binding(
                        get: { candidate.sortsInto },
                        set: { model.setSetupSortsInto(id: candidate.id, $0) }
                    )) {
                        Text("Sort into this").tag(true)
                        Text("Just for dragging").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                }
                if candidate.sortsInto {
                    HStack(spacing: 6) {
                        TextField("What goes here? (optional)", text: Binding(
                            get: { candidate.note },
                            set: { model.setSetupNote(id: candidate.id, to: $0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        if candidate.isDrafting {
                            ProgressView().controlSize(.mini)
                                .help("Apple Intelligence is writing a note")
                        }
                    }
                }
            }
        }
        .padding(10)
        .cardSurface(radius: 10)
    }
}
