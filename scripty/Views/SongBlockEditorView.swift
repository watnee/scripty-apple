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
    /// The screenplay behind this sheet, so the song can be sent into it from
    /// here — the list's context menu carries the same action, but the writer
    /// who has just finished polishing a verse is standing in this editor, not
    /// over a row.
    private let scriptModel: ScriptModel
    /// Told when the song has landed in the script, so whoever presented this
    /// sheet can clear the way to the screenplay — from the songs list that
    /// means the list dismissing too, as it does for its own insert.
    private let onInserted: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
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
    /// In flight to the screenplay. Guards the button rather than showing a
    /// spinner: the send is one POST and a reload, over in a beat.
    @State private var isInserting = false
    /// What an insert that put nothing in the script has to say for itself —
    /// an empty song, or a send the server refused.
    @State private var insertMessage: String?
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

    /// Whether the song is up to be read rather than written in — where a
    /// lyric opens now, the way Pages and Word open a document on iOS. The
    /// lines are the same lines in the same order; they simply take no caret,
    /// and the swipes that would delete or tint one are put away with it.
    @State private var isReadingView: Bool

    /// Whether documents open to be read, and which way this song was last put.
    private let readingViews = ReadingViewSettings.shared

    init(app: AppModel, document: TextDocument, scriptModel: ScriptModel,
         onInserted: (() -> Void)? = nil) {
        _model = State(initialValue: SongBlockModel(app: app, document: document))
        _editions = State(initialValue: EditionsModel(app: app, document: document))
        _isReadingView = State(initialValue: ReadingViewSettings.shared
            .opensInReadingView(.document(id: document.id)))
        self.scriptModel = scriptModel
        self.onInserted = onInserted
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
                                    focusedLine: $focusedLine,
                                    isReadingView: isReadingView)
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
                // The list pads every row up to its default minimum height,
                // which reads as double spacing between lyric lines. A verse
                // is single-spaced: let each line be exactly as tall as its
                // text, the way the web's song editor draws them near-flush.
                .environment(\.defaultMinListRowHeight, 1)
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
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    editionBanner
                    offlineCopyBanner
                }
            }
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
                // Two things the opening decision could not know until the
                // lyric was in hand. A song with no lines is nothing to read —
                // what it has instead is an Add Line button, which reading
                // view would have hidden. And lines this device is still
                // holding are writing in progress that has not reached the
                // server, which is not a song anyone opened to read.
                if model.blocks.isEmpty || model.hasUnsavedChanges {
                    isReadingView = false
                }
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
            .alert("Insert into Script", isPresented: insertMessageBinding) {
                Button("OK", role: .cancel) { insertMessage = nil }
            } message: {
                Text(insertMessage ?? "")
            }
            // The connection came back: push the lines held on this device
            // right away rather than waiting out each one's retry backoff —
            // the same sweep the screenplay editor runs.
            .onChange(of: model.app.connectivity.isOnline) { _, online in
                guard online else { return }
                Task { await model.syncHeldWork() }
            }
            // Backgrounding flushes the debounced commit immediately; coming
            // back is a second chance for anything still held, since the retry
            // backoffs may have run out while the app slept.
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background, .inactive:
                    // Persist-first: the system may not let the commits run.
                    Task { await model.flushPendingCommits() }
                case .active:
                    if model.hasUnsavedChanges, model.app.connectivity.isOnline {
                        Task { await model.syncHeldWork() }
                    }
                @unknown default:
                    break
                }
            }
        }
    }

    // MARK: - Reading view

    /// Whether the server left this lyric open to be changed at all. Asks the
    /// links rather than the mode: a reader who was never given an editable
    /// line has no edit view to be offered, and a button promising one would
    /// be a promise this app cannot keep.
    private var isSongEditable: Bool {
        model.canAddLine || model.blocks.contains(where: \.isEditable)
    }

    /// Hands the song to the writer, and remembers that this is one they write
    /// in — so Edit is a cost paid once per song rather than on every visit.
    private func beginEditing() {
        isReadingView = false
        readingViews.remember(false, for: .document(id: model.document.id))
    }

    /// Puts it back up to be read, and remembers that too. Half-typed lines go
    /// first: the rows stop taking a caret the moment the flag flips, and a
    /// line still holding uncommitted text would have nowhere left to send it
    /// from.
    private func enterReadingView() {
        Task {
            await model.commitAll()
            isReadingView = true
            readingViews.remember(true, for: .document(id: model.document.id))
        }
    }

    /// Sends the song into the screenplay as Lyrics blocks, at the end of the
    /// script — the same call the list's context menu makes. Half-typed lines
    /// are flushed first, so what lands is what is on screen; a song that
    /// landed dismisses down to the screenplay it just changed.
    private func insert() {
        isInserting = true
        Task {
            await model.commitAll()
            let count = await scriptModel.insertDocument(model.document)
            isInserting = false
            if let count, count > 0 {
                dismiss()
                onInserted?()
            } else if count == 0 {
                insertMessage = "Nothing to insert from \"\(model.document.displayTitle)\"."
            } else {
                insertMessage = scriptModel.errorMessage
                    ?? "Could not insert into the script."
            }
        }
    }

    /// The same standing answer the screenplay shows: where do the words on
    /// this screen currently live? Nil in demo, where there is no cloud to be
    /// honest about.
    private var cloudState: CloudSyncState? {
        guard !model.app.isDemo else { return nil }
        if !model.app.connectivity.isOnline { return .offline }
        // Refused beats retrying: with both on screen, the one that will not
        // fix itself is the one the badge must name.
        if model.hasFailedSaves { return .failed }
        return model.hasUnsavedChanges ? .holding : .synced
    }

    /// Says the lyric on screen is the copy saved on this device, and how old
    /// it is — an out-of-date lyric should not look current. Only shown when
    /// the fallback actually happened, not merely because the radio is off;
    /// the same rule the projects sidebar follows.
    @ViewBuilder
    private var offlineCopyBanner: some View {
        if let savedAt = model.offlineCopySavedAt {
            HStack(spacing: 6) {
                Image(systemName: "wifi.slash")
                    .font(.caption)
                Text("Offline — lyrics saved "
                     + savedAt.formatted(.relative(presentation: .named)))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(.orange.opacity(0.10))
            .overlay(alignment: .bottom) {
                Rectangle().fill(.separator).frame(height: 0.5)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Offline. Showing the lyrics saved on this device "
                                + savedAt.formatted(.relative(presentation: .named)) + ".")
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
        // Beside the way out, where the screenplay keeps it: leaving is the
        // moment a writer wonders whether their words are anywhere but here.
        if let cloud = cloudState {
            ToolbarItem(placement: .topBarLeading) {
                CloudSyncBadge(state: cloud,
                               heldCount: model.unsavedBlockIds.count,
                               lastSyncedAt: model.lastSyncedAt,
                               sync: { await model.syncNow() })
            }
            .sharedBackgroundVisibility(.hidden)
        }
        // Undo sits on the leading edge, where the screenplay editor puts it:
        // where the server keeps a stack for this song, or where this device is
        // holding edits of its own to take back.
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
        // The list's context-menu action, reachable without leaving the song.
        // Same gate — the server advertised an `insert` link on this document —
        // and the same landing: the end of the script.
        if model.document.hasLink(.insert) {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    insert()
                } label: {
                    Label("Insert into Script", systemImage: "text.insert")
                }
                .disabled(isInserting)
            }
        }
        ToolbarItem(placement: .secondaryAction) {
            Toggle(isOn: wordCountBinding) {
                Label("Word Count", systemImage: "number")
            }
        }
        // The way back into reading, in the "…" where Pages keeps its own.
        // Without it the remembered choice could only ever travel toward the
        // editor, and a song a writer only ever reads would have no way to say
        // so after the first tap on Edit.
        if isSongEditable && !isReadingView {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    enterReadingView()
                } label: {
                    Label("Reading View", systemImage: "book")
                }
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
            // The way into writing, leading this group so a phone — which
            // draws about two controls on the trailing side before the rest go
            // to the "…" — always draws it. Gone once it is used: the sheet is
            // then the editor it has always been.
            if isSongEditable && isReadingView {
                Button {
                    beginEditing()
                } label: {
                    Label("Edit", systemImage: "square.and.pencil")
                }
            }
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
                    if model.canAddLine && !isReadingView {
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

    private var insertMessageBinding: Binding<Bool> {
        Binding(get: { insertMessage != nil },
                set: { if !$0 { insertMessage = nil } })
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
