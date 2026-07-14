//
//  ScriptView.swift
//  scripty
//
//  The screenplay page for one project. Blocks are edited in place — tap into
//  one and type, Return opens the next element — with undo/redo, characters and
//  export alongside, every affordance gated by the links the server advertised.
//

import SwiftUI

struct ScriptView: View {
    @State private var model: ScriptModel
    @State private var detailBlock: Block?
    @State private var showingCharacters = false

    init(app: AppModel, project: Project) {
        _model = State(initialValue: ScriptModel(app: app, project: project))
    }

    /// The block under the caret, which the element bar acts on.
    private var focusedBlock: Block? {
        model.blocks.first { $0.id == model.focusedBlockID }
    }

    var body: some View {
        ScrollViewReader { scroll in
            List {
                ForEach(model.blocks) { block in
                    row(for: block)
                        .id(block.id)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 24))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            swipeActions(for: block)
                        }
                        .contextMenu {
                            if block.isEditable {
                                Button {
                                    detailBlock = block
                                } label: {
                                    Label("Details…", systemImage: "info.circle")
                                }
                            }
                        }
                }
            }
            .listStyle(.plain)
            // Return puts the caret in a block that may be below the fold.
            .onChange(of: model.focusedBlockID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    scroll.scrollTo(id, anchor: .center)
                }
            }
        }
        .overlay { emptyState }
        .safeAreaInset(edge: .bottom) {
            if let block = focusedBlock {
                ElementTypeBar(model: model, block: block)
            }
        }
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
        .sheet(item: $detailBlock) { block in
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

    /// Only blocks the server says we may edit become text fields; the rest
    /// (a read-only share, a page break) stay as rendered page elements.
    @ViewBuilder
    private func row(for block: Block) -> some View {
        if block.isEditable, block.blockType != .pageBreak {
            EditableBlockRow(model: model, block: block)
        } else {
            BlockRowView(block: block)
                .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private func swipeActions(for block: Block) -> some View {
        if block.hasLink(.delete) {
            Button(role: .destructive) {
                Task { await model.deleteBlock(block) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        if block.hasLink(.toggleBookmark) {
            Button {
                Task { await model.toggleBookmark(block) }
            } label: {
                Label("Bookmark", systemImage: "bookmark")
            }
            .tint(.orange)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.blocks.isEmpty {
            if model.isLoading {
                ProgressView()
            } else if model.canStartScript {
                ContentUnavailableView {
                    Label("Empty Script", systemImage: "doc.plaintext")
                } description: {
                    Text("Start writing — return opens the next element.")
                } actions: {
                    Button("Start Writing") {
                        Task { await model.createInitialBlock() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView(
                    "Empty Script",
                    systemImage: "doc.plaintext",
                    description: Text("This script has nothing in it yet."))
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.canAppendBlock {
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
            get: { model.errorMessage != nil && detailBlock == nil },
            set: { if !$0 { model.errorMessage = nil } })
    }
}
