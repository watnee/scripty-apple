//
//  SongBlockEditorView.swift
//  scripty
//
//  A song as its lyric lines, which is how the server has always stored one.
//
//  Return makes the next line, Backspace at the head of one folds it into the
//  line above, and each line can be tinted, moved or deleted on its own.
//  Editing a song as a single block of text — which is what this client did
//  before — could not express any of that, and left editions and per-line
//  history unreachable.
//

import SwiftUI

struct SongBlockEditorView: View {
    @State private var model: SongBlockModel
    @State private var editions: EditionsModel

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedLine: Int?

    /// The same device-wide readout preference the screenplay honours.
    private let settings = PresentationSettings.shared
    @State private var showingEditions = false
    @State private var showingVersions = false
    @State private var showingTrash = false
    @State private var showingIgnoredWords = false
    /// Whether the search bar is up. A button rather than a standing field:
    /// `.searchable` in this sheet draws a full-width bar across the bottom of
    /// every opening — `.searchToolbarBehavior(.minimize)` collapses a toolbar
    /// field only outside a sheet — and searching is the rare errand here, not
    /// the ordinary state. The screenplay's search is a toolbar button for the
    /// same reason.
    @State private var isSearching = false
    @State private var searchText = ""
    /// Which lines the current search matched, by id.
    ///
    /// Held rather than recomputed from the text on every redraw because these
    /// rows are editable: typing in a visible line changes what it says, and a
    /// live filter would make the line vanish out from under the cursor the
    /// moment it stopped matching. The set is refreshed when the query changes
    /// or the lyric is reloaded, which is exactly when the web re-runs its own
    /// filter.
    @State private var matchedLines: Set<Int> = []

    init(app: AppModel, document: TextDocument) {
        _model = State(initialValue: SongBlockModel(app: app, document: document))
        _editions = State(initialValue: EditionsModel(app: app, document: document))
    }

    private var query: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    /// The lyric, narrowed to the lines that matched. An empty query shows the
    /// whole song, which is the ordinary state of this editor.
    private var shownBlocks: [SongBlock] {
        query.isEmpty ? model.blocks : model.blocks.filter { matchedLines.contains($0.id) }
    }

    /// Recomputes the matched set from what the lines currently say.
    private func runSearch() {
        let needle = query.lowercased()
        guard !needle.isEmpty else {
            matchedLines = []
            return
        }
        matchedLines = Set(
            model.blocks.filter { $0.text.lowercased().contains(needle) }.map(\.id))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(shownBlocks) { block in
                        SongLineRow(model: model,
                                    block: block,
                                    focusedLine: $focusedLine)
                            .id(block.id)
                            // No hairline between one lyric line and the next.
                            // A plain list rules off every row, which turns a
                            // verse into a table; the screenplay draws its
                            // blocks in a LazyVStack with nothing between them,
                            // and a lyric reads the same way. The tinted row
                            // backgrounds still separate highlighted lines.
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                // One device-wide type size scales the lyric here, the way it
                // scales the screenplay — the web reuses its global text-size
                // preference for song lines for the same reason.
                .environment(\.scriptTextScale, settings.textScale)
                .onChange(of: focusedLine) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .overlay { emptyState }
            .safeAreaInset(edge: .top, spacing: 0) { editionBanner }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    searchBar
                    wordCountBar
                }
            }
            .navigationTitle(model.document.displayTitle)
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
            .onChange(of: searchText) { _, _ in
                runSearch()
            }
            .task {
                await model.load()
                await editions.load()
                // A reloaded lyric is a different set of lines; re-match so a
                // search left running does not keep hiding rows by stale id.
                runSearch()
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
                        runSearch()
                    }
                }
            }
            .sheet(isPresented: $showingIgnoredWords) {
                SpellcheckWordsView()
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
                                  runSearch()
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
                // Both rewind the lyric to a different set of lines, so the
                // matched set has to be taken again or a search would keep
                // hiding rows by ids that no longer mean anything.
                Button {
                    Task {
                        await model.undo()
                        runSearch()
                    }
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!model.canUndo)

                Button {
                    Task {
                        await model.redo()
                        runSearch()
                    }
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
        // The same device-wide spelling controls the screenplay's View menu
        // carries. A lyric is where they are needed most — invented words,
        // dialect spellings and names by the verse — and this editor had no way
        // to reach them at all.
        ToolbarItem(placement: .secondaryAction) {
            SpellingMenu(showingIgnoredWords: $showingIgnoredWords)
        }
        // Text size, the web song editor's Tools-menu A−/A+. It drives the same
        // device-wide preference the screenplay editor changes, so a size set
        // here shows up there and vice versa. No keyboard shortcuts: the
        // screenplay already owns ⌘+/⌘−, and this editor opens over it.
        ToolbarItem(placement: .secondaryAction) {
            Menu {
                Button {
                    settings.increaseTextSize()
                } label: {
                    Label("Bigger", systemImage: "textformat.size.larger")
                }
                .disabled(!settings.canIncreaseTextSize)

                Button {
                    settings.decreaseTextSize()
                } label: {
                    Label("Smaller", systemImage: "textformat.size.smaller")
                }
                .disabled(!settings.canDecreaseTextSize)

                Button {
                    settings.resetTextSize()
                } label: {
                    Label("Actual Size (\(settings.textSize)%)", systemImage: "textformat")
                }
                .disabled(settings.textSize == PresentationSettings.defaultTextSize)
            } label: {
                Label("Text Size", systemImage: "textformat.size")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            // No keyboard shortcut on Search: the screenplay's own button owns
            // ⌘F, and this editor opens over it — the same reason the text-size
            // menu below claims no keys.
            Button {
                isSearching.toggle()
                if !isSearching { searchText = "" }
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
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
        }
    }

    @ViewBuilder
    private var searchBar: some View {
        if isSearching {
            SongSearchBar(text: $searchText) {
                isSearching = false
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
            WordCountBar(words: words)
        }
    }

    private var wordCountBinding: Binding<Bool> {
        Binding(get: { settings.showsWordCount }, set: { settings.showsWordCount = $0 })
    }

    @ViewBuilder
    private var emptyState: some View {
        if shownBlocks.isEmpty {
            if !query.isEmpty {
                // The song has lines, none of them say this — not an empty song.
                ContentUnavailableView.search(text: query)
            } else if model.isLoading {
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

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }
}

/// Find-in-lyric, presented as a bar above the keyboard the way the
/// screenplay's search is — but narrowing the list rather than stepping a
/// cursor through hits, which is how the web song editor filters its lines.
private struct SongSearchBar: View {
    @Binding var text: String
    /// Called when the writer taps Done; the host hides the bar.
    let onDismiss: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search lyrics", text: $text)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($isFocused)
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear Search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            Button("Done") {
                text = ""
                isFocused = false
                onDismiss()
            }
            .font(.body.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // No background of its own: the host mounts it with `.safeAreaBar`,
        // which supplies the Liquid Glass and the separation from the lyric.
        .onAppear { isFocused = true }
    }
}
