//
//  ScriptView.swift
//  scripty
//
//  The screenplay page for one project: blocks rendered per element type,
//  with editing, undo/redo, characters, and export — every affordance
//  gated by the links the server advertised.
//

import SwiftUI

struct ScriptView: View {
    @State private var model: ScriptModel
    @State private var editingBlock: Block?
    @State private var showingCreate = false
    @State private var showingCharacters = false

    init(app: AppModel, project: Project) {
        _model = State(initialValue: ScriptModel(app: app, project: project))
    }

    var body: some View {
        List {
            ForEach(model.blocks) { block in
                BlockRowView(block: block)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 24, bottom: 4, trailing: 24))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if block.isEditable {
                            editingBlock = block
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
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
            }
        }
        .listStyle(.plain)
        .overlay {
            if model.blocks.isEmpty {
                if model.isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView(
                        "Empty Script",
                        systemImage: "doc.plaintext",
                        description: Text("Add a block to start writing."))
                }
            }
        }
        .navigationTitle(model.project.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingCreate = true
                } label: {
                    Label("Add Block", systemImage: "plus")
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
        .refreshable {
            await model.loadBlocks()
            await model.refreshUndoRedo()
        }
        .task {
            await model.loadEverything()
            model.startSyncPolling()
        }
        .onDisappear { model.stopSyncPolling() }
        .sheet(item: $editingBlock) { block in
            BlockEditorSheet(model: model, block: block)
        }
        .sheet(isPresented: $showingCreate) {
            BlockEditorSheet(model: model, block: nil)
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

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil && editingBlock == nil && !showingCreate },
            set: { if !$0 { model.errorMessage = nil } })
    }
}
