//
//  SongEditorView.swift
//  scripty
//
//  Title + content editor for a note, and for a song the server has no lyric
//  lines for. List rows carry only a preview, so an existing document's full
//  content is fetched when the sheet opens. Read-only when the server didn't
//  advertise an `update` link.
//
//  The writing surface is the whole sheet below the title rather than a row in
//  a Form. A note is prose — often pages of it — and the form put it in a fixed
//  260-point box that scrolled inside the form's own scroll view: two nested
//  scrollers fighting over one drag, and a text view too short to hold a
//  paragraph. What sits around it now is only chrome that earns its place: the
//  formatting bar while the caret is in the note, and the same word-count
//  readout the screenplay and lyric editors show under the same preference.
//
//  A song or a note saves itself as it is written, as it does in the browser.
//  Every other writing surface in this app has worked that way for as long as
//  it has existed — the screenplay debounces each block, a lyric line saves on
//  the way out of it — and this was the last place where an hour of prose lived
//  only in a text view until somebody remembered to press a button. There is no
//  longer a button to remember: the first save of a new document creates it, and
//  every save after that edits it.
//
//  Nothing waits on the title. The server requires one and the list needs
//  something to draw, so a document written without one is saved under the
//  name the list has always drawn for it — "Untitled Notes", the very words
//  `TextDocument.displayTitle` puts there — and typing a real title later is
//  an ordinary rename. Only a writer who *deletes* the name of a document that
//  had one is asked to put it back, because that is the one case where
//  supplying "Untitled" would be taking something away rather than giving
//  something.
//
//  So this sheet now stops the writer over exactly one thing, the thing the
//  Save button was really standing in for: a save the server refused, where
//  the words are only on this device.
//

import SwiftUI

struct SongEditorView: View {
    let model: ScriptModel
    let document: TextDocument?   // nil = create
    let type: DocumentType
    /// Told when the document has landed in the script, so whoever presented
    /// this sheet can clear the way to the screenplay — from the songs list
    /// that means the list dismissing too, as it does for its own insert.
    var onInserted: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var title: String
    @State private var content: String
    /// The document this sheet made. Nil until a new document's first save
    /// lands — from then on this sheet is editing that, and every part of it
    /// that asked "which document?" gets this one instead of nothing.
    @State private var created: TextDocument?
    @State private var isSaving = false
    /// Whether the one create this sheet will ever make is in flight. Kept
    /// apart from `isSaving` because it guards something a save does not need
    /// guarding against: a second POST would make a second document.
    @State private var isCreating = false
    @State private var isLoading = false
    @State private var didLoad = false
    @State private var errorMessage: String?
    /// What the writer is told about the saving of an existing note. Nil until
    /// something has been typed, so a note opened and not touched says nothing.
    @State private var saveStatus: SaveStatus?
    /// The armed debounce. Cancelled and replaced on every keystroke, which is
    /// what makes this a save a second after typing stops rather than one per
    /// character — the same shape `SongBlockModel` gives a lyric line.
    @State private var autosave: Task<Void, Never>?
    /// Whether the caret is in the note itself, so the formatting bar shows
    /// only when there is a line under the caret for it to act on — pressing
    /// "H1" while the title field has focus would silently head a line the
    /// writer cannot see.
    @State private var isWritingBody = false
    @State private var confirmingDiscard = false
    /// In flight to the screenplay. Guards the button rather than showing a
    /// spinner: the send is a save, one POST and a reload, over in a beat.
    @State private var isInserting = false
    /// What an insert that put nothing in the script has to say for itself —
    /// an empty document, unsaved words, or a send the server refused.
    @State private var insertMessage: String?
    /// Set by Discard on the way out, so the parting save knows the words on
    /// screen are not wanted.
    @State private var discarding = false
    /// Whether this document is up to be read rather than written in — where
    /// an existing song or note opens, the way Pages and Word open a file on
    /// iOS. Nothing about the sheet moves: the same title and the same words,
    /// with no caret in them and Edit in the corner.
    ///
    /// State rather than a constant because the sheet leaves the mode two
    /// ways: the writer tapping Edit, and the load finding an empty document,
    /// which is nothing to read and so belongs to the writer.
    @State private var isReadingView: Bool
    /// The formatting bar's handle on the text view.
    @State private var formatting = NoteEditorController()
    @FocusState private var titleFocused: Bool
    @State private var showingIgnoredWords = false

