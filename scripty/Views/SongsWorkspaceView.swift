//
//  SongsWorkspaceView.swift
//  scripty
//
//  Every song in the project on one screen — the browser's "edit all on one
//  page".
//
//  The songs list opens one song at a time, which is right when you know which
//  song you want. It is wrong for the job this screen exists for: a lyric that
//  needs a line moved into the song before it, or a phrase changed the same way
//  in four places. That means opening, editing, closing and opening again, and
//  losing your place each time.
//
//  Each song keeps its own model, made when it is first opened and kept
//  afterwards, so collapsing and expanding costs nothing and half-typed lines
//  survive it. Nothing is loaded for a song nobody has opened.
//
//  It reads as well as writes. The other job a screen of every song does is
//  the one nobody can do in the song editor at all — reading the set through,
//  song after song, to hear whether the third one follows the second. That was
//  a page of live text fields with a caret waiting in every one of them, which
//  is exactly the accident the reading view exists to stop. So the mode the
//  song editor has is here too, taken across the whole screen rather than song
//  by song: one press swaps every open lyric for the reading column in place
//  and everything around them — the headers, the open set, the banners, the
//  saving — stays exactly where it was. Two taps in a verse, or Edit in the
//  same corner, hands it all back.
//

import SwiftUI

struct SongsWorkspaceView: View {
    let app: AppModel
    let model: ScriptModel

