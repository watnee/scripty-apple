//
//  ProjectArchiveView.swift
//  scripty
//
//  Screenplays put aside without being deleted.
//
//  Its own view rather than a second use of `ArchiveView`: the two share a
//  model but not a row, and this one has no "open" at all. On the web an
//  archived screenplay opens in place; here the detail pane resolves its
//  selection against the project list, and an archived project is by definition
//  not in it — so opening one means bringing it back first. Unarchive is
//  therefore the primary action rather than the way to a secondary one.
//
//  Nothing here is destructive and nothing is on a clock, so — unlike
//  `TrashView` — no action asks first. Deleting from the archive is the
//  ordinary soft delete: it lands in the trash and stays restorable, which is
//  why it needs no alert either.
//
//  Edit mode ticks rows for the one action worth repeating, as the document
//  archive does. There is no bulk archive one level up to mirror — screenplays
//  are put aside one production at a time, as they finish — but coming back is
//  the other way round: someone opening this sheet after a season is looking at
//  a shelf, and wants a handful of it back at once.
//

import SwiftUI

struct ProjectArchiveView: View {
    @State private var model: ArchiveModel<ArchivedProject>
    /// Called after anything leaves the archive, so the list behind us reloads.
    var onChanged: () async -> Void = {}

    @Environment(\.dismiss) private var dismiss
    /// The ticked rows, by id, and whether anything is being ticked at all.
    @State private var selection = Set<Int>()
    @State private var editMode: EditMode = .inactive

    init(app: AppModel,
         source: HALLink,
         onChanged: @escaping () async -> Void = {}) {
        _model = State(initialValue: ArchiveModel<ArchivedProject>(app: app, source: source))
        self.onChanged = onChanged
    }

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                ForEach(model.items) { project in
                    ArchivedProjectRow(project: project)
                        .swipeActions(edge: .leading) {
                            if model.canUnarchive(project) {
                                Button {
                                    unarchive(project)
                                } label: {
                                    Label("Unarchive", systemImage: "arrow.up.bin")
                                }
                                .tint(.blue)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            if model.canDelete(project) {
                                Button(role: .destructive) {
                                    delete(project)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        .contextMenu {
                            if model.canUnarchive(project) {
                                Button {
                                    unarchive(project)
                                } label: {
                                    Label("Unarchive", systemImage: "arrow.up.bin")
                                }
                            }
                            if model.canDelete(project) {
                                // Not the trash's purge: this is the soft delete,
                                // and the trash catches it — so no alert.
                                Button(role: .destructive) {
                                    delete(project)
                                } label: {
                                    Label("Move to Trash", systemImage: "trash")
                                }
                            }
                        }
                }
            }
            .overlay { emptyState }
            .navigationTitle("Archive")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbarContent }
            .environment(\.editMode, $editMode)
            // Leaving edit mode drops the ticks with the bar that acted on them.
            .onChange(of: editMode) { _, mode in
                if !mode.isEditing { selection.removeAll() }
            }
            // A screenplay can leave the archive behind this sheet's back —
            // another device, or the swipe on the row beside it.
            .onChange(of: model.items) { _, items in
                selection.formIntersection(Set(items.map(\.id)))
            }
            .task { await model.load() }
            .refreshable { await model.load() }
            .alert("Error", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
        }
        // Worth entering only where a selection could do something, and only
        // with more than one row on the shelf.
        if model.canBulkUnarchive && model.items.count > 1 {
            ToolbarItem(placement: .primaryAction) {
                EditButton()
            }
        }
        if editMode.isEditing && !selection.isEmpty {
            ToolbarItemGroup(placement: .bottomBar) {
                // Titled rather than a `Label`, for the reason the document
                // archive's is: a bottom bar draws a lone Label as a bare
                // glyph, and the count is the whole point of saying anything.
                Button("Unarchive \(selection.count)") {
                    bulkUnarchive()
                }
                .disabled(model.isWorking)
                Spacer()
            }
        }
    }

    private func unarchive(_ project: ArchivedProject) {
        Task {
            if await model.unarchive(project) { await onChanged() }
        }
    }

    /// Brings the ticked screenplays back, in the order the archive is showing
    /// them.
    private func bulkUnarchive() {
        let ids = model.items.map(\.id).filter { selection.contains($0) }
        guard !ids.isEmpty else { return }
        Task {
            if await model.bulkUnarchive(ids) {
                selection.removeAll()
                editMode = .inactive
                await onChanged()
            }
        }
    }

    /// The trash behind the list changes too, so the sidebar reloads either way.
    private func delete(_ project: ArchivedProject) {
        Task {
            if await model.delete(project) { await onChanged() }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isEmpty {
            if model.isLoading {
                ProgressView()
            } else {
                ContentUnavailableView(
                    "Nothing Archived",
                    systemImage: "archivebox",
                    description: Text("Archive a screenplay to put it aside without deleting it. It keeps its script, songs, notes and versions, and nothing here is ever removed on its own."))
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }
}

/// One archived screenplay.
///
/// Carries no purge date, unlike `TrashedProjectRow` — there is none to carry.
/// The date shown is when it was put aside; the last edit sits under it,
/// because a wrapped production is often recognised by when the work stopped.
struct ArchivedProjectRow: View {
    let project: ArchivedProject

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(project.displayTitle)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if let archived = project.archivedAt {
                    Text(archived, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                if let edited = project.lastEdited {
                    Text("Edited \(edited, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let teams = project.teams, !teams.isEmpty {
                    Text(teams.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