    /// What was on screen when the document finished loading. Anything typed
    /// after that is the work a discard would throw away.
    @State private var savedTitle: String
    @State private var savedContent: String

    /// Whether `savedTitle`/`savedContent` are the server's actual words —
    /// the full fetch landed, or a save did. Opened offline, they are the list
    /// row's truncated preview, and passing *that* as a held draft's base
    /// would guarantee the staleness gate later reads the writer's own words
    /// as "changed elsewhere" and throws them away. No baseline → nil base →
    /// the draft restores and drains ungated, which loses nothing.
    @State private var haveServerBaseline = false

    private let settings = PresentationSettings.shared

    init(model: ScriptModel, document: TextDocument?, type: DocumentType,
         onInserted: (() -> Void)? = nil) {
        self.model = model
        self.document = document
        self.type = type
        self.onInserted = onInserted
        let title = document?.title ?? ""
        let content = document?.content ?? ""
        _title = State(initialValue: title)
        _content = State(initialValue: content)
        _savedTitle = State(initialValue: title)
        _savedContent = State(initialValue: content)
        // A document being written for the first time is never opened to be
        // read: there is nothing in it yet, and the writer asked for a blank
        // one. Everything else opens the way it was last left, or the way the
        // "Open in Edit View" switch says if it has never been put either way.
        _isReadingView = State(initialValue: document.map {
            ReadingViewSettings.shared.opensInReadingView(.document(id: $0.id))
        } ?? false)
    }

    /// Whether documents open to be read, and which way this one was last put.
    private let readingViews = ReadingViewSettings.shared

    /// The document being written: the one this sheet was opened on, or the one
    /// its first save created. Nil only while a new document has yet to land.
    private var target: TextDocument? { document ?? created }

    private var isNew: Bool { target == nil }

    /// Whether the server left this document open to be changed at all. The
    /// standing permission, as against `canEdit` below, which is that *and*
    /// the writer having asked for the keyboard.
    private var isDocumentEditable: Bool { document?.hasLink(.update) ?? true }

    /// Whether the words on screen can be typed into right now. Every save
    /// path in this sheet already guards on it, which is what makes reading
    /// view inert here rather than merely quiet: nothing autosaves, nothing is
    /// flushed on the way out, and nothing is counted as unsaved, because
    /// nothing can have changed.
    private var canEdit: Bool { isDocumentEditable && !isReadingView }
    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The word for what is being written, for the sentences that need it.
    private var kindWord: String { type == .song ? "song" : "note" }

    /// What the server ends up holding for a title field containing `raw`:
    /// the trimmed words, or — where a document is allowed to have no name —
    /// the one the list has always drawn for it. Deliberately spelled the same
    /// way `TextDocument.displayTitle` spells it, so a document saved under
    /// this name reads on every screen exactly as it did before it had one.
    private func storedName(for raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled \(type.label)" : trimmed
    }

    /// Whether an empty title field may be saved under that borrowed name.
    ///
    /// True for a document with no name to lose: one being written for the
    /// first time, one the server itself holds untitled, and one already filed
    /// under the borrowed name — clearing "Untitled Notes" to type a real one
    /// is the first half of a rename, and pausing in the middle of it should
    /// not raise a warning about a name that was never the writer's.
    ///
    /// False once it has a name of its own. A writer who clears the title of
    /// "Ballad of the Lost Hour" has deleted something, and answering that by
    /// filing it under "Untitled Song" behind their back is not a rescue.
    private var mayGoUntitled: Bool {
        let saved = savedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return saved.isEmpty || saved == storedName(for: "")
    }

    /// How long typing has to stop before the note is sent. The browser waits
    /// 900ms; this waits a little longer because a phone's save is a request
    /// over whatever network it has, not a same-host POST.
    private static let autosaveDelay: Duration = .milliseconds(1200)

    /// A create waits longer than a save does. A save is a correction to
    /// something that exists; a create names a document in the list and cannot
    /// be taken back by typing more, so a title still being typed — "Ballad",
    /// mid-way to "Ballad of the Lost Hour" — should not become one.
    private static let createDelay: Duration = .milliseconds(2500)

