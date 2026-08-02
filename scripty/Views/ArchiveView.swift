//
//  ArchiveView.swift
//  scripty
//
//  A project's archived songs and notes.
//
//  Reads like `TrashView` and behaves unlike it in the ways that matter.
//  Unarchive is the primary action on the leading edge, as Restore is there —
//  but there is no purge, no "empty", and no confirmation on anything, because
//  nothing here is destructive and nothing is on a clock. Deleting from the
//  archive is the ordinary soft delete, so it goes to the trash and stays
//  recoverable; that is why it needs no alert either.
//
//  Tapping a row opens the song or note. An archived document is still whole,
//  which is the whole difference between putting something aside and binning it.
//
//  Edit mode ticks rows, as the songs list does, and for the one action worth
//  repeating: a writer who archived a batch at the end of a draft is here to
//  take a batch back. There is no bulk delete to go with it — sending several
//  archived documents to the trash in one tap is not a thing anyone has needed,
//  and the swipe is right there for the odd one.
//

import SwiftUI

struct ArchiveView: View {
    @State private var model: ArchiveModel<ArchivedDocument>
    /// Called after anything leaves the archive, so the list behind us reloads.
    var onChanged: () async -> Void = {}
    /// Opens an archived document in the editor. The sheet dismisses first —
    /// two sheets deep is not where anyone wants to be editing lyrics.
    var onOpen: (TextDocument) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var opening: Int?
    /// The ticked rows, by id, and whether anything is being ticked at all.
    @State private var selection = Set<Int>()
    @State private var editMode: EditMode = .inactive

    init(app: AppModel,
         source: HALLink,
         onChanged: @escaping () async -> Void = {},
         onOpen: @escaping (TextDocument) -> Void = { _ in }) {
        _model = State(initialValue: ArchiveModel<ArchivedDocument>(app: app, source: source))
        self.onChanged = onChanged
        self.onOpen = onOpen
    }

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                ForEach(model.items) { item in
                    Button {
                        open(item)
                    } label: {
                        ArchivedDocumentRow(document: item, isOpening: opening == item.id)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .leading) {
                        if model.canUnarchive(item) {
                            Button {
                                unarchive(item)
                            } label: {
                                Label("Unarchive", systemImage: "arrow.up.bin")
                            }
                            .tint(.blue)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        if model.canDelete(item) {
                            Button(role: .destructive) {
                                Task { await model.delete(item) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .contextMenu {
                        if model.canUnarchive(item) {
                            Button {
                                unarchive(item)
                            } label: {
                                Label("Unarchive", systemImage: "arrow.up.bin")
                            }
                        }
                        if model.canDelete(item) {
                            // Not marked destructive-with-alert like a purge:
                            // this is the soft delete, and the trash catches it.
                            Button(role: .destructive) {
                                Task { await model.delete(item) }
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
            // Leaving edit mode drops the ticks with the bar that acted on them,
            // so reopening it never starts with someone else's selection.
            .onChange(of: editMode) { _, mode in
                if !mode.isEditing { selection.removeAll() }
            }
            // Anything can leave the archive behind this sheet's back — another
            // device, or the swipe on the row beside it. Drop ids that are no
            // longer here rather than posting them.
            .onChange(of: model.items) { _, items in
                let present = Set(items.map(\.id))
                selection.formIntersection(present)
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
        // with more than one row: ticking the single thing in the archive to
        // bring it back is the swipe with extra steps.
        if model.canBulkUnarchive && model.items.count > 1 {
            ToolbarItem(placement: .primaryAction) {
                EditButton()
            }
        }
        // Shown only once something is ticked — an empty bar under a list
        // nobody is selecting from is noise. No confirmation: nothing is lost,
        // and archiving them again is one swipe away.
        if editMode.isEditing && !selection.isEmpty {
            ToolbarItemGroup(placement: .bottomBar) {
                // Titled, not a `Label`. A bottom bar draws a lone Label as a
                // bare glyph — `.labelStyle(.titleAndIcon)` does not talk it
                // out of it — and the count is the whole point of saying
                // anything: an archive box with no number on it leaves the
                // writer pressing it to find out how much it moves.
                Button("Unarchive \(selection.count)") {
                    bulkUnarchive()
                }
                .disabled(model.isWorking)
                Spacer()
            }
        }
    }

    /// Brings the ticked rows back, in the order the archive is showing them —
    /// so they rejoin the end of the list in the order the writer sees here,
    /// not the order rows happened to be tapped.
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

    private func unarchive(_ item: ArchivedDocument) {
        Task {
            if await model.unarchive(item) { await onChanged() }
        }
    }

    private func open(_ item: ArchivedDocument) {
        guard opening == nil else { return }
        opening = item.id
        Task {
            defer { opening = nil }
            let document: TextDocument? = await model.resource(.document, of: item)
            guard let document else { return }
            dismiss()
            onOpen(document)
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
                    description: Text("Archive a song or note to put it aside without deleting it. It keeps everything it had, and nothing here is ever removed on its own."))
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }
}

/// One archived song or note.
///
/// Carries no purge date, unlike `DeletedDocumentRow` — there is none to carry.
/// The date shown is when it was put aside, which is what the writer is
/// recognising it by.
struct ArchivedDocumentRow: View {
    let document: ArchivedDocument
    var isOpening = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(document.displayTitle)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if isOpening {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if let archived = document.archivedAt {
                    Text(archived, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                Text((document.documentTypeLabel ?? document.kind.label).uppercased())
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary.opacity(0.5), in: Capsule())
                    .foregroundStyle(.secondary)
                if let preview = document.preview?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !preview.isEmpty {
                    Text(preview)
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
