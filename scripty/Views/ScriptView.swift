//
//  ScriptView.swift
//  scripty
//
//  The screenplay page for one project: a continuous document, the way the web
//  editor works. You type straight into the page — Return opens the next
//  element, Tab retypes the current one, Backspace at the top of an empty one
//  removes it. Every affordance is still gated by the links the server sent.
//

import SwiftUI

struct ScriptView: View {
    @State private var model: ScriptModel
    @State private var showingCharacters = false
    @State private var detailBlock: Block?

    /// A US Letter page body at screenplay measure. Indents are fractions of
    /// this, matching the web's `--screenplay-*-indent`.
    private static let pageWidth: CGFloat = 620

    init(app: AppModel, project: Project) {
        _model = State(initialValue: ScriptModel(app: app, project: project))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.blocks) { block in
                        BlockEditorRow(model: model,
                                       block: block,
                                       pageWidth: Self.pageWidth,
                                       onShowDetails: { detailBlock = block })
                            .id(block.id)
                    }
                }
                .frame(maxWidth: Self.pageWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .padding(.horizontal, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.focus?.generation) {
                guard let id = model.focus?.blockId else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .overlay { emptyState }
        .safeAreaInset(edge: .bottom) {
            if let block = focusedBlock, block.hasLink(.setType) {
                ElementTypeBar(current: block.blockType) { type in
                    Task { await model.retype(block, to: type) }
                } onDone: {
                    model.endEditing()
                }
            }
        }
        .navigationTitle(model.project.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .refreshable {
            await model.flushDrafts()
            await model.loadBlocks()
            await model.refreshUndoRedo()
        }
        .task {
            await model.loadEverything()
            model.startSyncPolling()
        }
        .onDisappear {
            model.stopSyncPolling()
            Task { await model.flushDrafts() }
        }
        .sheet(isPresented: $showingCharacters) {
            CharactersView(model: model)
        }
        .sheet(item: $detailBlock) { block in
            BlockDetailsSheet(model: model, block: block)
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var focusedBlock: Block? {
        guard let id = model.focus?.blockId else { return nil }
        return model.blocks.first { $0.id == id }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.blocks.isEmpty {
            if model.isLoading {
                ProgressView()
            } else {
                ContentUnavailableView {
                    Label("Empty Script", systemImage: "doc.plaintext")
                } description: {
                    Text("Start typing to write your first scene.")
                } actions: {
                    // The server only offers this link while the script is empty.
                    if model.blocksLinks.contains(.createInitial) {
                        Button("Start Writing") {
                            Task { await model.createInitialBlock() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await model.appendBlock() }
            } label: {
                Label("Add Element", systemImage: "plus")
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

// MARK: - One element on the page

private struct BlockEditorRow: View {
    let model: ScriptModel
    let block: Block
    let pageWidth: CGFloat
    let onShowDetails: () -> Void

    var body: some View {
        element
            .padding(.top, ScreenplayLayout.topPadding(for: block.blockType))
            .padding(.bottom, 2)
            .overlay(alignment: .topTrailing) { badges }
            .contextMenu { menu }
    }

    @ViewBuilder
    private var element: some View {
        let layout = ScreenplayLayout.of(block.blockType)

        if block.blockType == .pageBreak {
            pageBreak
        } else if block.isEditable {
            BlockTextView(
                block: block,
                text: model.content(of: block),
                focus: model.focus,
                onEdit: { model.edit(block, content: $0) },
                onReturn: { before, after in
                    Task { await model.splitBlock(block, before: before, after: after) }
                },
                onTab: { backward in
                    Task { await model.cycleType(block, backward: backward) }
                },
                onBackspaceAtStart: {
                    Task { await model.backspaceAtStart(of: block) }
                },
                onFocus: { model.focusArrived(at: block.id) })
            .frame(width: pageWidth * layout.width)
            .padding(.leading, pageWidth * layout.indent)
        } else {
            // No update link: render it, don't offer to edit it.
            BlockRowView(block: block)
        }
    }

    private var pageBreak: some View {
        HStack(spacing: 12) {
            line
            Text("PAGE BREAK")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            line
        }
        .padding(.vertical, 8)
        .frame(width: pageWidth)
    }

    private var line: some View {
        Rectangle().fill(.tertiary).frame(height: 1)
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 4) {
            if block.isPinned { Image(systemName: "pin.fill") }
            if block.isBookmarked { Image(systemName: "bookmark.fill") }
        }
        .font(.caption2)
        .foregroundStyle(.orange)
    }

    @ViewBuilder
    private var menu: some View {
        if block.hasLink(.setType) {
            Menu("Change Element To") {
                ForEach(BlockType.allCases) { type in
                    Button {
                        Task { await model.retype(block, to: type) }
                    } label: {
                        if type == block.blockType {
                            Label(type.label, systemImage: "checkmark")
                        } else {
                            Text(type.label)
                        }
                    }
                }
            }
        }
        if block.hasLink(.update) {
            Button {
                onShowDetails()
            } label: {
                Label("Speaker & Tags", systemImage: "tag")
            }
        }
        if block.hasLink(.toggleBookmark) {
            Button {
                Task { await model.toggleBookmark(block) }
            } label: {
                Label(block.isBookmarked ? "Remove Bookmark" : "Bookmark",
                      systemImage: block.isBookmarked ? "bookmark.slash" : "bookmark")
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
                Task { await model.deleteBlock(block) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

// MARK: - Element bar

/// The touch equivalent of Tab. The web puts an element toolbar above the
/// script for the same reason: without a hardware keyboard there is no Tab key.
private struct ElementTypeBar: View {
    let current: BlockType
    let onSelect: (BlockType) -> Void
    let onDone: () -> Void

    /// The classic seven, in Tab order; the rest live behind the ellipsis.
    private var secondary: [BlockType] {
        BlockType.allCases.filter { !Fountain.tabCycle.contains($0) }
    }

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Fountain.tabCycle) { type in
                        Button(type.label) { onSelect(type) }
                            .buttonStyle(.bordered)
                            .tint(type == current ? .accentColor : .secondary)
                    }
                    Menu {
                        ForEach(secondary) { type in
                            Button(type.label) { onSelect(type) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 12)
            }

            Button("Done", action: onDone)
                .buttonStyle(.borderedProminent)
                .padding(.trailing, 12)
        }
        .padding(.vertical, 8)
        .background(.bar)
    }
}