    /// Where an autosaving note has got to. Absent while nothing has been
    /// typed, so an untouched note carries no chrome at all.
    private enum SaveStatus: Equatable {
        case saving
        case saved
        /// The save couldn't get out, but the words are on disk on this
        /// device and the reconnect sweep will send them — leaving loses
        /// nothing. The screenplay's "held" state, in a note.
        case held
        /// The save was refused. Sticky: this is the one state the writer has
        /// to see, because it is the one where leaving loses something.
        case failed(String)
    }

    /// Whether leaving now would lose something. A brand-new document counts as
    /// changed the moment anything is typed into it — there is nothing on the
    /// server yet for it to match.
    private var hasUnsavedChanges: Bool {
        canEdit && !isLoading && (title != savedTitle || content != savedContent)
    }

    /// Whether going now would really lose the words, which is the only thing
    /// worth stopping a writer to ask about.
    ///
    /// Almost never, and that is the point of the change: what is on screen is
    /// saved, or a beat away from being saved by the parting flush — a
    /// document with nothing in its title field included, since that one saves
    /// itself under the list's own "Untitled …". What is left is the one case
    /// the flush cannot rescue: a save the server refused, where trying again
    /// on the way out is all leaving would achieve.
    private var leavingLosesWork: Bool { saveFailed }

    /// Notes get the list and heading controls; lyrics take the same keyboard
    /// rules but not the bar, which is the split the browser makes too.
    private var showsFormatBar: Bool { type != .song && canEdit }

