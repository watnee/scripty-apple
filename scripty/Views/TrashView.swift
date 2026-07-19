//
//  TrashView.swift
//  scripty
//
//  A trash, whatever is in it. Elements and screenplays are listed the same
//  way — swipe to restore, swipe to destroy — because they are the same
//  decision at different scales.
//
//  Restoring is the primary action and the one on the leading edge; purging is
//  destructive, on the trailing edge, and always asks first. Nothing here is
//  undoable by the undo stack, so the confirmations are the only safety net.
//

import SwiftUI

struct TrashView<Item: Decodable & Identifiable & HALResource, Row: View>: View
where Item.ID == Int {
    @State private var model: TrashModel<Item>
    let title: String
    let emptyMessage: String
    /// Draws one item; the caller knows what its items look like.
    @ViewBuilder let row: (Item) -> Row
    /// Called after anything is restored, so the caller can reload behind us.
    var onChanged: () async -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var pendingPurge: Item?
    @State private var confirmEmpty = false

    init(app: AppModel,
         source: HALLink,
         title: String,
         emptyMessage: String,
         onChanged: @escaping () async -> Void = {},
         @ViewBuilder row: @escaping (Item) -> Row) {
        _model = State(initialValue: TrashModel<Item>(app: app, source: source))
        self.title = title
        self.emptyMessage = emptyMessage
        self.onChanged = onChanged
        self.row = row
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.items) { item in
                    row(item)
                        .swipeActions(edge: .leading) {
                            if model.canRestore(item) {
                                Button {
                                    Task {
                                        if await model.restore(item) { await onChanged() }
                                    }
                                } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }
                                .tint(.blue)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            if model.canPurge(item) {
                                Button(role: .destructive) {
                                    pendingPurge = item
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        .contextMenu {
                            if model.canRestore(item) {
                                Button {
                                    Task {
                                        if await model.restore(item) { await onChanged() }
                                    }
                                } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }
                            }
                            if model.canPurge(item) {
                                Button(role: .destructive) {
                                    pendingPurge = item
                                } label: {
                                    Label("Delete Permanently", systemImage: "trash")
                                }
                            }
                        }
                }
            }
            .overlay { emptyState }
            .navigationTitle(title)
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if model.canEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button(role: .destructive) {
                            confirmEmpty = true
                        } label: {
                            Label("Empty Trash", systemImage: "trash.slash")
                        }
                        .disabled(model.isWorking)
                    }
                }
            }
            .task { await model.load() }
            .refreshable { await model.load() }
            .alert("Delete Permanently", isPresented: purgeBinding) {
                Button("Cancel", role: .cancel) { pendingPurge = nil }
                Button("Delete", role: .destructive) {
                    let item = pendingPurge
                    pendingPurge = nil
                    Task {
                        guard let item else { return }
                        await model.purge(item)
                    }
                }
            } message: {
                Text("This cannot be undone.")
            }
            .alert("Empty Trash", isPresented: $confirmEmpty) {
                Button("Cancel", role: .cancel) {}
                Button("Empty Trash", role: .destructive) {
                    Task { await model.emptyTrash() }
                }
            } message: {
                Text("Permanently delete everything in the trash. This cannot be undone.")
            }
            .alert("Error", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isEmpty {
            if model.isLoading {
                ProgressView()
            } else {
                ContentUnavailableView(
                    "Trash is Empty",
                    systemImage: "trash",
                    description: Text(emptyMessage))
            }
        }
    }

    private var purgeBinding: Binding<Bool> {
        Binding(get: { pendingPurge != nil },
                set: { if !$0 { pendingPurge = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }
}

/// One deleted screenplay element.
struct DeletedBlockRow: View {
    let block: DeletedBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let type = block.typeLabel {
                    Text(type.uppercased())
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let deleted = block.deletedAt {
                    Text(deleted, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(block.displayPreview)
                .font(.callout)
                .foregroundStyle(block.isEmptyElement ? .secondary : .primary)
                .lineLimit(2)

            HStack(spacing: 6) {
                if let who = block.deletedByName, !who.isEmpty {
                    Text("Deleted by \(who)")
                }
                if let purge = block.purgeAt {
                    Text("· Removed \(purge, format: .relative(presentation: .named))")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

/// One deleted song or note.
struct DeletedDocumentRow: View {
    let document: DeletedDocument

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
                if let deleted = document.deletedAt {
                    Text(deleted, format: .relative(presentation: .named))
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

            if let purge = document.purgesAt {
                Text("Removed \(purge, format: .relative(presentation: .named))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// One deleted screenplay.
struct TrashedProjectRow: View {
    let project: TrashedProject

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(project.displayTitle)
                .font(.body.weight(.medium))
            if let deleted = project.deletedAt {
                Text("Deleted \(deleted, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
