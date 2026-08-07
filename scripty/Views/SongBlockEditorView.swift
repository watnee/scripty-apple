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
    /// Whether this song is closed to typing. Per song and per edition, kept
    /// on the device — see `DocumentViewOptions`.
    @State private var options: DocumentViewOptions
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
    /// The name being typed at the head of the lyric, and whether the caret is
    /// in it. Held apart from the document until it is sent: a rename goes a
    /// beat after typing stops, not once per keystroke the way a lyric line
    /// saves — a song's name is short, and every character of it would
    /// otherwise be a write the list behind this sheet has to follow.
    @State private var titleDraft: String
    @FocusState private var titleFocused: Bool
    /// The armed rename, cancelled and replaced on every keystroke.
    @State private var renameSave: Task<Void, Never>?
    /// The wait a note's title takes, for the same reason: a name half-typed
    /// is not a name.
    private static let renameDelay: Duration = .milliseconds(1200)
    /// The OS text-size setting as a multiplier, folded into the heading's
    /// scale the way `ReadSongView` folds it into the reader's — the lines
    /// below already honour it through `ProseFont`.
    @ScaledMetric(relativeTo: .body) private var dynamicTypeScale: CGFloat = 1

    /// The same device-wide readout preference the screenplay honours.
    private let settings = PresentationSettings.shared
    /// Whether the offline strip has been closed for the copy currently shown.
    private let notices = DismissedNotices.shared
    @State private var showingEditions = false
    @State private var showingVersions = false
    @State private var showingTrash = false
    @State private var showingIgnoredWords = false
    /// Whether the song's recordings are up — the demo, the voice memo, the
    /// reference track. A sheet like the version history, for the reason given
    /// in `SongRecordingsView`: this column is for the words.
    @State private var showingRecordings = false
    /// Whether the two-versions screen is up. Only ever opened by a press —
    /// a sheet that appeared over a half-typed line because a sweep found
    /// something would interrupt the one thing this screen is for.
    @State private var showingConflicts = false
    /// Whether the search bar is up. A button rather than a standing field:
    /// `.searchable` in this sheet draws a full-width bar across the bottom of
    /// every opening — `.searchToolbarBehavior(.minimize)` collapses a toolbar
    /// field only outside a sheet — and searching is the rare errand here, not
    /// the ordinary state. The screenplay's search is a toolbar button for the
    /// same reason.
    @State private var isSearching = false
    /// Whether the lyric is being read rather than written. The song's answer
    /// to the screenplay's Read Script: the editable lines are swapped for the
    /// reading column in place, and everything around them — the toolbar, the
    /// banners, the saving — stays put.
    ///
    /// Where the song opens, and remembered like the screenplay's: this editor
    /// used to keep two flags, a remembered "reading view" that left the lines
    /// on screen with the caret taken out of them and a forgotten Read Song
    /// that swapped in the verse. Two names for one posture, and the one a song
    /// opened in was the one that did the least. Reading means the reading
    /// surface here now; the lines left inert is what the lock is for.
    @State private var isReading: Bool
    /// The line a double tap on the reader asked to write in, waiting for the
    /// rows to exist to be asked. Nil the rest of the time.
    ///
    /// Not handed straight to `model.focusRequest` at the moment of the tap,
    /// because the list is not on screen then and is lazy when it arrives: a
    /// row the list never builds is a row that never grants itself first
    /// responder, and the writer would be left looking at a lyric with no
    /// keyboard — the same trap `ScriptView.pendingWriteTarget` exists for.
    @State private var pendingWriteLine: Int?
    /// In flight to the screenplay. Guards the button rather than showing a
    /// spinner: the send is one POST and a reload, over in a beat.
    @State private var isInserting = false
    /// What an insert that put nothing in the script has to say for itself —
    /// an empty song, or a send the server refused.
    @State private var insertMessage: String?
    /// A trip back from the archive in flight.
    @State private var isUnarchiving = false
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

    /// Whether documents open to be read, and which way this song was last put.
    private let readingViews = ReadingViewSettings.shared

    /// This song on paper — the server's PDF where there is a route to it, and
    /// the lines on screen drawn here where there is not. Made from the
    /// screenplay behind the sheet because that is what holds the project's
    /// export links, exactly as the insert action does.
    @State private var printer: DocumentPrintModel

    /// The device's voice, shared with the screenplay behind this sheet and
    /// with the note editor — see `ScriptNarrator`. Reading a song ends
    /// whatever was being read before it, which is the only sane answer on a
    /// device with one pair of headphones.
    private let narrator = ScriptNarrator.shared

    /// Whether the bars around the lyric are folded away because the song is
    /// being scrolled down through — the screenplay's fold, off the shared rule
    /// in `ChromeFold`. Both surfaces feed it: the lines while they are being
    /// written, the verse while it is being read.
    @State private var fold = ChromeFold()

    /// Which layout this is in, which is the whole of what the fold asks.
    /// Compact only, exactly as the screenplay has it: a song opened at full
    /// iPad width has room for its toolbar.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isCompact: Bool { horizontalSizeClass == .compact }

    init(app: AppModel, document: TextDocument, scriptModel: ScriptModel,
         onInserted: (() -> Void)? = nil) {
        _model = State(initialValue: SongBlockModel(app: app, document: document))
        _editions = State(initialValue: EditionsModel(app: app, document: document))
        _printer = State(initialValue: DocumentPrintModel(model: scriptModel))
        _isReading = State(initialValue: ReadingViewSettings.shared
            .opensInReadingView(.document(id: document.id)))
        _options = State(initialValue: DocumentViewOptions(documentId: document.id, kind: .song))
        // The stored name, not `displayTitle`: a song the server holds
        // untitled opens on the field's placeholder rather than on the words
        // "Untitled Song", which nobody typed and nobody should have to delete
        // before typing a real one.
        _titleDraft = State(initialValue: document.title ?? "")
        self.scriptModel = scriptModel
        self.onInserted = onInserted
    }

    private var query: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    /// The lyric, narrowed to the lines that matched. An empty query shows the
    /// whole song, which is the ordinary state of this editor.
    ///
    /// A line the caret is in is never filtered out from under it, whatever it
    /// says. A row that leaves this list is torn out of the ForEach — so a line
    /// made by Return, which is empty and matches nothing, vanished the instant
    /// it appeared: nothing claimed first responder, the keyboard stayed on the
    /// line above, the next verse went into the end of *that*, and a stray
    /// blank line was saved. Now that the live text is what gets searched, a
    /// line being typed into would otherwise disappear the moment its words
    /// stopped matching, which is worse again.
    ///
    /// Asked here rather than folded into `matchedLines`, so the caret moving
    /// needs no recompute: the answer is read fresh on every redraw anyway.
    private var shownBlocks: [SongBlock] {
        guard !query.isEmpty else { return model.blocks }
        return model.blocks.filter {
            matchedLines.contains($0.id) || $0.id == model.focusedBlockId
        }
    }

    /// What the menu bar's Undo and Redo do while this editor is up. Both
    /// rewind the lyric to a different set of lines, so the search has to be
    /// re-run behind them, exactly as the toolbar buttons do it.
    ///
    /// Empty while the song is being read — there is nothing on that surface a
    /// step back would be a step back from — but still published, so ⌘Z over a
    /// song can never fall through to the script the cover is hiding.
    ///
    /// ⌘⇧A rides along on the same value and is *not* emptied by the reading
    /// mode: a song up to be read is exactly the one somebody wants read to
    /// them, and the chord would otherwise start the screenplay behind this
    /// sheet reading itself.
    private var menuActions: DocumentEditorActions {
        let readAloud: (() -> Void)? = model.blocks.isEmpty ? nil : { toggleReadAloud() }
        // ⌘P rides along for the reason ⌘⇧A does: the chord would otherwise
        // reach the screenplay behind this sheet and print a script the writer
        // cannot see.
        let printSong: (() -> Void)? = canPrintSong
            ? { printer.print(model.document, lines: printableLines) }
            : nil
        guard !isReading else {
            return DocumentEditorActions(readAloud: readAloud, print: printSong)
        }
        return DocumentEditorActions(
            undo: { Task { await model.undo(); runSearch() } },
            redo: { Task { await model.redo(); runSearch() } },
            canUndo: model.canUndo,
            canRedo: model.canRedo,
            readAloud: readAloud,
            print: printSong)
    }

    /// Whether there is a lyric to put on paper. Not gated on a link: with
    /// lines on screen this device can draw the sheet itself, which is the
    /// whole point of the offline fallback.
    private var canPrintSong: Bool { !model.blocks.isEmpty }

    /// The lyric as it goes to the printer — what is on screen, line for line,
    /// blank lines and all. `currentText` for the reason the reader and the
    /// narrator use it: a line typed a moment ago should print as typed.
    ///
    /// Only ever read at the moment of printing, so a song being written does
    /// not gather its own lyric on every keystroke.
    private var printableLines: [String] {
        model.blocks.map { model.currentText($0) }
    }

    /// Recomputes the matched set from what the lines currently say.
    ///
    /// `currentText`, not `block.text`: every other read of a line in this file
    /// goes through it — the rows, the print, the narration, the word count —
    /// because a line being typed into, or held after a failed save, says one
    /// thing on screen and another on the server. Searching the server's copy
    /// meant a writer who worked offline for an hour got "No results" for a
    /// word that was on the screen in front of them, would print, and was in
    /// the word count. Same for anything typed inside the 600ms debounce.
    ///
    /// And the line holding the caret always matches, whatever it says. A row
    /// that leaves `shownBlocks` is torn out of the list — so a line made by
    /// Return, which is empty and matches nothing, vanished from under the
    /// caret the instant it appeared: nothing claimed first responder, the
    /// keyboard stayed on the line above, the next verse was typed into the
    /// end of *that*, and a stray blank line was saved to the server. With the
    /// live text now searched, a line being typed into would disappear the
    /// moment its words stopped matching, which is worse. So the rule is
    /// simply that a line the caret is in is never filtered out from under it.
    ///
    /// No screenplay precedent to follow here: `ScriptSearchBar` steps a
    /// cursor through hits and never takes a row away, so this is a rule this
    /// surface needs on its own.
    private func runSearch() {
        let needle = query.lowercased()
        guard !needle.isEmpty else {
            matchedLines = []
            return
        }
        matchedLines = Set(
            model.blocks.filter { model.currentText($0).lowercased().contains(needle) }
                .map(\.id))
    }

    var body: some View {
        NavigationStack {
            Group {
                // Reading wins while it is on; the lines wait underneath and
                // come back exactly as they were left.
                if isReading {
                    VStack(spacing: 0) {
                        // Over the page rather than in it: the reader sets the
                        // words exactly as they were written, and a control
                        // inside that column would be one more thing in the
                        // lyric. The writing surface keeps its own copy at the
                        // head of the lines — see `recordingsRow`.
                        recordingsBar
                        reader
                    }
                } else {
                    lyricList
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    archivedBanner
                    editionBanner
                    lockBanner
                    // Above the offline strip: that one is waiting on a
                    // connection, and this one is waiting on the writer.
                    conflictBanner
                    offlineCopyBanner
                }
            }
            // A fresh load — a newer cached copy, or the real lyric — is a new
            // situation, so whatever was closed about the old one stops
            // applying and the strip is free to speak again.
            .onChange(of: offlineCopyState) { _, _ in
                notices.situationChanged(offlineCopyKey)
            }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    searchBar
                    // Under the search field and above the keyboard's own
                    // strip: the transport is the thing being reached for while
                    // a reading runs, and the way down from a line is the thing
                    // being reached for while one is being typed.
                    narrationBar
                    keyboardBar
                }
            }
            // Floated after the strips above, so it settles just over them
            // rather than under them — the same place the screenplay puts it,
            // saying the same thing about the same kind of step.
            .historyToast(model.historyToast)
            .navigationTitle(model.document.displayTitle)
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            // Scrolling down through the song folds the bar away for reading
            // room, the way the screenplay's does — `respondToScroll` sets the
            // flag, and the readout at the foot folds on the same one.
            .toolbarVisibility(fold.isHidden ? .hidden : .visible, for: .navigationBar)
            #endif
            .toolbar { toolbar }
            // Search is a toolbar errand with a bar of its own: the chrome
            // comes back for it rather than leaving the writer to work it in a
            // bare room. Same for changing what this screen is — tapping Edit
            // on a song scrolled halfway down should not hand back a page with
            // no way off it.
            .onChange(of: isSearching) { _, searching in
                if searching { fold.show() }
            }
            .onChange(of: isReading) { _, _ in fold.show() }
            // ⌘Z belongs to this lyric while it is open. Without this the menu
            // bar's Undo still reaches the screenplay behind the cover — a
            // scene's focused value is not covered up by a sheet over it — and
            // stepping back in a song would rewind the script instead. See
            // `DocumentEditorActions`.
            .focusedSceneValue(\.documentEditorActions, menuActions)
            .onChange(of: searchText) { _, _ in
                runSearch()
            }
            // And whenever the lyric itself changes under an open search. The
            // matched set used to be recomputed on the query, the load and a
            // history step alone — so a line added, removed or landed while
            // the search bar was up was judged against a set that predated it.
            // A new line has an id in no match set at all, which is how Return
            // inside a search took the row out from under the caret.
            .onChange(of: model.blocks) { _, _ in
                guard !query.isEmpty else { return }
                runSearch()
            }
            // A reading in progress follows the lyric it is reading: a line
            // committed, a sync, a restore all reshape the run, and the
            // narrator keeps its place across the rebuild. Only while the voice
            // is on this song, and only while it is running — idle, the run is
            // built fresh the next time Read Aloud is pressed.
            //
            // These are the saved lines rather than the half-typed ones, which
            // is the point: they change when a line lands, not per keystroke,
            // and rebuilding the run restarts the line being spoken.
            .onChange(of: model.blocks) { _, _ in
                guard narrator.isActive, isBeingRead else { return }
                narrator.prepare(narrationSource,
                                 subject: narrationSubject,
                                 title: model.document.displayTitle)
            }
            // Closing the song ends its reading. The sheet is the only place
            // its transport is drawn, and a voice left singing a song nobody
            // can see — with the screenplay's own transport back on screen
            // underneath — is a reading with no way to stop it.
            .onDisappear {
                if isBeingRead { narrator.stop() }
            }
            // The lock follows the edition on screen, so a rewrite opened from
            // a locked song is judged by its own key rather than inheriting the
            // lock for the rest of the session. Same wiring as the screenplay's.
            .onChange(of: editions.selectedId) { _, id in
                options.editionId = id
            }
            .task {
                await model.load()
                // Two things the opening decision could not know until the
                // lyric was in hand. A song with no lines is nothing to read —
                // what it has instead is an Add Line button, which the reader
                // has no room for. And lines this device is still holding are
                // writing in progress that has not reached the server, which is
                // not a song anyone opened to read. Neither is remembered: the
                // song has said nothing about how it wants to open, and once
                // there are lines in it the answer changes.
                if model.blocks.isEmpty || model.hasUnsavedChanges {
                    isReading = false
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
            .sheet(isPresented: $showingConflicts) {
                SyncConflictsView(conflicts: model.conflicts,
                                  keepMine: { await model.keepMine($0) },
                                  keepTheirs: { model.keepTheirs($0) },
                                  noun: "line")
            }
            .sheet(isPresented: $showingIgnoredWords) {
                SpellcheckWordsView()
            }
            .sheet(isPresented: $showingRecordings) {
                SongRecordingsView(app: model.app, document: model.document)
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
            .documentPrintPresentation(printer)
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

    /// The mode, as a Toggle can use it. Through the two functions below rather
    /// than straight at the state, so choosing it in the menu is remembered —
    /// and commits the half-typed line — exactly as tapping Edit is.
    private var readingBinding: Binding<Bool> {
        Binding(get: { isReading },
                set: { reading in
                    if reading { enterReadingView() } else { beginEditing() }
                })
    }

    /// Hands the song to the writer, and remembers that this is one they write
    /// in — so Edit is a cost paid once per song rather than on every visit.
    private func beginEditing() {
        isReading = false
        readingViews.remember(false, for: .document(id: model.document.id))
    }

    /// The double-tap way in, for both of the things that can stand between a
    /// writer and a lyric: the reading view it opened in, and the lock. Whatever
    /// is in the way comes off — a locked song opened to be read is one gesture
    /// away from the keyboard, not two — and the line takes the caret where the
    /// finger landed, which the row's own text view arranges.
    ///
    /// Nil where nothing is in the way, or where the server never offered this
    /// song to be written in: the lines are already taking a caret, or no lock
    /// of this device's would give them one.
    /// Handed how far into the lyric the finger landed — into the whole of it
    /// where the tap was made on the reader, and into the one line where it was
    /// made on a locked row. Only the first is spent: leaving the reading view
    /// swaps the column for a list of rows, so the line and the caret have to be
    /// carried across, while a lock leaves each line the view it already was and
    /// the row places its own caret.
    private var startWriting: ((Int) -> Void)? {
        guard isSongEditable, isReading || options.isEditingLocked else { return nil }
        return { offset in
            if options.isEditingLocked { options.setEditingLocked(false) }
            guard isReading else { return }
            // Asked before the mode changes, while the lines on screen are still
            // the ones the offset was measured against.
            if let (block, caret) = lyricPosition(at: offset), block.isEditable {
                model.caretRequests[block.id] = caret
                pendingWriteLine = block.id
            }
            beginEditing()
        }
    }

    /// Which line a tap `offset` into the whole lyric landed in, and how far
    /// into that line it was — the reader's one number walked back into the row
    /// the lyric is actually kept in. See `ReadSongView.onEdit`, which counts
    /// the lines the way this adds them up: each line's own length, and one for
    /// the break after it.
    ///
    /// The caret comes back in Characters, because that is what `caretRequests`
    /// is in, while the offset arrives in UTF-16 — the count a text view
    /// reports its own selection in. Nil for a lyric with no lines at all,
    /// which is a song there was nothing to tap in.
    private func lyricPosition(at offset: Int) -> (SongBlock, Int)? {
        var start = 0
        for block in model.blocks {
            let text = model.currentText(block)
            let length = (text as NSString).length
            // `<=`, so an offset at the very end of a line belongs to that line
            // rather than to the start of the next one.
            if offset <= start + length {
                return (block, text.characterOffset(utf16: offset - start))
            }
            start += length + 1
        }
        // Past the last line: a tap in the slack under a short lyric.
        return model.blocks.last.map { ($0, model.currentText($0).count) }
    }

    /// Puts it back up to be read, and remembers that too. Half-typed lines go
    /// first: the rows leave the screen the moment the flag flips, and a line
    /// still holding uncommitted text would have nowhere left to send it from.
    ///
    /// Focus goes with them, because a `focusedLine` still pointing at a row
    /// would have that row grant itself first responder the moment the list
    /// came back, putting the keyboard up over a lyric nobody asked to type
    /// into. Search goes too: its bar draws over the lines and it works by
    /// narrowing them, and neither means anything on a surface with no rows.
    private func enterReadingView() {
        Task {
            await model.commitAll()
            isReading = true
            focusedLine = nil
            isSearching = false
            searchText = ""
            readingViews.remember(true, for: .document(id: model.document.id))
        }
    }

    // MARK: - Surfaces

    /// The writing surface: the lyric as editable lines.
    private var lyricList: some View {
        ScrollViewReader { proxy in
            List {
                recordingsRow

                titleHeading

                ForEach(shownBlocks) { block in
                    SongLineRow(model: model,
                                block: block,
                                isLocked: options.isEditingLocked,
                                focusedLine: $focusedLine,
                                startWriting: startWriting,
                                isBeingRead: readingLineId == block.id)
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
            // The line a double tap asked for, claimed the moment these rows
            // are the surface — `initial`, because the tap that asked was made
            // on the reader and this list did not exist to hear it. Scrolled to
            // as well as focused: the list is built fresh at the top, and a row
            // it never reaches is never built to take the caret.
            .onChange(of: pendingWriteLine, initial: true) { _, id in
                guard let id else { return }
                pendingWriteLine = nil
                model.focusRequest = id
                proxy.scrollTo(id, anchor: .center)
            }
            // Only gestures reach this — the spy drops programmatic jumps, so
            // neither the scroll to a focused line nor the one that follows the
            // voice can fold the bars away under a writer who never scrolled.
            .onUserScroll(respondToScroll)
            // Follow the voice, as the screenplay's column does. Centred, so
            // the line being sung has the verse around it rather than sitting
            // at the very top with the next line always a jump away.
            .onChange(of: readingLineId) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        // Belongs to this surface rather than to the screen: the reader has an
        // empty state of its own, and "Add Line" is an offer that makes no
        // sense on a page being read.
        .overlay { emptyState }
    }

    /// The way to what this song sounds like, over the words it is made of —
    /// the voice memo the tune was first sung into, the demo, the reference
    /// track being chased.
    ///
    /// In the lyric itself rather than in the "…", which is where a row like
    /// this would ordinarily go. That menu is full: this sheet defines more
    /// toolbar items than iOS will draw, and the ones past the limit are
    /// dropped without a word — Print… already is, on a phone, and a
    /// Recordings item put up there was never seen once. At the head of the
    /// verse it is also seen without scrolling, which the foot of a long lyric
    /// never was.
    ///
    /// Drawn only where the server advertised the collection — an older
    /// deployment has never heard of recordings and this client then says
    /// nothing about them anywhere — and offered to readers as well as
    /// writers, since listening needs no permission to type.
    @ViewBuilder
    private var recordingsRow: some View {
        if model.document.hasLink(.audioRecordings) {
            recordingsButton
                .listRowSeparator(.hidden)
                .padding(.top, 8)
        }
    }

    /// The same row over the reading surface, which is not a list and has no
    /// row to put it in. A song opens here whenever the writer left it here,
    /// and someone reading a lyric is exactly the person who wants to hear it.
    @ViewBuilder
    private var recordingsBar: some View {
        if model.document.hasLink(.audioRecordings) {
            VStack(spacing: 0) {
                recordingsButton
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                Divider()
            }
        }
    }

    private var recordingsButton: some View {
        Button {
            showingRecordings = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                Text("Recordings")
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Recordings kept with this song")
    }

    /// The song's name at the head of the lyric, in the face, the size and the
    /// place the reader heads its own page with — see `DocumentTitleType`. The
    /// lines were the whole of this surface before, so a song read and then
    /// written in lost its title on the way in and the writer was left looking
    /// at a verse with nothing over it.
    ///
    /// Typed over in place, where a writer's eye already is. Renaming was a
    /// swipe on a row in the list one screen back, which is a journey from
    /// inside the song it names — the same gap the title page's project name
    /// closed for a screenplay.
    ///
    /// The row insets are the lyric rows' own, so the title and the lines it
    /// heads share a left edge with the reader's column.
    @ViewBuilder
    private var titleHeading: some View {
        Group {
            if canRenameSong {
                TextField("Song title", text: $titleDraft)
                    .focused($titleFocused)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    // Return in a title means "that's the name": a song is
                    // headed with one line, unlike the verse below it, where
                    // Return makes the next line.
                    .onSubmit { commitRename() }
            } else {
                Text(model.document.displayTitle)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .font(DocumentTitleType.font(scale: titleScale))
        .accessibilityLabel("Title")
        .padding(.horizontal, 4)
        .padding(.top, ProseColumn.titleTopPadding)
        .padding(.bottom, ProseColumn.titleBottomPadding)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        // The name lands a beat after typing stops, the way a note's title
        // does. Deliberately not left to the field losing focus: the lines
        // under it are UIKit text views that take first responder for
        // themselves, and SwiftUI's focus engine stops agreeing with UIKit
        // about who holds it once one of them has — the disagreement
        // `SoftwareKeyboard` exists for. A rename that waited to be told the
        // caret had left would be one that sometimes never happened.
        .onChange(of: titleDraft) { _, _ in scheduleRename() }
        // Leaving the field sends it now rather than waiting the debounce out.
        // Two signals, because neither covers everything: SwiftUI's own focus,
        // where it still knows where the caret is, and the software keyboard
        // going away where it does not. On a device with a hardware keyboard
        // there is no software keyboard to go, which is what Return is for.
        .onChange(of: titleFocused) { _, focused in
            guard !focused else { return }
            commitRename()
        }
        .onChange(of: SoftwareKeyboard.shared.isVisible) { _, visible in
            guard !visible else { return }
            commitRename()
        }
    }

    /// Whether the heading takes a caret. The server's own `update` link
    /// first — a reader is shown the name, not a field — and then the two
    /// postures that close this lyric to typing, since a song that cannot have
    /// a line changed should not be renameable by a stray tap either.
    private var canRenameSong: Bool {
        model.document.hasLink(.update) && !isReading && !options.isEditingLocked
    }

    private var titleScale: CGFloat { CGFloat(settings.textScale) * dynamicTypeScale }

    /// Arms the debounce. Long enough that a name still being typed —
    /// "Ballad", on its way to "Ballad of the Lost Hour" — is not filed as one,
    /// and the same wait a note's title takes.
    private func scheduleRename() {
        guard canRenameSong else { return }
        renameSave?.cancel()
        renameSave = Task {
            try? await Task.sleep(for: Self.renameDelay)
            guard !Task.isCancelled else { return }
            sendRename()
        }
    }

    /// Sends whatever is typed now rather than waiting the debounce out.
    private func commitRename() {
        renameSave?.cancel()
        sendRename()
    }

    /// Sends the typed name, or puts the heading back.
    ///
    /// A blank one is restored rather than sent: the server requires a name and
    /// every list in the app has to draw something for this song. So is a name
    /// a failed rename left on screen — the heading must not go on showing
    /// words the server never took.
    private func sendRename() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = model.document.title ?? ""
        guard trimmed != current else { return }
        guard !trimmed.isEmpty else {
            titleDraft = current
            return
        }
        Task {
            // The script's model rather than this one, because a rename is a
            // whole-document PUT — it fetches the lyric first so the words are
            // preserved — and because the lists behind this sheet are its to
            // refresh.
            if await scriptModel.renameDocument(model.document, title: trimmed) {
                model.adoptTitle(trimmed)
            } else {
                titleDraft = current
            }
        }
    }

    /// The reading surface: the lyric as verse, in place of the lines.
    ///
    /// Fed from `currentText` rather than from what was last saved, so a line
    /// typed a moment ago reads as typed — leaving the lines resigns the
    /// keyboard and commits them anyway, but the words on screen must not
    /// depend on that having landed.
    private var reader: some View {
        ReadSongView(title: model.document.displayTitle,
                     lines: model.blocks.map { model.currentText($0) },
                     textScale: settings.textScale,
                     isLoading: model.isLoading,
                     // The same closure the lines themselves take: the reading
                     // posture comes off, and with it anything else standing
                     // between the writer and the lyric underneath.
                     onEdit: startWriting,
                     // The reader names a line by its position; the run is
                     // started from the line's id, which is what the narrator
                     // was prepared with.
                     onReadFrom: { index in
                         guard model.blocks.indices.contains(index) else { return }
                         readAloud(from: model.blocks[index].id)
                     },
                     // This editor keeps a row per line, so the reader adds its
                     // column up the same way — see `linesAreRows`.
                     linesAreRows: true,
                     onUserScroll: respondToScroll,
                     // The line the voice is on, as a position: the reader is
                     // handed strings, not lines with ids.
                     highlighted: readingLineIndex)
    }

    /// Folds the bars away while the song is scrolled down through, and brings
    /// them back the moment the direction turns. The rule is shared with the
    /// screenplay and the note editor — see `ChromeFold` — and all this adds is
    /// where it applies.
    private func respondToScroll(delta: CGFloat, fromTop: CGFloat) {
        guard isCompact else { return }
        fold.respond(delta: delta, fromTop: fromTop)
    }

    /// Where in the lyric the voice is, counted the way the reader counts —
    /// nil when this song is not the one being read.
    private var readingLineIndex: Int? {
        guard let id = readingLineId else { return nil }
        return model.blocks.firstIndex { $0.id == id }
    }

    // MARK: - Reading aloud

    /// What the narrator calls this song while it reads it.
    private var narrationSubject: NarrationSubject { .document(id: model.document.id) }

    /// Whether the voice on the device is reading *this* song. One narrator
    /// serves every surface, so a reading being loaded is not the same question
    /// as this song being the one loaded — and the line ids a song counts by
    /// mean nothing in a screenplay.
    private var isBeingRead: Bool { narrator.subject == narrationSubject }

    /// The lyric as the narrator takes it: what is on screen, line for line,
    /// blank lines and all. `currentText` rather than the saved content, so a
    /// line typed a moment ago is read as typed — the same copy the reading
    /// surface is fed.
    private var narrationSource: NarrationSource {
        .lyric(model.blocks.map { NarrationLine(id: $0.id, text: model.currentText($0)) })
    }

    /// Reads the song out loud, here on this sheet — the transport comes up at
    /// the foot of it and the line being read is lit and scrolled to, exactly
    /// as the screenplay does it. Reaching for it while this song is being read
    /// pauses and resumes, so the one control is the whole errand.
    private func toggleReadAloud() {
        if narrator.isActive && isBeingRead {
            narrator.togglePlayPause()
            return
        }
        // From the line the writer is in, where there is one — the screenplay's
        // rule, in a song's terms. Reading mode has no caret, so the line being
        // read is the next best answer to "where am I": without it, pressing
        // Read Aloud while looking at the third verse always started the song
        // again from the top.
        readAloud(from: model.focusedBlockId ?? readingLineId)
    }

    /// Prepares the run and starts it at one line — the toolbar's entry point
    /// and the reader's context menu both come through here, so a reading
    /// begun either way is prepared exactly the same.
    private func readAloud(from id: Int?) {
        narrator.prepare(narrationSource,
                         subject: narrationSubject,
                         title: model.document.displayTitle)
        if let id {
            narrator.play(atOrAfter: id)
        } else {
            narrator.play()
        }
    }

    /// The transport, up only while this song is the thing being read.
    @ViewBuilder
    private var narrationBar: some View {
        if narrator.isActive && isBeingRead {
            NarrationTransportBar(narrator: narrator)
        }
    }

    /// The line being read, or nil when the voice is elsewhere — what both
    /// surfaces light and scroll to.
    private var readingLineId: Int? {
        isBeingRead ? narrator.currentBlockId : nil
    }

    // MARK: - Actions

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
        // First of all, as in the screenplay: every other state clears up on
        // its own and this one cannot.
        if model.hasConflicts { return .conflicted }
        if !model.app.connectivity.isOnline { return .offline }
        // Refused beats retrying: with both on screen, the one that will not
        // fix itself is the one the badge must name.
        if model.hasFailedSaves { return .failed }
        return model.hasUnsavedChanges ? .holding : .synced
    }

    /// Two versions of a line exist and only the writer can settle it.
    @ViewBuilder
    private var conflictBanner: some View {
        if !model.conflicts.isEmpty {
            ConflictBanner(count: model.conflicts.count) { showingConflicts = true }
        }
    }

    /// Which copy the strip is reporting, or nil when the lyric on screen came
    /// from the server. The date is the situation: a newer stale copy is a
    /// different thing to be told, so it is told even if the last one was
    /// closed.
    private var offlineCopyState: String? {
        model.offlineCopySavedAt.map(DismissedNotices.offlineCopyState(savedAt:))
    }

    /// The songs workspace raises the same notice about the same lyric under
    /// this key, so closing it in either place closes it in both.
    private var offlineCopyKey: String {
        DismissedNotices.offlineCopyKey(songId: model.document.id)
    }

    /// Says the lyric on screen is the copy saved on this device, and how old
    /// it is — an out-of-date lyric should not look current. Only shown when
    /// the fallback actually happened, not merely because the radio is off;
    /// the same rule the projects sidebar follows.
    @ViewBuilder
    private var offlineCopyBanner: some View {
        let isClosed = offlineCopyState.map { notices.isDismissed(offlineCopyKey, state: $0) } ?? true
        if let savedAt = model.offlineCopySavedAt, !isClosed {
            HStack(spacing: 6) {
                Image(systemName: "wifi.slash")
                    .font(.caption)
                Text("Offline — lyrics saved "
                     + savedAt.formatted(.relative(presentation: .named)))
                    .lineLimit(1)
                Spacer(minLength: 0)
                NoticeCloseButton(action: dismissOfflineCopy)
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
            // `.ignore`, not `.combine`: a combined element swallows the close
            // button, and a notice VoiceOver cannot put down is worse than one
            // nobody can close at all.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Offline. Showing the lyrics saved on this device "
                                + savedAt.formatted(.relative(presentation: .named)) + ".")
            .accessibilityAction(named: "Dismiss") { dismissOfflineCopy() }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func dismissOfflineCopy() {
        guard let state = offlineCopyState else { return }
        withAnimation(.snappy(duration: 0.2)) {
            notices.dismiss(offlineCopyKey, state: state)
        }
    }

    /// Says the lyric is closed to typing — see `EditingLockBanner`, which the
    /// note editor shows in the same place for the same reason.
    @ViewBuilder
    private var lockBanner: some View {
        if options.isEditingLocked {
            EditingLockBanner { options.setEditingLocked(false) }
        }
    }

    /// Says this song is in the archive, and offers the way back.
    ///
    /// Above the edition strip rather than below it: which shelf the song is on
    /// outranks which rewrite of it is open. See `ArchivedBanner`, which the
    /// note editor shows in the same place for the same reason.
    @ViewBuilder
    private var archivedBanner: some View {
        if model.document.isArchived {
            ArchivedBanner(
                kind: .song,
                unarchive: model.document.hasLink(.unarchive) ? { unarchive() } : nil,
                isWorking: isUnarchiving)
        }
    }

    /// Brings this song back into the list, leaving the editor open — a writer
    /// who reached for it while reading a lyric is most likely about to work on
    /// it, and closing the cover under them would take that away.
    private func unarchive() {
        guard !isUnarchiving else { return }
        isUnarchiving = true
        Task {
            defer { isUnarchiving = false }
            // The script's model rather than this one, for the reason a rename
            // goes there: the lists behind this cover are its to refresh.
            if await scriptModel.unarchiveDocument(model.document) {
                model.adoptUnarchived()
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

    /// Split in two only because a toolbar builder takes ten children and this
    /// editor now draws eleven; the division is the one the note sheet already
    /// makes — what is on the bar itself, and what is behind the "…".
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        barToolbar
        overflowToolbar
    }

    @ToolbarContentBuilder
    private var barToolbar: some ToolbarContent {
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
                               sync: { await model.syncNow() },
                               conflictCount: model.conflicts.count,
                               review: { showingConflicts = true })
            }
            .sharedBackgroundVisibility(.hidden)
        }
        // Undo sits on the leading edge, where the screenplay editor puts it:
        // where the server keeps a stack for this song, or where this device is
        // holding edits of its own to take back. Not while reading: there is
        // nothing on that surface for a step back to be a step back from.
        if model.offersUndoRedo && !isReading {
            ToolbarItemGroup(placement: .navigation) {
                // Held, either one keeps walking — see `HistoryStepButton`,
                // which the screenplay's Undo is made of too. A lyric is where
                // that matters most: a verse is retyped a line at a time, so
                // the change a writer wants gone is a run of small steps rather
                // than one big one.
                //
                // Both rewind the lyric to a different set of lines, so the
                // matched set has to be taken again or a search would keep
                // hiding rows by ids that no longer mean anything. Inside the
                // step rather than after the hold, since every step of a hold
                // moves the lines again.
                HistoryStepButton(title: "Undo",
                                  systemImage: "arrow.uturn.backward",
                                  isOffered: { model.canUndo }) {
                    await model.undo()
                    runSearch()
                }

                HistoryStepButton(title: "Redo",
                                  systemImage: "arrow.uturn.forward",
                                  isOffered: { model.canRedo }) {
                    await model.redo()
                    runSearch()
                }
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            // The way into writing, leading this group so a phone — which
            // draws about two controls on the trailing side before the rest go
            // to the "…" — always draws it. It is the one thing a reader most
            // needs, which is why it is out here rather than two taps deep in
            // the overflow beside the toggle that also reaches it. Gone once it
            // is used: the sheet is then the editor it has always been.
            if isSongEditable && isReading {
                Button {
                    beginEditing()
                } label: {
                    Label("Edit", systemImage: "square.and.pencil")
                }
            } else if !isReading && !model.blocks.isEmpty {
                // And the way back, in the slot Edit leaves behind, so this
                // corner is one tap to whichever surface is not up. Reading was
                // reachable only from inside the "…" on the way back, which
                // made a mode that is swapped in and out of while working cost
                // one tap out and two in. Ungated by `isSongEditable`: reading
                // is nobody's privilege, and the toggle in the "…" stays for
                // the reader whose song this button never appears on.
                //
                // It leads Search here, as Edit leads it while reading: the
                // trailing side draws about two controls on a phone, so the
                // pair of them is what a phone shows, and where there is room
                // for only one this is the one worth having.
                Button {
                    enterReadingView()
                } label: {
                    Label("Read Song", systemImage: "book")
                }
            }
            // No keyboard shortcut on Search: the screenplay's own button owns
            // ⌘F, and this editor opens over it — the same reason the text-size
            // menu in the overflow claims no keys.
            //
            // Search narrows the lines, so it is only offered where there are
            // lines to narrow; reading swaps them out.
            if !isReading {
                Button {
                    isSearching.toggle()
                    if !isSearching { searchText = "" }
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
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

    @ToolbarContentBuilder
    private var overflowToolbar: some ToolbarContent {
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
        // How long the lyric runs, said outright rather than offered as a strip
        // to switch on. A song is short and a writer asks the question now and
        // then, not continuously — so the answer belongs where the other
        // now-and-then questions are answered, and the lines get the whole
        // sheet back. Off the model's memo, which counts what is on screen
        // rather than what was last saved. No page estimate: a song is measured
        // in lines, not pages.
        //
        // A disabled `Button` rather than the bare `Label` this wants to be: a
        // toolbar item with no control in it is dropped from the overflow menu
        // without a word — the row simply never appears. Disabled is also how
        // the row should read, since there is nothing to press.
        ToolbarItem(placement: .secondaryAction) {
            Button {} label: {
                Label(wordCountTitle, systemImage: "number")
            }
            .disabled(true)
        }
        // The mode itself, in the "…" this sheet has instead of a View menu —
        // the screenplay's Read Script toggle, in the song's own words. A
        // toggle rather than a one-way "Reading View" button because the mode
        // has to travel both ways for everyone: the Edit button below is the
        // way out for a writer, and this is the way out for a reader the server
        // never gave the keyboard to. Without it the remembered choice could
        // only ever travel toward the editor, and a song a writer only ever
        // reads would have no way to say so after the first tap on Edit.
        //
        // Offered wherever there are lines to read, as the screenplay's toggle
        // is — and always while the mode is on, even if the last line went
        // while it was, so it is never a room with no door.
        if !model.blocks.isEmpty || isReading {
            ToolbarItem(placement: .secondaryAction) {
                Toggle(isOn: readingBinding) {
                    Label("Read Song", systemImage: "book")
                }
            }
        }
        // The other kind of reading, next to it: the song out loud, in the
        // voice and at the speed the screenplay's Read Aloud is set to. Both
        // surfaces offer it — a lyric is as worth hearing while it is being
        // written as after — so this is gated on there being a line to read
        // rather than on the mode.
        //
        // In the "…" rather than out on the bar. The trailing side of this
        // sheet's navigation bar draws about two controls on a phone and there
        // are five things wanting them, so a sixth would only ever be the
        // overflow's anyway; this way it sits with the reading toggle it is a
        // sibling of. Once a reading starts the transport at the foot of the
        // sheet is the control, and it is nobody's second tap.
        if !model.blocks.isEmpty {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    toggleReadAloud()
                } label: {
                    let isPausing = narrator.isSpeaking && isBeingRead
                    Label(isPausing ? "Pause Reading" : "Read Aloud",
                          systemImage: isPausing ? "pause.fill" : "speaker.wave.2")
                }
            }
        }
        // The lyric on paper. In the "…" with the two ways of reading it,
        // because it is the third of them: a printed lyric sheet is what a
        // song is taken into a room to be sung from.
        //
        // Offered wherever there is a lyric — printing is a read, so it is not
        // gated on being able to type — and it prints the words on screen
        // rather than the words the server has, which are not the same thing
        // for a verse typed a moment ago on a device with no route out.
        if canPrintSong {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    printer.print(model.document, lines: printableLines)
                } label: {
                    Label("Print…", systemImage: "printer")
                }
                .disabled(printer.isPrinting)
            }
        }
        // The same device-wide spelling controls the screenplay's View menu
        // carries. A lyric is where they are needed most — invented words,
        // dialect spellings and names by the verse — and this editor had no way
        // to reach them at all.
        ToolbarItem(placement: .secondaryAction) {
            SpellingMenu(showingIgnoredWords: $showingIgnoredWords)
        }
        // Beside the spelling controls, and the screenplay's "…" now keeps its
        // own lock in the same place for the same reason: both are about
        // typing, and neither means anything to someone the server never gave
        // the keyboard to. (That one used to sit in the View menu among the
        // display switches; it came over to this arrangement rather than the
        // other way round.) Offered even while locked — it is the way back. No
        // keyboard shortcut: the screenplay owns ⌘⇧Q and this editor opens over
        // it, the same reason Search and Text Size claim no keys here.
        if canEditSong {
            ToolbarItem(placement: .secondaryAction) {
                Toggle(isOn: lockBinding) {
                    Label("Lock Editing", systemImage: "lock")
                }
            }
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
    }

    @ViewBuilder
    private var searchBar: some View {
        if isSearching {
            SongSearchBar(text: $searchText) {
                isSearching = false
            }
        }
    }

    /// The menu's readout: "29 words", or "1 word" for the song that is one
    /// word long. Singular where the workspaces' own counts are singular — the
    /// same number said the same way wherever it is read.
    private var wordCountTitle: String {
        let words = model.wordCount
        return "\(ScriptWordCount.formatted(words)) \(words == 1 ? "word" : "words")"
    }

    /// The way down from a lyric line. Only while one is being typed into —
    /// there is no keyboard to hide otherwise, and a lyric is short enough that
    /// a standing strip would be a row of the song lost to a button. Tapping it
    /// ends the line's editing, which clears the focus and takes the bar with
    /// it, exactly as tapping away from the line already does.
    ///
    /// Asked of the model rather than of `focusedLine`: no view here claims that
    /// focus state with `.focused()`, so SwiftUI throws its value away and the
    /// bar would never appear.
    @ViewBuilder
    private var keyboardBar: some View {
        if model.focusedBlockId != nil {
            // The line's own `onEndEditing` clears these too, but not before
            // the row has had an update to re-grant itself first responder
            // from either — which would hand the keyboard straight back.
            HideKeyboardBar(releaseFocus: {
                focusedLine = nil
                model.focusedBlockId = nil
                model.focusRequest = nil
            })
        } else if SoftwareKeyboard.shared.isVisible {
            // The keyboard is up over something that is not a lyric line — the
            // heading, or the search field. Asked of the keyboard rather than
            // of the heading's `@FocusState`, which stays false when the writer
            // taps into it: the lines are UIKit text views that have held first
            // responder, and SwiftUI's focus engine no longer agrees with UIKit
            // about who holds it. Same reasoning, and the same fix, as the note
            // sheet's own title.
            HideKeyboardBar(releaseFocus: { titleFocused = false })
        }
    }

    /// Whether there is anything here to lock. A reader was never handed the
    /// keyboard, so offering to take it away would be nonsense — the same rule
    /// `canEditScript` applies to the screenplay's own lock. Either half is
    /// enough: a song with no lines yet can still be added to, and a song whose
    /// create link is gone can still have its existing lines typed into.
    private var canEditSong: Bool {
        model.canAddLine || model.blocks.contains(where: \.isEditable)
    }

    /// The lock's setter is a method rather than a property, because what it
    /// writes depends on which edition is open. Locking flushes first: what is
    /// half-typed when the writer closes the lyric is part of the lyric, and
    /// the debounce that would have saved it is about to have no field left to
    /// fire from.
    private var lockBinding: Binding<Bool> {
        Binding(get: { options.isEditingLocked },
                set: { locked in
                    if locked { Task { await model.commitAll() } }
                    options.setEditingLocked(locked)
                })
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
                    // No reading test: this state belongs to the writing
                    // surface, and the reader has an empty state of its own.
                    if model.canAddLine, !options.isEditingLocked {
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
