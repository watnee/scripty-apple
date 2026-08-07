//
//  NotesWorkspaceView.swift
//  scripty
//
//  Every note in the project on one screen — the counterpart of the songs
//  workspace, and it exists for the same reason.
//
//  The notes list opens one note at a time, which is right when you know which
//  note you want. It is wrong for the job this screen is for: a fact that turns
//  out to belong in a different note, or the same character's name spelled two
//  ways across four of them. That means opening, editing, closing and opening
//  again, and losing your place each time.
//
//  What it is *not* is the songs workspace with the word changed. A song is an
//  ordered list of lyric lines belonging to an edition, so its pane is a stack
//  of line editors with their own commit rules. A note is prose in one field.
//  So this borrows the shape — collapsible sections, a filter, reorder by one
//  slot, the remembered open set — and keeps its own middle: one text view per
//  note, saving itself as it is written, exactly as the note editor does.
//
//  It reads as well as writes, and it locks. Those are the other two things a
//  screen of every note is for, and for a while they were the songs workspace's
//  alone: reading the set through — a page of live text fields with a caret
//  waiting in every one of them is exactly the accident the reading view exists
//  to stop — and closing a finished batch to typing without opening each note
//  to find its switch. Both work here the way they work there. Reading is one
//  posture for the whole screen, taken in place: the panes swap for the reading
//  column and the headers, the open set, the banners and the saving all stay
//  where they were. The lock stays per note, because that is what a lock is.
//
//  The open set is shared with the songs workspace and with the browser, under
//  the one key all three already use. Song and note ids come from the same
//  table, so an id in that set can only ever match one of them and the two
//  screens never confuse each other's sections.
//

import SwiftUI

struct NotesWorkspaceView: View {
    let app: AppModel
    let model: ScriptModel