    /// Only here to seed the printer, which needs the model the moment this
    /// screen is made rather than the first time something is printed — and to
    /// settle which way the screen comes up.
    init(app: AppModel, model: ScriptModel) {
        self.app = app
        self.model = model
        _printer = State(initialValue: DocumentPrintModel(model: model))
        // The remembered choice only, with no fall back to the app-wide "open
        // documents for reading" switch: this screen is reached by pressing
        // "Edit All on One Page", and coming up with no caret in it would be
        // the button's own word contradicted. So it writes unless the writer
        // has put *this* screen into reading themselves — see
        // `ReadingViewSettings.chosenReadingView`.
        _isReading = State(initialValue: ReadingViewSettings.shared
            .chosenReadingView(.songsWorkspace(project: model.project.id)) ?? false)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focusedLine: Int?

    /// The device-wide type size, so lyrics in the workspace read at the same
    /// size the writer chose in a song or the screenplay — it is one setting.
    private let settings = PresentationSettings.shared

    /// Which songs' offline lines have been closed. Per song, and under the
    /// same keys the song editor uses: it is one notice about one lyric, and
    /// closing it in the editor should not leave it standing here.
    private let notices = DismissedNotices.shared

    /// One per song, made on first expand. Songs nobody opens cost nothing.
    @State private var lyrics: [Int: SongBlockModel] = [:]
    /// Whether each song is closed to typing. A lock set in the song editor has
    /// to hold here too, or the screen that shows every lyric at once would be
    /// the way around every lock in the project.
    ///
    /// One for every song rather than only the opened ones, which is what these
    /// were. A collapsed song can now say it is locked and be locked from its
    /// own menu, and Lock All Songs has to reach the ones nobody expanded —
    /// they are exactly the songs a writer finishing a book means. A reader is
    /// two `UserDefaults` reads, so a book's worth of them is nothing next to
    /// one lyric loading.
    @State private var locks: [Int: DocumentViewOptions] = [:]
    @State private var expanded: Set<Int> = []
    @State private var filter = ""
    @State private var showingIgnoredWords = false
    /// Whether the two-versions screen is up, over every song open here.
    @State private var showingConflicts = false
    /// Every song on screen on paper. One printer for the screen, as the songs
    /// list keeps one for the list.
    @State private var printer: DocumentPrintModel
    /// Whether the screen is showing the songs to be dragged into order rather
    /// than to be written in. See `arrangingList`.
    @State private var isArranging = false
    /// Set once the saved open set has been restored, so the first restore does
    /// not immediately save the empty starting state back over it.
    @State private var didRestore = false
    /// Whether the songs are up to be read rather than written in. The song
    /// editor's own mode, taken across every song on screen: the editable lines
    /// are swapped for the reading column in place, and the headers, the open
    /// set and everything in the bars stay put.
    ///
    /// One flag for the screen rather than one per song, because this screen is
    /// one thing — a set read through, or a set worked on — and a page where
    /// the second song takes a caret and the third does not is neither. A song
    /// that wants a posture of its own has an editor where it can have one.
    @State private var isReading: Bool

    /// The line a double tap in the reading view asked for the caret in, held
    /// until the writing rows exist to take it.
    ///
    /// Not handed straight to `focusedLine` at the moment of the tap, for the
    /// reason `SongBlockEditorView.pendingWriteLine` exists: the row being
    /// focused is the one the mode change is about to build, and focus claimed
    /// before a view claims it is focus SwiftUI throws away — no caret, and no
    /// keyboard.
    @State private var pendingWriteLine: Int?

    /// Which way this screen was last put, remembered per project.
    private let readingViews = ReadingViewSettings.shared

    /// Which songs were left open, remembered per project. Shared with the web,
    /// which stores the same set under the same key.
    private var openStore: SongWorkspaceOpenState {
        SongWorkspaceOpenState(projectId: model.project.id)
    }

    private var songs: [TextDocument] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.songs }
        return model.songs.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isArranging {
                    arrangingList
                } else {
                    songList
                }
            }
            .listStyle(.plain)
            // Same single-spacing rule as the song editor: without this the
            // list pads every lyric line up to its default minimum row height,
            // and a verse reads double-spaced.
            .environment(\.defaultMinListRowHeight, 1)
            .environment(\.scriptTextScale, settings.textScale)
            .searchable(text: $filter, prompt: "Filter songs")
            .overlay { emptyState }
            // The same way down from a lyric line the song editor gives, since
            // this screen is the same rows in a different list. Mounted in the
            // bar rather than in the list, where a conditional row is a coin
            // toss from one launch to the next.
            .safeAreaBar(edge: .bottom, spacing: 0) {
                if isArranging {
                    arrangingBar
                // Asked of the lyrics rather than of `focusedLine`, which
                // SwiftUI discards: no row claims it with `.focused()`.
                } else if lyrics.values.contains(where: { $0.focusedBlockId != nil }) {
                    HideKeyboardBar(releaseFocus: {
                        focusedLine = nil
                        for lyric in lyrics.values {
                            lyric.focusedBlockId = nil
                            lyric.focusRequest = nil
                        }
                    })
                }
            }
            .navigationTitle("All Songs")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
            // Same claim the song editor makes, and for the same reason: this
            // is a cover over the screenplay, and without it the menu's ⌘Z
            // would rewind the script behind it. Published even when it can do
            // nothing, so a step here never falls through to the script.
            .focusedSceneValue(\.documentEditorActions, menuActions)
            .documentPrintPresentation(printer)
            .sheet(isPresented: $showingIgnoredWords) {
                SpellcheckWordsView()
            }
            .sheet(isPresented: $showingConflicts) {
                SyncConflictsView(
                    conflicts: openConflicts,
                    keepMine: { conflict in
                        guard let lyric = lyric(holding: conflict) else { return .failed }
                        return await lyric.keepMine(conflict)
                    },
                    keepTheirs: { conflict in lyric(holding: conflict)?.keepTheirs(conflict) },
                    noun: "line")
            }
            // Leaving flushes every song that was opened: a line half-typed in
            // the third song down is no less precious than one in the first.
            .task {
                await model.loadDocuments()
                restoreOpenSongs()
            }
            // Remembered per project. Guarded on the restore having happened, so
            // the empty starting set never overwrites what was saved.
            .onChange(of: expanded) { _, ids in
                guard didRestore else { return }
                openStore.save(ids)
            }
            // The connection came back: every open lyric may be holding lines
            // written while it was down, or showing the offline copy — the
            // sweep pushes the one and replaces the other.
            .onChange(of: app.connectivity.isOnline) { _, online in
                guard online else { return }
                Task { await syncOpenLyrics() }
            }
            // Backgrounding persists every half-typed line before the system
            // decides how much longer this process runs; the foreground is a
            // second chance for anything still held.
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background, .inactive:
                    Task {
                        for lyric in lyrics.values {
                            await lyric.flushPendingCommits()
                        }
                    }
                case .active:
                    if app.connectivity.isOnline {
                        Task { await syncOpenLyrics() }
                    }
                @unknown default:
                    break
                }
            }
            // A lyric that reloaded — from the server, or from a newer cached
            // copy — is a new situation, so whatever was closed about the old
            // one stops applying.
            .onChange(of: offlineStamps) { old, new in
                for id in Set(old.keys).union(new.keys) where old[id] != new[id] {
                    notices.situationChanged(DismissedNotices.offlineCopyKey(songId: id))
                }
            }
            // A lock reader per song, kept in step with the songs. `initial`
            // for the case where the project's songs were already in hand when
            // this screen opened, which is most of the time.
            .onChange(of: model.songs.map(\.id), initial: true) { _, _ in
                ensureLocks()
            }
            // The other half of the double tap out of reading: the writing rows
            // are on screen by the time this runs, so the line named a moment
            // ago is a line there is something to focus.
            .onChange(of: pendingWriteLine) { _, id in
                guard let id else { return }
                pendingWriteLine = nil
                focusedLine = id
            }
        }
    }

    // MARK: - Reading and writing

    /// The mode, as a Toggle can use it — through the two functions below
    /// rather than straight at the state, so choosing it in the "…" is
    /// remembered, and flushes what is half-typed, exactly as the button is.
    private var readingBinding: Binding<Bool> {
        Binding(get: { isReading },
                set: { reading in
                    if reading { enterReadingView() } else { beginEditing() }
                })
    }

    /// Hands the songs back to the writer, and remembers that this is a screen
    /// they write on — so Edit is a cost paid once rather than on every visit.
    private func beginEditing() {
        isReading = false
        readingViews.remember(false, for: .songsWorkspace(project: model.project.id))
    }

    /// Puts the songs up to be read, and remembers that too.
    ///
    /// Half-typed lines go first: every row leaves the screen the moment the
    /// flag flips, and a line still holding uncommitted text would have nowhere
    /// left to send it from. Focus goes with them, or a row would grant itself
    /// first responder the moment the lines came back and put the keyboard up
    /// over a lyric nobody asked to type into. Arranging goes too — it is the
    /// other thing this screen can be in the middle of, and reading is an
    /// answer to "show me the songs", not "show me the order".
    private func enterReadingView() {
        focusedLine = nil
        for lyric in lyrics.values {
            lyric.focusedBlockId = nil
            lyric.focusRequest = nil
        }
        Task {
            await commitEverything()
            isArranging = false
            isReading = true
            readingViews.remember(true, for: .songsWorkspace(project: model.project.id))
        }
    }

    // MARK: - The two lists

    /// Every song, open to be written in or to be read — the screen this is
    /// most of the time. Which of the two it is changes the lines inside each
    /// section and nothing else about it: the headers, the open set and the
    /// scroll position all survive the mode being swapped under them.
    private var songList: some View {
        List {
            ForEach(songs) { song in
                Section {
                    if expanded.contains(song.id) {
                        lines(for: song)
                    }
                } header: {
                    header(song)
                }
                .listRowSeparator(.hidden)
            }
        }
    }

    /// The same songs as a plain list of titles, to be dragged into order.
    ///
    /// Arranging is a mode rather than something a writer can do to the screen
    /// as it stands, and that is forced by what a list can be asked to do. A
    /// song here is a `Section` with its lyric lines as the rows inside it, and
    /// a section cannot be dragged: the reordering a list *does* offer,
    /// `.onMove`, moves rows within one `ForEach`, and a lyric line and the
    /// song it belongs to cannot both be that row. So the songs are laid out on
    /// their own for as long as it takes to arrange them — which is also what
    /// makes the gesture usable, since a screen of open lyrics is a long scroll
    /// to drag the fourth song past the first.
    ///
    /// The lyrics are not gone: every model is kept, and closing the mode gives
    /// back the same screen, still open at the same songs.
    private var arrangingList: some View {
        List {
            ForEach(songs) { song in
                HStack(spacing: 8) {
                    Text(song.displayTitle)
                        .font(.headline)
                    Spacer(minLength: 0)
                    if isLocked(song) {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }
            .onMove { source, destination in
                var rearranged = songs
                rearranged.move(fromOffsets: source, toOffset: destination)
                save(rearranged)
            }
        }
        // What puts the grip on every row and lets it be dragged. Held active
        // rather than bound to a toggle: there is nothing else to be in the
        // middle of here, and the way out is the bar below.
        .environment(\.editMode, .constant(.active))
    }

    /// The way out of arranging, in the bar the keyboard key uses — the only
    /// room on this screen for a control that is only sometimes there.
    private var arrangingBar: some View {
        HStack {
            Text("Drag the songs into the order you want.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Done") { isArranging = false }
                .font(.body.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// Opens the arranging mode, after putting away whatever is half-typed:
    /// the lines are about to leave the screen, and a verse must not leave with
    /// them.
    private func startArranging() {
        focusedLine = nil
        for lyric in lyrics.values {
            lyric.focusedBlockId = nil
            lyric.focusRequest = nil
        }
        Task {
            await commitEverything()
            isArranging = true
        }
    }

    // MARK: - Offline notices

    private func offlineKey(_ song: TextDocument) -> String {
        DismissedNotices.offlineCopyKey(songId: song.id)
    }

    private func offlineState(_ savedAt: Date) -> String {
        DismissedNotices.offlineCopyState(savedAt: savedAt)
    }

    private func dismissOffline(_ song: TextDocument, savedAt: Date) {
        withAnimation(.snappy(duration: 0.2)) {
            notices.dismiss(offlineKey(song), state: offlineState(savedAt))
        }
    }

    /// Every open lyric's stale-copy stamp, by song. Watched as one value
    /// rather than row by row: a row that has stopped being offline is a row
    /// that is no longer on screen to notice it, and its dismissal still has to
    /// be retired.
    private var offlineStamps: [Int: String] {
        lyrics.compactMapValues { $0.offlineCopySavedAt.map(offlineState) }
    }

    // MARK: - Undo and redo

    /// The lyric a keyboard step applies to: the one holding the caret.
    ///
    /// Every song here keeps its own history, so there is no single stack for a
    /// screen-wide ⌘Z to walk — but there is always an unambiguous answer while
    /// the writer is typing, which is the only time the chord is reached for.
    /// Asked of the lyrics rather than of `focusedLine`, for the reason the
    /// hide-keyboard bar above asks them: no row claims SwiftUI's focus value,
    /// so it is discarded. With the caret nowhere the chord does nothing rather
    /// than guessing at a song, or reaching past this cover to the script.
    private var focusedLyric: SongBlockModel? {
        lyrics.values.first { $0.focusedBlockId != nil }
    }

    private var menuActions: DocumentEditorActions {
        // ⌘P means every song on this screen, which is what this screen is.
        // Claimed even with the caret nowhere, so the chord cannot fall through
        // the cover and send the screenplay behind it to the printer.
        let printSongs: (() -> Void)? = songs.isEmpty ? nil : { printAll() }
        // Nothing to step back through on a page being read — and still
        // published, so ⌘Z over the songs can never fall through to the script
        // this screen is covering.
        guard !isReading, let lyric = focusedLyric else {
            return DocumentEditorActions(print: printSongs)
        }
        return DocumentEditorActions(
            undo: { Task { await lyric.undo() } },
            redo: { Task { await lyric.redo() } },
            canUndo: lyric.canUndo,
            canRedo: lyric.canRedo,
            print: printSongs)
    }

    /// The songs on screen on paper, one to a sheet — the same file the list's
    /// own Print All produces, since it is the same gathering.
    ///
    /// The lyrics open here answer for themselves where the print has to be
    /// drawn on the device: they hold what has been typed this minute, which
    /// is newer than the copy on disk. A song nobody expanded falls back to
    /// that copy like everything else.
    private func printAll() {
        printer.print(all: songs, of: .song, named: printJobName) { song in
            guard let lyric = lyrics[song.id], !lyric.blocks.isEmpty else { return nil }
            return lyric.blocks.map { lyric.currentText($0) }
        }
    }

    /// What the printer queue calls the job — the same name the songs list
    /// gives the songbook it downloads.
    private var printJobName: String {
        model.project.displayTitle.isEmpty
            ? "songs"
            : model.project.displayTitle + " Songs"
    }

    /// Undo and redo for one song's lyric, in the header that names it.
    ///
    /// Per song rather than per screen, because that is what the history is:
    /// each lyric keeps its own, on the server and on this device, and a single
    /// pair in the toolbar could only ever guess which one a press meant. They
    /// appear on a song that is open — there is nothing to watch change in a
    /// collapsed one — and only where there is a history to walk, which offline
    /// means the steps this device is holding. Same order and same symbols as
    /// the song editor's own pair, so the gesture reads the same in both.
    ///
    /// Gone while the songs are being read, as the editor's pair is: there is
    /// nothing on that surface for a step back to be a step back from.
    @ViewBuilder
    private func historyButtons(_ song: TextDocument) -> some View {
        if !isReading, expanded.contains(song.id),
           let lyric = lyrics[song.id], lyric.offersUndoRedo {
            Button {
                Task { await lyric.undo() }
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 32, height: 32)
                    // 32pt is well under the 44pt minimum, and these sit right
                    // beside the full-width expand button — a miss collapses
                    // the document instead. 4pt each side is the ceiling here:
                    // the header spaces them 8pt apart, so any more and
                    // neighbouring hit areas would overlap rather than meet.
                    .glyphHitArea()
            }
            .glyphHitInset()
            .buttonStyle(.borderless)
            .disabled(!lyric.canUndo)
            .accessibilityLabel("Undo in \(song.displayTitle)")

            Button {
                Task { await lyric.redo() }
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 32, height: 32)
                    // 32pt is well under the 44pt minimum, and these sit right
                    // beside the full-width expand button — a miss collapses
                    // the document instead. 4pt each side is the ceiling here:
                    // the header spaces them 8pt apart, so any more and
                    // neighbouring hit areas would overlap rather than meet.
                    .glyphHitArea()
            }
            .glyphHitInset()
            .buttonStyle(.borderless)
            .disabled(!lyric.canRedo)
            .accessibilityLabel("Redo in \(song.displayTitle)")
        }
    }

    private func syncOpenLyrics() async {
        for lyric in lyrics.values
        where lyric.hasUnsavedChanges || lyric.isShowingOfflineCopy {
            await lyric.syncHeldWork()
        }
    }

    // MARK: - Rows

    private func header(_ song: TextDocument) -> some View {
        HStack(spacing: 8) {
            Button {
                toggle(song)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded.contains(song.id) ? 90 : 0))
                    Text(song.displayTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    // Why this song's lines will not take a keystroke. The
                    // switch is in the song's own editor, so all this has to
                    // do is answer the question.
                    if isLocked(song) {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    statusLabel(song)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isLocked(song)
                                ? "\(song.displayTitle), locked"
                                : song.displayTitle)
            .accessibilityHint(expanded.contains(song.id) ? "Hide lyrics" : "Show lyrics")
            .accessibilityAddTraits(expanded.contains(song.id) ? [.isSelected] : [])
            historyButtons(song)
            if canReorder || canLock(song) {
                songMenu(song)
            }
        }
        .textCase(nil)
    }

    /// What the header says on the right: whether this song's lines are all on
    /// the server, and how long the lyric runs when they are. A collapsed
    /// section is the only place its writer can be told either — the notes
    /// workspace says the same two things in the same corner.
    ///
    /// Counted over what is on screen rather than what was last saved, exactly
    /// as the song editor's own readout counts it.
    @ViewBuilder
    private func statusLabel(_ song: TextDocument) -> some View {
        if let lyric = lyrics[song.id], !lyric.isLoading {
            if lyric.hasFailedSaves {
                Label("Not saved", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if lyric.hasUnsavedChanges {
                Label("Kept on this device", systemImage: "icloud.slash")
                    .font(.caption)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Kept on this device — saves when you're back online")
            } else {
                // Off the lyric's own memo: this header redraws on every
                // keystroke in its song, and re-splitting every line per
                // character — for each of a dozen open songs — was the most
                // expensive thing on the screen.
                let words = lyric.wordCount
                Text("\(words) \(words == 1 ? "word" : "words")")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// What can be done to one song from the row that names it: moved a slot,
    /// and closed to typing.
    ///
    /// The one-slot move is kept beside the drag. The web puts a drag handle on
    /// every song here, and Arrange Songs is what answers it — but a handle's
    /// arrow keys also move a card a single slot, and that is worth having in
    /// reach without changing what the screen is. It is the route for a nudge,
    /// for VoiceOver, and for anyone who would rather not hold a drag steady
    /// down a scrolling list.
    ///
    /// The lock joins it rather than taking a button of its own in the header.
    /// There is no room: an open song already carries Undo, Redo and this, and
    /// a fourth glyph on an iPhone would push the title into an ellipsis. The
    /// padlock in the header still says *which* songs are locked; this is where
    /// the answer is changed — a menu on the song, for the writer looking at
    /// one song and meaning it.
    private func songMenu(_ song: TextDocument) -> some View {
        let at = songs.firstIndex { $0.id == song.id }
        return Menu {
            if canReorder {
                Button {
                    move(song, by: -1)
                } label: {
                    Label("Move Up", systemImage: "arrow.up")
                }
                .disabled(at == 0)
                Button {
                    move(song, by: 1)
                } label: {
                    Label("Move Down", systemImage: "arrow.down")
                }
                .disabled(at == songs.count - 1)
            }
            if canLock(song) {
                Toggle(isOn: lockBinding(song)) {
                    Label("Lock Editing", systemImage: "lock")
                }
            }
        } label: {
            // "…" rather than the two arrows this wore while it only reordered:
            // a glyph that says one of the things behind it would send a writer
            // looking elsewhere for the other.
            Image(systemName: "ellipsis")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .glyphHitArea()
        }
        .glyphHitInset()
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("More for \(song.displayTitle)")
    }

    @ViewBuilder
    private func lines(for song: TextDocument) -> some View {
        if let lyric = lyrics[song.id] {
            // Not while reading. The strip is an offer to take a lock off so
            // the words can be typed into, and there is no typing on this
            // surface to be stopped — the padlock in the header still says
            // which song is closed, which is all a reader needs told. In the
            // song editor it stands through both modes because there it is one
            // strip at the top of one song; here it would be one inside every
            // open lyric, down a page whose whole point is an uninterrupted
            // read.
            if !isReading {
                lockBanner(song, lyric)
            }
            // The same honesty the song editor's banner gives: an out-of-date
            // lyric must not look current — and the same ✕, since a writer who
            // has read it should be able to get the row back.
            if let savedAt = lyric.offlineCopySavedAt,
               !notices.isDismissed(offlineKey(song), state: offlineState(savedAt)) {
                HStack(spacing: 6) {
                    Label("Offline — lyrics saved "
                          + savedAt.formatted(.relative(presentation: .named)),
                          systemImage: "wifi.slash")
                    Spacer(minLength: 0)
                    NoticeCloseButton { dismissOffline(song, savedAt: savedAt) }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                // `.ignore` rather than `.combine`, so the close button comes
                // through as a named action instead of being swallowed.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Offline. Showing the lyrics saved on this device "
                                    + savedAt.formatted(.relative(presentation: .named)) + ".")
                .accessibilityAction(named: "Dismiss") { dismissOffline(song, savedAt: savedAt) }
            }
            if lyric.blocks.isEmpty {
                Text(lyric.isLoading ? "Loading…" : "No lines yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if isReading {
                // Fed from what is on screen rather than from what was last
                // saved, as the song editor's reader is: a line typed a moment
                // ago has to read as typed whether or not its save has landed.
                // Still one row per line, and still the lines' own ids — the
                // rows are what the mode changes, not how many there are.
                ForEach(lyric.blocks) { block in
                    readingLine(block, in: song, of: lyric)
                }
            } else {
                ForEach(lyric.blocks) { block in
                    SongLineRow(model: lyric,
                                block: block,
                                isLocked: isLocked(song),
                                focusedLine: $focusedLine,
                                startWriting: startWriting(song, lyric))
                }
            }
            // No Add Line button under a song that has lines. This screen
            // stacks every song in the project, so a button under each one
            // repeats down the whole list and reads as part of the next song's
            // verse. Return at the end of a line makes the next line, which is
            // how a lyric is written anyway. A song with nothing in it has no
            // line to press Return at, so that one keeps the offer.
            //
            // Never while reading: a page being read has no room for an offer
            // to start writing on it, which is the rule the song editor's own
            // reader follows.
            if !isReading, lyric.blocks.isEmpty, !lyric.isLoading,
               lyric.canAddLine, !isLocked(song) {
                Button {
                    Task {
                        if let created = await lyric.appendLine() { focusedLine = created }
                    }
                } label: {
                    Label("Add Line", systemImage: "plus")
                        .font(.callout)
                }
            }
        }
    }

    /// One line of a lyric, set to be read: the writing surface's own text view
    /// with the caret taken out of it — `ProseText`, which is what the song
    /// editor's reader is built from too.
    ///
    /// The padding, the row insets and the single spacing are the editable
    /// row's own, down to the two points above and below, because that is the
    /// whole rule of this mode: the words do not move on the way into reading.
    /// Same engine, same face, same width, same left edge, line for line — the
    /// only difference is that one takes a caret and the other does not.
    ///
    /// A blank line is drawn as a space so it stands as tall as the empty row
    /// it replaces; a verse break is something the writer typed and can see
    /// themselves having typed.
    ///
    /// Highlights are deliberately not drawn, as `ReadSongView` does not draw
    /// them: a tint is a working mark on a line to come back to, which is not
    /// what this surface is for.
    private func readingLine(_ block: SongBlock,
                             in song: TextDocument,
                             of lyric: SongBlockModel) -> some View {
        let text = lyric.currentText(block)
        return ProseText(text: text.isEmpty ? " " : text,
                  textScale: settings.textScale,
                  // Two taps in the words are the same instruction as Edit in
                  // the corner, the way they are in Pages and Word. The line is
                  // named as well as the song, so the caret can land in the
                  // words the finger actually touched.
                  startWriting: startWriting(song, lyric, block))
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    /// Says this song is closed to typing, and takes the lock off when tapped —
    /// `EditingLockBanner`, the strip both song editors already show over a
    /// locked lyric.
    ///
    /// The padlock in the header above says *which* song is locked, but it is a
    /// glyph rather than a way out, and the switch itself is inside that song's
    /// own editor, behind its overflow menu. Without this, a writer working down
    /// this page meets a verse that silently refuses every keystroke with
    /// nothing on screen to do about it — the double tap on the words gets in
    /// too, but a gesture nobody is told about cannot be the only door.
    ///
    /// Only where the words were the writer's to begin with. A lyric the server
    /// handed over read-only has no lock of this device's to take off, and a
    /// strip offering to unlock it would be a second dead end behind the first.
    @ViewBuilder
    private func lockBanner(_ song: TextDocument, _ lyric: SongBlockModel) -> some View {
        if isLocked(song), isWritable(lyric) {
            EditingLockBanner { locks[song.id]?.setEditingLocked(false) }
                // Edge to edge, as it is over a single song's lyric: the strip
                // is about the whole song, not about the column of lines the
                // rows' own 16pt insets belong to.
                .listRowInsets(EdgeInsets())
        }
    }

    /// Whether the server would take a keystroke in this lyric at all —
    /// `SongBlockEditorView.isSongEditable` asks the same of its one song.
    private func isWritable(_ lyric: SongBlockModel) -> Bool {
        lyric.canAddLine || lyric.blocks.contains(where: \.isEditable)
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.songs.isEmpty {
            ContentUnavailableView(
                "No Songs Yet",
                systemImage: "music.note",
                description: Text("Create a song and it will show up here alongside the rest."))
        } else if songs.isEmpty {
            ContentUnavailableView.search(text: filter)
        }
    }

    /// Where the writing on this screen currently lives, read across every song
    /// that has been opened. Same precedence as the song editor's badge —
    /// refused beats retrying — but taken over the whole workspace, because a
    /// verse held back in the fourth song down is as unsaved as one in the
    /// first, and nothing else here would say so while that song is collapsed.
    private var cloudState: CloudSyncState? {
        guard !app.isDemo else { return nil }
        // Ahead of the rest, as everywhere else: those clear up on their own
        // and this one is waiting on the writer.
        if !openConflicts.isEmpty { return .conflicted }
        if !app.connectivity.isOnline { return .offline }
        if lyrics.values.contains(where: \.hasFailedSaves) { return .failed }
        return lyrics.values.contains(where: \.hasUnsavedChanges) ? .holding : .synced
    }

    /// Every unanswered disagreement across the songs opened here, oldest
    /// first. Only the songs that have been opened have a lyric model to have
    /// found one — the same limit the held-line count above lives with.
    private var openConflicts: [SyncConflict] {
        lyrics.values.flatMap(\.conflicts).sorted { $0.detectedAt < $1.detectedAt }
    }

    /// Which song's lyric a conflict belongs to. The workspace shows one list
    /// over many models, so the resolution has to be handed back to the model
    /// that filed it — anything else would write a verse into the wrong song.
    private func lyric(holding conflict: SyncConflict) -> SongBlockModel? {
        lyrics.values.first { $0.conflicts.contains { $0.id == conflict.id } }
    }

    /// Lines still kept on this device, counted across every open song.
    private var heldLineCount: Int {
        lyrics.values.reduce(0) { $0 + $1.unsavedBlockIds.count }
    }

    /// When this *screen* was last in step with the server — so the oldest of
    /// the open songs, not the newest. One song syncing a moment ago says
    /// nothing about the four beneath it, and the badge's panel is answering
    /// "is what I can see up to date?".
    private var lastSyncedAt: Date? {
        lyrics.values.compactMap(\.lastSyncedAt).min()
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") {
                Task {
                    await commitEverything()
                    // The list behind this cover draws a preview and an edited
                    // date per song; without this it keeps showing the ones it
                    // had before the writer spent an hour in here.
                    await model.refreshAfterDocumentEdit()
                    dismiss()
                }
            }
        }
        // Beside the way out, where the song editor and the screenplay keep it:
        // leaving is the moment a writer wonders whether their words are
        // anywhere but here.
        if let cloud = cloudState {
            ToolbarItem(placement: .topBarLeading) {
                CloudSyncBadge(state: cloud,
                               heldCount: heldLineCount,
                               lastSyncedAt: lastSyncedAt,
                               // Pressable, as every other badge in the app is.
                               // This was the one screen where a writer staring
                               // at an amber cloud could not tap it to find out
                               // when anything last landed, or to try again.
                               sync: { await syncEverything() },
                               conflictCount: openConflicts.count,
                               review: openConflicts.isEmpty ? nil : { showingConflicts = true })
            }
            .sharedBackgroundVisibility(.hidden)
        }
        // "Expand"/"Collapse" rather than the "Expand All"/"Collapse All" these
        // were: the badge has to fit beside them, and with Done, a badge and
        // both words spelled out the iPhone bar is one item over what it will
        // draw — it then drops one, and not the same one twice: one launch
        // loses Collapse All, the next loses the badge. A badge that is only
        // sometimes there is worse than no badge. The two words each buy back
        // the room, and the "All" they lose is the part the buttons never
        // needed: every song on screen is what this screen is.
        ToolbarItemGroup(placement: .primaryAction) {
            // The mode, leading the group so a phone — which draws about two
            // controls on the trailing side before the rest go to the "…" —
            // always draws it. Icon-only like its neighbours, and in the one
            // capsule with them rather than as an item of its own: a third
            // toolbar item beside Done and the badge is what tips this bar into
            // dropping something, and not the same something twice.
            //
            // One button that swaps rather than a pair, so this corner is
            // always one tap to whichever surface is not up — the arrangement
            // the song editor arrived at.
            if isReading {
                Button {
                    beginEditing()
                } label: {
                    Label("Edit", systemImage: "square.and.pencil")
                }
                .labelStyle(.iconOnly)
            } else {
                Button {
                    enterReadingView()
                } label: {
                    Label("Read Songs", systemImage: "book")
                }
                .labelStyle(.iconOnly)
                .disabled(songs.isEmpty)
            }
            // Only the songs currently passing the filter, so "expand all"
            // means the same thing the writer can see.
            Button {
                for song in songs { open(song) }
            } label: {
                Label("Expand All", systemImage: "rectangle.expand.vertical")
            }
            .labelStyle(.iconOnly)
            .disabled(songs.isEmpty)

            Button {
                expanded.subtract(songs.map(\.id))
            } label: {
                Label("Collapse All", systemImage: "rectangle.compress.vertical")
            }
            .labelStyle(.iconOnly)
            .disabled(expanded.isEmpty)
        }
        // The mode itself, in the "…" this screen has instead of a View menu —
        // the song editor's own toggle, in the plural. It says which way the
        // screen is currently put, which a button that swaps its own label
        // cannot, and it is the way back for anyone the button above is not
        // enough for.
        ToolbarItem(placement: .secondaryAction) {
            Toggle(isOn: readingBinding) {
                Label("Read Songs", systemImage: "book")
            }
            .disabled(songs.isEmpty && !isReading)
        }
        // In the overflow rather than the bar itself, which on an iPhone is
        // already one item from dropping something. Arranging is a thing a
        // writer does once in a while and then leaves alone, unlike the two
        // buttons above.
        if canReorder {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    startArranging()
                } label: {
                    Label("Arrange Songs", systemImage: "arrow.up.arrow.down")
                }
            }
        }
        // The one screen that can close the whole book at once, which is the
        // job the lock is most often wanted for and the one it was worst at: a
        // finished show meant opening each song, finding the switch behind its
        // overflow menu, and closing it again, however many numbers that is.
        //
        // In the overflow beside Arrange, not the bar: this is done at the end
        // of a draft, not while working. It changes nothing about what a lock
        // is — it sets each song's own, one after another, so unlocking the one
        // number being rewritten leaves the rest of the book closed.
        if !lockableSongs.isEmpty {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    setLock(!allLocked, on: lockableSongs)
                } label: {
                    Label(allLocked ? "Unlock All Songs" : "Lock All Songs",
                          systemImage: allLocked ? "lock.open" : "lock")
                }
            }
        }
        // Every song at once is where a field of red squiggles is hardest to
        // read past, so the switch belongs here as much as anywhere.
        ToolbarItem(placement: .secondaryAction) {
            SpellingMenu(showingIgnoredWords: $showingIgnoredWords)
        }
        // Every song at once is also the screen a writer prints a set list
        // from. In the overflow with Arrange, for the reason that one is: the
        // bar itself is an item from dropping something on a phone.
        if !songs.isEmpty {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    printAll()
                } label: {
                    Label("Print All Songs…", systemImage: "printer")
                }
                .disabled(printer.isPrinting)
            }
        }
    }

    // MARK: - Ordering

    /// Only where the server said the songs may be rearranged, and only with
    /// more than one of them on screen to rearrange.
    private var canReorder: Bool { model.canReorderDocuments && songs.count > 1 }

    /// Moves a song one slot among the ones the filter is showing.
    private func move(_ song: TextDocument, by delta: Int) {
        guard let rearranged = songs.moving(song, by: delta) else { return }
        save(rearranged)
    }

    /// Saves the songs on screen as the writer's own arrangement — songs the
    /// filter hid keep the places they held, since they were not on screen to
    /// have been moved past.
    private func save(_ rearranged: [TextDocument]) {
        guard canReorder else { return }
        let merged = model.songs.merging(shown: rearranged)
        Task { await model.reorderDocuments(merged) }
    }

    // MARK: - Opening and closing

    private func toggle(_ song: TextDocument) {
        if expanded.contains(song.id) {
            expanded.remove(song.id)
            // Collapsing is not leaving: flush what was typed, but keep the
            // model so opening it again is instant and loses nothing.
            if let lyric = lyrics[song.id] {
                Task { await lyric.commitAll() }
            }
        } else {
            open(song)
        }
    }

    private func open(_ song: TextDocument) {
        expanded.insert(song.id)
        // Also here, and not only from the watcher above: the songs left open
        // last time are restored the instant the documents land, which is
        // before SwiftUI has run a redraw for the change that would have made
        // these.
        ensureLock(song)
        guard lyrics[song.id] == nil else { return }
        let lyric = SongBlockModel(app: app, document: song)
        lyrics[song.id] = lyric
        Task { await lyric.load() }
    }

    /// No edition named: this screen always reads the default lyric, which is
    /// the one a song-level lock covers.
    private func ensureLock(_ song: TextDocument) {
        guard locks[song.id] == nil else { return }
        locks[song.id] = DocumentViewOptions(documentId: song.id, kind: .song)
    }

    private func ensureLocks() {
        for song in model.songs { ensureLock(song) }
    }

    /// Whether this song is closed to typing.
    private func isLocked(_ song: TextDocument) -> Bool {
        locks[song.id]?.isEditingLocked ?? false
    }

    /// Whether there is anything here to lock — the same rule the songs list
    /// goes by, so the switch is in the same places on both screens. Asked of
    /// the document's link rather than of its lyric, which a collapsed song has
    /// not loaded: an affordance that appeared on expanding a song would look
    /// like it belonged to the expanding.
    private func canLock(_ song: TextDocument) -> Bool {
        song.hasLink(.update) && locks[song.id] != nil
    }

    private func lockBinding(_ song: TextDocument) -> Binding<Bool> {
        Binding(get: { isLocked(song) }, set: { setLock($0, on: [song]) })
    }

    /// Closes songs to typing, or opens them again.
    ///
    /// Locking puts the keyboard away and flushes first, for the reason the
    /// song editor's own switch does: what is half-typed when a lyric is closed
    /// is part of the lyric, and the debounce that would have saved it is about
    /// to have no field left to fire from. The lock itself is set without
    /// waiting on that — the tick in the menu has to answer the tap, and the
    /// commit is on its way regardless.
    private func setLock(_ locked: Bool, on targets: [TextDocument]) {
        if locked {
            for song in targets {
                guard let lyric = lyrics[song.id] else { continue }
                if lyric.focusedBlockId != nil { focusedLine = nil }
                lyric.focusedBlockId = nil
                lyric.focusRequest = nil
                Task { await lyric.commitAll() }
            }
        }
        for song in targets {
            locks[song.id]?.setEditingLocked(locked)
        }
    }

    /// The songs a lock could be put on — which is every one of them for a
    /// writer, and none of them for a collaborator reading the show.
    ///
    /// Only the songs currently passing the filter, the rule Expand All above
    /// goes by: "all songs" has to mean the songs the writer can see, or a
    /// filtered screen would quietly reach past its own edges.
    private var lockableSongs: [TextDocument] {
        songs.filter(canLock)
    }

    /// Whether the button says Lock or Unlock. A screen with one song still
    /// open to typing offers to close it, so the writer finishing a book presses
    /// this once and is done — the flip to Unlock is the confirmation that the
    /// press landed on all of them.
    private var allLocked: Bool {
        let lockable = lockableSongs
        return !lockable.isEmpty && lockable.allSatisfy(isLocked)
    }

    /// The double tap into writing, for both of the things that can stand
    /// between a writer and a lyric here: the reading view the screen is in,
    /// and this song's own lock. Whatever is in the way comes off, so a verse
    /// being read is one gesture from the keyboard rather than two.
    ///
    /// Only this song's lock: the others on screen were each locked on purpose,
    /// one at a time, and a gesture that cleared them all would be the accident
    /// the lock exists to prevent. Reading, on the other hand, is the screen's
    /// posture and comes off for the screen — there is no such thing as one
    /// song being read here while its neighbours are typed into.
    ///
    /// Handed how far into the line the finger landed, in UTF-16, and spent
    /// only on the way out of reading: a lock leaves each line the view it
    /// already was and the row places its own caret, while leaving the reading
    /// view tears the row down and builds the writing row in its place, so the
    /// caret has to be carried across. One line to a row here, which is why
    /// this needs none of the walking back through a whole lyric that
    /// `SongBlockEditorView`'s single reading column does — the row the tap
    /// landed in is the row that was asked.
    ///
    /// Nil where nothing is in the way, or where the server never offered this
    /// song to be written in: the lines are already taking a caret, or nothing
    /// this device can undo would give them one.
    private func startWriting(_ song: TextDocument,
                              _ lyric: SongBlockModel,
                              _ block: SongBlock? = nil) -> ((Int) -> Void)? {
        guard isWritable(lyric), isReading || isLocked(song) else { return nil }
        return { offset in
            if isLocked(song) { locks[song.id]?.setEditingLocked(false) }
            guard isReading else { return }
            // Asked before the mode changes, while the words on screen are
            // still the ones the offset was measured against.
            if let block, block.isEditable {
                lyric.caretRequests[block.id] =
                    lyric.currentText(block).characterOffset(utf16: offset)
                pendingWriteLine = block.id
            }
            beginEditing()
        }
    }

    /// Reopens the songs left open last time. Runs after the documents load so
    /// a remembered id that no longer names a song is simply dropped rather than
    /// opening an empty section.
    private func restoreOpenSongs() {
        let saved = openStore.load()
        for song in model.songs where saved.contains(song.id) {
            open(song)
        }
        didRestore = true
    }

    private func commitEverything() async {
        for lyric in lyrics.values {
            await lyric.commitAll()
        }
    }

    /// Push everything held and pull whatever changed, song by song — what the
    /// badge's "Sync Now" does here. Serial rather than parallel: each
    /// `syncNow` ends in a reload, and a dozen of those at once is a dozen
    /// round trips the badge would have to keep a spinner over anyway. It
    /// refuses a second press until this returns.
    private func syncEverything() async {
        for lyric in lyrics.values {
            await lyric.syncNow()
        }
    }
}
