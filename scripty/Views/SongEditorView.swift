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
//  What it says about all that is what a song says: the cloud in the corner,
//  the same badge the lyric editor and the screenplay wear, in the same place.
//  The running commentary this sheet used to keep under the note — "Saving…",
//  "Saved", a Retry button — was a second vocabulary for a question every other
//  writing surface in the app already answers with one glyph, and it was the
//  loudest of the three about the state that matters least. A save that cannot
//  get out now retries itself on the screenplay's backoff instead of asking to
//  be pressed, and the connection coming back sends it at once.
//
//  So this sheet stops the writer over exactly one thing, and it is the one
//  case where leaving really does lose the words: a document that has never
//  reached the server at all. A save refused on a document that exists is on
//  disk and in the reconnect sweep — the badge goes red and nothing else
//  happens, exactly as a refused lyric line behaves.
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
    /// The word count, worked out only when the words change. Held rather than
    /// computed because `body` reruns on every keystroke — see `WordCountMemo`
    /// for why a class in `@State` may be written from there.
    @State private var wordCounter = WordCountMemo()
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
    /// The whole document, once it has been fetched — what this sheet was
    /// handed is the list row, which carries a truncated preview and none of
    /// the state that only the full resource reports. Kept rather than read for
    /// its words and dropped, because the archived stamp arrives on it and
    /// nothing else on screen would know.
    @State private var loaded: TextDocument?
    /// A trip back from the archive in flight.
    @State private var isUnarchiving = false
    @State private var errorMessage: String?
    /// What the writer is told about the saving of an existing note. Nil until
    /// something has been typed, so a note opened and not touched says nothing.
    @State private var saveStatus: SaveStatus?
    /// The armed debounce. Cancelled and replaced on every keystroke, which is
    /// what makes this a save a second after typing stops rather than one per
    /// character — the same shape `SongBlockModel` gives a lyric line.
    @State private var autosave: Task<Void, Never>?
    /// The armed retry of a save that couldn't get out, and how many have gone
    /// already. A lyric line has retried itself on a backoff for as long as
    /// there has been a badge to explain it; with the Retry button gone from
    /// under the note, this is what takes its place.
    @State private var retry: Task<Void, Never>?
    @State private var retryAttempt = 0
    /// When this document was last known to be in step with the server, for
    /// the badge's detail panel — the same thing the lyric editor's badge
    /// reports. Nil until the first save of this sitting lands: "last synced"
    /// on a document opened and not typed into would be a claim about a
    /// request nobody made.
    @State private var lastSyncedAt: Date?
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
    /// iOS, and the mode the screenplay calls Read Script.
    ///
    /// One flag, as the screenplay has one. This sheet used to keep two: a
    /// remembered "reading view" that left the writing surface on screen with
    /// the caret taken out of it, and — for songs only — a separate, forgotten
    /// Read Song that swapped in the reader. Two names for one posture, and
    /// the one that was remembered was the one that did the least: a note
    /// opened for reading was a text view nobody could type in. Reading means
    /// the reading surface here now, for both kinds, and the writing surface
    /// left inert is what the lock is for.
    ///
    /// State rather than a constant because the sheet leaves the mode two
    /// ways: the writer tapping Edit, and the load finding an empty document,
    /// which is nothing to read and so belongs to the writer.
    @State private var isReading: Bool
    /// Whether this document is closed to typing. Per document, kept on the
    /// device — see `DocumentViewOptions`, which the lyric editor shares.
    ///
    /// Optional because a document that has never reached the server has no id
    /// to file a lock under, and nothing to lock either: it is being written
    /// this minute. The one this sheet creates gets its options the moment the
    /// create lands, so a song typed here can be locked without reopening it.
    @State private var options: DocumentViewOptions?
    /// The formatting bar's handle on the text view, and the document's own
    /// undo history — the title's as well as the words', since a writer given
    /// one document has one ⌘Z. Seeded with whatever the sheet opens showing —
    /// see `NoteHistory`.
    @State private var formatting: NoteEditorController
    @FocusState private var titleFocused: Bool
    @State private var showingIgnoredWords = false
    /// Whether the two-versions screen is up. Opened by a press only — the
    /// banner and the badge both offer it, and neither takes the words away
    /// without being asked.
    @State private var showingConflicts = false

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

    /// When the copy on screen was saved to this device, or nil where these are
    /// the server's own words. The lyric editor has said this in a strip above
    /// the lines for as long as it has read offline; a note is fetched the same
    /// way and was the one document surface that showed a stale copy silently.
    @State private var offlineCopySavedAt: Date?
    /// Whether the offline strip has been closed for the copy currently shown.
    private let notices = DismissedNotices.shared

    /// The device's voice, shared with the screenplay behind this sheet and
    /// with the lyric editor — see `ScriptNarrator`.
    private let narrator = ScriptNarrator.shared

    private let settings = PresentationSettings.shared

    /// The OS text-size setting as a multiplier, folded into the title's own
    /// scale the way `ReadSongView` folds it into the reader's. The words below
    /// already honour it — `NoteTextView` sizes its type through
    /// `UIFontMetrics` — so a title that ignored it would be the one line on
    /// the sheet that did.
    @ScaledMetric(relativeTo: .body) private var dynamicTypeScale: CGFloat = 1

    private var titleScale: CGFloat { CGFloat(settings.textScale) * dynamicTypeScale }

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
        _formatting = State(initialValue: NoteEditorController(title: title,
                                                              text: content))
        // A document being written for the first time is never opened to be
        // read: there is nothing in it yet, and the writer asked for a blank
        // one. Everything else opens the way it was last left, or the way the
        // "Open in Edit View" switch says if it has never been put either way.
        _isReading = State(initialValue: document.map {
            ReadingViewSettings.shared.opensInReadingView(.document(id: $0.id))
        } ?? false)
        _options = State(initialValue: document.map {
            DocumentViewOptions(documentId: $0.id, kind: Self.lockKind(for: type))
        })
    }

    /// Whether documents open to be read, and which way this one was last put.
    private let readingViews = ReadingViewSettings.shared

    /// The document being written: the one this sheet was opened on, or the one
    /// its first save created. Nil only while a new document has yet to land.
    /// The document this sheet is acting on, in order of how much is known
    /// about it: the fetched resource, then the row it opened with, then the
    /// one its own first save made.
    private var target: TextDocument? { loaded ?? document ?? created }

    private var isNew: Bool { target == nil }

    /// Whether the server left this document open to be changed at all. The
    /// standing permission, as against `canEdit` below, which is that *and*
    /// the writer having asked for the keyboard.
    private var isDocumentEditable: Bool { document?.hasLink(.update) ?? true }

    /// Whether the words on screen can be typed into right now. Every save
    /// path in this sheet already guards on it, which is what makes reading and
    /// the lock inert here rather than merely quiet: nothing autosaves, nothing
    /// is flushed on the way out, and nothing is counted as unsaved, because
    /// nothing can have changed.
    private var canEdit: Bool { isDocumentEditable && !isReading && !isLocked }

    /// Whether this device has closed the document to typing. A choice about
    /// this phone, as against `isDocumentEditable`, which is what the server
    /// allows — a locked document is still one the writer may unlock, which is
    /// why the switch stays offered while it is on.
    private var isLocked: Bool { options?.isEditingLocked ?? false }

    /// The double-tap way in, for both of the things that can stand between a
    /// writer and the words: the reading surface the document opened on, and
    /// the lock. Whatever is in the way comes off — a locked note opened to be
    /// read is one gesture away from the keyboard, not two — which is why this
    /// is one closure rather than one per posture.
    ///
    /// Nil where nothing is in the way, or where the server never offered this
    /// document to be written in: the words are already taking a caret, or no
    /// lock of this device's would give them one. The reader and the text view
    /// both take it, so the gesture means the same thing on either surface.
    private var startWriting: (() -> Void)? {
        guard isDocumentEditable, isReading || isLocked else { return nil }
        return {
            options?.setEditingLocked(false)
            if isReading { beginEditing() }
        }
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The word for what is being written, for the sentences that need it.
    private var kindWord: String { type == .song ? "song" : "note" }

    /// The versions of *this* document waiting to be chosen between. The
    /// script's own banner counts every conflict in the project; a sheet over
    /// one note has no business speaking for the others.
    ///
    /// Filed under the document this sheet is editing — which for a document
    /// created here is the one that landed, not the nil it opened with.
    private var conflicts: [SyncConflict] {
        guard let id = (created ?? document)?.id else { return [] }
        return model.conflicts(forDocument: id)
    }

    /// Two versions of this note exist and only the writer can settle it.
    @ViewBuilder
    private var conflictBanner: some View {
        if !conflicts.isEmpty {
            ConflictBanner(count: conflicts.count) { showingConflicts = true }
        }
    }

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

    /// The screenplay's backoff, unchanged, and a lyric line's: past the last
    /// delay the words stay held and the next keystroke — or the connection
    /// coming back — re-arms it.
    private static let retryDelays: [Duration] =
        [.seconds(2), .seconds(5), .seconds(15), .seconds(30), .seconds(60)]

    /// Where an autosaving note has got to. Absent while nothing has been
    /// typed: an untouched sheet is showing the server's own copy, which the
    /// badge reads as saved.
    private enum SaveStatus: Equatable {
        case saving
        case saved
        /// The save couldn't get out, but the words are on disk on this
        /// device and the reconnect sweep will send them — leaving loses
        /// nothing. The screenplay's "held" state, in a note.
        case held
        /// The save was refused, with the reason. For a document that exists
        /// the words are still on disk and the sweep still has them, so this
        /// is a red badge and a line of explanation, nothing more. For one
        /// that was never created it is the only warning there is: see
        /// `leavingLosesWork`.
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
    /// One case, and it is the case a song cannot have: a document that was
    /// never created. Everything else on this screen is somewhere other than
    /// this view — saved, a beat away from the parting flush, or held on disk
    /// with the reconnect sweep carrying it, which is true of a refused save
    /// too. A create has none of that. There is no row on the server for a
    /// draft to be measured against, so nothing goes to the drafts store and
    /// no sweep will pick it up; the words are here and nowhere else, and
    /// dismissing is the one gesture that ends them.
    private var leavingLosesWork: Bool { isNew && saveFailed }

    /// Both kinds get the bar, because both get undo — which on a device with
    /// no hardware keyboard has no other route here, and which a writer needs
    /// as much in a verse as in a note. Only the *structure* half is a note's:
    /// lyrics take the same keyboard rules but have no bullets and no headings,
    /// which is the split the browser makes too.
    private var showsFormatBar: Bool { canEdit }
    private var showsFormatStructure: Bool { type != .song }

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
                // Reading takes the whole sheet, title field included: the
                // reader sets the title itself, in the face the rest of the
                // page is in.
                if isReading {
                    reader
                } else {
                    titleField
                    // No rule under the name. The reading surface draws none,
                    // and a line across the sheet that appears the moment Edit
                    // is tapped is one more thing that changes with the mode —
                    // the gap the title's own padding leaves is separation
                    // enough, as it is in the lyric editor.
                    editor
                }
            }
            .overlay {
                if isLoading { ProgressView() }
            }
            // Above the words, where the lyric editor keeps its own: a locked
            // note looks exactly like an unlocked one, so a tap that does
            // nothing needs something on screen to say why — and an old copy
            // of the words looks exactly like a current one.
            //
            // Outermost first, widening to narrowest: being archived is where
            // this note stands, the lock is what this session may do to it, and
            // the last two are about the words on screen right now — a second
            // version waiting to be chosen between, and how old this copy is.
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    archivedBanner
                    lockBanner
                    conflictBanner
                    offlineCopyBanner
                }
            }
            // A fresh copy is a new situation, so whatever was closed about the
            // old one stops applying and the strip is free to speak again.
            .onChange(of: offlineCopyState) { _, _ in
                notices.situationChanged(offlineCopyKey)
            }
            .safeAreaBar(edge: .bottom, spacing: 0) { footer }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(isPresented: $showingIgnoredWords) {
                SpellcheckWordsView()
            }
            .sheet(isPresented: $showingConflicts) {
                SyncConflictsView(conflicts: conflicts,
                                  keepMine: { await model.keepMine($0) },
                                  keepTheirs: { model.keepTheirs($0) },
                                  noun: kindWord)
            }
            // ⌘Z belongs to the words in here, not to the script this sheet
            // covers — see `DocumentEditorActions`, and `NoteHistory` for why
            // this document's own history is the only thing it could sensibly
            // mean.
            .focusedSceneValue(\.documentEditorActions, undoActions)
            // Before the load below, which is the first thing that may want to
            // put a name back.
            .onAppear { formatting.restoreTitle = restoreTitle }
            .task { await loadFullContentIfNeeded() }
            // The name is part of the document, so it is part of its history:
            // a new song opens with the caret here, and everything typed into
            // it before the first line of the lyric would otherwise be the one
            // writing on this screen that could not be taken back.
            .onChange(of: title) { _, new in
                formatting.captureTitle(new)
                scheduleAutosave()
            }
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
            // The connection came back: send what is held right now rather
            // than waiting out the backoff, the same edge the lyric editor and
            // the screenplay both take. This is also what turns an amber badge
            // green without the writer touching anything — and what gets a
            // document written offline created the moment there is a route.
            .onChange(of: model.app.connectivity.isOnline) { _, online in
                guard online, saveStatus == .held || saveFailed else { return }
                retry?.cancel()
                retryAttempt = 0
                Task { await saveNow() }
            }
            // Covers every other way this editor goes away: Done, an insert
            // that landed, and the parent view deciding it is finished with it.
            .onDisappear {
                autosave?.cancel()
                retry?.cancel()
                flush()
                // Closing the document ends its reading: this sheet is the only
                // place its transport is drawn, and a voice left reading a note
                // nobody can see is a reading with no way to stop it.
                if isBeingRead { narrator.stop() }
            }
            // A sheet dragged away takes the note with it, and unlike a button
            // it gives no chance to say so. An autosaving note has nothing to
            // lose to the drag — it is already saved, saving, or held — so the
            // drag is only refused where the words really would go.
            // Presented as a full-screen cover now, which has no drag to
            // refuse; kept because the same view is still put up as a sheet
            // from the script, where the drag is real and would take the words
            // with it.
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

    /// The menu bar's Undo and Redo while this sheet is up: the text view's own
    /// history, the same one the bar's two buttons drive. A document that
    /// cannot be typed into offers neither, but still claims the pair — falling
    /// through to the script behind would be worse than doing nothing.
    /// Read Aloud rides along on the same value, and unlike the pair it is
    /// offered whatever posture the document is in: a note up to be read is
    /// exactly the one somebody wants read to them, and without it ⌘⇧A would
    /// reach past this sheet and start the screenplay behind it reading itself.
    private var undoActions: DocumentEditorActions {
        let readAloud: (() -> Void)? = hasWordsToSpeak ? { toggleReadAloud() } : nil
        guard canEdit else { return DocumentEditorActions(readAloud: readAloud) }
        return DocumentEditorActions(undo: { formatting.undo() },
                                     redo: { formatting.redo() },
                                     canUndo: formatting.canUndo,
                                     canRedo: formatting.canRedo,
                                     readAloud: readAloud)
    }

    /// What a step out of the history does to the title field: puts the name
    /// back, and takes the caret with it when that name is what the step was.
    ///
    /// The caret half matters in both directions. A rename undone with the
    /// caret left in the lyric is a change the writer watches happen somewhere
    /// they are not looking; and a step through the words while the title still
    /// holds SwiftUI's focus would have the field claim the keyboard straight
    /// back from the text view the coordinator just handed it to.
    private var restoreTitle: (String, Bool) -> Void {
        { name, takeFocus in
            title = name
            titleFocused = takeFocus
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

    /// Only ever asked over a document that was never created — the sheet does
    /// not stop a writer for anything it can still put right itself. "Your most
    /// recent edits" would be a kind way of putting it here: there is no
    /// earlier copy sitting safely on the server, there is nothing at all.
    private var discardMessage: String {
        "This \(kindWord) has not reached the server, so it exists only on this device."
    }

    /// Where the words on this screen currently live — the same standing answer
    /// the lyric editor and the screenplay give, in the same corner. Nil in
    /// demo, where there is no cloud to be honest about.
    ///
    /// Offline outranks refused, as it does in the lyric editor: with no route
    /// at all, "couldn't save" is a diagnosis the app has not earned.
    ///
    /// A save merely *pending* — the debounce armed, or the PUT in flight — is
    /// not "holding". The lyric editor's badge stays green through typing and
    /// only colours when a write has actually failed to get out, and a badge
    /// that went amber every time a writer paused for a second would be a badge
    /// nobody reads by the end of the first page.
    ///
    /// The exception is a document that has never been created: there the
    /// earlier words are not safe on the server either, because there is no
    /// server copy at all, and a green tick would be the one lie this badge
    /// must never tell.
    private var cloudState: CloudSyncState? {
        guard !model.app.isDemo else { return nil }
        // Ahead of every other state, as everywhere else: the rest pass by
        // themselves and this one is waiting on the person reading it.
        if !conflicts.isEmpty { return .conflicted }
        if !model.app.connectivity.isOnline { return .offline }
        switch saveStatus {
        case .failed: return .failed
        case .held: return .holding
        case .saving: return isNew ? .holding : .synced
        case .saved, .none: return .synced
        }
    }

    /// What the badge says aloud, where this sheet knows something its default
    /// sentence doesn't. A document that was never created is not "kept on this
    /// device and syncing later": nothing is keeping it but this screen, and a
    /// spoken label that implies otherwise is the one that would cost a writer
    /// their words.
    private var cloudLabel: String? {
        guard isNew, saveStatus != nil, saveStatus != .saved else { return nil }
        switch cloudState {
        case .offline:
            return "Offline. This \(kindWord) has not been created yet — keep this editor open until you're back online."
        case .failed:
            return "This \(kindWord) could not be created, so it exists only on this device."
        default:
            return nil
        }
    }

    // MARK: - Surfaces

    /// The name, at the head of the sheet — set the way the reader sets it, so
    /// a song read and then written in is headed by the same words in the same
    /// face in the same place. It was a smaller sans-serif field before, which
    /// made the title the one thing on the page that changed when the mode did.
    ///
    /// Still a field rather than a heading with a rename behind it: this sheet
    /// has always saved the name as it is typed, and there was never a reason
    /// to make the writer ask for the caret it already had.
    private var titleField: some View {
        TextField(type == .song ? "Song title" : "Note title", text: $title)
            .font(DocumentTitleType.font(scale: titleScale))
            .textInputAutocapitalization(.words)
            .submitLabel(.next)
            .focused($titleFocused)
            // Return in the title means "on with it", not a line break — there
            // is nowhere else for the caret to go.
            .onSubmit { formatting.focus() }
            .disabled(!canEdit)
            // The reader's own margins, so the name is in the same place in
            // both modes — and so the words under it start where the reading
            // surface starts them.
            .padding(.horizontal, ProseColumn.horizontalPadding)
            .padding(.top, ProseColumn.titleTopPadding)
            .padding(.bottom, ProseColumn.titleBottomPadding)
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
                     // Two taps in the words are the same instruction as Edit
                     // in the corner, the way they are in Pages and Word — and
                     // the caret lands where the finger did rather than at the
                     // top. Offered only where Edit itself is: a document the
                     // server sent read-only has nowhere for this to go.
                     startWriting: startWriting,
                     onFocusChange: { isWritingBody = $0 })
            // The reader's margins, and no top padding of its own: the gap
            // above the first line is the title's bottom padding on both
            // surfaces, so the words start at the same height either way.
            .padding(.horizontal, ProseColumn.horizontalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(type == .song ? "Lyrics" : "Notes")
    }

    /// The reading surface, in place of the title and the writing: a song set
    /// as verse, a note set as prose. Reads the text on screen rather than the
    /// last saved copy, so a verse typed a moment ago is there to be read
    /// whether or not its save has landed.
    @ViewBuilder
    private var reader: some View {
        if type == .song {
            ReadSongView(title: trimmedTitle,
                         lines: content.components(separatedBy: .newlines),
                         textScale: settings.textScale,
                         onEdit: startWriting)
        } else {
            ReadNoteView(title: trimmedTitle,
                         text: content,
                         textScale: settings.textScale,
                         onEdit: startWriting)
        }
    }

    /// Which copy the strip is reporting, or nil when the words on screen came
    /// from the server. The date is the situation: a newer stale copy is a
    /// different thing to be told, so it is told even if the last one was
    /// closed.
    private var offlineCopyState: String? {
        offlineCopySavedAt.map(DismissedNotices.offlineCopyState(savedAt:))
    }

    private var offlineCopyKey: String {
        DismissedNotices.documentCopyKey(documentId: target?.id ?? 0)
    }

    /// Says the words on screen are the copy saved on this device, and how old
    /// they are — the lyric editor's strip, in a note, down to the ✕. Only when
    /// the fallback actually happened, not merely because the radio is off.
    @ViewBuilder
    private var offlineCopyBanner: some View {
        let isClosed = offlineCopyState.map { notices.isDismissed(offlineCopyKey, state: $0) } ?? true
        if let savedAt = offlineCopySavedAt, !isClosed {
            HStack(spacing: 6) {
                Image(systemName: "wifi.slash")
                    .font(.caption)
                Text("Offline — \(kindWord) saved "
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
            .accessibilityLabel("Offline. Showing the \(kindWord) saved on this device "
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

    /// Says the document is closed to typing, and unlocks it when tapped. Not
    /// while it is being read: the reader takes no keystrokes either, and a
    /// strip explaining why a surface that has no caret has no caret would be
    /// the app talking to itself.
    @ViewBuilder
    private var lockBanner: some View {
        if isLocked && !isReading {
            EditingLockBanner { options?.setEditingLocked(false) }
        }
    }

    /// Says this document is in the archive, and offers the way back.
    ///
    /// Shown while reading as well as while writing, unlike the lock strip: the
    /// lock explains a keyboard that will not come, which a reader is not
    /// waiting for, but *where a document lives* is as worth knowing to someone
    /// reading it as to someone typing into it — and reading is how an archived
    /// document opens.
    ///
    /// Reads the archived stamp from the loaded document rather than from
    /// `document`, which is the summary row this sheet was handed: the list
    /// never carries the stamp, and the row that opened this came from the
    /// archive sheet, which is a different resource again.
    @ViewBuilder
    private var archivedBanner: some View {
        if let target, target.isArchived {
            ArchivedBanner(
                kind: type,
                unarchive: target.hasLink(.unarchive) ? { unarchive(target) } : nil,
                isWorking: isUnarchiving)
        }
    }

    /// Brings this document back, and says so by dropping the strip: the
    /// reloaded document has no archived stamp and no `unarchive` link.
    ///
    /// The sheet deliberately stays open. Unarchiving is not leaving — a writer
    /// who reached for it while reading a lyric is most likely about to work on
    /// it, and closing the editor under them would take that away.
    private func unarchive(_ document: TextDocument) {
        guard !isUnarchiving else { return }
        isUnarchiving = true
        Task {
            defer { isUnarchiving = false }
            guard await model.unarchiveDocument(document) else {
                errorMessage = model.errorMessage
                    ?? "Could not bring \"\(document.displayTitle)\" back."
                return
            }
            // Re-read so the strip, and the links behind every other control in
            // this toolbar, come from the document as it is now — the list it
            // just rejoined is where the settled version of it is.
            if let fresh = model.documents.first(where: { $0.id == document.id }) {
                loaded = fresh
            }
        }
    }

    /// Whether there is anything here to read. A document with no words in it
    /// is nothing to open a reader on — the same test the screenplay's Read
    /// Script toggle makes against the script having elements — and neither is
    /// one that has yet to reach the server, since there would be nothing to
    /// remember the choice against. `isNew` rather than `document`: a song
    /// written in this sheet and created a moment ago is a document like any
    /// other, and should not have to be reopened to be read.
    private var hasSomethingToRead: Bool {
        !isNew && !content.isEmpty
    }

    private var placeholder: String {
        if !canEdit { return "" }   // nothing to invite; this note is read-only
        return type == .song ? "Write the lyrics here…" : "Write your notes here…"
    }

    /// Under the note: what went wrong, how long it is, and the formatting bar
    /// riding above the keyboard. Stacked in that order so the bar sits closest
    /// to the writer's thumbs and the readouts stay put above it.
    ///
    /// Where the note stands with the server is the badge's job now, not this
    /// bar's. What is left here is the half a glyph cannot carry: *why* the
    /// server refused, and a held edit set aside because the note moved on
    /// elsewhere. Both are rare, both are things a writer has to be told in
    /// words, and neither of them says "Saved".
    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 0) {
            if let notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
            if settings.showsWordCount {
                // Memoized: `content` is bound to the text view, so this whole
                // body reruns per character and the count was re-splitting the
                // entire note every time.
                WordCountBar(words: wordCounter.words(in: content))
            }
            // Under the readouts and above the formatting bar: the transport is
            // what a listener reaches for, and the formatting bar belongs to the
            // keyboard it rides over.
            narrationBar
            if showsFormatBar && isTyping {
                // One bar for both fields now, where the title used to get a
                // strip carrying nothing but the way out of the keyboard. The
                // list and heading controls still wait for the caret to reach
                // the words — a bullet added from a title would land in a
                // paragraph nobody is looking at — but undo is about the
                // document, and the title is part of the document.
                //
                // The title field's focus is SwiftUI's, so the chip is told to
                // drop it the way SwiftUI understands rather than leaving it to
                // be re-asserted over the resign.
                NoteFormatBar(controller: formatting,
                              showsStructure: showsFormatStructure && isWritingBody,
                              releaseFocus: { titleFocused = false })
            }
        }
    }

    /// The one line of prose under the note, or none. A refusal outranks the
    /// set-aside notice: it is the newer news, and the writer is standing over
    /// the words it concerns.
    private var notice: String? {
        if case .failed(let message) = saveStatus { return message }
        return errorMessage
    }

    /// Whether this sheet is being written in.
    ///
    /// The body reports its own focus, and for the title there is nothing to
    /// ask: its `@FocusState` stays false even when the caret is plainly in it,
    /// because the UIKit editor below has held first responder and SwiftUI's
    /// focus engine no longer agrees with UIKit about who has it now. So the
    /// keyboard is watched instead — see `SoftwareKeyboard`.
    ///
    /// Which is why the bar is not the *only* place undo is offered — a device
    /// with a hardware keyboard raises no software keyboard, and the caret can
    /// sit in a title this view has no truthful way to ask about. The toolbar
    /// carries the pair as well, where it does not depend on knowing.
    private var isTyping: Bool {
        canEdit && (isWritingBody || SoftwareKeyboard.shared.isVisible)
    }

    /// Split in two only because a toolbar builder takes ten children and this
    /// sheet now draws eleven; the division is the ordinary one — what is on
    /// the bar itself, and what is behind the "…".
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        barToolbarContent
        overflowToolbarContent
    }

    @ToolbarContentBuilder
    private var barToolbarContent: some ToolbarContent {
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
        //
        // Undo and redo used to take that same corner as well, one here and
        // one in the overflow, following the screenplay. On this sheet that
        // made three undo affordances and two redos, competing with Done, the
        // cloud badge and Find for an iPhone bar that shows two things — which
        // is what pushed the rest into the overflow in the first place. The
        // pair below, on the leading edge, is the lyric editor's arrangement,
        // and the lyric editor is this sheet's closer sibling.
        if isDocumentEditable && isReading {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    beginEditing()
                } label: {
                    Label("Edit", systemImage: "square.and.pencil")
                }
            }
        }
        // Beside the way out, where the lyric editor and the screenplay both
        // keep it: leaving is the moment a writer wonders whether their words
        // are anywhere but here.
        if let cloud = cloudState {
            ToolbarItem(placement: .topBarLeading) {
                CloudSyncBadge(state: cloud,
                               label: cloudLabel,
                               lastSyncedAt: lastSyncedAt,
                               // Pressable, as the lyric editor's badge is: a
                               // glyph that reports a problem and offers
                               // nothing leaves the writer guessing whether
                               // waiting helps.
                               sync: { await syncNow() },
                               conflictCount: conflicts.count,
                               review: conflicts.isEmpty ? nil : { showingConflicts = true })
            }
            .sharedBackgroundVisibility(.hidden)
        }
        // Undo and redo, on the leading edge where the lyric editor and the
        // screenplay both put them. The formatting bar carries the same pair,
        // but only while the caret is in the words — a writer who has put the
        // keyboard away, or who is looking at a note from the title field, had
        // no way back on a device with no ⌘Z.
        if canEdit {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    formatting.undo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!formatting.canUndo)

                Button {
                    formatting.redo()
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(!formatting.canRedo)
            }
        }
        // Find, where the lyric editor keeps its own Search. The system's find
        // bar does the work — see `NoteEditorController.find` for why this is
        // find-and-step rather than the lyric's filter — so there is nothing to
        // put on screen here and no chord to claim. Only over the writing
        // surface: reading swaps the text view out, and the reader has no
        // find bar to open.
        if !isReading {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    formatting.find(replacing: canEdit)
                } label: {
                    Label("Find", systemImage: "magnifyingglass")
                }
                .disabled(content.isEmpty)
            }
        }
    }

    @ToolbarContentBuilder
    private var overflowToolbarContent: some ToolbarContent {
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
        // The mode itself, in the "…" this sheet has instead of a View menu —
        // the screenplay's Read Script toggle, wearing this document's word for
        // itself. A toggle rather than a one-way "Reading View" button because
        // the mode has to travel both ways for everyone: the Edit button above
        // is the way out for a writer, and this is the way out for a reader the
        // server never gave the keyboard to.
        //
        // Offered wherever there is something to read, as the screenplay's is —
        // and always while the mode is on, so it is never a room with no door.
        if hasSomethingToRead || isReading {
            ToolbarItem(placement: .secondaryAction) {
                Toggle(isOn: readingBinding) {
                    Label(type == .song ? "Read Song" : "Read Note", systemImage: "book")
                }
            }
        }
        // The other kind of reading, next to it: the words out loud, in the
        // voice and at the speed the screenplay's Read Aloud is set to. Offered
        // on both surfaces — words are as worth hearing while they are being
        // written as after — and behind the "…" because this sheet's bar draws
        // two controls on a phone and already has more than two things wanting
        // them. Once a reading starts, the transport at the foot of the sheet
        // is the control.
        if hasWordsToSpeak {
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
        // Reached from here rather than from a screenplay's View menu, which is
        // where the only copy of these controls used to live — a writer working
        // in a note had no way to reach them at all.
        //
        // Offered whatever posture the document is in, as the lyric editor
        // offers it: the switch and the ignored-word list are the device's, not
        // this document's, and a writer who has just unlocked a note to fix the
        // word the checker keeps underlining should not have had to unlock it
        // first to say so.
        ToolbarItem(placement: .secondaryAction) {
            SpellingMenu(showingIgnoredWords: $showingIgnoredWords)
        }
        // Beside the spelling controls, where the lyric editor and the
        // screenplay's View menu both keep it and for the same reason: both are
        // about typing, and neither means anything to someone the server never
        // gave the keyboard to. Offered even while locked — it is the way back —
        // and only once there is a document to file the lock against. No
        // keyboard shortcut: the screenplay owns ⌘⇧Q and this sheet opens over
        // it, the same reason nothing else here claims a key.
        if isDocumentEditable, let options {
            ToolbarItem(placement: .secondaryAction) {
                Toggle(isOn: lockBinding(options)) {
                    Label("Lock Editing", systemImage: "lock")
                }
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

    /// The mode, as a Toggle can use it. Through the two functions below rather
    /// than straight at the state, so choosing it here is remembered — and
    /// saved on the way in — exactly as choosing it with the Edit button is.
    private var readingBinding: Binding<Bool> {
        Binding(get: { isReading },
                set: { reading in
                    if reading { enterReadingView() } else { beginEditing() }
                })
    }

    /// Hands the document to the writer, and remembers that this is one they
    /// write in — so the Edit button is a cost paid once per document rather
    /// than on every visit.
    private func beginEditing() {
        isReading = false
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
            isReading = true
            // The writing surface goes away with the flag, so the formatting
            // bar's "the caret is in the body" answer has to be let go of too —
            // nothing will fire the text view's blur once it is off screen.
            isWritingBody = false
            guard let target else { return }
            readingViews.remember(true, for: .document(id: target.id))
        }
    }

    // MARK: - Reading aloud

    /// Whether there is a word here for a voice to say. Unlike the reading
    /// *view*, this does not wait for the document to exist on the server: a
    /// song being typed for the first time is as readable as one that has been
    /// there for a year, and nothing about speaking it needs an id.
    private var hasWordsToSpeak: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Which document this sheet handed the narrator, when it started a
    /// reading.
    ///
    /// Kept rather than computed because the answer can change underneath a
    /// reading: a new note creates itself a second after the first word is
    /// typed, and the subject it was prepared under — `newDocument` — becomes
    /// `document(id:)` the moment it lands. Computed, the transport would
    /// vanish mid-sentence while the voice carried on with no way to stop it.
    @State private var readingSubject: NarrationSubject?

    /// Whether the voice on the device is reading this document.
    private var isBeingRead: Bool {
        readingSubject != nil && narrator.subject == readingSubject
    }

    /// The words as the narrator takes them: a song as lines, a note as prose.
    /// What is on screen rather than what was last saved, so a verse typed a
    /// moment ago is read as typed.
    private var narrationSource: NarrationSource {
        guard type == .song else { return .note(content) }
        let lines = content.components(separatedBy: .newlines)
        // Positions for ids: these lines are pieces of one string, and nothing
        // on either surface points at one.
        return .lyric(lines.enumerated().map { NarrationLine(id: $0.offset, text: $0.element) })
    }

    /// Reads the document out loud, here on this sheet — the transport comes up
    /// at the foot of it, as it does on the screenplay and in the lyric editor.
    /// Reaching for it while this document is being read pauses and resumes.
    ///
    /// The run is built once, at the press. Everywhere else a reading follows
    /// the words as they change, because everywhere else they change when an
    /// element lands; here `content` is bound to the text view and changes on
    /// every keystroke, and rebuilding the run restarts the sentence being
    /// spoken. So a note typed into while it reads is read as it was when the
    /// voice started — press it again to hear the new words.
    private func toggleReadAloud() {
        if narrator.isActive && isBeingRead {
            narrator.togglePlayPause()
            return
        }
        let subject: NarrationSubject = target.map { .document(id: $0.id) } ?? .newDocument
        readingSubject = subject
        narrator.prepare(narrationSource,
                         subject: subject,
                         title: trimmedTitle.isEmpty
                            ? (type == .song ? "Untitled Song" : "Untitled Notes")
                            : trimmedTitle)
        narrator.play()
    }

    /// The transport, up only while this document is the thing being read.
    @ViewBuilder
    private var narrationBar: some View {
        if narrator.isActive && isBeingRead {
            NarrationTransportBar(narrator: narrator)
        }
    }

    // MARK: - Editing lock

    /// Which family of keys this document's lock is filed under — a note's and
    /// a song's are kept apart, so a key says what it locks. "Other" is a note,
    /// as it is everywhere else on these screens.
    private static func lockKind(for type: DocumentType) -> DocumentViewOptions.Kind {
        type == .song ? .song : .note
    }

    /// The lock, as a Toggle can use it.
    ///
    /// Locking saves first, and the flag follows the save rather than leading
    /// it: `saveNow` is guarded on `canEdit`, so a lock set ahead of the send
    /// would quietly make the send a no-op and leave the last sentence typed
    /// sitting in a text view nobody is going to look at again. The same order,
    /// and the same reason, as entering the reader.
    private func lockBinding(_ options: DocumentViewOptions) -> Binding<Bool> {
        Binding(get: { options.isEditingLocked },
                set: { locked in
                    guard locked else {
                        options.setEditingLocked(false)
                        return
                    }
                    autosave?.cancel()
                    Task {
                        await saveNow()
                        options.setEditingLocked(true)
                    }
                })
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
            loaded = full
            title = full.title ?? title
            content = full.content ?? ""
        }
        // Whether what landed came off the network or off this device — the
        // copy kept here is the whole document, so it is worth showing and
        // worth typing into, but it is not evidence of what the server holds.
        offlineCopySavedAt = model.documentCopySavedAt[document.id]
        // Whatever landed is the baseline for "has anything been typed" —
        // including a load that failed and left the list row's preview. But
        // only a real fetch makes it *base evidence* for held drafts; see
        // `haveServerBaseline`.
        savedTitle = title
        savedContent = content
        haveServerBaseline = full != nil && offlineCopySavedAt == nil
        // The document that just landed is where undo stops. What the sheet
        // opened with was the list row's preview — a truncated one — and
        // leaving that at the bottom of the stack would put one press of ⌘Z
        // between the writer and losing most of their note.
        formatting.reset(title: title, to: content)
        // Two things the opening decision could not know until the document
        // was in hand, both of which mean this one belongs to the writer.
        //
        // Words this device is still holding are writing in progress that has
        // not reached the server — and `adoptHeldDraft` below is itself
        // guarded on `canEdit`, so leaving the sheet in reading view would put
        // the server's older copy on screen and quietly leave the writer's own
        // paragraph out of sight.
        //
        // An empty document is nothing to read: the reader's own "Nothing to
        // Read", with the writing waiting behind a button nobody asked to
        // press. Not remembered, as the screenplay's empty-script fallback is
        // not — the document has said nothing about how it wants to open, and
        // once there are words in it the answer changes.
        if model.heldDocumentDraft(for: document) != nil || content.isEmpty {
            isReading = false
        }
        // The copy kept on this device is not a server copy, and judging a
        // held draft's staleness against it would set aside the writer's own
        // words for disagreeing with words the server may never have held.
        adoptHeldDraft(for: document, sawServerCopy: haveServerBaseline)
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
            // And nothing to walk back *to*: the only other text here is that
            // same truncated preview. The draft is where this note begins.
            formatting.reset(title: title, to: content)
            saveStatus = .held
            // Nothing has been typed to arm the debounce, so the backoff is
            // the only thing that will try these words again inside this
            // sheet — the load failing is usually the connection, and the
            // online edge covers that, but a fetch that failed for its own
            // reasons should not leave the draft sitting here untried.
            scheduleRetry()
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
            // Both versions are real writing and the server's is the newer
            // one; neither is this sheet's to throw away. The draft becomes a
            // conflict — the banner below offers the choice, and the words
            // survive the sheet being closed on it.
            model.quarantineDocumentDraft(draft, serverTitle: savedTitle,
                                          serverContent: savedContent)
            return
        }
        title = draft.title
        content = draft.content
        // One press of undo, back to the words the server holds. An edit made
        // offline is the one edit in a note a writer may never have watched
        // themselves make — it was typed in another session, on another day —
        // and until now taking it back meant retyping the paragraph it
        // replaced from memory. The name goes with it: a draft carries both,
        // and a step that put back yesterday's words under today's title would
        // describe a document that never existed.
        formatting.record(title: title, text: content)
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
        guard canEdit, !isLoading else { return }
        // Undoing back to what the server already has is not "no change" — it
        // is the change that makes the held draft pointless, so it goes.
        guard hasUnsavedChanges else {
            dropHeldDraftIfBackToServerCopy()
            return
        }
        // Said from the first keystroke rather than when the request leaves:
        // what the writer needs to know is that the words are on their way, and
        // a readout that still says "Saved" over unsent text is the one thing
        // this bar must never do.
        saveStatus = .saving
        let delay = isNew ? Self.createDelay : Self.autosaveDelay
        // A keystroke is a better retry than the backoff's: it sends newer
        // words, and sooner. The budget goes back to full with it, so a note
        // written through a long tunnel keeps earning attempts.
        retry?.cancel()
        retryAttempt = 0
        autosave?.cancel()
        autosave = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await saveNow()
        }
    }

    /// What the badge's button does: stop waiting and settle this document with
    /// the server now — the lyric editor's "Sync Now", in a note.
    ///
    /// Two errands, and which one it is depends on whether there is anything
    /// unsent. Words still here go first, without waiting out the debounce or
    /// the backoff. With nothing to send, the honest reading of the button
    /// ("Check for Changes", as the panel labels it in the settled state) is to
    /// ask the server what it holds and take it — but only when this screen has
    /// nothing of its own to lose, which after the send above is the ordinary
    /// case.
    private func syncNow() async {
        autosave?.cancel()
        retry?.cancel()
        retryAttempt = 0
        if hasUnsavedChanges {
            await saveNow()
            return
        }
        guard canEdit, let document = target,
              let full = await model.fetchDocument(document),
              // The copy on this device is not an answer to "what does the
              // server say?" — it is the question restated. Adopting it here
              // would put old words on screen and call them current.
              model.documentCopySavedAt[document.id] == nil else { return }
        let serverTitle = full.title ?? ""
        let serverContent = full.content ?? ""
        // Typed into while the fetch was in flight: those words are newer than
        // what came back, and the debounce that will send them is already armed.
        guard !hasUnsavedChanges else { return }
        savedTitle = serverTitle
        savedContent = serverContent
        haveServerBaseline = true
        lastSyncedAt = .now
        guard serverContent != content || serverTitle != title else { return }
        // The note changed somewhere else. One press of undo back to what was
        // on this screen a moment ago, the same courtesy an adopted offline
        // draft gets — nobody watched these words arrive.
        title = serverTitle
        content = serverContent
        // The name goes into the step beside the words, for the reason the
        // adopted draft above records both: the note may have been renamed
        // elsewhere too, and a step that put back the old title under the new
        // words would describe a document nobody ever wrote.
        formatting.record(title: serverTitle, text: serverContent)
    }

    /// Try again later, on the backoff the screenplay and the lyric editor
    /// share. Only for a write that couldn't get out — a refusal is not
    /// something a retry fixes, and hammering the server over it would only
    /// keep the badge pulsing at a writer who can do nothing about it.
    ///
    /// Past the last delay this stops. The words stay where they are — on disk
    /// for a document that exists, on screen for one that doesn't — and the
    /// next keystroke or the connection returning arms it all over again.
    private func scheduleRetry() {
        guard retryAttempt < Self.retryDelays.count else { return }
        let delay = Self.retryDelays[retryAttempt]
        retryAttempt += 1
        retry?.cancel()
        retry = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await saveNow()
        }
    }

    /// The note is back to exactly the words the server holds — undone, or
    /// typed back — so anything held for it on this device describes an edit
    /// that no longer exists.
    ///
    /// It has to go now rather than at the next save, because there will be no
    /// next save: nothing is dirty. Left alone, the reconnect sweep would push
    /// it and put back the paragraph the writer just took off the screen —
    /// which is undo losing to the network, the one way this feature could be
    /// worse than not having it. Only against a real server copy: without one
    /// `savedContent` is the list row's truncated preview and proves nothing.
    private func dropHeldDraftIfBackToServerCopy() {
        guard haveServerBaseline, let document,
              model.heldDocumentDraft(for: document) != nil else { return }
        model.discardDocumentDraft(for: document.id)
        saveStatus = .saved
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
            lastSyncedAt = .now
            saveStatus = .saved
            errorMessage = nil
            retry?.cancel()
            retryAttempt = 0
            // Typed into while that was in flight: those words have not been
            // sent.
            if hasUnsavedChanges { scheduleAutosave() }
        case .held:
            // On disk, retried by the reconnect sweep — and, while this sheet
            // is open, by the backoff, so the badge clears itself the moment
            // the route comes back rather than waiting for the writer to
            // notice it hasn't.
            saveStatus = .held
            scheduleRetry()
        case .failed:
            // Refused. The draft is still on disk and the sweep still has it;
            // what a retry from here would earn is another refusal.
            retry?.cancel()
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
            // There is a document to file a lock against now, so the switch
            // can be offered without the writer having to reopen what they are
            // already looking at.
            options = DocumentViewOptions(documentId: document.id,
                                          kind: Self.lockKind(for: type))
            savedTitle = sentTitle
            savedContent = sentContent
            // The server has just told us what it holds, which is as good a
            // baseline as a fetch — and the one a held draft would be judged
            // against if the next save cannot get out.
            haveServerBaseline = true
            lastSyncedAt = .now
            saveStatus = .saved
            errorMessage = nil
            retry?.cancel()
            retryAttempt = 0
            // Typed into while the create was in flight: those words are not on
            // the server yet, and now there is a document to send them to.
            if hasUnsavedChanges { scheduleAutosave() }
        case .unreachable:
            // The one held-shaped failure with nowhere to be held, so the
            // backoff matters more here than anywhere else on this screen: it
            // is what gets the document made while the writer is still sitting
            // in front of it, before Done can cost them anything.
            saveStatus = .failed("Not saved — couldn't reach the server.")
            scheduleRetry()
        case .failed:
            retry?.cancel()
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
