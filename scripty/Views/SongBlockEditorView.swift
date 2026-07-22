//
//  SongBlockEditorView.swift
//  scripty
//
//  A song as its lyric lines, which is how the server has always stored one.
//
//  Return makes the next line, Backspace on an empty one removes it, and each
//  line can be tinted, moved or deleted on its own. Editing a song as a single
//  block of text — which is what this client did before — could not express any
//  of that, and left editions and per-line history unreachable.
//

import SwiftUI

struct SongBlockEditorView: View {
    @State private var model: SongBlockModel
    @State private var editions: SongEditionsModel

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedLine: Int?

    /// The same device-wide readout preference the screenplay honours.
    private let settings = PresentationSettings.shared
    @State private var showingEditions = false
    @State private var showingVersions = false
    @State private var showingTrash = false

    init(app: AppModel, document: TextDocument) {
        _model = State(initialValue: SongBlockModel(app: app, document: document))
        _editions = State(initialValue: SongEditionsModel(app: app, document: document))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(model.blocks) { block in
                        line(block)
                            .id(block.id)
                    }
                }
                .listStyle(.plain)
                .onChange(of: focusedLine) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .overlay { emptyState }
            .safeAreaInset(edge: .top, spacing: 0) { editionBanner }
            .safeAreaInset(edge: .bottom, spacing: 0) { wordCountBar }
            .navigationTitle(model.document.displayTitle)
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
            .task {
                await model.load()
                await editions.load()
            }
            .sheet(isPresented: $showingEditions) {
                EditionsView(model: editions) { edition in
                    // Flush anything half-typed before the lyric is replaced.
                    await model.commitAll()
                    model.editionBlocksLink = editions.blocksLink(for: edition)
                }
            }
            .sheet(isPresented: $showingVersions) {
                if let versions = model.versionsLink {
                    VersionHistoryView(app: model.app, source: versions, subject: "song") {
                        // A restore rewrites the lyric, so reload rather than
                        // trusting the lines on screen.
                        await model.load()
                    }
                }
            }
            .sheet(isPresented: $showingTrash) {
                if let trash = model.trashLink {
                    TrashView(app: model.app,
                              source: trash,
                              title: "Deleted Lines",
                              emptyMessage: "Lines you delete from this song can be restored here.",
                              onChanged: {
                                  // A restored line goes back into the lyric,
                                  // so the list on screen is out of date.
                                  await model.load()
                              }) { (line: DeletedSongBlock) in
                        DeletedSongBlockRow(line: line)
                    }
                }
            }
            .alert("Error", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    /// One lyric line.
    ///
    /// The per-line actions hang off the number in the margin rather than off
    /// a context menu on the row. The text field fills the row and swallows a
    /// long press, so a row-level menu is simply unreachable — which is how the
    /// first version of this shipped, with Move, Highlight and Delete visible
    /// in the code and unusable in the app. The number is also worth having:
    /// lyrics get discussed by line.
    private func line(_ block: SongBlock) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Menu {
                lineMenu(block)
            } label: {
                Text("\(block.order ?? 0)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Line \(block.order ?? 0) actions")

            TextField("", text: binding(for: block), axis: .vertical)
                .focused($focusedLine, equals: block.id)
                .disabled(!block.isEditable)
                .submitLabel(.return)
                .onSubmit {
                    Task {
                        if let created = await model.addLine(below: block) {
                            focusedLine = created
                        }
                    }
                }
                .onChange(of: focusedLine) { previous, _ in
                    // Save on the way out rather than waiting for the debounce.
                    if previous == block.id {
                        Task { await model.commit(block) }
                    }
                }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .listRowBackground(rowBackground(block))
        .swipeActions(edge: .trailing) {
            if block.hasLink(.delete) {
                Button(role: .destructive) {
                    Task { await model.delete(block) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func rowBackground(_ block: SongBlock) -> some View {
        if let tint = block.tint {
            tint.color(for: colorScheme)
        } else {
            Color.clear
        }
    }

    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    private func lineMenu(_ block: SongBlock) -> some View {
        if model.canMoveUp(block) {
            Button {
                Task { await model.move(block, by: -1) }
            } label: {
                Label("Move Up", systemImage: "arrow.up")
            }
        }
        if model.canMoveDown(block) {
            Button {
                Task { await model.move(block, by: 1) }
            } label: {
                Label("Move Down", systemImage: "arrow.down")
            }
        }
        if block.hasLink(.setHighlight) {
            Menu {
                ForEach(BlockHighlight.allCases) { colour in
                    Button(colour.label) {
                        Task { await model.setHighlight(block, to: colour) }
                    }
                }
                Button("None") {
                    Task { await model.setHighlight(block, to: nil) }
                }
            } label: {
                Label("Highlight", systemImage: "highlighter")
            }
        }
        if block.hasLink(.delete) {
            Button(role: .destructive) {
                Task { await model.delete(block) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// Says which edition is open, but only when it is not the default —
    /// the same rule and the same reasoning as the screenplay's banner.
    @ViewBuilder
    private var editionBanner: some View {
        if let edition = editions.selected, !edition.isTheDefault {
            Button {
                showingEditions = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "music.note.list")
                        .font(.caption)
                    Text("Editing")
                        .foregroundStyle(.secondary)
                    Text(edition.displayName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .font(.footnote)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(.tint.opacity(0.10))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(.separator).frame(height: 0.5)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Editing the \(edition.displayName) edition. Change edition.")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") {
                Task {
                    await model.commitAll()
                    dismiss()
                }
            }
        }
        // Undo sits on the leading edge, where the screenplay editor puts it,
        // and only appears where the server keeps a stack for this song.
        if model.hasUndoStack {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    Task { await model.undo() }
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!model.canUndo)

                Button {
                    Task { await model.redo() }
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(!model.canRedo)
            }
        }
        ToolbarItem(placement: .secondaryAction) {
            Toggle(isOn: wordCountBinding) {
                Label("Word Count", systemImage: "number")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.trashLink != nil {
                Button {
                    showingTrash = true
                } label: {
                    Label("Deleted Lines", systemImage: "trash")
                }
            }
            if editions.hasChoice || editions.canCreate {
                Button {
                    showingEditions = true
                } label: {
                    Label("Editions", systemImage: "doc.on.doc")
                }
            }
            if model.versionsLink != nil {
                Button {
                    showingVersions = true
                } label: {
                    Label("Version History", systemImage: "clock.arrow.circlepath")
                }
            }
            if model.canAddLine {
                Button {
                    Task {
                        if let created = await model.appendLine() {
                            focusedLine = created
                        }
                    }
                } label: {
                    Label("Add Line", systemImage: "plus")
                }
            }
        }
    }

    /// How many words the lyric runs to, counted over what is on screen rather
    /// than what was last saved — the web watches the textareas for the same
    /// reason. No page estimate here: a song is measured in lines, not pages.
    @ViewBuilder
    private var wordCountBar: some View {
        if settings.showsWordCount {
            let words = model.blocks.reduce(0) { running, block in
                running + ScriptStats.countWords(model.currentText(block))
            }
            Text("\(ScriptWordCount.formatted(words)) words")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .background(.bar)
                .overlay(alignment: .top) {
                    Rectangle().fill(.separator).frame(height: 0.5)
                }
        }
    }

    private var wordCountBinding: Binding<Bool> {
        Binding(get: { settings.showsWordCount }, set: { settings.showsWordCount = $0 })
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.blocks.isEmpty {
            if model.isLoading {
                ProgressView()
            } else {
                ContentUnavailableView {
                    Label("No Lyrics Yet", systemImage: "music.note")
                } description: {
                    Text("Add the first line to start writing.")
                } actions: {
                    if model.canAddLine {
                        Button("Add Line") {
                            Task {
                                if let created = await model.appendLine() {
                                    focusedLine = created
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    private func binding(for block: SongBlock) -> Binding<String> {
        Binding(
            get: { model.currentText(block) },
            set: { model.edit(block, text: $0) })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }
}
