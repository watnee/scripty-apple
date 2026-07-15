//
//  ScriptView.swift
//  scripty
//
//  The screenplay page for one project. Editing happens inline, the way the
//  web editor works: tap a block and type, press Return for the next element,
//  Backspace at the start to merge upward, and use the element-type bar to
//  retype. Every affordance is still gated by the links the server advertised.
//

import SwiftUI

struct ScriptView: View {
    @State private var model: ScriptModel
    @State private var detailsBlock: Block?
    @State private var showingCharacters = false

    init(app: AppModel, project: Project) {
        _model = State(initialValue: ScriptModel(app: app, project: project))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.blocks) { block in
                    row(for: block)
                        .padding(.horizontal, 24)
                        .id(block.id)
                }
            }
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .overlay { emptyState }
        .safeAreaInset(edge: .bottom) { elementBar }
        .navigationTitle(model.project.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .refreshable {
            await model.loadBlocks()
            await model.refreshUndoRedo()
        }
        .task {
            await model.loadEverything()
            model.startSyncPolling()
        }
        .onDisappear { model.stopSyncPolling() }
        .sheet(item: $detailsBlock) { block in
            BlockEditorSheet(model: model, block: block)
        }
        .sheet(isPresented: $showingCharacters) {
            CharactersView(model: model)
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func row(for block: Block) -> some View {
        if block.isEditable {
            EditableBlockRow(model: model, block: block,
                             onOpenDetails: { detailsBlock = block })
        } else {
            // Read-only blocks (no edit link): render, but don't offer editing.
            BlockRowView(block: block)
                .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.blocks.isEmpty {
            if model.isLoading {
                ProgressView()
            } else if model.canEditScript {
                ContentUnavailableView {
                    Label("Empty Script", systemImage: "doc.plaintext")
                } description: {
                    Text("Start writing to add your first element.")
                } actions: {
                    Button("Start Writing") {
                        Task { await model.createFirstBlock() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView("Empty Script", systemImage: "doc.plaintext")
            }
        }
    }

    @ViewBuilder
    private var elementBar: some View {
        if let id = model.focusedBlockId, let block = model.blocks.first(where: { $0.id == id }) {
            ElementTypeBar(model: model, block: block)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.canEditScript {
                Button {
                    Task { await model.appendBlock() }
                } label: {
                    Label("Add Block", systemImage: "plus")
                }
            }

            if model.canViewCharacters {
                Button {
                    showingCharacters = true
                } label: {
                    Label("Characters", systemImage: "person.2")
                }
            }

            if !model.exportOptions.isEmpty {
                ExportButton(model: model)
            }
        }

        if let undoRedo = model.undoRedo {
            ToolbarItemGroup(placement: .secondaryAction) {
                Button {
                    Task { await model.undo() }
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!(undoRedo.canUndo ?? false))

                Button {
                    Task { await model.redo() }
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(!(undoRedo.canRedo ?? false))
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil && detailsBlock == nil && !showingCharacters },
            set: { if !$0 { model.errorMessage = nil } })
    }
}
