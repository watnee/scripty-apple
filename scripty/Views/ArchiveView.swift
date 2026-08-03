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
            .toolbar { toolbar }
            .environment(\.editMode, $editMode)
            .onChange(of: editMode) { _, mode in
                if !mode.isEditing { selection.removeAll() }
            }
            // Bringing a set back empties the archive it was ticked in, and
            // the Edit button goes with it — so the mode has to stand itself
            // down rather than strand a list with no way out of it.
            .onChange(of: model.items.count) { _, count in
                if count <= 1 { editMode = .inactive }
                selection = selection.intersection(model.items.map(\.id))
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
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
        }
        // Archiving twelve songs is one tap in the list; bringing them back
        // was twelve here. Offered only where the server said so and where
        // there is more than one row to tick.
        if model.canBulkUnarchive && model.items.count > 1 {
            ToolbarItem(placement: .navigation) {
                EditButton()
            }
        }
        if editMode.isEditing && !selection.isEmpty {
            ToolbarItem(placement: .bottomBar) {
                Button {
                    unarchiveSelected()
                } label: {
                    Label(selection.count == 1
                          ? "Unarchive 1 Item"
                          : "Unarchive \(selection.count) Items",
                          systemImage: "arrow.up.bin")
                }
                .disabled(model.isWorking)
            }
        }
    }

    private func unarchive(_ item: ArchivedDocument) {
        Task {
            if await model.unarchive(item) { await onChanged() }
        }
    }

    /// No confirmation, like everything else here: nothing on this screen is
    /// destructive, and putting a song back is undone by archiving it again.
    private func unarchiveSelected() {
        // In the order the archive showed them, which is the order the server
        // documents this taking.
        let ids = model.items.map(\.id).filter(selection.contains)
        Task {
            guard await model.bulkUnarchive(ids) else { return }
            selection.removeAll()
            editMode = .inactive
            await onChanged()
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