    /// Seeds the printer, as in the songs workspace, and settles which way the
    /// screen comes up.
    init(app: AppModel, model: ScriptModel) {
        self.app = app
        self.model = model
        _printer = State(initialValue: DocumentPrintModel(model: model))
        _exporter = State(initialValue: DocumentExportModel(model: model))
        // The remembered choice only, with no fall back to the app-wide "open
        // documents for reading" switch — the rule the songs workspace goes by.
        // This screen is reached by pressing "Edit All on One Page", and coming
        // up with no caret in it would be the button's own word contradicted.
        _isReading = State(initialValue: ReadingViewSettings.shared
            .chosenReadingView(.notesWorkspace(project: model.project.id)) ?? false)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    /// The device-wide type size, so prose here reads at the size the writer
    /// chose in a note or the screenplay — it is one setting.
    private let settings = PresentationSettings.shared

    /// Which notes' stale copies have been closed. Per note, and under the same
    /// keys the note editor uses: it is one notice about one note, and closing
    /// it in the editor should not leave it standing here.
    private let notices = DismissedNotices.shared

    /// One per note, made on first expand. Notes nobody opens cost nothing —
    /// the list carries only a preview, so an unopened note is never fetched.
    @State private var drafts: [Int: NoteDraft] = [:]
    /// Whether each note is closed to typing. A lock set in the note editor has
    /// to hold here too, or the screen that shows every note at once would be
    /// the way around every lock in the project — the songs workspace mirrors
    /// its own locks for exactly that reason.
    ///
    /// One for every note rather than only the opened ones, which is what these
    /// were. A collapsed note can now say it is locked and be locked from its
    /// own menu, and Lock All Notes has to reach the ones nobody expanded —
    /// they are exactly the notes a writer finishing a batch means. A reader is
    /// two `UserDefaults` reads, so a project's worth of them is nothing next
    /// to one note loading.
    @State private var locks: [Int: DocumentViewOptions] = [:]
    @State private var expanded: Set<Int> = []
    @State private var filter = ""
    @State private var showingIgnoredWords = false
    /// Whether the two-versions screen is up. Opened by a press only: a sheet
    /// that appeared over a half-typed note because a sweep found something
    /// would interrupt the one thing this screen is for.
    @State private var showingConflicts = false
    /// Set once the saved open set has been restored, so the first restore does
    /// not immediately save the empty starting state back over it.
    @State private var didRestore = false
    /// Every note on screen on paper. One printer for the screen, as the notes
    /// list keeps one for the list.
    @State private var printer: DocumentPrintModel

    /// And the same gathering as a file. Beside the printer for the reason the
    /// two controls sit beside each other: one is an errand, the other is a
    /// choice of format — see `DocumentExportMenu`.
    @State private var exporter: DocumentExportModel

    /// The device's one voice, shared with the screenplay behind this cover and
    /// with both editors — see `ScriptNarrator`. Reading here ends whatever was
    /// being read before it, which is the only sane answer on a device with one
    /// pair of headphones.
    private let narrator = ScriptNarrator.shared
    /// Which note holds the caret, so a keyboard ⌘Z has an unambiguous answer.
    /// Reported by the panes themselves rather than kept in a `@FocusState`:
    /// these are bridged text views that grant themselves first responder, and
    /// SwiftUI discards a focus value no view claimed with `.focused()`.
    @State private var focusedNote: Int?
    /// Whether the screen is showing the notes to be dragged into order rather
    /// than to be written in. See `arrangingList`.
    @State private var isArranging = false
    /// Whether the notes are up to be read rather than written in. The note
    /// editor's own mode, taken across every note on screen: the panes are
    /// swapped for the reading column in place, and the headers, the open set
    /// and everything in the bars stay put.
    ///
    /// One flag for the screen rather than one per note, because this screen is
    /// one thing — a set read through, or a set worked on — and a page where
    /// the second note takes a caret and the third does not is neither. A note
    /// that wants a posture of its own has an editor where it can have one.
    @State private var isReading: Bool
    /// Where a double tap on a reading pane asked for the caret, by note.
    ///
    /// Spent by the writing pane the mode change builds in its place — the note
    /// editor carries the same request across the same handoff, for the same
    /// reason: the view that measured the offset is torn down before the view
    /// that can act on it exists.
    @State private var caretRequests: [Int: Int] = [:]

    /// Which way this screen was last put, remembered per project.
    private let readingViews = ReadingViewSettings.shared

    private var openStore: SongWorkspaceOpenState {
        SongWorkspaceOpenState(projectId: model.project.id)
    }

    private var notes: [TextDocument] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.notes }
        return model.notes.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isArranging {
                    arrangingList
                } else {
                    noteList
                }
            }
            .listStyle(.plain)
            .searchable(text: $filter, prompt: "Filter notes")
            .overlay { emptyState }
            // The same way down from a note the editor gives. Mounted in the
            // bar rather than in the list, where a conditional row is a coin
            // toss from one launch to the next — the songs workspace carries
            // its own for the same reason.
            //
            // Asked of `focusedNote`, which the panes report themselves: these
            // are bridged text views that take first responder for themselves,
            // and SwiftUI discards a focus value no view claimed.
            .safeAreaBar(edge: .bottom, spacing: 0) {
                if isArranging {
                    arrangingBar
                } else if narrator.isActive && isBeingRead {
                    narrationBar
                } else if let id = focusedNote, drafts[id] != nil {
                    HideKeyboardBar(releaseFocus: { focusedNote = nil })
                }
            }
            .navigationTitle("All Notes")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .safeAreaInset(edge: .top, spacing: 0) { conflictBanner }
            .toolbar { toolbar }
            // A reading belongs to this screen, so it ends when the screen
            // does — the same rule both editors keep. Left running, the voice
            // would go on reading notes over whatever the writer went to
            // next, with no transport anywhere to stop it.
            .onDisappear {
                if isBeingRead { narrator.stop() }
            }
            // Same claim the note editor makes, and for the same reason: this
            // is a cover over the screenplay, and without it the menu's ⌘Z
            // would rewind the script behind it. Published even when it can do
            // nothing, so a step here never falls through to the script.
            .focusedSceneValue(\.documentEditorActions, menuActions)
            .documentPrintPresentation(printer)
            .documentExportPresentation(exporter)
            .sheet(isPresented: $showingIgnoredWords) {
                SpellcheckWordsView()
            }
            .sheet(isPresented: $showingConflicts) {
                SyncConflictsView(conflicts: noteConflicts,
                                  keepMine: { await model.keepMine($0) },
                                  keepTheirs: { model.keepTheirs($0) },
                                  noun: "note")
            }
            .task {
                await model.loadDocuments()
                restoreOpenNotes()
            }
            .onChange(of: expanded) { _, ids in
                guard didRestore else { return }
                openStore.save(ids)
            }
            // The connection came back: any note holding words this device
            // could not send gets another go at sending them.
            .onChange(of: app.connectivity.isOnline) { _, online in
                guard online else { return }
                Task { await flushAll() }
            }
            // Backgrounding persists every half-typed paragraph before the
            // system decides how much longer this process runs.
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background, .inactive:
                    Task { await flushAll() }
                case .active:
                    break
                @unknown default:
                    break
                }
            }
            // A note that reloaded — from the server, or from a newer cached
            // copy — is a new situation, so whatever was closed about the old
            // one stops applying. The songs workspace has had this from the
            // start; without it, dismissing the strip once meant a *newer*
            // stale copy was never announced for that note again.
            .onChange(of: offlineStamps) { old, new in
                for id in Set(old.keys).union(new.keys) where old[id] != new[id] {
                    notices.situationChanged(DismissedNotices.documentCopyKey(documentId: id))
                }
            }
            // A lock reader per note, kept in step with the notes. `initial`
            // for the case where the project's notes were already in hand when
            // this screen opened, which is most of the time.
            .onChange(of: model.notes.map(\.id), initial: true) { _, _ in
                ensureLocks()
            }
        }
    }

    // MARK: - Reading and writing

    /// The mode, as a Toggle can use it — through the two functions below rather
    /// than straight at the state, so choosing it in the "…" is remembered, and
    /// flushes what is half-typed, exactly as the button is.
    private var readingBinding: Binding<Bool> {
        Binding(get: { isReading },
                set: { reading in
                    if reading { enterReadingView() } else { beginEditing() }
                })
    }

    /// Hands the notes back to the writer, and remembers that this is a screen
    /// they write on — so Edit is a cost paid once rather than on every visit.
    private func beginEditing() {
        isReading = false
        readingViews.remember(false, for: .notesWorkspace(project: model.project.id))
    }

    /// Puts the notes up to be read, and remembers that too.
    ///
    /// Half-typed paragraphs go first: every pane leaves the screen the moment
    /// the flag flips, and a note still holding unsent words would have nowhere
    /// left to send them from. Focus goes with them, or a pane would grant
    /// itself first responder the moment the fields came back and put the
    /// keyboard up over a note nobody asked to type into. Arranging goes too —
    /// it is the other thing this screen can be in the middle of, and reading is
    /// an answer to "show me the notes", not "show me the order".
    private func enterReadingView() {
        focusedNote = nil
        Task {
            await flushAll()
            isArranging = false
            isReading = true
            readingViews.remember(true, for: .notesWorkspace(project: model.project.id))
        }
    }

    // MARK: - The two lists

    /// Every note, open to be written in or to be read — the screen this is most
    /// of the time. Which of the two it is changes what is inside each section
    /// and nothing else about it: the headers, the open set and the scroll
    /// position all survive the mode being swapped under them.
    private var noteList: some View {
        List {
            ForEach(notes) { note in
                Section {
                    if expanded.contains(note.id) {
                        noteBody(for: note)
                    }
                } header: {
                    header(note)
                }
                .listRowSeparator(.hidden)
            }
        }
    }

    /// The same notes as a plain list of titles, to be dragged into order.
    ///
    /// Arranging is a mode rather than something a writer can do to the screen
    /// as it stands, and that is forced by what a list can be asked to do — a
    /// note here is a `Section`, and a section cannot be dragged. The songs
    /// workspace lays its own out the same way for the same reason, and there
    /// as here it is what makes the gesture usable: a screen of open notes is a
    /// long scroll to drag the fourth one past the first.
    ///
    /// The panes are not gone: every draft is kept, and closing the mode gives
    /// back the same screen, still open at the same notes.
    private var arrangingList: some View {
        List {
            ForEach(notes) { note in
                HStack(spacing: 8) {
                    Text(note.displayTitle)
                        .font(.headline)
                    Spacer(minLength: 0)
                    if isLocked(note) {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }
            .onMove { source, destination in
                var rearranged = notes
                rearranged.move(fromOffsets: source, toOffset: destination)
                saveOrder(rearranged)
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
            Text("Drag the notes into the order you want.")
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

    /// Opens the arranging mode, after putting away whatever is half-typed: the
    /// panes are about to leave the screen, and a paragraph must not leave with
    /// them.
    private func startArranging() {
        focusedNote = nil
        Task {
            await flushAll()
            isArranging = true
        }
    }

    // MARK: - Offline notices

    private func offlineKey(_ note: TextDocument) -> String {
        DismissedNotices.documentCopyKey(documentId: note.id)
    }

    private func offlineState(_ savedAt: Date) -> String {
        DismissedNotices.offlineCopyState(savedAt: savedAt)
    }

    private func dismissOffline(_ note: TextDocument, savedAt: Date) {
        withAnimation(.snappy(duration: 0.2)) {
            notices.dismiss(offlineKey(note), state: offlineState(savedAt))
        }
    }

    /// Every open note's stale-copy stamp, by note. Watched as one value
    /// rather than row by row: a row that has stopped being offline is a row
    /// that is no longer on screen to notice it, and its dismissal still has to
    /// be retired.
    private var offlineStamps: [Int: String] {
        drafts.compactMapValues { $0.offlineCopySavedAt.map(offlineState) }
    }

    // MARK: - Rows

    private func header(_ note: TextDocument) -> some View {
        HStack(spacing: 8) {
            Button {
                toggle(note)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded.contains(note.id) ? 90 : 0))
                    Text(note.displayTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    // Why this note's words will not take a keystroke. The
                    // switch is in the note's own editor, so all this has to do
                    // is answer the question — the songs workspace says it the
                    // same way in the same place.
                    if isLocked(note) {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    statusLabel(note)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isLocked(note)
                                ? "\(note.displayTitle), locked"
                                : note.displayTitle)
            .accessibilityHint(expanded.contains(note.id) ? "Hide this note" : "Show this note")
            .accessibilityAddTraits(expanded.contains(note.id) ? [.isSelected] : [])
            historyButtons(note)
            if canReorder || canLock(note) {
                noteMenu(note)
            }
        }
        .textCase(nil)
    }

    // MARK: - Undo and redo

    /// Undo and redo for one note's prose, in the header that names it.
    ///
    /// Per note rather than per screen, because that is what the history is:
    /// each pane is its own document with its own stack, and a single pair in
    /// the toolbar could only ever guess which one a press meant. They appear
    /// on a note that is open — there is nothing to watch change in a collapsed
    /// one — and never on one the server will not take an edit for. Same order
    /// and same symbols as the note editor's own pair, so the gesture reads the
    /// same in both. The songs workspace puts its own pair here too.
    ///
    /// Gone while the notes are being read, as the editor's pair is: there is
    /// nothing on that surface for a step back to be a step back from.
    @ViewBuilder
    private func historyButtons(_ note: TextDocument) -> some View {
        if !isReading, expanded.contains(note.id), let draft = drafts[note.id], canWrite(in: note) {
            Button {
                draft.history.undo()
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
            .disabled(!draft.history.canUndo)
            .accessibilityLabel("Undo in \(note.displayTitle)")

            Button {
                draft.history.redo()
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
            .disabled(!draft.history.canRedo)
            .accessibilityLabel("Redo in \(note.displayTitle)")
        }
    }

    /// What the menu bar's ⌘Z means here: the note holding the caret. With the
    /// caret nowhere the chord does nothing rather than guessing at a note, or
    /// reaching past this cover to the script.
    private var menuActions: DocumentEditorActions {
        // ⌘P means every note on this screen, whatever the caret is doing —
        // and is claimed even when there is nothing to print, so the chord
        // cannot fall through this cover to the screenplay behind it.
        let printNotes: (() -> Void)? = notes.isEmpty ? nil : { printAll() }
        // And ⌘⇧A means every note on this screen, read as one run — claimed
        // for the reason ⌘P is. `readAloudTarget` prefers this value whenever
        // it is present, so leaving it nil disabled the chord here rather than
        // letting it fall through, which meant the one screen showing every
        // note at once was the one screen that could not be read aloud.
        let readNotes: (() -> Void)? = notes.isEmpty ? nil : { toggleReadAloud() }
        // Nothing to step back through on a page being read — and still
        // published, so ⌘Z over the notes can never fall through to the script
        // this screen is covering.
        guard !isReading, let id = focusedNote, let draft = drafts[id], canWrite(id) else {
            return DocumentEditorActions(readAloud: readNotes, print: printNotes)
        }
        return DocumentEditorActions(undo: { draft.history.undo() },
                                     redo: { draft.history.redo() },
                                     canUndo: draft.history.canUndo,
                                     canRedo: draft.history.canRedo,
                                     readAloud: readNotes,
                                     print: printNotes)
    }

    // MARK: - Reading the set through

    /// This screen's claim on the device's one voice.
    private var narrationSubject: NarrationSubject {
        .workspace(project: model.project.id, kind: .notes)
    }

    /// Whether the voice is reading *this* screen rather than one note, the
    /// screenplay behind the cover, or a song.
    private var isBeingRead: Bool { narrator.subject == narrationSubject }

    /// Every note on screen as one run, in the order the list is showing them.
    ///
    /// Each note's title goes in as a Markdown heading, because
    /// `cues(forNote:)` already reads one as a heading cue — so the run
    /// announces which note it has reached without this having to invent a way
    /// of saying so.
    ///
    /// Built from the same two places the print of this screen is: an open note
    /// holds what has been typed this minute, and a note nobody expanded was
    /// never fetched and falls back to the copy this device kept.
    private var narrationSource: NarrationSource {
        var parts: [String] = []
        for note in notes {
            parts.append("# " + note.displayTitle)
            if let draft = drafts[note.id] {
                parts.append(draft.content)
            } else if let cached = model.cachedDocumentLines(note) {
                parts.append(cached.joined(separator: "\n"))
            }
        }
        return .note(parts.joined(separator: "\n\n"))
    }

    /// Reads the set through, or pauses and resumes one already running.
    private func toggleReadAloud() {
        if narrator.isActive && isBeingRead {
            narrator.togglePlayPause()
            return
        }
        narrator.prepare(narrationSource, subject: narrationSubject, title: printJobName)
        narrator.play()
    }

    /// The transport, up only while this screen is the thing being read.
    @ViewBuilder
    private var narrationBar: some View {
        if narrator.isActive && isBeingRead {
            NarrationTransportBar(narrator: narrator)
        }
    }

    /// The notes on screen on paper, one to a sheet — the same file the list's
    /// own Print All produces.
    ///
    /// The notes open here answer for themselves where the sheet has to be
    /// drawn on the device: their panes hold what has been typed this minute.
    /// A note nobody expanded was never fetched, so it falls back to whatever
    /// copy this device kept.
    private func printAll() {
        printer.print(all: notes, of: .notes, named: printJobName) { note in
            guard let draft = drafts[note.id], !draft.content.isEmpty else { return nil }
            return draft.content.components(separatedBy: "\n")
        }
    }

    /// What the printer queue calls the job — the same name the notes list
    /// gives the file it downloads.
    private var printJobName: String {
        model.project.displayTitle.isEmpty
            ? "notes"
            : model.project.displayTitle + " Notes"
    }

    /// What the header says on the right: how far a save has got while one is
    /// happening, and how long the note is the rest of the time. A closed
    /// section is the only place its writer can be told either.
    @ViewBuilder
    private func statusLabel(_ note: TextDocument) -> some View {
        if let draft = drafts[note.id] {
            switch draft.status {
            case .saving:
                Text("Saving…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .held:
                Label("Kept on this device", systemImage: "icloud.slash")
                    .font(.caption)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Kept on this device — saves when you're back online")
            case .failed:
                Label("Not saved", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .idle, .saved:
                if !draft.isLoading {
                    // Off the draft's own memo: this header redraws on every
                    // keystroke in its note, and re-splitting the whole thing
                    // per character — ten times over, with ten notes open —
                    // was the most expensive thing on the screen.
                    let words = draft.wordCount
                    Text("\(words) \(words == 1 ? "word" : "words")")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// What can be done to one note from the row that names it: moved a slot,
    /// and closed to typing.
    ///
    /// The one-slot move is kept beside the drag, exactly as the songs
    /// workspace keeps its own. Arrange Notes is the answer to rearranging a
    /// screenful, but a nudge of one row is worth having in reach without
    /// changing what the screen is — and it is the route for VoiceOver, and for
    /// anyone who would rather not hold a drag steady down a scrolling list.
    ///
    /// The lock joins it rather than taking a button of its own in the header.
    /// There is no room: an open note already carries Undo, Redo and this, and a
    /// fourth glyph on an iPhone would push the title into an ellipsis. The
    /// padlock in the header still says *which* notes are locked; this is where
    /// the answer is changed — a menu on the note, for the writer looking at one
    /// note and meaning it.
    private func noteMenu(_ note: TextDocument) -> some View {
        let at = notes.firstIndex { $0.id == note.id }
        return Menu {
            if canReorder {
                Button {
                    move(note, by: -1)
                } label: {
                    Label("Move Up", systemImage: "arrow.up")
                }
                .disabled(at == 0)
                Button {
                    move(note, by: 1)
                } label: {
                    Label("Move Down", systemImage: "arrow.down")
                }
                .disabled(at == notes.count - 1)
            }
            if canLock(note) {
                Toggle(isOn: lockBinding(note)) {
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
        .accessibilityLabel("More for \(note.displayTitle)")
    }

    @ViewBuilder
    private func noteBody(for note: TextDocument) -> some View {
        if let draft = drafts[note.id] {
            if draft.isLoading {
                Text("Loading…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                // Not while reading. The strip is an offer to take a lock off
                // so the words can be typed into, and there is no typing on
                // this surface to be stopped — the padlock in the header still
                // says which note is closed, which is all a reader needs told.
                // In the note editor it stands through both modes because there
                // it is one strip at the top of one note; here it would be one
                // inside every open pane, down a page whose whole point is an
                // uninterrupted read.
                if !isReading {
                    lockBanner(note, draft)
                }
                // The same honesty the songs workspace gives a lyric it had to
                // read off disk: an out-of-date note must not look current.
                if let savedAt = draft.offlineCopySavedAt,
                   !notices.isDismissed(offlineKey(note), state: offlineState(savedAt)) {
                    HStack(spacing: 6) {
                        Label("Offline — note saved "
                              + savedAt.formatted(.relative(presentation: .named)),
                              systemImage: "wifi.slash")
                        Spacer(minLength: 0)
                        NoticeCloseButton { dismissOffline(note, savedAt: savedAt) }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    // `.ignore` rather than `.combine`, so the close button
                    // comes through as a named action instead of being
                    // swallowed.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Offline. Showing the note saved on this device "
                                        + savedAt.formatted(.relative(presentation: .named)) + ".")
                    .accessibilityAction(named: "Dismiss") { dismissOffline(note, savedAt: savedAt) }
                }
                if isReading {
                    readingPane(note, draft)
                } else {
                    // A fixed height rather than one that grows with the prose:
                    // a list of ten notes each as tall as its content would be
                    // a page nobody can navigate, and the point of this screen
                    // is seeing several at once. Each field scrolls inside
                    // itself.
                    NoteTextView(text: contentBinding(for: note),
                                 controller: draft.history,
                                 isEditable: canWrite(in: note),
                                 spellChecks: settings.isSpellcheckEnabled,
                                 spellcheckRevision: SpellcheckDictionary.shared.revision,
                                 textScale: settings.textScale,
                                 placeholder: canWrite(in: note) ? "Write your notes here…" : "",
                                 // Two taps take this note's lock off, the way
                                 // they do on a locked lyric here and on a
                                 // locked note in its own editor.
                                 startWriting: startWriting(note),
                                 // The other end of a double tap made on the
                                 // reading pane, which is no longer on screen
                                 // to place its own caret.
                                 caret: caretRequests[note.id],
                                 onCaretApplied: { caretRequests[note.id] = nil },
                                 // Which note a keyboard ⌘Z means. Cleared only
                                 // when the caret leaves *this* pane for
                                 // something that is not another one, so
                                 // tabbing between two notes never leaves the
                                 // chord pointing at neither.
                                 onFocusChange: { focused in
                                     if focused {
                                         focusedNote = note.id
                                     } else if focusedNote == note.id {
                                         focusedNote = nil
                                     }
                                 })
                        .frame(height: 240)
                        .accessibilityLabel(note.displayTitle)
                }
                if case .failed(let message) = draft.status {
                    HStack(spacing: 6) {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                        Button("Retry") {
                            Task { await save(note) }
                        }
                        .font(.footnote.weight(.medium))
                    }
                }
            }
        }
    }

    /// Writes straight into the note's own draft and arms its debounce, so one
    /// note being typed into never re-renders or re-saves any of the others.
    private func contentBinding(for note: TextDocument) -> Binding<String> {
        Binding(
            get: { drafts[note.id]?.content ?? "" },
            set: { newValue in
                guard let draft = drafts[note.id], draft.content != newValue else { return }
                draft.content = newValue
                scheduleSave(note)
            })
    }

    /// One note, set to be read: the writing pane's own text view with the caret
    /// taken out of it — `ProseText`, which is what the note editor's reader is
    /// built from too.
    ///
    /// The same width, the same face and the same scale as the field it stands
    /// in for, and it is a list row either way, so the words break where they
    /// broke a moment ago. That is the whole rule of this mode: the words do not
    /// move on the way into reading.
    ///
    /// The one thing that does change is the height. The writing pane is clamped
    /// to 240 points and scrolls inside itself, which is right for a screen of
    /// fields to work in and wrong for the job reading is here for — a note read
    /// through a porthole is a note nobody reads. `ProseText` does not scroll, so
    /// a clamp would simply cut the end off; it reports its full height and the
    /// list scrolls the page, note after note, which is what reading a set is.
    private func readingPane(_ note: TextDocument, _ draft: NoteDraft) -> some View {
        // Fed from what is on screen rather than from what was last saved, as
        // the note editor's reader is: a paragraph typed a moment ago has to
        // read as typed whether or not its save has landed. A blank note is
        // drawn as a space so its section does not collapse to nothing.
        ProseText(text: draft.content.isEmpty ? " " : draft.content,
                  textScale: settings.textScale,
                  // Two taps in the prose are the same instruction as Edit in
                  // the corner, the way they are in Pages and Word.
                  startWriting: startWriting(note))
            .accessibilityLabel(note.displayTitle)
    }

    /// Says this note is closed to typing, and takes the lock off when tapped —
    /// `EditingLockBanner`, the strip both editors already show over a locked
    /// document.
    ///
    /// The padlock in the header above says *which* note is locked, but it is a
    /// glyph rather than a way out, and the switch itself is in this note's own
    /// menu beside it. Without this, a writer working down this page meets a
    /// note that silently refuses every keystroke with nothing on screen to do
    /// about it — the double tap on the words gets in too, but a gesture nobody
    /// is told about cannot be the only door.
    ///
    /// Only where the words were the writer's to begin with. A note the server
    /// handed over read-only has no lock of this device's to take off, and a
    /// strip offering to unlock it would be a second dead end behind the first.
    @ViewBuilder
    private func lockBanner(_ note: TextDocument, _ draft: NoteDraft) -> some View {
        if isLocked(note), draft.canEdit {
            EditingLockBanner { locks[note.id]?.setEditingLocked(false) }
                // Edge to edge, as it is over a single note: the strip is about
                // the whole note, not about the column of prose the row's own
                // insets belong to.
                .listRowInsets(EdgeInsets())
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.notes.isEmpty {
            ContentUnavailableView(
                "No Notes Yet",
                systemImage: "note.text",
                description: Text("Create a note and it will show up here alongside the rest."))
        } else if notes.isEmpty {
            ContentUnavailableView.search(text: filter)
        }
    }

    /// Where the writing on this screen currently lives, read across every note
    /// that has been opened. Same precedence as the note editor's badge —
    /// refused beats waiting — but taken over the whole workspace, because a
    /// paragraph held back in the fourth note down is as unsaved as one in the
    /// first, and nothing else here would say so while that note is collapsed.
    ///
    /// A save merely in flight is not "holding", exactly as in the note editor:
    /// a badge that went amber every time a writer paused for a second is a
    /// badge nobody reads by the end of the first page.
    private var cloudState: CloudSyncState? {
        guard !app.isDemo else { return nil }
        // Ahead of the rest, as every sibling has it: the others clear up on
        // their own and this one is waiting on the writer. Without it two
        // devices editing the same note left this badge reading "Synced" —
        // green, over a note in disagreement — with nothing on the screen
        // offering a way to settle it, though the sheet and the routing were
        // both already here.
        if !noteConflicts.isEmpty { return .conflicted }
        if !app.connectivity.isOnline { return .offline }
        if drafts.values.contains(where: { if case .failed = $0.status { return true } else { return false } }) {
            return .failed
        }
        return drafts.values.contains { $0.status == .held } ? .holding : .synced
    }

    /// Notes still kept on this device, counted across every open pane — the
    /// refused ones too, since those words are equally still only here.
    private var heldNoteCount: Int {
        drafts.values.filter { draft in
            switch draft.status {
            case .held, .failed: true
            default: false
            }
        }.count
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") {
                Task {
                    await flushAll()
                    await model.refreshAfterDocumentEdit()
                    dismiss()
                }
            }
        }
        // Beside the way out, where the note editor and the songs workspace both
        // keep it: leaving is the moment a writer wonders whether their words
        // are anywhere but here.
        if let cloud = cloudState {
            ToolbarItem(placement: .topBarLeading) {
                CloudSyncBadge(state: cloud,
                               heldCount: heldNoteCount,
                               sync: { await flushAll() },
                               conflictCount: noteConflicts.count,
                               review: noteConflicts.isEmpty
                                   ? nil : { showingConflicts = true })
            }
            .sharedBackgroundVisibility(.hidden)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            // The mode, leading the group so a phone — which draws about two
            // controls on the trailing side before the rest go to the "…" —
            // always draws it. Icon-only like its neighbours, and in the one
            // capsule with them rather than as an item of its own: a third
            // toolbar item beside Done and the badge is what tips this bar into
            // dropping something, and not the same something twice.
            //
            // One button that swaps rather than a pair, so this corner is always
            // one tap to whichever surface is not up — the arrangement the note
            // editor and the songs workspace both arrived at.
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
                    Label("Read Notes", systemImage: "book")
                }
                .labelStyle(.iconOnly)
                .disabled(notes.isEmpty)
            }
            // Only the notes currently passing the filter, so "expand all"
            // means the same thing the writer can see.
            //
            // Icon-only, as the songs workspace draws them: with Done, a badge
            // and both phrases spelled out, the iPhone bar is an item over what
            // it will draw and drops a different one on each launch — a badge
            // that is only sometimes there is worse than no badge.
            Button {
                for note in notes { open(note) }
            } label: {
                Label("Expand All", systemImage: "rectangle.expand.vertical")
            }
            .labelStyle(.iconOnly)
            .disabled(notes.isEmpty)

            Button {
                expanded.subtract(notes.map(\.id))
            } label: {
                Label("Collapse All", systemImage: "rectangle.compress.vertical")
            }
            .labelStyle(.iconOnly)
            .disabled(expanded.isEmpty)
        }
        // The mode itself, in the "…" this screen has instead of a View menu —
        // the note editor's own toggle, in the plural. It says which way the
        // screen is currently put, which a button that swaps its own label
        // cannot, and it is the way back for anyone the button above is not
        // enough for.
        ToolbarItem(placement: .secondaryAction) {
            Toggle(isOn: readingBinding) {
                Label("Read Notes", systemImage: "book")
            }
            .disabled(notes.isEmpty && !isReading)
        }
        // In the overflow rather than the bar itself, which on an iPhone is
        // already one item from dropping something. Arranging is a thing a
        // writer does once in a while and then leaves alone, unlike the buttons
        // above.
        if canReorder {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    startArranging()
                } label: {
                    Label("Arrange Notes", systemImage: "arrow.up.arrow.down")
                }
            }
        }
        // The one screen that can close every note at once, which is the job the
        // lock is most often wanted for and the one it was worst at: a finished
        // batch meant opening each note, finding the switch behind its overflow
        // menu, and closing it again, however many there are.
        //
        // In the overflow beside Arrange, not the bar: this is done at the end
        // of a session, not while working. It changes nothing about what a lock
        // is — it sets each note's own, one after another, so unlocking the one
        // note being rewritten leaves the rest closed.
        if !lockableNotes.isEmpty {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    setLock(!allLocked, on: lockableNotes)
                } label: {
                    Label(allLocked ? "Unlock All Notes" : "Lock All Notes",
                          systemImage: allLocked ? "lock.open" : "lock")
                }
            }
        }
        ToolbarItem(placement: .secondaryAction) {
            SpellingMenu(showingIgnoredWords: $showingIgnoredWords)
        }
        // Every note at once is the screen a writer prints a set of them from.
        // In the overflow, where the songs workspace keeps its own: the bar
        // itself is an item from dropping something on a phone.
        if !notes.isEmpty {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    printAll()
                } label: {
                    Label("Print All Notes…", systemImage: "printer")
                }
                .disabled(printer.isPrinting)
            }
            // Reading the set through, beside printing it — the two errands
            // this screen exists for once the writing is done. Pauses and
            // resumes while it is running, so the one item is the whole thing.
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    toggleReadAloud()
                } label: {
                    Label(narrator.isActive && isBeingRead
                            ? "Stop Reading Notes" : "Read Notes Aloud",
                          systemImage: narrator.isActive && isBeingRead
                            ? "stop" : "speaker.wave.2")
                }
            }
            // The same gathering as a file, beside the print of it — the rule
            // `DocumentExportMenu` states, and the one the help already
            // promised this screen kept.
            ToolbarItem(placement: .secondaryAction) {
                DocumentExportMenu(exporter: exporter,
                                   options: model.collectionExportOptions(for: .notes),
                                   name: printJobName)
            }
        }
    }

    // MARK: - Two versions of a note

    /// The unanswered disagreements about the notes this screen is for.
    ///
    /// Scoped to notes the list actually holds rather than to every document
    /// conflict in the project: `.document` covers prose songs too, and a
    /// verse offered for keeping in a screen headed "All Notes" would be the
    /// wrong question in the wrong place. Deliberately read from `model.notes`
    /// rather than the filtered `notes` — a filter typed to find one note is
    /// not a decision to stop being asked about the others.
    ///
    /// One case is knowingly not here: a note *deleted* elsewhere is in no
    /// list to be matched against, so its words are offered by the
    /// screenplay's own banner, which speaks for the whole project.
    private var noteConflicts: [SyncConflict] {
        model.conflicts.filter { conflict in
            guard case let .document(id) = conflict.subject else { return false }
            return model.notes.contains { $0.id == id }
        }
    }

    /// Two versions of a note exist and only the writer can settle it. The
    /// same strip the screenplay and the song editors raise. Both ways in are
    /// offered, as they are everywhere else: the badge answers a writer who
    /// went looking, and the banner tells one who did not know to.
    @ViewBuilder
    private var conflictBanner: some View {
        if !noteConflicts.isEmpty {
            ConflictBanner(count: noteConflicts.count) { showingConflicts = true }
        }
    }

    // MARK: - Ordering

    /// Only where the server said the documents may be rearranged, and only
    /// with more than one on screen to rearrange.
    private var canReorder: Bool { model.canReorderDocuments && notes.count > 1 }

    /// Moves a note one slot among the ones the filter is showing.
    private func move(_ note: TextDocument, by delta: Int) {
        guard let rearranged = notes.moving(note, by: delta) else { return }
        saveOrder(rearranged)
    }

    /// Saves the notes on screen as the writer's own arrangement — notes the
    /// filter hid keep the places they held, since they were not on screen to
    /// have been moved past.
    ///
    /// Named apart from `save(_:)`, which sends one note's words: this screen
    /// has two quite different things to save and one of them is not prose.
    private func saveOrder(_ rearranged: [TextDocument]) {
        guard canReorder else { return }
        let merged = model.notes.merging(shown: rearranged)
        Task { await model.reorderDocuments(merged) }
    }

    // MARK: - Opening and closing

    private func toggle(_ note: TextDocument) {
        if expanded.contains(note.id) {
            expanded.remove(note.id)
            // Collapsing is not leaving: send what was typed, but keep the
            // draft so opening it again is instant and loses nothing.
            Task { await save(note) }
        } else {
            open(note)
        }
    }

    private func open(_ note: TextDocument) {
        expanded.insert(note.id)
        // Also here, and not only from the watcher on the notes: the ones left
        // open last time are restored the instant the documents land, which is
        // before SwiftUI has run a redraw for the change that would have made
        // these.
        ensureLock(note)
        guard drafts[note.id] == nil else { return }
        let draft = NoteDraft(document: note)
        drafts[note.id] = draft
        Task {
            let full = await model.fetchDocument(note)
            draft.content = full?.content ?? note.content ?? ""
            draft.savedContent = draft.content
            // These are the words the pane opens showing, so they are where a
            // step back stops. Anything the history held before them described
            // the truncated preview it was seeded with.
            draft.history.reset(to: draft.content)
            // Whether these words came off the network or off this device. A
            // copy kept here is the whole note and is worth working in, but the
            // pane says so — an out-of-date note must not look current.
            draft.offlineCopySavedAt = model.documentCopySavedAt[note.id]
            // Only a real fetch is evidence of what the server holds; opened
            // offline, the row's preview is truncated and passing *that* as a
            // held draft's base would make the staleness gate read the
            // writer's own words as "changed elsewhere" and discard them. A
            // cached copy is no better evidence: it is what the server said
            // some time ago, not what it says now.
            draft.haveServerBaseline = full != nil && draft.offlineCopySavedAt == nil
            draft.isLoading = false
        }
    }

    /// A lock reader for this note, made once. Under the note's own key family,
    /// so it reads the very lock the note editor writes — see
    /// `DocumentViewOptions.Kind`.
    private func ensureLock(_ note: TextDocument) {
        guard locks[note.id] == nil else { return }
        locks[note.id] = DocumentViewOptions(documentId: note.id, kind: .note)
    }

    private func ensureLocks() {
        for note in model.notes { ensureLock(note) }
    }

    /// Whether this note is closed to typing.
    private func isLocked(_ note: TextDocument) -> Bool {
        locks[note.id]?.isEditingLocked ?? false
    }

    /// Whether there is anything here to lock — the same rule the notes list
    /// goes by, so the switch is in the same places on both screens. Asked of
    /// the document's link rather than of its draft, which a collapsed note has
    /// not loaded: an affordance that appeared on expanding a note would look
    /// like it belonged to the expanding.
    private func canLock(_ note: TextDocument) -> Bool {
        note.hasLink(.update) && locks[note.id] != nil
    }

    private func lockBinding(_ note: TextDocument) -> Binding<Bool> {
        Binding(get: { isLocked(note) }, set: { setLock($0, on: [note]) })
    }

    /// Closes notes to typing, or opens them again.
    ///
    /// Locking puts the keyboard away and sends what is held first, for the
    /// reason the note editor's own switch does: what is half-typed when a note
    /// is closed is part of the note, and the debounce that would have saved it
    /// is about to have no field left to fire from. The lock itself is set
    /// without waiting on that — the tick in the menu has to answer the tap, and
    /// the save is on its way regardless.
    private func setLock(_ locked: Bool, on targets: [TextDocument]) {
        if locked {
            for note in targets where drafts[note.id] != nil {
                if focusedNote == note.id { focusedNote = nil }
                Task { await save(note) }
            }
        }
        for note in targets {
            locks[note.id]?.setEditingLocked(locked)
        }
    }

    /// The notes a lock could be put on — which is every one of them for a
    /// writer, and none of them for a collaborator reading the project.
    ///
    /// Only the notes currently passing the filter, the rule Expand All goes by:
    /// "all notes" has to mean the notes the writer can see, or a filtered
    /// screen would quietly reach past its own edges.
    private var lockableNotes: [TextDocument] {
        notes.filter(canLock)
    }

    /// Whether the button says Lock or Unlock. A screen with one note still open
    /// to typing offers to close it, so the writer finishing a batch presses
    /// this once and is done — the flip to Unlock is the confirmation that the
    /// press landed on all of them.
    private var allLocked: Bool {
        let lockable = lockableNotes
        return !lockable.isEmpty && lockable.allSatisfy(isLocked)
    }

    /// Whether the words in this pane will take a keystroke: the server's own
    /// permission, and this device's lock over it. By id, because the keyboard's
    /// ⌘Z knows only which pane holds the caret.
    private func canWrite(_ id: Int) -> Bool {
        (drafts[id]?.canEdit ?? false) && !(locks[id]?.isEditingLocked ?? false)
    }

    private func canWrite(in note: TextDocument) -> Bool { canWrite(note.id) }

    /// The double tap into writing, for both of the things that can stand
    /// between a writer and a note here: the reading view the screen is in, and
    /// this note's own lock. Whatever is in the way comes off, so a paragraph
    /// being read is one gesture from the keyboard rather than two.
    ///
    /// Only this note's lock: the others on screen were each locked on purpose,
    /// one at a time, and a gesture that cleared them all would be the accident
    /// the lock exists to prevent. Reading, on the other hand, is the screen's
    /// posture and comes off for the screen — there is no such thing as one note
    /// being read here while its neighbours are typed into.
    ///
    /// Where the finger landed is spent only on the way out of reading: a lock
    /// leaves the note the same view it already was and the text view puts its
    /// own caret in, while leaving the reading view tears that pane down and
    /// builds the field in its place, so the offset has to be carried across.
    /// A note is one string on both surfaces, so what the reader measured is
    /// already what the field wants.
    ///
    /// Nil where nothing is in the way, or where the server never offered this
    /// note to be written in.
    private func startWriting(_ note: TextDocument) -> ((Int) -> Void)? {
        guard drafts[note.id]?.canEdit == true, isReading || isLocked(note) else { return nil }
        return { offset in
            if isLocked(note) { locks[note.id]?.setEditingLocked(false) }
            guard isReading else { return }
            caretRequests[note.id] = offset
            beginEditing()
        }
    }

    /// Reopens the notes left open last time. Runs after the documents load so
    /// a remembered id that no longer names a note is simply dropped rather
    /// than opening an empty section.
    private func restoreOpenNotes() {
        let saved = openStore.load()
        for note in model.notes where saved.contains(note.id) {
            open(note)
        }
        didRestore = true
    }

    // MARK: - Saving

    private func scheduleSave(_ note: TextDocument) {
        guard let draft = drafts[note.id], canWrite(in: note) else { return }
        draft.status = .saving
        draft.debounce?.cancel()
        draft.debounce = Task {
            try? await Task.sleep(for: NoteDraft.saveDelay)
            guard !Task.isCancelled else { return }
            await save(note)
        }
    }

    /// Sends one note's words. Mirrors the note editor's own save, down to
    /// comparing what went against what is on screen afterwards — a save
    /// landing while more is being typed is the ordinary case here, where
    /// several notes may be open at once.
    private func save(_ note: TextDocument) async {
        guard let draft = drafts[note.id], draft.canEdit, !draft.isSaving else { return }
        draft.debounce?.cancel()
        guard draft.content != draft.savedContent else {
            if draft.status == .saving { draft.status = .saved }
            return
        }
        let sent = draft.content
        // The title is not editable on this screen, so it goes back exactly as
        // it came — leaving it out would save the note under an empty name.
        let title = note.title ?? note.displayTitle
        draft.isSaving = true
        draft.status = .saving
        let outcome = await model.saveDocumentOutcome(
            note, title: title, content: sent,
            baseTitle: draft.haveServerBaseline ? title : nil,
            baseContent: draft.haveServerBaseline ? draft.savedContent : nil)
        draft.isSaving = false
        switch outcome {
        case .saved:
            draft.savedContent = sent
            draft.haveServerBaseline = true
            draft.status = .saved
            // Typed into while that was in flight: those words have not gone.
            if draft.content != sent { scheduleSave(note) }
        case .held:
            draft.status = .held
        case .failed:
            draft.status = .failed(model.errorMessage ?? "Not saved.")
        }
    }

    /// Every open note, without waiting out any debounce. What Done, the
    /// background and the reconnect all need.
    private func flushAll() async {
        for note in model.notes where drafts[note.id] != nil {
            await save(note)
        }
    }
}

/// One note's words while the workspace holds them.
///
/// A reference type so the binding above can write into it without replacing a
/// dictionary entry — a struct here would mean every keystroke in one note
/// re-publishing the whole `drafts` map, and with ten notes open that is ten
/// text views redrawn per character.
@Observable
@MainActor
final class NoteDraft {
    /// The same debounce the note editor waits: long enough that ordinary
    /// typing is not a request per word, short enough that a writer who looks
    /// away is already saved.
    static let saveDelay: Duration = .milliseconds(1200)

    enum Status: Equatable {
        case idle
        case saving
        case saved
        /// Not sent, but on disk here and queued for the reconnect sweep.
        case held
        /// Refused. The one state the writer has to see, because it is the one
        /// where leaving costs something.
        case failed(String)
    }

    let document: TextDocument

    /// This note's own undo stack, and the handle the header's two buttons
    /// hold on the text view drawing it. One per note, like everything else
    /// here: each pane is a separate document, and a single history across the
    /// screen could only ever guess which one a step back meant. See
    /// `NoteHistory` for why it is the app's stack rather than UIKit's.
    let history = NoteEditorController()

    var content = ""
    /// What the server last confirmed it holds.
    var savedContent = ""
    /// Whether `savedContent` is the server's actual words rather than the
    /// list row's truncated preview, or the copy kept on this device.
    var haveServerBaseline = false
    /// When the words in this pane were saved to this device, or nil where they
    /// are the server's own. The songs workspace says the same thing about a
    /// lyric it had to read off disk.
    var offlineCopySavedAt: Date?
    var isLoading = true
    var isSaving = false
    var status: Status = .idle
    /// The armed debounce, cancelled and replaced on every keystroke.
    @ObservationIgnored var debounce: Task<Void, Never>?

    /// How long this note runs to. Ignored by observation because the header
    /// reads it from `body` and the memo writes on a miss — observed state
    /// written mid-render is the thing SwiftUI warns about.
    @ObservationIgnored private let counter = WordCountMemo()
    var wordCount: Int { counter.words(in: content) }

    /// Read-only where the server did not advertise an update link, the same
    /// gate the single-note editor uses.
    var canEdit: Bool { document.hasLink(.update) }

    init(document: TextDocument) {
        self.document = document
    }
}
