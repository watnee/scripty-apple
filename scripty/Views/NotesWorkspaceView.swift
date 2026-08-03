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

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    /// The device-wide type size, so prose here reads at the size the writer
    /// chose in a note or the screenplay — it is one setting.
    private let settings = PresentationSettings.shared

    /// One per note, made on first expand. Notes nobody opens cost nothing —
    /// the list carries only a preview, so an unopened note is never fetched.
    @State private var drafts: [Int: NoteDraft] = [:]
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
        }
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
                    statusLabel(note)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(note.displayTitle)
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
        if expanded.contains(note.id), let draft = drafts[note.id], draft.canEdit {
            Button {
                draft.history.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!draft.history.canUndo)
            .accessibilityLabel("Undo in \(note.displayTitle)")

            Button {
                draft.history.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!draft.history.canRedo)
            .accessibilityLabel("Redo in \(note.displayTitle)")
        }
    }

    /// What the menu bar's ⌘Z means here: the note holding the caret. With the
    /// caret nowhere the chord does nothing rather than guessing at a note, or
    /// reaching past this cover to the script.
    private var menuActions: DocumentEditorActions {
        guard let id = focusedNote, let draft = drafts[id], draft.canEdit else {
            return DocumentEditorActions()
        }
        return DocumentEditorActions(undo: { draft.history.undo() },
                                     redo: { draft.history.redo() },
                                     canUndo: draft.history.canUndo,
                                     canRedo: draft.history.canRedo)
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
                    let words = ScriptStats.countWords(draft.content)
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
                .contentShape(Rectangle())
        }
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
                // A fixed height rather than one that grows with the prose: a
                // list of ten notes each as tall as its content would be a page
                // nobody can navigate, and the point of this screen is seeing
                // several at once. Each field scrolls inside itself.
                NoteTextView(text: contentBinding(for: note),
                             controller: draft.history,
                             isEditable: draft.canEdit,
                             spellChecks: settings.isSpellcheckEnabled,
                             spellcheckRevision: SpellcheckDictionary.shared.revision,
                             textScale: settings.textScale,
                             placeholder: draft.canEdit ? "Write your notes here…" : "",
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
        ToolbarItemGroup(placement: .primaryAction) {
            // Only the notes currently passing the filter, so "expand all"
            // means the same thing the writer can see.
            Button("Expand All") {
                for note in notes { open(note) }
            }
            .disabled(notes.isEmpty)

            Button("Collapse All") {
                expanded.subtract(notes.map(\.id))
            }
            .disabled(expanded.isEmpty)
        }
        ToolbarItem(placement: .secondaryAction) {
            SpellingMenu(showingIgnoredWords: $showingIgnoredWords)
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
        Task {
            let full = await model.fetchDocument(note)
            draft.content = full?.content ?? note.content ?? ""
            draft.savedContent = draft.content
            // These are the words the pane opens showing, so they are where a
            // step back stops. Anything the history held before them described
            // the truncated preview it was seeded with.
            draft.history.reset(to: draft.content)
            // Only a real fetch is evidence of what the server holds; opened
            // offline, the row's preview is truncated and passing *that* as a
            // held draft's base would make the staleness gate read the
            // writer's own words as "changed elsewhere" and discard them.
            draft.haveServerBaseline = full != nil
            draft.isLoading = false
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
        guard let draft = drafts[note.id], draft.canEdit else { return }
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
    /// list row's truncated preview.
    var haveServerBaseline = false
    var isLoading = true
    var isSaving = false
    var status: Status = .idle
    /// The armed debounce, cancelled and replaced on every keystroke.
    @ObservationIgnored var debounce: Task<Void, Never>?

    /// Read-only where the server did not advertise an update link, the same
    /// gate the single-note editor uses.
    var canEdit: Bool { document.hasLink(.update) }

    init(document: TextDocument) {
        self.document = document
    }
}
