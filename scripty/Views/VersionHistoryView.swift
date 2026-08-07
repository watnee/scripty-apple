//
//  VersionHistoryView.swift
//  scripty
//
//  Saved snapshots, newest first. Named versions and automatic saves are
//  separated, because a history where the four snapshots the writer
//  deliberately marked are buried among a hundred autosaves is not much of a
//  history.
//
//  Serves a screenplay and a song alike; `subject` is the only word that
//  changes, and calling a song "the script" would be the one place the shared
//  view showed through.
//

import SwiftUI

struct VersionHistoryView: View {
    @State private var model: VersionHistoryModel
    /// Called after a restore, so the script on screen reloads — a restore
    /// rewrites the blocks underneath whatever the writer was looking at.
    let onRestored: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isNaming = false
    @State private var newLabel = ""
    @State private var pendingRestore: ProjectVersion?

    /// What this is a history of, as the writer would say it: "script", "song".
    let subject: String

    init(
        app: AppModel,
        source: HALLink,
        subject: String = "script",
        onRestored: @escaping () async -> Void
    ) {
        _model = State(initialValue: VersionHistoryModel(app: app, source: source))
        self.subject = subject
        self.onRestored = onRestored
    }

    var body: some View {
        NavigationStack {
            List {
                if !model.namedVersions.isEmpty {
                    Section("Saved Versions") {
                        ForEach(model.namedVersions) { row($0) }
                    }
                }
                if !model.autoSaves.isEmpty {
                    Section {
                        ForEach(model.autoSaves) { row($0) }
                    } header: {
                        Text("Autosaves")
                    } footer: {
                        Text("Saved automatically as the \(subject) changes.")
                    }
                }
            }
            .overlay { emptyState }
            .navigationTitle("Version History")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if model.canCreate {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            newLabel = ""
                            isNaming = true
                        } label: {
                            Label("Save Version", systemImage: "plus")
                        }
                        .disabled(model.isWorking)
                    }
                }
            }
            .task { await model.load() }
            .refreshable { await model.load() }
            .alert("Save Version", isPresented: $isNaming) {
                TextField("Name (optional)", text: $newLabel)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    let label = newLabel
                    Task { await model.createVersion(label: label) }
                }
            } message: {
                Text("Saves the \(subject) as it stands now.")
            }
            .alert("Restore Version", isPresented: restoreBinding) {
                Button("Cancel", role: .cancel) { pendingRestore = nil }
                Button("Restore", role: .destructive) {
                    let version = pendingRestore
                    pendingRestore = nil
                    Task {
                        guard let version, await model.restore(version) else { return }
                        await onRestored()
                    }
                }
            } message: {
                Text("Replace the current \(subject) with “\(pendingRestore?.displayLabel ?? "")”? "
                     + "The current state is saved first, so this can be undone.")
            }
            .alert("Error", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    private func row(_ version: ProjectVersion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(version.displayLabel)
                    .font(.body.weight(version.isAutoSave ? .regular : .medium))
                Spacer()
                if let created = version.createdAt {
                    Text(created, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !version.sizeSummary.isEmpty {
                Text(version.sizeSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let summary = version.changeSummary, !summary.isEmpty {
                changeSummary(summary)
            }
        }
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing) {
            if model.canDelete(version) {
                Button(role: .destructive) {
                    Task { await model.delete(version) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .contextMenu {
            if model.canRestore(version) {
                Button {
                    pendingRestore = version
                } label: {
                    Label("Restore This Version", systemImage: "clock.arrow.circlepath")
                }
            }
            if model.canDelete(version) {
                Button(role: .destructive) {
                    Task { await model.delete(version) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .onTapGesture {
            if model.canRestore(version) { pendingRestore = version }
        }
    }

    /// What changed since the snapshot before it — the server works this out,
    /// so nothing is diffed here.
    ///
    /// The counts first, then the lines the server already phrased. Those were
    /// decoded and then read only to ask whether they were empty, so a summary
    /// carrying nothing else — every count zero, both flags false — passed
    /// `isEmpty`, reached this function, and drew an empty eight-point row: the
    /// one part of the change summary written for a person to read was the part
    /// that never got to the screen.
    @ViewBuilder
    private func changeSummary(_ summary: VersionChangeSummary) -> some View {
        let details = summary.details ?? []
        let hasCounts = !summary.tallies.isEmpty
            || (summary.projectMetadataChanged ?? false)
            || (summary.titleChanged ?? false)
        VStack(alignment: .leading, spacing: 2) {
            // Only where there is something to put in it, or the row itself
            // becomes the empty space this used to leave.
            if hasCounts {
                HStack(spacing: 8) {
                    ForEach(summary.tallies, id: \.symbol) { tally in
                        Text("\(tally.symbol)\(tally.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(colour(for: tally.symbol))
                    }
                    if summary.projectMetadataChanged ?? false {
                        Text("title page")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if summary.titleChanged ?? false {
                        Text("title")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // The server caps and phrases these itself — five, then "and N
            // more changes" — so there is nothing to trim here.
            ForEach(Array(details.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func colour(for symbol: String) -> Color {
        switch symbol {
        case "+": return .green
        case "−": return .red
        default: return .orange
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.versions.isEmpty {
            if model.isLoading {
                ProgressView()
            } else {
                ContentUnavailableView {
                    Label("No Versions Yet", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Snapshots appear here as you write, and you can save one by hand at any time.")
                } actions: {
                    if model.canCreate {
                        Button("Save Version") {
                            newLabel = ""
                            isNaming = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    private var restoreBinding: Binding<Bool> {
        Binding(get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }
}
