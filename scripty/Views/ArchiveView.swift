//
//  ArchiveView.swift
//  scripty
//
//  The songs and notes put aside. A shelf, not a bin.
//
//  It reads almost exactly like the trash, and the differences are the point.
//  Nothing here is counting down, so no row carries a purge date and no action
//  needs a warning: "Put Back" is one tap, and it is the leading swipe because
//  it is what the writer came for. The second action is Delete, which does what
//  Delete does everywhere else in this app — it sends the document to the
//  trash, from which it can still be recovered. An archived song someone has
//  finished with should not have to be unarchived first just to throw away.
//
//  Songs and notes share the screen because the server keeps one archive per
//  project and tells the two apart by type — the same arrangement the trash
//  uses, and the same badge on the row.
//

import SwiftUI

struct ArchiveView: View {
    @State private var model: TrashModel<ArchivedDocument>
    /// Called after anything moves, so the list behind us reloads.
    var onChanged: () async -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var pendingDelete: ArchivedDocument?

    init(app: AppModel, source: HALLink, onChanged: @escaping () async -> Void = {}) {
        // The archive's two directions: back to the list, or on to the trash.
        _model = State(initialValue: TrashModel<ArchivedDocument>(
            app: app, source: source, restoreRel: .unarchive, removeRel: .delete))
        self.onChanged = onChanged
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.items) { document in
                    ArchivedDocumentRow(document: document)
                        .swipeActions(edge: .leading) {
                            if model.canRestore(document) {
                                putBackButton(document)
                                    .tint(.blue)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            if model.canPurge(document) {
                                Button(role: .destructive) {
                                    pendingDelete = document
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        .contextMenu {
                            if model.canRestore(document) {
                                putBackButton(document)
                            }
                            if model.canPurge(document) {
                                Button(role: .destructive) {
                                    pendingDelete = document
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                }
            }
            .overlay { emptyState }
            .navigationTitle("Archived Songs & Notes")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await model.load() }
            .refreshable { await model.load() }
            // Asked about, unlike putting back — this one takes the document
            // somewhere else again. Not "cannot be undone", because it can:
            // the trash is where it lands.
            .alert("Move to Trash", isPresented: deleteBinding) {
                Button("Cancel", role: .cancel) { pendingDelete = nil }
                Button("Delete", role: .destructive) {
                    let document = pendingDelete
                    pendingDelete = nil
                    Task {
                        guard let document else { return }
                        if await model.purge(document) { await onChanged() }
                    }
                }
            } message: {
                Text("\"\(pendingDelete?.displayTitle ?? "")\" can still be recovered from the trash.")
            }
            .alert("Error", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    private func putBackButton(_ document: ArchivedDocument) -> some View {
        Button {
            Task {
                if await model.restore(document) { await onChanged() }
            }
        } label: {
            Label("Put Back", systemImage: "tray.and.arrow.up")
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
                    description: Text("Songs and notes you set aside are kept here, "
                                      + "whole and ready to come back."))
            }
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }
}

/// One archived song or note.
///
/// Deliberately quieter than the trash's row: there is no deadline to report,
/// so the only date is when it was set aside.
struct ArchivedDocumentRow: View {
    let document: ArchivedDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let type = document.documentTypeLabel, !type.isEmpty {
                    Text(type.uppercased())
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let archived = document.archivedAt {
                    Text(archived, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(document.displayTitle)
                .font(.body.weight(.medium))

            if let preview = document.preview, !preview.isEmpty {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}
