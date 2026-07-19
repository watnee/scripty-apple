//
//  EditionsView.swift
//  scripty
//
//  The screenplay's named editions — pick one to work in, or manage the set.
//
//  Default and published are shown as separate marks because they are separate
//  decisions: the default is what opens when nothing is named, the published
//  one is what view-only readers see. A writer can be drafting in one while
//  readers stay on the last cut, and a picker that conflated them would hide
//  exactly that.
//

import SwiftUI

struct EditionsView<Model: EditionListing>: View {
    /// Generic over what is being edited: a screenplay's editions and a song's
    /// are the same picker over different contents.
    let model: Model
    /// Called when the writer chooses a different edition to read.
    let onSelect: (ScriptEdition) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isCreating = false
    @State private var newName = ""
    @State private var copyCurrent = true
    @State private var renaming: ScriptEdition?
    @State private var renameText = ""
    @State private var pendingDelete: ScriptEdition?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.editions) { edition in
                        row(edition)
                    }
                } footer: {
                    Text("The default edition opens when none is chosen. "
                         + "The published edition is the one view-only readers see.")
                }
            }
            .overlay { emptyState }
            .navigationTitle("Editions")
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
                            newName = ""
                            copyCurrent = true
                            isCreating = true
                        } label: {
                            Label("New Edition", systemImage: "plus")
                        }
                        .disabled(model.isWorking)
                    }
                }
            }
            .task { await model.load() }
            .refreshable { await model.load() }
            .alert("New Edition", isPresented: $isCreating) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    let name = newName
                    let source = copyCurrent ? model.selected : nil
                    Task { await model.create(name: name, copyFrom: source) }
                }
            } message: {
                Text(copyCurrent && model.selected != nil
                     ? "Starts as a copy of “\(model.selected?.displayName ?? "")”."
                     : "Starts empty.")
            }
            .alert("Rename Edition", isPresented: renameBinding) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Rename") {
                    let edition = renaming
                    let name = renameText
                    renaming = nil
                    Task {
                        guard let edition else { return }
                        await model.rename(edition, to: name)
                    }
                }
            }
            .alert("Delete Edition", isPresented: deleteBinding) {
                Button("Cancel", role: .cancel) { pendingDelete = nil }
                Button("Delete", role: .destructive) {
                    let edition = pendingDelete
                    pendingDelete = nil
                    Task {
                        guard let edition else { return }
                        await model.delete(edition)
                    }
                }
            } message: {
                Text("Delete “\(pendingDelete?.displayName ?? "")” and everything written in it. "
                     + "This cannot be undone.")
            }
            .alert("Error", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    private func row(_ edition: ScriptEdition) -> some View {
        Button {
            Task {
                model.selectedId = edition.id
                await onSelect(edition)
                dismiss()
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: edition.id == model.selected?.id
                      ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(edition.id == model.selected?.id
                                     ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))

                VStack(alignment: .leading, spacing: 3) {
                    Text(edition.displayName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)

                    HStack(spacing: 6) {
                        if edition.isTheDefault { badge("Default", .blue) }
                        if edition.isThePublished { badge("Published", .green) }
                        if let count = edition.blockCount {
                            Text("\(count) \(count == 1 ? model.itemNoun : model.itemNoun + "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let edited = edition.lastEdited {
                        Text("Edited \(edited, format: .relative(presentation: .named))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            if model.canDelete(edition) {
                Button(role: .destructive) {
                    pendingDelete = edition
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .contextMenu {
            if model.canRename(edition) {
                Button {
                    renameText = edition.displayName
                    renaming = edition
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            }
            if model.canSetDefault(edition) {
                Button {
                    Task { await model.setDefault(edition) }
                } label: {
                    Label("Make Default", systemImage: "star")
                }
            }
            if model.canSetPublished(edition) {
                Button {
                    Task { await model.setPublished(edition) }
                } label: {
                    Label("Publish to Readers", systemImage: "eye")
                }
            }
            if model.canDelete(edition) {
                Button(role: .destructive) {
                    pendingDelete = edition
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private func badge(_ text: String, _ colour: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(colour.opacity(0.15), in: Capsule())
            .foregroundStyle(colour)
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.editions.isEmpty {
            if model.isLoading {
                ProgressView()
            } else {
                ContentUnavailableView(
                    "No Editions",
                    systemImage: "doc.on.doc",
                    description: Text("This has a single edition."))
            }
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }
}
