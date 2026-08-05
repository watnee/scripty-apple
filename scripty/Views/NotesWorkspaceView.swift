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
//  The open set is shared with the songs workspace and with the browser, under
//  the one key all three already use. Song and note ids come from the same
//  table, so an id in that set can only ever match one of them and the two
//  screens never confuse each other's sections.
//

import SwiftUI

struct NotesWorkspaceView: View {
    let app: AppModel
    let model: ScriptModel

    /// Only here to seed the printer, as in the songs workspace.
    init(app: AppModel, model: ScriptModel) {
        self.app = app
        self.model = model
        _printer = State(initialValue: DocumentPrintModel(model: model))
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
    /// Whether each opened note is closed to typing. A lock set in the note
    /// editor has to hold here too, or the screen that shows every note at once
    /// would be the way around every lock in the project — the songs workspace
    /// mirrors its own locks for exactly that reason. Read only: the switch
    /// stays in the note's own editor, where a writer is looking at one note
    /// and means it.
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
    /// Which note holds the caret, so a keyboard ⌘Z has an unambiguous answer.
    /// Reported by the panes themselves rather than kept in a `@FocusState`:
    /// these are bridged text views that grant themselves first responder, and
    /// SwiftUI discards a focus value no view claimed with `.focused()`.
    @State private var focusedNote: Int?

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
                if let id = focusedNote, drafts[id] != nil {
                    HideKeyboardBar(releaseFocus: { focusedNote = nil })
                }
            }
            .navigationTitle("All Notes")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .safeAreaInset(edge: .top, spacing: 0) { conflictBanner }
            .toolbar { toolbar }
            // Same claim the note editor makes, and for the same reason: this
            // is a cover over the screenplay, and without it the menu's ⌘Z
            // would rewind the script behind it. Published even when it can do
            // nothing, so a step here never falls through to the script.
            .focusedSceneValue(\.documentEditorActions, menuActions)
            .documentPrintPresentation(printer)
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
            if canReorder {
                reorderMenu(note)
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
    @ViewBuilder
    private func historyButtons(_ note: TextDocument) -> some View {
        if expanded.contains(note.id), let draft = drafts[note.id], canWrite(in: note) {
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
        guard let id = focusedNote, let draft = drafts[id], canWrite(id) else {
            return DocumentEditorActions(print: printNotes)
        }
        return DocumentEditorActions(undo: { draft.history.undo() },
                                     redo: { draft.history.redo() },
                                     canUndo: draft.history.canUndo,
                                     canRedo: draft.history.canRedo,
                                     print: printNotes)
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

    /// The songs workspace offers the same one-slot move for the same reason:
    /// each document is a `Section`, and sections do not take `.onMove`.
    private func reorderMenu(_ note: TextDocument) -> some View {
        let at = notes.firstIndex { $0.id == note.id }
        return Menu {
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
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .glyphHitArea()
        }
        .glyphHitInset()
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("Reorder \(note.displayTitle)")
    }

    @ViewBuilder
    private func noteBody(for note: TextDocument) -> some View {
        if let draft = drafts[note.id] {
            if draft.isLoading {
                Text("Loading…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
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
                // A fixed height rather than one that grows with the prose: a
                // list of ten notes each as tall as its content would be a page
                // nobody can navigate, and the point of this screen is seeing
                // several at once. Each field scrolls inside itself.
                NoteTextView(text: contentBinding(for: note),
                             controller: draft.history,
                             isEditable: canWrite(in: note),
                             spellChecks: settings.isSpellcheckEnabled,
                             spellcheckRevision: SpellcheckDictionary.shared.revision,
                             textScale: settings.textScale,
                             placeholder: canWrite(in: note) ? "Write your notes here…" : "",
                             // Two taps take this note's lock off, the way they
                             // do on a locked lyric here and on a locked note
                             // in its own editor.
                             startWriting: startWriting(note),
                             // Which note a keyboard ⌘Z means. Cleared only
                             // when the caret leaves *this* pane for something
                             // that is not another one, so tabbing between two
                             // notes never leaves the chord pointing at neither.
                             onFocusChange: { focused in
                                 if focused {
                                     focusedNote = note.id
                                 } else if focusedNote == note.id {
                                     focusedNote = nil
                                 }
                             })
                    .frame(height: 240)
                    .accessibilityLabel(note.displayTitle)
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
                               sync: { await flushAll() })
            }
            .sharedBackgroundVisibility(.hidden)
        }
        ToolbarItemGroup(placement: .primaryAction) {
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
    /// same strip the screenplay and the song editors raise — this screen has
    /// no cloud badge of its own, so it is the only way in from here.
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

    /// Moves a note one slot among the ones the filter is showing, then saves
    /// the whole list — notes the filter hid keep the places they held, since
    /// they are not on screen to have been moved past.
    private func move(_ note: TextDocument, by delta: Int) {
        guard canReorder, let rearranged = notes.moving(note, by: delta) else { return }
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
        guard drafts[note.id] == nil else { return }
        let draft = NoteDraft(document: note)
        drafts[note.id] = draft
        // Under the note's own key family, so this reads the very lock the note
        // editor writes — see `DocumentViewOptions.Kind`.
        locks[note.id] = DocumentViewOptions(documentId: note.id, kind: .note)
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

    /// Whether this note is closed to typing. A note nobody has opened has no
    /// stored answer here and needs none — nothing of it is on screen to type
    /// into.
    private func isLocked(_ note: TextDocument) -> Bool {
        locks[note.id]?.isEditingLocked ?? false
    }

    /// Whether the words in this pane will take a keystroke: the server's own
    /// permission, and this device's lock over it. By id, because the keyboard's
    /// ⌘Z knows only which pane holds the caret.
    private func canWrite(_ id: Int) -> Bool {
        (drafts[id]?.canEdit ?? false) && !(locks[id]?.isEditingLocked ?? false)
    }

    private func canWrite(in note: TextDocument) -> Bool { canWrite(note.id) }

    /// The double tap that takes a locked note's lock off, so a writer working
    /// down this screen can start typing in the one note they meant without
    /// going back to its editor to find the switch. Nil for a note already open
    /// to be typed in — there is nothing to undo.
    ///
    /// Only this note's lock: the others on screen were each locked on purpose,
    /// one at a time, and a gesture that cleared them all would be the accident
    /// the lock exists to prevent.
    private func startWriting(_ note: TextDocument) -> (() -> Void)? {
        guard isLocked(note), drafts[note.id]?.canEdit == true else { return nil }
        return { locks[note.id]?.setEditingLocked(false) }
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
