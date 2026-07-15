//
//  ScriptView.swift
//  scripty
//
//  The screenplay page for one project. Blocks are edited inline — you type
//  straight onto the page the way the web app works — with Return splitting
//  into the next element, Backspace merging into the one above, and an
//  element-type bar for retyping. Every affordance is gated by the links the
//  server advertised; a read-only viewer still sees the page, just not the
//  keyboard.
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
                        .id(block.id)
                }
            }
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .overlay { emptyState }
        .safeAreaInset(edge: .bottom) { typeBar }
        .navigationTitle(model.project.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
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
            EditableBlockRow(model: model, block: block) {
                detailsBlock = block
            }
        } else {
            BlockRowView(block: block)
                .padding(.vertical, 4)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.blocks.isEmpty {
            if model.isLoading {
                ProgressView()
            } else if model.canSeedInitial {
                ContentUnavailableView {
                    Label("Empty Script", systemImage: "doc.plaintext")
                } description: {
                    Text("Start writing to add your first element.")
                } actions: {
                    Button("Start Writing") {
                        Task { await model.seedInitialBlock() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView(
                    "Empty Script",
                    systemImage: "doc.plaintext",
                    description: Text("This script has no elements yet."))
            }
        }
    }

    @ViewBuilder
    private var typeBar: some View {
        if let id = model.focusedBlockId,
           let block = model.blocks.first(where: { $0.id == id }),
           block.hasLink(.setType) {
            ElementTypeBar(model: model, block: block)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.canSeedInitial || model.blocks.contains(where: { $0.hasLink(.createBelow) }) {
                Button {
                    Task { await model.appendBlock() }
                } label: {
                    Label("Add Element", systemImage: "plus")
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
