//
//  ScriptView.swift
//  scripty
//
//  The screenplay page for one project — a continuous editor, like the web
//  app: tap a block to type in place, Return starts the next element below,
//  the type bar retypes the current one, and rows drag to reorder. Every
//  affordance is gated by the links the server advertised.
//

import SwiftUI

struct ScriptView: View {
    @State private var model: ScriptModel
    @State private var detailBlock: Block?
    @State private var showingCharacters = false

    /// The block currently being typed into, and its uncommitted text.
    @State private var editingID: Int?
    @State private var draft = ""
    @FocusState private var focusedBlockID: Int?

    init(app: AppModel, project: Project) {
        _model = State(initialValue: ScriptModel(app: app, project: project))
    }

    private var editingBlock: Block? {
        editingID.flatMap { id in model.blocks.first { $0.id == id } }
    }

    var body: some View {
        List {
            ForEach(model.blocks) { block in
                row(for: block)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 24, bottom: 4, trailing: 24))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if block.hasLink(.delete) {
                            Button(role: .destructive) {
                                Task { await delete(block) }
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
            .onMove { source, destination in
                Task {
                    await commitEdit()
                    await model.moveBlocks(from: source, to: destination)
                }
            }
        }
        .listStyle(.plain)
        .overlay { emptyState }
        .navigationTitle(model.project.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) { typeBar }
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
            BlockDetailsSheet(model: model, block: block)
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

    // MARK: - Rows

    @ViewBuilder
    private func row(for block: Block) -> some View {
        if editingID == block.id {
            BlockEditorRow(block: block, text: $draft, focusedBlockID: $focusedBlockID)
                .onChange(of: draft) { _, text in
                    // A newline means Return: split here into a new element.
                    if text.contains("\n") { splitOnReturn(block) }
                }
                .onChange(of: focusedBlockID) { _, focused in
                    // Focus left this row (keyboard dismissed, another row tapped).
                    if focused != block.id, editingID == block.id {
                        Task { await commitEdit() }
                    }
                }
        } else {
            BlockRowView(block: block)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard block.isEditable else { return }
                    Task { await beginEditing(block) }
                }
                .contextMenu { contextMenu(for: block) }
        }
    }

    @ViewBuilder
    private func contextMenu(for block: Block) -> some View {
        if block.isEditable {
            Button {
                detailBlock = block
            } label: {
                Label("Details…", systemImage: "info.circle")
            }
        }
        if block.hasLink(.createBelow) {
            Button {
                Task { await addBlock(below: block) }
            } label: {
                Label("Add Block Below", systemImage: "text.insert")
            }
        }
        if block.hasLink(.togglePinned) {
            Button {
                Task { await model.togglePinned(block) }
            } label: {
                Label(block.isPinned ? "Unpin" : "Pin",
                      systemImage: block.isPinned ? "pin.slash" : "pin")
            }
        }
        if block.hasLink(.delete) {
            Button(role: .destructive) {
                Task { await delete(block) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.blocks.isEmpty {
            if model.isLoading {
                ProgressView()
            } else if model.canCreateInitialBlock {
                ContentUnavailableView {
                    Label("Empty Script", systemImage: "doc.plaintext")
                } description: {
                    Text("Start with a scene heading, an action line — whatever comes first.")
                } actions: {
                    Button("Start Writing") {
                        Task {
                            if let block = await model.createInitialBlock() {
                                await beginEditing(block)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView(
                    "Empty Script",
                    systemImage: "doc.plaintext",
                    description: Text("This script has no blocks yet."))
            }
        }
    }

    // MARK: - Type bar

    @ViewBuilder
    private var typeBar: some View {
        if let block = editingBlock, block.hasLink(.setType) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 8) {
                    BlockTypeBar(current: block.blockType) { type in
                        Task { await retype(block, to: type) }
                    }
                    Button("Done") {
                        Task { await endEditing() }
                    }
                    .font(.footnote.weight(.semibold))
                    .padding(.trailing, 12)
                }
                .padding(.vertical, 6)
            }
            .background(.bar)
            .transition(.move(edge: .bottom))
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.canAddBlock {
                Button {
                    Task { await addBlock(below: model.blocks.last) }
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

        if model.canReorder {
            ToolbarItem(placement: .secondaryAction) {
                EditButton()
            }
        }

        if let undoRedo = model.undoRedo {
            ToolbarItemGroup(placement: .secondaryAction) {
                Button {
                    Task {
                        await commitEdit()
                        await model.undo()
                    }
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!(undoRedo.canUndo ?? false))

                Button {
                    Task {
                        await commitEdit()
                        await model.redo()
                    }
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(!(undoRedo.canRedo ?? false))
            }
        }
    }

    // MARK: - Editing

    /// Moves the cursor into `block`, saving whatever was being typed before.
    private func beginEditing(_ block: Block) async {
        if editingID != block.id { await commitEdit() }
        draft = block.content ?? ""
        editingID = block.id
        model.hasActiveEdit = true
        focusedBlockID = block.id
    }

    /// Writes the draft back if it changed. Safe to call when nothing is
    /// being edited.
    private func commitEdit() async {
        guard let block = editingBlock else {
            model.hasActiveEdit = false
            return
        }
        let text = draft
        if text != (block.content ?? "") {
            await model.updateBlock(block, content: text,
                                    personId: block.personId, tags: block.tags)
        }
    }

    private func endEditing() async {
        await commitEdit()
        editingID = nil
        focusedBlockID = nil
        model.hasActiveEdit = false
    }

    /// Return in the editor: the text before the caret stays, the text after
    /// it starts the next element below — the same split the web editor does.
    private func splitOnReturn(_ block: Block) {
        guard let newline = draft.firstIndex(of: "\n") else { return }
        let head = String(draft[draft.startIndex..<newline])
        let tail = String(draft[draft.index(after: newline)...])
        draft = head   // strip the newline; blocks are single elements

        Task {
            if head != (block.content ?? "") {
                await model.updateBlock(block, content: head,
                                        personId: block.personId, tags: block.tags)
            }
            let next = block.blockType.typeBelow
            // Dialogue under a cue (or a parenthetical) keeps the speaker.
            let speaker = next == .dialogue ? block.personId : nil
            if let created = await model.createBlockBelow(block, type: next,
                                                          content: tail, personId: speaker) {
                await beginEditing(created)
            }
        }
    }

    /// The `+` button and the context menu: insert below and start typing.
    private func addBlock(below block: Block?) async {
        await commitEdit()
        let created: Block?
        if let block, block.hasLink(.createBelow) {
            created = await model.createBlockBelow(block, type: block.blockType.typeBelow)
        } else {
            created = await model.createInitialBlock()
        }
        if let created {
            await beginEditing(created)
        }
    }

    private func retype(_ block: Block, to type: BlockType) async {
        guard type != block.blockType else { return }
        // Persist the in-flight text first: setType echoes stored content back,
        // so an uncommitted draft would be overwritten by the response.
        await commitEdit()
        await model.setType(block, to: type)
        // Retyping keeps the caret where it was; pick the text back up from
        // the server's copy, which may have moved a cue name to the speaker.
        draft = model.blocks.first { $0.id == block.id }?.content ?? draft
        focusedBlockID = block.id
    }

    private func delete(_ block: Block) async {
        if editingID == block.id {
            editingID = nil
            focusedBlockID = nil
            model.hasActiveEdit = false
        }
        await model.deleteBlock(block)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil && detailBlock == nil },
            set: { if !$0 { model.errorMessage = nil } })
    }
}