    /// What the sheet calls itself. Settled on how it was opened rather than
    /// on whether the document exists yet: a create landing mid-sentence is not
    /// a reason for the screen the writer is looking at to rename itself.
    ///
    /// It does follow the one change that is the writer's own doing. A note up
    /// to be read is "Note"; tapping Edit makes it "Edit Note", which is the
    /// title saying what the sheet has just become rather than renaming itself
    /// behind anyone's back — and the same words a read-only note has always
    /// carried, since to a reader the two states look alike.
    private var navTitle: String {
        if document == nil { return type == .song ? "New Song" : "New Note" }
        return canEdit ? "Edit \(type.label)" : type.label
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                titleField
                Divider()
                editor
            }
            .overlay {
                if isLoading { ProgressView() }
            }
            .safeAreaBar(edge: .bottom, spacing: 0) { footer }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(isPresented: $showingIgnoredWords) {
                SpellcheckWordsView()
            }
            .task { await loadFullContentIfNeeded() }
            .onChange(of: title) { _, _ in scheduleAutosave() }
            .onChange(of: content) { _, _ in scheduleAutosave() }
            // A phone put down mid-sentence is backgrounded, and a backgrounded
            // app is one the system may end without asking. Don't wait out the
            // debounce for that. The sheet is still here, so this is the
            // ordinary save rather than the parting one below.
            .onChange(of: scenePhase) { _, phase in
                guard phase != .active else { return }
                autosave?.cancel()
                Task { await saveNow() }
            }
            // Covers every other way this sheet goes away: Done, the drag, and
            // the parent view deciding it is finished with it.
            .onDisappear {
                autosave?.cancel()
                flush()
            }
            // A sheet dragged away takes the note with it, and unlike a button
            // it gives no chance to say so. An autosaving note has nothing to
            // lose to the drag — it is already saved, or saving — so the drag
            // is only refused where the words really would go.
            .interactiveDismissDisabled(leavingLosesWork)
            .confirmationDialog(saveFailed ? "Discard unsaved changes?" : "Discard changes?",
                                isPresented: $confirmingDiscard,
                                titleVisibility: .visible) {
                Button("Discard", role: .destructive) {
                    // Before dismissing, or the parting save below would send
                    // the very words the writer just chose to throw away —
                    // and the held draft would push them on the next sweep.
                    discarding = true
                    if let target { model.discardDocumentDraft(for: target.id) }
                    dismiss()
                }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text(discardMessage)
            }
            .alert("Insert into Script", isPresented: insertMessageBinding) {
                Button("OK", role: .cancel) { insertMessage = nil }
            } message: {
                Text(insertMessage ?? "")
            }
        }
    }

    private var insertMessageBinding: Binding<Bool> {
        Binding(get: { insertMessage != nil },
                set: { if !$0 { insertMessage = nil } })
    }

    /// Whether the last save was refused and the words are still only here.
    private var saveFailed: Bool {
        if case .failed = saveStatus { return true }
        return false
    }

    /// Only ever asked over a refused save now — the sheet does not stop a
    /// writer for anything it can still put right itself. "Most recent edits"
    /// would be a kind way of putting it for a document that was never
    /// created: there is no earlier copy sitting safely on the server, there
    /// is nothing at all.
    private var discardMessage: String {
        isNew
            ? "This \(kindWord) has not reached the server, so it exists only on this device."
            : "The last save did not reach the server, so your most recent edits are only on this device."
    }

    // MARK: - Surfaces

    private var titleField: some View {
        TextField(type == .song ? "Song title" : "Note title", text: $title)
            .font(.title3.weight(.semibold))
            .textInputAutocapitalization(.words)
            .submitLabel(.next)
            .focused($titleFocused)
            // Return in the title means "on with it", not a line break — there
            // is nowhere else for the caret to go.
            .onSubmit { formatting.focus() }
            .disabled(!canEdit)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .accessibilityLabel("Title")
    }

    private var editor: some View {
        NoteTextView(text: $content,
                     controller: formatting,
                     isEditable: canEdit,
                     spellChecks: settings.isSpellcheckEnabled,
                     spellcheckRevision: SpellcheckDictionary.shared.revision,
                     textScale: settings.textScale,
                     placeholder: placeholder,
                     onFocusChange: { isWritingBody = $0 })
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(type == .song ? "Lyrics" : "Notes")
    }

    private var placeholder: String {
        if !canEdit { return "" }   // nothing to invite; this note is read-only
        return type == .song ? "Write the lyrics here…" : "Write your notes here…"
    }

    /// Under the note: what went wrong, whether it is saved, how long it is,
    /// and the formatting bar riding above the keyboard. Stacked in that order
    /// so the bar sits closest to the writer's thumbs and the readouts stay put
    /// above it.
    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 0) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
            saveStatusBar
            if settings.showsWordCount {
                WordCountBar(words: ScriptStats.countWords(content))
            }
            if showsFormatBar && isWritingBody {
                NoteFormatBar(controller: formatting)
            }
        }
    }

    /// Says where the note stands with the server, and — when that is nowhere —
    /// offers the one thing worth offering, which is to try again.
    @ViewBuilder
    private var saveStatusBar: some View {
        if let saveStatus {
            HStack(spacing: 6) {
                switch saveStatus {
                case .saving:
                    ProgressView().controlSize(.mini)
                    Text("Saving…").foregroundStyle(.secondary)
                case .saved:
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                    Text("Saved").foregroundStyle(.secondary)
                case .held:
                    Image(systemName: "icloud.slash")
                        .foregroundStyle(.orange)
                    Text("Kept on this device — saves when you're back online")
                        .foregroundStyle(.secondary)
                    Button("Retry") { Task { await saveNow() } }
                        .font(.footnote.weight(.medium))
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message).foregroundStyle(.primary)
                    Button("Retry") { Task { await saveNow() } }
                        .font(.footnote.weight(.medium))
                }
                Spacer(minLength: 0)
            }
            .font(.footnote)
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // An autosaving document is only ever left, never cancelled: there is
        // nothing to cancel back to, and no Save to pair a Cancel with. Leaving
        // is only asked about where it would really cost something.
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") {
                if leavingLosesWork {
                    confirmingDiscard = true
                } else {
                    dismiss()
                }
            }
        }
        // The way into writing, where Pages and Word both keep it. Beside Done
        // on the leading edge would put it under the thumb that just opened
        // the sheet; the trailing corner is where a document app has taught
        // everyone to look for Edit, and it is the only thing this sheet draws
        // there. Gone the moment it is used, since the sheet is then the
        // editor it has always been.
        if isDocumentEditable && isReadingView {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    beginEditing()
                } label: {
                    Label("Edit", systemImage: "square.and.pencil")
                }
            }
        }
        // The list's context-menu action, reachable without leaving the
        // editor. Same gate — the server advertised an `insert` link on this
        // document — and the same landing: the end of the script, a song as
        // Lyrics blocks, a note as Note blocks. A document created by this
        // sheet a moment ago has that link too, so a song written here can go
        // straight into the script without being reopened.
        if let target, target.hasLink(.insert) {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    insert(target)
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
        // The way back, in the "…" where Pages keeps its own Reading View
        // item. Without it the remembered choice could only ever travel one
        // way — every document a writer had tapped Edit in would stay an
        // editor for good, with nothing to say "this one I only read".
        if isDocumentEditable && !isReadingView && !isNew {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    enterReadingView()
                } label: {
                    Label("Reading View", systemImage: "book")
                }
            }
        }
        // Only where there is typing to check. Reached from here rather than
        // from a screenplay's View menu, which is where the only copy of these
        // controls used to live — a writer working in a note had no way to
        // reach them at all.
        if canEdit {
            ToolbarItem(placement: .secondaryAction) {
                SpellingMenu(showingIgnoredWords: $showingIgnoredWords)
            }
        }
        // The same device-wide type size the lyric and screenplay editors set.
        // Notes already read it; until now nothing on this screen could change
        // it, so a writer who had sized the script up found their notes still
        // at 100%.
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

    private var wordCountBinding: Binding<Bool> {
        Binding(get: { settings.showsWordCount }, set: { settings.showsWordCount = $0 })
    }

    // MARK: - Reading view

    /// Hands the document to the writer, and remembers that this is one they
    /// write in — so the Edit button is a cost paid once per document rather
    /// than on every visit.
    private func beginEditing() {
        isReadingView = false
        guard let target else { return }
        readingViews.remember(false, for: .document(id: target.id))
    }

    /// Puts it back up to be read, and remembers that too.
    ///
    /// The save goes first and the mode follows it, rather than the other way
    /// round: `saveNow` is guarded on `canEdit`, so a flag flipped ahead of the
    /// send would silently make the send a no-op and leave the last sentence
    /// typed sitting in a text view nobody is going to look at again.
    private func enterReadingView() {
        autosave?.cancel()
        Task {
            await saveNow()
            isReadingView = true
            guard let target else { return }
            readingViews.remember(true, for: .document(id: target.id))
        }
    }

    // MARK: - Actions

    /// The list only has a preview, so pull the full document once on open.
    private func loadFullContentIfNeeded() async {
        guard let document else {
            // A new one opens with the caret in the title, which is the only
            // field that has to be filled in for it to be saveable.
            titleFocused = canEdit
            return
        }
        guard !didLoad else { return }
        didLoad = true
        isLoading = true
        defer { isLoading = false }
        let full = await model.fetchDocument(document)
        if let full {
            title = full.title ?? title
            content = full.content ?? ""
        }
        // Whatever landed is the baseline for "has anything been typed" —
        // including a load that failed and left the list row's preview. But
        // only a real fetch makes it *base evidence* for held drafts; see
        // `haveServerBaseline`.
        savedTitle = title
        savedContent = content
        haveServerBaseline = full != nil
        // Two things the opening decision could not know until the document
        // was in hand, both of which mean this one belongs to the writer.
        //
        // Words this device is still holding are writing in progress that has
        // not reached the server — and `adoptHeldDraft` below is itself
        // guarded on `canEdit`, so leaving the sheet in reading view would put
        // the server's older copy on screen and quietly leave the writer's own
        // paragraph out of sight.
        //
        // An empty document is nothing to read: a blank sheet with no caret
        // and no placeholder, waiting to be tapped past.
        if model.heldDocumentDraft(for: document) != nil || content.isEmpty {
            isReadingView = false
        }
        adoptHeldDraft(for: document, sawServerCopy: full != nil)
    }

    /// Words a previous run couldn't send take the screen back — unless the
    /// note moved on elsewhere in the meantime, in which case the server is
    /// last-write-wins and the draft is set aside, never silently.
    private func adoptHeldDraft(for document: TextDocument, sawServerCopy: Bool) {
        guard canEdit, let draft = model.heldDocumentDraft(for: document) else { return }
        guard sawServerCopy else {
            // No server copy to judge staleness against — the list row's
            // preview is truncated and would fail the comparison falsely.
            // Adopt; the reconnect sweep re-checks with the real thing.
            title = draft.title
            content = draft.content
            saveStatus = .held
            return
        }
        if draft.title == savedTitle && draft.content == savedContent {
            // Finished business — the server already says this.
            model.discardDocumentDraft(for: document.id)
            return
        }
        let baseMatches = (draft.baseContent == nil && draft.baseTitle == nil)
            || (draft.baseContent == savedContent && (draft.baseTitle ?? savedTitle) == savedTitle)
        guard baseMatches else {
            model.discardDocumentDraft(for: document.id)
            errorMessage = "An offline edit was set aside — this "
                + (type == .song ? "song" : "note") + " changed elsewhere."
            return
        }
        title = draft.title
        content = draft.content
        saveStatus = .held
        // The ordinary machinery takes it from here: the debounce fires, the
        // save lands or holds again.
        scheduleAutosave()
    }

    // MARK: - Autosave

    /// Arms the debounce. The load above writes into the same two fields, so
    /// this checks that the note has really diverged rather than trusting that
    /// a change came from the keyboard.
    private func scheduleAutosave() {
        guard canEdit, !isLoading, hasUnsavedChanges else { return }
        // Said from the first keystroke rather than when the request leaves:
        // what the writer needs to know is that the words are on their way, and
        // a readout that still says "Saved" over unsent text is the one thing
        // this bar must never do.
        saveStatus = .saving
        let delay = isNew ? Self.createDelay : Self.autosaveDelay
        autosave?.cancel()
        autosave = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await saveNow()
        }
    }

    /// Sends what is on screen and says so.
    ///
    /// A save landing while more is being typed is the ordinary case, so what
    /// went is remembered and compared against what is there afterwards — if
    /// the note moved on in the meantime, another save is armed rather than the
    /// newer words being marked as saved.
    private func saveNow() async {
        guard canEdit, !isSaving else { return }
        // Typed back to what the server already holds — there is nothing to
        // send, but the bar has been saying "Saving…" since the keystroke that
        // got it there. A new document typed into and then emptied again holds
        // nothing anywhere, and must not be told it is saved: the bar goes back
        // to saying nothing, which is what an untouched sheet says.
        guard hasUnsavedChanges else {
            if saveStatus == .saving { saveStatus = isNew ? nil : .saved }
            return
        }
        // The server requires a title and the list needs something to draw, so
        // a document with nothing in the field goes under the name the list
        // already draws for it. The one refusal left is the writer deleting a
        // name it *had* — see `mayGoUntitled`.
        guard !trimmedTitle.isEmpty || mayGoUntitled else {
            saveStatus = .failed("Add a title to save this \(kindWord).")
            return
        }
        guard let document = target else {
            await createNow()
            return
        }
        let sentTitle = title
        let sentContent = content
        isSaving = true
        saveStatus = .saving
        let outcome = await model.saveDocumentOutcome(
            document, title: storedName(for: title), content: sentContent,
            // What the server holds, which for a document saved without a name
            // is the borrowed one — not the empty field that stands in for it
            // here. A base of "" against a server saying "Untitled Notes" is a
            // held draft the reconnect sweep would set aside as stale.
            baseTitle: haveServerBaseline ? storedName(for: savedTitle) : nil,
            baseContent: haveServerBaseline ? savedContent : nil)
        isSaving = false
        switch outcome {
        case .saved:
            savedTitle = sentTitle
            savedContent = sentContent
            // The server just accepted these words, which makes them as good
            // a baseline as a fetch.
            haveServerBaseline = true
            saveStatus = .saved
            errorMessage = nil
            // Typed into while that was in flight: those words have not been
            // sent.
            if hasUnsavedChanges { scheduleAutosave() }
        case .held:
            // On disk, retried by the reconnect sweep: not saved, not lost.
            saveStatus = .held
        case .failed:
            saveStatus = .failed(model.errorMessage ?? "Not saved.")
        }
    }

    /// The first save of a new document, which has to make it before it can
    /// write to it. From here on this sheet is an ordinary editor: `target`
    /// answers with what came back, and every save after this one is the PUT
    /// above.
    ///
    /// A create that cannot get out is not held the way a save is — there is no
    /// document on the server for a draft to be measured against, so nothing
    /// goes to the drafts store and no sweep will pick it up. It reads as a
    /// failure because that is what it is: the words are only here. Typing on
    /// re-arms the debounce, so the create that could not go out at the kitchen
    /// table goes out when the train reaches the station.
    private func createNow() async {
        let sentTitle = title
        let sentContent = content
        let createdTitle = storedName(for: title)
        let model = model
        let type = type
        isSaving = true
        isCreating = true
        saveStatus = .saving
        // On a task of its own, and deliberately so. Everything that reaches
        // here arrives on the debounce task, which the next keystroke cancels
        // and the sheet's dismissal cancels — and a cancelled POST is the one
        // failure this editor cannot climb out of, because the server may have
        // made the document anyway and the retry would make a second one. A
        // PUT can be abandoned and repeated; a create is asked exactly once.
        let outcome = await Task { @MainActor in
            await model.createDocumentOutcome(title: createdTitle, content: sentContent, type: type)
        }.value
        isSaving = false
        isCreating = false
        switch outcome {
        case .created(let document):
            created = document
            savedTitle = sentTitle
            savedContent = sentContent
            // The server has just told us what it holds, which is as good a
            // baseline as a fetch — and the one a held draft would be judged
            // against if the next save cannot get out.
            haveServerBaseline = true
            saveStatus = .saved
            errorMessage = nil
            // Typed into while the create was in flight: those words are not on
            // the server yet, and now there is a document to send them to.
            if hasUnsavedChanges { scheduleAutosave() }
        case .unreachable:
            saveStatus = .failed("Not saved — couldn't reach the server.")
        case .failed:
            saveStatus = .failed(model.errorMessage ?? "Not saved.")
        }
    }

    /// Sends whatever is unsent without waiting out the debounce, on a task
    /// that belongs to the model rather than to this view — a sheet on its way
    /// out takes its own tasks with it, and this is exactly the moment the
    /// last paragraph would be lost.
    ///
    /// Also where the lists left alone during the session are brought back into
    /// step, since every save until now deliberately skipped them.
    ///
    /// A new document dismissed inside the create debounce is created here, not
    /// abandoned. Done is now the ordinary way out of a song written in one
    /// sitting, and it must not be a way to throw it away by being quick.
    private func flush() {
        guard canEdit else { return }
        let dirty = hasUnsavedChanges && (!trimmedTitle.isEmpty || mayGoUntitled)
            && !discarding
        guard dirty || saveStatus != nil else { return }
        let sentTitle = storedName(for: title)
        let sentContent = content
        let baseTitle = haveServerBaseline ? storedName(for: savedTitle) : nil
        let baseContent = haveServerBaseline ? savedContent : nil
        let type = type
        let model = model
        let target = target
        let alreadyCreating = isCreating
        Task { @MainActor in
            if dirty {
                if let target {
                    // The outcome path holds the words on failure, so a sheet
                    // dismissed on a train still delivers its last paragraph on
                    // the next reconnect sweep.
                    await model.saveDocumentOutcome(target, title: sentTitle, content: sentContent,
                                                    baseTitle: baseTitle, baseContent: baseContent)
                } else if !alreadyCreating {
                    // Nothing was ever created, so there is nothing to hold
                    // this against: it lands or it doesn't. It having reached
                    // here at all means the writer was not asked, which means
                    // there is a title — the untitled case never dismisses
                    // without the discard prompt. And only if the debounce did
                    // not get there first: that create outlives this sheet, so
                    // a second one here would be a second document.
                    await model.createDocument(title: sentTitle, content: sentContent, type: type)
                }
            }
            await model.refreshAfterDocumentEdit()
        }
    }

    /// Sends the document into the screenplay as blocks, at the end of the
    /// script — the same call the list's context menu makes. The words on
    /// screen are saved first, so what lands is what the writer is looking at;
    /// a save the server refuses stops the insert rather than quietly sending
    /// the server's older copy. A document that landed dismisses down to the
    /// screenplay it just changed.
    private func insert(_ document: TextDocument) {
        isInserting = true
        Task {
            autosave?.cancel()
            await saveNow()
            if case .failed(let reason) = saveStatus {
                isInserting = false
                insertMessage = "\(reason) Nothing was inserted."
                return
            }
            let count = await model.insertDocument(document)
            isInserting = false
            if let count, count > 0 {
                dismiss()
                onInserted?()
            } else if count == 0 {
                insertMessage = "Nothing to insert from \"\(document.displayTitle)\"."
            } else {
                insertMessage = model.errorMessage
                    ?? "Could not insert into the script."
            }
        }
    }
}
