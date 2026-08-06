//
//  ScriptView.swift
//  scripty
//
//  The screenplay page for one project. Editable elements are typed into
//  directly — Return, Backspace and Tab split, merge and retype the way the
//  web editor does — so writing is continuous rather than one block at a
//  time. Every affordance is still gated by the links the server advertised.
//

import SwiftUI

struct ScriptView: View {
    /// A list the Home Screen menu or a widget row asked for, waiting to be
    /// opened. Written back to nil once it has been, so the sheet does not
    /// reopen every time this view is rebuilt.
    @Binding var openingDocuments: DocumentsRequest?
    /// An element a tapped Bookmarks widget row asked for, waiting to be
    /// scrolled to. Written back to nil once it has been taken, so it is not
    /// re-taken every time this view is rebuilt.
    @Binding var openingBookmark: Int?

    @State private var model: ScriptModel
    @State private var showingCharacters = false
    /// What the Songs & Notes sheet was asked for, and whether it is open at
    /// all: which of the two lists it opens on, the song or note to open
    /// straight into if the request named one, and whether the composer comes
    /// up with it.
    ///
    /// The request is the sheet's item rather than a set of flags beside an
    /// `isPresented` — a sheet raised that way reads the rest of the view as it
    /// stood *before* the button ran, so a list chosen in the same tap arrives
    /// stale and "All Notes…" opens on songs.
    @State private var documentsSheet: DocumentsRequest?
    /// The song or note opened straight from the script's Songs menu, without
    /// going through the Songs & Notes screen first.
    @State private var openingDocument: TextDocument?
    @State private var showingTitlePage = false
    /// Whether the rename sheet is up for the screenplay on screen. The name
    /// is the thing being reached for, so it is offered under the name.
    @State private var showingRename = false
    /// Whether the heading at the top of the writing column is being typed
    /// over, and the name being typed. The sheet above is still the way in
    /// from the menus; this is the way in from the title itself, which is
    /// where the web app has always renamed a screenplay.
    @State private var isRetitling = false
    @State private var titleDraft = ""
    @FocusState private var titleFieldFocused: Bool
    /// The armed rename, cancelled and replaced on every keystroke — a name is
    /// sent a beat after typing stops rather than once per character.
    @State private var retitleSave: Task<Void, Never>?
    /// The wait a note's title takes, for the same reason: a name half-typed
    /// is not a name.
    private static let retitleDelay: Duration = .milliseconds(1200)
    @State private var showingOutline = false
    @State private var showingStats = false
    @State private var showingIgnoredWords = false
    /// Whether the two-versions screen is up. Never opened on its own: a sheet
    /// that took the script away mid-sentence because a sweep found something
    /// would be the writing equivalent of being interrupted mid-word. The
    /// banner and the cloud badge wait to be pressed.
    @State private var showingConflicts = false
    /// Whether the format bar is unfolded above the element-type bar. Off by
    /// default and deliberately not persisted: formatting is an occasional
    /// errand, and each session should start with the screen it saves.
    @State private var showingFormatBar = false
    @State private var isSearching = false
    /// Whether the script is up for reading silently — a surface of
    /// this screen, like page view, not a screen of its own: the mode swaps
    /// the writing column for the reader in place, and the toolbar and the
    /// reading position stay put.
    ///
    /// Where a screenplay *opens* now, and no longer only a posture entered by
    /// hand. Pages and Word both open a document to be read on iOS and put an
    /// Edit button in the corner, and a screenplay that comes up live to the
    /// keyboard is one a thumb scrolling through it will eventually type into.
    /// `ReadingViewSettings` holds the two rules that make that bearable — a
    /// document reopens the way it was left, and one switch changes the answer
    /// for the documents nobody has chosen for — and `setReading` is what
    /// tells it which way this one was put.
    @State private var isReading: Bool
    /// Whether the paper on screen was reached from the reader, by the bottom
    /// bar's Page View button.
    ///
    /// The two are exclusive — asking for paper takes the reader down (see the
    /// `isPageView` hook) — so without this the button would be a one-way door:
    /// tap it while reading and the way back is the View menu, three taps up in
    /// the corner, and what it lands on is the writing column rather than the
    /// reading you left. Remembering which posture the paper came from is what
    /// lets the one button make the round trip.
    ///
    /// Cleared whenever paper goes off, whichever route turned it off, so a
    /// stale true can never put the reader up over a writer's script.
    @State private var paperCameFromReader = false
    /// The voice that reads out loud. The device's one narrator rather than
    /// this screen's own, since the song and note editors read through it too —
    /// see `ScriptNarrator`. A reading still survives the reading mode coming
    /// and going; what ends it is leaving the screenplay, or another document
    /// being read instead.
    private let narrator = ScriptNarrator.shared
    @State private var showingPageSetup = false
    @State private var showingVersions = false
    /// Drives the screenplay file picker. Set by the toolbar's Import button
    /// and the File menu's "Import Script…" command (⌘⇧I); the importer's
    /// machinery hangs off the always-present `.scriptImporter` modifier, so
    /// the menu route works even in focus mode, where the toolbar button is gone.
    @State private var showingScriptImporter = false
    /// Presented from the link the block collection advertised.
    @State private var trashLink: HALLink?
    @State private var showingEditions = false
    /// The element whose comment thread is open, if any.
    @State private var commentTarget: Block?
    @State private var activityLink: HALLink?
    /// The sheet holds two things — who can already see the screenplay, and the
    /// invitations — and either one alone is worth opening it for. Inviting is
    /// only offered where the server has invitations over the API turned on.
    @State private var showingShare = false
    @State private var editions: EditionsModel
    @State private var exporter: ScriptExportModel
    @State private var navigator = ScriptNavigator()
    @State private var search = ScriptSearchModel()
    @State private var selection = BlockSelectionModel()
    /// One list for the whole script: only the element being typed into can
    /// have suggestions open, so there is nothing per-row to keep.
    @State private var autocomplete = ScriptAutocomplete()

    /// Presentation is a device preference shared across every project, so the
    /// model is the app-wide one rather than one per script.
    private let settings = PresentationSettings.shared

    /// Whether a document opens to be read or to be written in, and which way
    /// this screenplay was last put. Shared with the song and note editors, so
    /// one switch answers for every document in the app.
    private let readingViews = ReadingViewSettings.shared

    /// Which screen the writer had open above the script when they last put the
    /// app down. The project list owns the project half of that record; this
    /// view owns the screen sitting on top of it.
    private let openEditors = OpenEditorState.shared
    /// Whether the held-work strip has been closed for the situation currently
    /// on. Shared, so leaving the script and coming back does not undo the tap.
    private let notices = DismissedNotices.shared
    /// What the Songs & Notes screen should reopen once it is up, when this
    /// launch is restoring a song or note editor that was reached through it.
    /// Held here rather than read from the record inside that screen because the
    /// record is handed over once, and this view is the one that claims it.
    @State private var reopeningInSongs: [OpenEditor] = []

    /// What this script shows and whether it can be typed into. Per project
    /// rather than shared, so marking up one draft leaves the others alone.
    @State private var options: ScriptViewOptions
    /// The remembered position is restored once per visit — a later reload
    /// (a restore from trash, a version rollback) must not yank the writer
    /// back to where they came in.
    @State private var hasRestoredPosition = false
    /// Per-body answers this screen would otherwise work out several times a
    /// redraw — see `ScriptViewMemo`.
    @State private var memo = ScriptViewMemo()
    /// An element a Bookmarks widget row asked for, held until the script it
    /// belongs to has actually arrived. Nil the rest of the time.
    @State private var pendingBookmarkBlockId: Int?
    /// An element a double tap asked to write in, held until the writing column
    /// is the surface on screen. Nil the rest of the time.
    ///
    /// Held rather than focused on the spot, for the same reason the navigator
    /// holds a scroll target: the tap that asks is made on the reader, and the
    /// column it names does not exist yet. Focus set against a surface that is
    /// on its way out is focus nothing ever claims.
    @State private var pendingWriteTarget: Int?

    /// How much room the script actually has, whichever surface is up. Zero
    /// until the first layout, which reads as "use the printed measure".
    @State private var availableWidth: CGFloat = 0

    /// The OS text-size setting, as a multiplier. Folded into `textScale` with
    /// the writer's own type-size control, so the two compose rather than one
    /// overriding the other.
    @ScaledMetric(relativeTo: .body) private var dynamicTypeScale: CGFloat = 1

    /// Whether the toolbar and the reading bars are folded away because the
    /// writer is scrolling down through the script — the reading posture
    /// Word's iOS app takes. Scrolling back up, or reaching the top, brings
    /// them straight back. Never persisted: every visit starts dressed.
    @State private var isChromeHidden = false
    /// How far the current run of scrolling has travelled in one direction.
    /// A change of direction resets it, so folding the bars away — or bringing
    /// them back — takes deliberate travel rather than a jitter of the finger.
    @State private var scrollRun: CGFloat = 0

    /// Pagination is recomputed when the script or the paper changes rather
    /// than on every redraw — it walks the whole script.
    @State private var pages: [ScriptPage] = []
    @State private var currentPage = 1
    /// The sheet the paper surface has been asked to scroll to, cleared once it
    /// has. Page view's counterpart to the navigator's pending target, kept
    /// local because nothing outside this view asks for a page.
    @State private var pendingPageTarget: Int?

    /// Watched so pending typing is flushed (and snapshotted to disk) the
    /// moment the app heads to the background — the debounce window may
    /// outlive the app's execution time, and this is the writer's only copy.
    @Environment(\.scenePhase) private var scenePhase

    /// Told when the project resource itself changes — a rename, new front
    /// matter, a script imported over the top. The list behind this screen is
    /// showing the old name until somebody says otherwise.
    private let onProjectChanged: (Project) async -> Void

    /// Whether the split view is showing one column or two, which here decides
    /// where the songs and notes are offered — see `documentsBar`.
    ///
    /// Passed in rather than read from the environment, for the reason
    /// `ContentView` gives where it reads it: inside a `NavigationSplitView`
    /// column the size class is `.compact` even on an iPad showing both, so a
    /// detail view asking for itself gets the iPhone answer everywhere.
    private let isCompact: Bool

    init(app: AppModel, project: Project, openingDocuments: Binding<DocumentsRequest?>,
         openingBookmark: Binding<Int?> = .constant(nil),
         isCompact: Bool = false,
         onProjectChanged: @escaping (Project) async -> Void = { _ in }) {
        _openingDocuments = openingDocuments
        _openingBookmark = openingBookmark
        self.isCompact = isCompact
        self.onProjectChanged = onProjectChanged
        let model = ScriptModel(app: app, project: project)
        _model = State(initialValue: model)
        _editions = State(initialValue: EditionsModel(app: app, project: project))
        _exporter = State(initialValue: ScriptExportModel(model: model))
        _options = State(initialValue: ScriptViewOptions(projectId: project.id))

        // Which surface this screenplay opens on, settled here rather than
        // when the elements land: decided later it would be a swap the writer
        // watches happen, a beat of the writing column and then the reader
        // over the top of it.
        //
        // Page view and outline mode opt out. Both are already postures of
        // their own — paper cannot be typed into either, and outline mode is
        // the writing surface narrowed to the skeleton, which is a thing
        // someone is doing rather than reading — so a script left in either
        // reopens in it. A script that turns out to have nothing in it opts
        // out too, but only the load can know that; see `leaveEmptyReader`.
        let presentation = PresentationSettings.shared
        let opensForReading = ReadingViewSettings.shared
            .opensInReadingView(.screenplay(project: project.id))
        _isReading = State(initialValue: opensForReading
                           && !presentation.isPageView
                           && !presentation.isOutlineMode)
    }

    var body: some View {
        presentations(over: lifecycle(over: scriptSurface))
    }

    /// The script with its chrome and banners — the sheets ride on
    /// `presentations` and the load/sync/mode hooks on `lifecycle`. Split three
    /// ways because one expression carrying every modifier is more than the
    /// type-checker will finish in reasonable time.
    private var scriptSurface: some View {
        Group {
            // Reading wins while it is on; page view and the column wait
            // underneath and come back exactly as they were left.
            if isReading {
                reader
            } else if settings.isPageView {
                pageView
            } else {
                editor
            }
        }
        // Measured out here rather than inside a surface, because the answer has
        // to be the same for all three: a reader that measured for itself put
        // the column somewhere slightly different from the one the writer had
        // just been typing in, and every line moved on the way into the mode.
        // It is also the only place that *can* measure when the script opens
        // straight into reading — the editor is never built to do it.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .environment(\.scriptTextScale, Double(textScale))
        .environment(\.scriptRowChrome, rowChrome)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                // Above the held-work strip: everything that one reports is
                // waiting on a connection, and this is waiting on the writer.
                conflictBanner
                unsavedBanner
                editionBanner
            }
        }
        // A closed strip is closed about one situation. When the situation
        // moves on — the connection comes back, everything lands, a refusal
        // arrives on top of held work — the dismissal stops applying and the
        // next thing worth saying gets said.
        .onChange(of: heldWorkState) { _, _ in
            notices.situationChanged(heldWorkKey)
        }
        // Outside the mode switch, so the readout is in the same place whether
        // the script is a column or a stack of pages. `.safeAreaBar` rather
        // than `.safeAreaInset`: the readout is a bar, so it takes the system's
        // Liquid Glass and the script passes under it.
        .safeAreaBar(edge: .bottom, spacing: 0) { wordCountBar }
        // Mounted after the readout, so it settles below it — the buttons are
        // the thing being reached for, and the count is a thing being read.
        .safeAreaBar(edge: .bottom) { documentsBar }
        // Last of the strips, so the transport sits nearest the thumb while a
        // reading runs. Deliberately not folded with the chrome: it is the
        // only handle on live audio, and someone scrolling while the script
        // is read to them has not stopped listening.
        .safeAreaBar(edge: .bottom) { narrationBar }
        // Floated after the word-count inset, so it settles just above the bar
        // (or the bottom safe area when the bar is off) rather than over it.
        .historyToast(model.historyToast)
        .navigationTitle(model.project.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .toolbarTitleMenu { projectButtons }
        // Scrolling down through the script folds the bar away for reading
        // room; `respondToScroll` is what sets the flag. The reading bars at
        // the bottom fold on the same flag, each at its own declaration.
        .toolbarVisibility(isChromeHidden ? .hidden : .visible, for: .navigationBar)
        // Search and selection are toolbar errands with bars of their own —
        // the chrome comes back for them rather than leaving the writer to
        // work them in a bare room. Search matters in particular: ⌘F can start
        // it while the toolbar is folded away.
        .onChange(of: isSearching) { _, searching in
            if searching { setChrome(hidden: false) }
        }
        .onChange(of: selection.isSelecting) { _, selecting in
            if selecting { setChrome(hidden: false) }
        }
        .exportPresentation(exporter)
        .focusedSceneValue(\.scriptActions, menuActions)
    }

    /// The load, sync and mode-change hooks — `scriptSurface`'s other half;
    /// see its header for why the split exists.
    private func lifecycle(over content: some View) -> some View {
        content
        .refreshable {
            await model.loadBlocks()
            await model.refreshUndoRedo()
        }
        .task {
            // The script, the cast, the history, the songs and notes and the
            // sync poll — all of it owned by the model rather than by this
            // task, which SwiftUI cancels as soon as it takes this build of the
            // view down. Opening a screenplay does exactly that, and a load
            // abandoned there is silent: see `ScriptModel.open`.
            await model.open()
            // A screenplay with nothing in it belongs to the writer, not the
            // reader. Here as well as on the blocks landing, because an empty
            // script *is* no change to them: they start empty and stay that
            // way, so nothing would ever fire.
            leaveEmptyReader()
            // Straight after the documents land, since a remembered song editor
            // needs the song itself, and before the edition restore below, whose
            // round trip a reopening sheet should not be made to wait out.
            reopenRememberedEditor()
            repaginate()
            // Loaded quietly: most projects have a single edition and should
            // show no sign of the feature at all.
            await editions.load()
            await reopenRememberedEdition()
        }
        .onDisappear {
            model.stopSyncPolling()
            // Leaving the screenplay ends its reading — the voice belongs to
            // this script, and the transport goes down with the screen.
            // Backgrounding the app is not leaving: no `onDisappear` fires
            // there, which is what keeps the lock-screen reading alive.
            //
            // Only its own: the narrator is shared now, and a song being read
            // from the sheet over this screen is not this screen's to stop.
            if isReadingThisScript { narrator.stop() }
        }
        // The connection came back: push the words held on this device right
        // away rather than waiting out each block's retry backoff, then pull
        // whatever changed elsewhere. Mirrors the web's sync-on-reconnect.
        .onChange(of: model.app.connectivity.isOnline) { _, online in
            guard online else { return }
            Task { await model.syncHeldWork() }
        }
        // Backgrounding flushes the debounced commit immediately — and stops
        // the 5s sync poll from hitting the network while nobody is looking.
        // Coming back is a second chance for anything still held: retry
        // backoffs may have run out while the app slept, and the monitor only
        // speaks on a *change* of route, so the foreground is the one moment
        // that reliably arrives with both a route and the writer's attention.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background, .inactive:
                model.stopSyncPolling()
                Task { await model.flushPendingCommits() }
            case .active:
                model.startSyncPolling()
                if model.hasHeldWork, model.app.connectivity.isOnline {
                    Task { await model.syncHeldWork() }
                }
            @unknown default:
                break
            }
        }
        // What the Home Screen widget draws is whatever this project's list
        // last held. Watched here rather than published from the load itself so
        // that every path which changes the documents — creating, renaming,
        // deleting, importing, restoring from the trash — is covered once.
        .publishingSongsAndNotes(from: model)
        // An element a tapped Bookmarks row named. Taken here and acted on
        // below, once the script it belongs to has landed.
        .openingBookmark($openingBookmark, perform: receiveBookmarkRequest)
        // Where the writer is, kept as they go rather than only on the way out:
        // a script left open and then killed should still reopen in the right
        // place. Typing says it here; reading says it from the scroll spy on
        // each surface, and whichever spoke last is where they were.
        .onChange(of: model.focusedBlockId) { _, id in options.rememberBlock(id) }
        // Which screen is up over the script, kept the same way and for the same
        // reason.
        .remembersOpenEditor(openEditor, atDepth: 0,
                             isEnabled: !model.app.isEphemeralDemo)
        .onChange(of: model.blocks) { _, _ in
            repaginate()
            // What the Bookmarks widget draws is whichever of these elements
            // are flagged. Hung off this closure rather than given a modifier
            // of its own, unlike the songs and notes above: the elements change
            // far more often than the documents do — every commit, every sync
            // poll — and this is the one pass that already watches them.
            publishBookmarks()
            openPendingBookmark()
            restoreRememberedPosition()
            leaveEmptyReader()
            // A reading in progress follows the script it is reading — an
            // edit, a sync, a restore all reshape the run, and the narrator
            // keeps its place across the rebuild. Idle, there is nothing to
            // keep in step; the run is built fresh when reading starts. And
            // only while the voice is on this script: handing it these blocks
            // while it reads a song would take the song off it.
            if narrator.isActive && isReadingThisScript {
                narrator.prepare(.script(model.blocks),
                                 subject: narrationSubject,
                                 title: model.project.displayTitle)
            }
        }
        .onChange(of: settings.pageSetup) { _, _ in repaginate() }
        // Hidden notes are hidden on paper too — otherwise the page count in
        // the navigator disagrees with the script on screen.
        .onChange(of: options.showsNotes) { _, _ in repaginate() }
        // The editing lock is per edition, so it has to follow the switch.
        .onChange(of: editions.selectedId) { _, id in options.editionId = id }
        // Pagination is skipped while the editor is up, so switching into page
        // view is the first point at which it can be computed. Today the mode
        // switch changes this view's identity and re-runs the .task above,
        // which happens to repaginate — but that is incidental, and the sheets
        // would come up empty if the Group were ever restructured.
        .onChange(of: settings.isPageView) { _, on in
            repaginate()
            // Asking for paper is asking to leave the reader: a Page View
            // toggle that visibly did nothing because reading sat on top of it
            // would read as broken. Not remembered as a choice about reading,
            // though — asking for paper is not the same as saying this script
            // should open ready to type in. Only on the way *on*: paper going
            // off is `setReading` clearing it as the reader comes up, and
            // answering that by leaving the reader would undo the mode the
            // writer just asked for.
            if on { setReading(false, remember: false) }
            // Paper going off ends the errand the bottom bar's Page View
            // button started, whichever route turned it off — its own second
            // tap, the View menu, ⌘⇧P, or the reader coming up over it. Left
            // standing, the flag would draw a "Read Script" button in a
            // *writer's* bar, one tap from putting the reader over the script
            // they were typing into.
            if !on { paperCameFromReader = false }
            // Changing surface is not leaving the page: the paper opens on the
            // sheet the column was showing, and the column comes back to the
            // element the sheet started with. Both read the position the other
            // has been keeping, so the switch is where it changes hands. The
            // reader is not part of that handoff — it restores its own place.
            guard !isReading else { return }
            if let id = options.rememberedBlockId,
               model.blocks.contains(where: { $0.id == id }) {
                scroll(toRemembered: id)
            }
        }
        // Outline mode is a request for the editor, narrowed — leave the
        // reader for it, as the page-view toggle above does, and on the same
        // terms: a mode change, not a choice about how this script opens.
        .onChange(of: settings.isOutlineMode) { _, on in
            if on { setReading(false, remember: false) }
        }
        // Leaving the reader sends the returning surface to where the reading
        // got to — the same handoff the column and the paper already make.
        // Entering needs nothing here: the reader restores the position itself.
        .onChange(of: isReading) { _, reading in
            guard !reading else { return }
            if let id = options.rememberedBlockId,
               model.blocks.contains(where: { $0.id == id }) {
                scroll(toRemembered: id)
            }
        }
    }

    /// Every sheet this screen can present, with the importer and the error
    /// alert — `body`'s other half; see `scriptSurface` for why the split
    /// exists.
    private func presentations(over content: some View) -> some View {
        content
        .sheet(isPresented: $showingPageSetup) {
            PageSetupSheet(settings: settings)
        }
        .sheet(item: $trashLink) { link in
            TrashView<DeletedBlock, DeletedBlockRow>(
                app: model.app,
                source: link,
                title: "Deleted Elements",
                emptyMessage: "Elements you delete can be restored from here.",
                // A restored element rejoins the script behind us.
                onChanged: {
                    await model.loadBlocks()
                    await model.refreshUndoRedo()
                    repaginate()
                }) { block in
                    DeletedBlockRow(block: block)
                }
        }
        .sheet(item: $activityLink) { link in
            ActivityView(app: model.app, source: link)
        }
        .sheet(isPresented: $showingShare) {
            ShareView(app: model.app,
                      source: model.project.link(.invitations),
                      contactsSource: model.project.link(.contactSuggestions),
                      accessSource: model.project.link(.access),
                      projectTitle: model.project.displayTitle)
        }
        .sheet(item: $commentTarget, onDismiss: {
            // The thread may have gained or lost comments, so repaint the
            // badge. Only the counts — reloading the script would throw away
            // whatever the writer has typed since.
            Task { await model.loadCommentCounts() }
        }) { block in
            // Presented from the link the block advertised, so the thread
            // cannot open for an element the server never offered one for.
            if let source = block.link(.comments) {
                CommentsView(app: model.app, block: block, source: source)
            }
        }
        .sheet(isPresented: $showingEditions) {
            EditionsView(model: editions) { edition in
                // The choice travels as the link the server gave for that
                // edition; changing it reloads the script.
                model.editionBlocksLink = editions.blocksLink(for: edition)
                await model.refreshUndoRedo()
                repaginate()
            }
        }
        .sheet(isPresented: $showingVersions) {
            // Presented from the link the project advertised, so the sheet
            // cannot open for a project the server keeps no history for.
            if let versions = model.project.link(.versions) {
                VersionHistoryView(app: model.app, source: versions, subject: "script") {
                    // A restore rewrites the script, so reload rather than
                    // trusting what is on screen.
                    await model.loadBlocks()
                    await model.refreshUndoRedo()
                    repaginate()
                }
            }
        }
        .sheet(isPresented: $showingCharacters) {
            CharactersView(model: model)
        }
        // The reopening path is dropped on the way out, so a restored editor is
        // reopened once: the next time this screen is asked for it is because
        // someone tapped for it, and they asked for the list rather than for
        // whatever was on it last night.
        //
        // A cover rather than a sheet: songs and notes are a place to work, not
        // something to glance at over the script. As a sheet an iPad left them
        // in a centred card with the screenplay showing around it — half a
        // screen for the lyric column and the editor stacked above it. Nothing
        // is lost by covering the script: every screen in this stack already
        // carries its own Done button, which is the only way out a cover
        // offers. See `SongsView` for the same change one rung up.
        .fullScreenCover(item: $documentsSheet, onDismiss: { reopeningInSongs = [] }) { request in
            // Identified by the request, because the screen's own list is
            // `@State` seeded from this argument — and seeding only happens the
            // first time a view identity exists. Without this, the second
            // opening reuses the state the first one left behind and "All
            // Songs…" lands on notes because that is where the last visit ended.
            SongsView(model: model, options: options, listType: request.type,
                      openingId: request.documentId, creating: request.creating,
                      reopening: reopeningInSongs)
                .id(request.id)
        }
        // A Songs or Notes quick action, now that the screenplay it settled on
        // is the one on screen. `initial` is what catches the tap that opened
        // this project — that was decided before this view existed — while the
        // change itself catches a tap for the screenplay already open.
        //
        // A project whose links offer no documents drops the request rather
        // than opening an empty sheet; the toolbar hides the button on the
        // same test.
        .onChange(of: openingDocuments, initial: true) { _, requested in
            guard let requested else { return }
            openingDocuments = nil
            guard model.canViewDocuments else { return }
            documentsSheet = requested
        }
        // A song reached from the toolbar menu opens the same editor the songs
        // list would have opened it in — the list is only skipped, not replaced.
        // A cover for the same reason the list is one: skipping the list is a
        // shortcut to the editor, not a smaller version of it.
        .fullScreenCover(item: $openingDocument, onDismiss: {
            // Saving a song re-syncs every place it was already inserted, so
            // the script may have changed while the editor was up; the menu
            // re-orders on the dates the same reload brings back.
            Task {
                await model.loadDocuments()
                await model.loadBlocks()
                repaginate()
            }
        }) { document in
            documentEditor(for: document)
        }
        // Renaming without going back to the list — the same sheet the list
        // raises, on the project already open here.
        .sheet(isPresented: $showingRename) {
            ProjectTitleSheet(title: model.project.title ?? "",
                              heading: "Rename Screenplay",
                              note: renameNote) { title in
                guard let updated = await model.renameProject(to: title) else { return false }
                // This screen's title is right the moment the model adopts it;
                // the list behind it is not, so hand the new resource back.
                await onProjectChanged(updated)
                return true
            }
        }
        .sheet(isPresented: $showingTitlePage) {
            TitlePageView(app: model.app, project: model.project) { updated in
                model.adopt(updated)
                // The name on this bar is now right and the one in the list
                // behind it is not, so hand the new resource back.
                Task { await onProjectChanged(updated) }
            }
        }
        .sheet(isPresented: $showingOutline) {
            ScriptOutlineView(model: model, navigator: navigator, options: options)
        }
        .sheet(isPresented: $showingStats) {
            ScriptStatsView(model: model)
        }
        .sheet(isPresented: $showingIgnoredWords) {
            SpellcheckWordsView()
        }
        .sheet(isPresented: $showingConflicts) {
            SyncConflictsView(conflicts: model.conflicts,
                              keepMine: { await model.keepMine($0) },
                              keepTheirs: { model.keepTheirs($0) },
                              noun: "change")
        }
        // Importing replaces every element, so the picker, its destructive
        // confirmation and the result all live here rather than on the toolbar
        // button — the File menu's ⌘⇧I opens the same picker, focus mode or not.
        .scriptImporter(app: model.app, project: model.project,
                        isPresented: $showingScriptImporter) { updated in
            model.adopt(updated)
            await onProjectChanged(updated)
            await model.loadBlocks()
            await model.refreshUndoRedo()
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    /// The line under the rename field, for the one case where renaming would
    /// otherwise look as though it had done nothing: a screenplay whose title
    /// page names it is headed with *that* title, so the project's own name is
    /// what is being typed here and the bar above will not change. Nil the rest
    /// of the time, where the two are the same thing.
    private var renameNote: String? {
        let screenplay = (model.project.screenplayTitle ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !screenplay.isEmpty else { return nil }
        return "This is the project\u{2019}s own name. The script stays headed "
            + "\u{201C}\(screenplay)\u{201D} — the screenplay title, which the title page sets."
    }

    /// Standing notice that some of what is on screen only exists on this
    /// device. It replaces the alert that a dropped connection used to throw
    /// up on every keystroke: the writing is safe and a retry is already in
    /// flight, so the honest thing to do is say so quietly and keep out of the
    /// way rather than demand a tap before the next word can be typed.
    /// Whether the device has no route to the network. The demo works with no
    /// connection at all, so it never wears the offline label.
    private var isOffline: Bool {
        !model.app.connectivity.isOnline && !model.app.isDemo
    }

    /// What the toolbar cloud says, or nil for the demo — a sample screenplay
    /// that never leaves the device has no cloud to report on, and a slashed
    /// one would read as a fault rather than as the point of the demo.
    ///
    /// Elements written offline are already inside `unsavedBlockIds`, so held
    /// work is one question, not two.
    private var cloudState: CloudSyncState? {
        guard !model.app.isDemo else { return nil }
        // First of all: the other states clear up on their own and this one
        // cannot. A writer who reads "offline" over two versions of their own
        // scene waits for a connection that will not settle anything.
        if model.hasConflicts { return .conflicted }
        if !model.app.connectivity.isOnline { return .offline }
        // Refused beats retrying: with both on screen, the one that will not
        // fix itself is the one the badge must name.
        if model.hasFailedSaves { return .failed }
        // Held notes count too — a note written offline is being carried by
        // this script's sweep even with its sheet long closed.
        return model.hasHeldWork ? .holding : .synced
    }

    /// Which situation the strip is reporting, or nil when there is nothing to
    /// say. Doubles as what a dismissal is *about*: the writer closed this
    /// notice saying this, so a different answer here raises it again.
    ///
    /// The two patient states are named by kind alone — carrying the count
    /// would send the strip back up the screen on the next keystroke, which is
    /// the opposite of having put it down. A refusal is different: another one
    /// arriving is news, and news is worth interrupting for.
    private var heldWorkState: String? {
        if isOffline { return "offline" }
        if model.hasFailedSaves { return "failed:\(model.failedBlockIds.count)" }
        if model.hasUnsavedChanges { return "unsaved" }
        return nil
    }

    /// What the writer's dismissal is filed under — this screenplay's strip,
    /// not every screenplay's.
    private var heldWorkKey: String { "script.held.\(model.project.id)" }

    private func dismissHeldWork() {
        guard let state = heldWorkState else { return }
        withAnimation(.snappy(duration: 0.2)) {
            notices.dismiss(heldWorkKey, state: state)
        }
    }

    @ViewBuilder
    private var unsavedBanner: some View {
        // Elements written offline are counted in `unsavedBlockIds` too, so
        // the number already covers them; they are named separately only when
        // they are the whole of what is held, because "3 elements kept on this
        // device" reads oddly for lines that do not exist anywhere yet.
        let count = model.unsavedBlockIds.count
        let newCount = model.pendingCreateCount
        let noun = { (n: Int) in n == 1 ? "element" : "elements" }
        let held = newCount == count && newCount > 0
            ? "· \(newCount) new \(noun(newCount)) kept on this device"
            : "· \(count) \(noun(count)) kept on this device"
        // Closed by the writer, for exactly what it is saying now. The toolbar
        // cloud carries on reporting the same state in the corner.
        let isClosed = heldWorkState.map { notices.isDismissed(heldWorkKey, state: $0) } ?? true
        if isClosed {
            EmptyView()
        } else if isOffline {
            heldWorkBanner(
                icon: "wifi.slash",
                title: "You're offline",
                detail: count > 0
                    ? held
                    : "— edits are kept on this device and sync when you're back online",
                count: count,
                accessibility: count > 0
                    ? "You're offline. \(count) " + (count == 1 ? "element is" : "elements are")
                      + " kept on this device and will sync when you're back online."
                    : "You're offline. Edits are kept on this device and sync when "
                      + "you're back online.")
        } else if model.hasFailedSaves {
            // Refused, not late: the promise the other two banners make —
            // that patience or a connection will finish the job — would be a
            // lie here, so this one says what happened and what still helps.
            let failedCount = model.failedBlockIds.count
            heldWorkBanner(
                icon: "exclamationmark.triangle",
                title: "Couldn't save",
                detail: "· \(failedCount) \(noun(failedCount)) the server wouldn't take",
                count: count,
                accessibility:
                    "\(failedCount) " + (failedCount == 1 ? "element" : "elements")
                    + " couldn't be saved to the server. Your words are kept on "
                    + "this device; editing the line tries again.",
                tint: .red)
        } else if model.hasUnsavedChanges {
            heldWorkBanner(
                icon: "arrow.trianglehead.2.clockwise.rotate.90",
                title: "Not saved yet",
                detail: held,
                count: count,
                accessibility:
                    "\(count) " + (count == 1 ? "element is" : "elements are")
                    + " not saved to the server yet. Your work is kept on this device "
                    + "and will be saved when the connection returns.")
        }
    }

    /// Two versions of something exist and only the writer can say which one
    /// wins. Its own strip rather than a fourth state of the one below,
    /// because it is not a state of the connection and — alone among these —
    /// it is a thing to press rather than a thing to read.
    @ViewBuilder
    private var conflictBanner: some View {
        if !model.conflicts.isEmpty {
            ConflictBanner(count: model.conflicts.count) { showingConflicts = true }
        }
    }

    /// The one look the banner states share: a quiet strip under the toolbar,
    /// amber for the held states, red for the refused one. Which state is on
    /// it is just words, an icon and the tint.
    private func heldWorkBanner(icon: String, title: String, detail: String,
                                count: Int, accessibility: String,
                                tint: Color = .orange) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
            Text(title)
                .fontWeight(.medium)
            Text(detail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            // Read and understood. The strip goes; the toolbar cloud stays.
            NoticeCloseButton(action: dismissHeldWork)
        }
        .font(.footnote)
        .foregroundStyle(tint)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(tint.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
        // `.ignore` rather than `.combine`: combining swallows the close button
        // whole, leaving VoiceOver a strip it can read but not put down. One
        // element with one named action is what a sighted writer gets too.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
        .accessibilityAction(named: "Dismiss") { dismissHeldWork() }
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.snappy(duration: 0.2), value: count)
    }

    /// Says which edition is open, but only when it is not the default one.
    ///
    /// This started as a suffix on the navigation title and did not survive
    /// contact with an iPad: an inline title shares the bar with eight toolbar
    /// icons, so the edition name — the part that mattered — was the part that
    /// got truncated. A banner has room for the whole name, and being harder to
    /// miss is the point rather than a side effect: a writer who does not
    /// notice they are typing into a revision instead of the shooting draft has
    /// a worse afternoon than one who reads a line of text.
    @ViewBuilder
    private var editionBanner: some View {
        if let edition = editions.selected, !edition.isTheDefault {
            Button {
                showingEditions = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                    Text("Editing")
                        .foregroundStyle(.secondary)
                    Text(edition.displayName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if edition.isThePublished {
                        Text("Published")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.green.opacity(0.15), in: Capsule())
                            .foregroundStyle(.green)
                    }
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
                    // An explicit rule rather than a Divider: Divider takes its
                    // orientation from the surrounding layout, and inside this
                    // overlay it came out vertical — a stray line down the
                    // middle of the banner.
                    Rectangle()
                        .fill(.separator)
                        .frame(height: 0.5)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Editing the \(edition.displayName) edition. Change edition.")
        }
    }

    /// The writing surface: one continuous column you type into.
    private var editor: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    titleHeading

                    ForEach(visibleBlocks) { block in
                        row(for: block)
                            .padding(.horizontal, 24)
                            // The element being read aloud, marked without
                            // moving anything: the wash is inset outwards, so
                            // switching it on cannot reflow the column.
                            .background(alignment: .center) { spotlight(block) }
                            .id(block.id)
                    }
                }
                // Marks the rows as scroll targets, which is what lets the
                // scroll spy below name them. No behaviour is attached, so
                // nothing snaps — the column scrolls exactly as before.
                .scrollTargetLayout()
                .padding(.vertical, 12)
                // Focus mode pulls the column in to a single measure and
                // drops the surrounding chrome, as the web app does.
                .frame(maxWidth: settings.isFocusMode ? 720 : .infinity)
                .frame(maxWidth: .infinity)
            }
            // The caret a double tap asked for, claimed the moment this column
            // is the surface — `initial`, because the tap that asked was made
            // on the reader and this view did not exist to hear it.
            .onChange(of: pendingWriteTarget, initial: true) { _, _ in
                claimWriteTarget()
            }
            // `initial` so a target set while the paper was on screen — the
            // handoff when the writer switches back to the column — is not
            // dropped by a scroll view that did not exist when it was set.
            .onChange(of: navigator.pendingScrollTarget, initial: true) { _, target in
                guard let target else { return }
                let anchor: UnitPoint =
                    navigator.pendingPlacement == .atTop ? .top : .center
                withAnimation { proxy.scrollTo(target, anchor: anchor) }
                // Clearing the target is what lets the same block be jumped
                // to twice in a row.
                navigator.consumeScrollTarget()
            }
            // Follow the voice, as the reader surface does. Centred rather than
            // at the top, because a line read at the very top of the screen
            // has no context above it and the next one is always a jump. The
            // scroll spy drops programmatic moves, so following cannot fold
            // the chrome away.
            .onChange(of: narrator.currentBlockId) { _, id in
                guard let id, isReadingThisScript else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            // Reading is leaving a place too. Focus alone only knows where the
            // writer last *typed*, so a script scrolled through and then closed
            // reopened wherever the cursor had been left, which on a long read
            // is nowhere near. The element at the top of the screen is the
            // honest answer to "where was I", and it is the one restoring puts
            // back at the top — record and restore agree, so reopening twice
            // over lands in the same place rather than creeping up the script.
            .onScrollTargetVisibilityChange(idType: Int.self) { visible in
                // Not until the remembered position has had its turn: the first
                // rows to appear are the top of the script, and recording those
                // would overwrite the very thing being restored.
                guard hasRestoredPosition, let top = visible.first else { return }
                options.rememberBlock(top)
            }
            // Only gestures reach this — the spy drops programmatic jumps, so
            // the outline and the position restore cannot fold the bars away
            // under a writer who never scrolled.
            .onUserScroll(respondToScroll)
            // The system indicator can be watched but not caught. This one is
            // a handle — grab it and the whole script rides under one drag,
            // the way Word's iOS app crosses a long document.
            .draggableScrollThumb()
        }
        .scrollDismissesKeyboard(.interactively)
        // A soft edge lets the writing dissolve into the navigation bar rather
        // than sliding under a hard line — the right treatment for a column of
        // text, where a hard edge cuts a sentence in half mid-scroll.
        .scrollEdgeEffectStyle(.soft, for: .top)
        .overlay { emptyState }
        // Each writing bar is mounted with `.safeAreaBar`, so the three stack
        // as Liquid Glass strips over the script instead of opaque slabs.
        .safeAreaBar(edge: .bottom) { editingBars }
        .safeAreaBar(edge: .bottom) { searchBar }
        .safeAreaBar(edge: .bottom) { bulkBar }
    }

    /// The screenplay's name at the head of the column, set the way the reader
    /// heads its own page: centred, in caps, in the script's own face.
    ///
    /// The writing surface used to carry the title only in the navigation bar,
    /// so leaving reading mode dropped it off the page — the same document,
    /// headed on one surface and bare on the other, with the position handed
    /// across between them. It is the same heading on both now, so switching
    /// modes moves the words under it and nothing else.
    ///
    /// Tapping it types over it, which is what a click of the title does in
    /// the web header. Set through `ScriptTitleType`, which is where the reader
    /// gets its own heading: the face and the size are the screen's one answer
    /// rather than each surface's, so the name does not change when the mode
    /// does.
    @ViewBuilder
    private var titleHeading: some View {
        let name = model.project.displayTitle
        Group {
            if isRetitling {
                TextField("Title", text: $titleDraft)
                    .focused($titleFieldFocused)
                    .multilineTextAlignment(.center)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    // Return in a title means "that's the name", not a second
                    // line: a screenplay is headed with one.
                    .onSubmit { commitRetitle() }
                    .accessibilityLabel("Screenplay title")
            } else {
                Text(name.uppercased())
                    .frame(maxWidth: .infinity, alignment: .center)
                    // The whole line rather than the glyphs: a title is a
                    // small target sitting in the middle of a wide column.
                    .contentShape(.rect)
                    .onTapGesture { beginRetitling() }
                    // Spoken as it is stored. The capitals are typesetting —
                    // a title page sets a title in caps — and VoiceOver
                    // spelling them out letter by letter is not the title.
                    .accessibilityLabel(name)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityAction(named: "Rename") { beginRetitling() }
            }
        }
        .font(ScriptTitleType.font(scale: textScale))
        .padding(.horizontal, 24)
        .padding(.bottom, ScriptTitleType.gap(scale: textScale))
        // The name lands as it is typed, a beat after typing stops, exactly as
        // a note's title does. Deliberately not left to the field losing focus:
        // this screen's elements are UIKit text views that take first responder
        // for themselves, and SwiftUI's focus engine stops agreeing with UIKit
        // about who holds it the moment one of them has — the same disagreement
        // `SoftwareKeyboard` exists for. A rename that depended on being told
        // the caret had left would be a rename that sometimes never happened.
        .onChange(of: titleDraft) { _, _ in scheduleRetitle() }
        // Three ways to be finished, because no one of them can be relied on
        // here. The caret leaving is the honest signal where SwiftUI still
        // knows where the caret is. The software keyboard going away covers
        // the case where it does not — but says nothing on a device with a
        // hardware keyboard, where there is no software keyboard to go. Return
        // covers that one. Whichever arrives first ends it; the rest find
        // `isRetitling` already false and do nothing.
        .onChange(of: titleFieldFocused) { _, focused in
            guard !focused, isRetitling else { return }
            commitRetitle()
        }
        .onChange(of: SoftwareKeyboard.shared.isVisible) { _, visible in
            guard !visible, isRetitling else { return }
            commitRetitle()
        }
        // The reader draws a heading of its own, so an edit still open when
        // the mode changes has nowhere left to be finished.
        .onChange(of: isReading) { _, reading in
            guard reading, isRetitling else { return }
            commitRetitle()
        }
    }

    /// What is actually stored behind the heading — the screenplay title where
    /// the title page sets one, else the project's name. Empty where the
    /// project has neither, so an untitled screenplay opens the field on its
    /// placeholder rather than on the words "Untitled Project", which nobody
    /// typed and nobody wants to delete before typing.
    private var headingSourceTitle: String {
        let screenplay = (model.project.screenplayTitle ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !screenplay.isEmpty { return screenplay }
        return (model.project.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Puts the caret in the heading. Gated on the same `update` link the
    /// menu's Rename is, so a reader's tap does nothing rather than opening a
    /// field whose contents the server would refuse.
    private func beginRetitling() {
        guard model.canRenameProject else { return }
        // The stored name, not the capitals on screen — those are how a title
        // page is set, and handing them back would have every rename shout.
        titleDraft = headingSourceTitle
        isRetitling = true
        titleFieldFocused = true
    }

    /// Arms the debounce. Long enough that a name still being typed — "The
    /// Long", on its way to "The Long Way Home" — is not filed as one, and the
    /// same wait a note's title takes.
    private func scheduleRetitle() {
        guard isRetitling else { return }
        retitleSave?.cancel()
        retitleSave = Task {
            try? await Task.sleep(for: Self.retitleDelay)
            guard !Task.isCancelled else { return }
            await sendRetitle()
        }
    }

    /// Finishes: the heading goes back to being a heading, and whatever was
    /// typed goes now rather than waiting out the debounce.
    private func commitRetitle() {
        isRetitling = false
        titleFieldFocused = false
        retitleSave?.cancel()
        Task { await sendRetitle() }
    }

    /// Sends the typed name.
    ///
    /// A blank field is a rename to nothing, which the server refuses and which
    /// no writer means: it is left alone rather than reported. So is a name
    /// typed back to what it already was — there is nothing to say.
    private func sendRetitle() async {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != headingSourceTitle else { return }
        guard let updated = await model.retitleScreenplay(to: trimmed) else { return }
        // This screen is right the moment the model adopts it; the list behind
        // it is not, so hand the new resource back.
        await onProjectChanged(updated)
    }

    /// Answers this screen works out once and then reuses for the rest of the
    /// redraw — and across redraws, while nothing they depend on has moved.
    ///
    /// A class held in `@State` rather than a static. Body may not write view
    /// state, but mutating a property of a class *instance* does not write the
    /// `@State` value — the reference is unchanged — so body may do this. The
    /// static this replaces was one slot for the whole process: two windows on
    /// two projects thrashed it to a zero hit rate, and the last script's
    /// entire `[Block]` was retained until the app quit, long after the project
    /// was closed and the account signed out.
    ///
    /// Deliberately not `@Observable`. It has to be invisible to SwiftUI, or
    /// every memo write would invalidate the body that wrote it.
    @MainActor private final class ScriptViewMemo {
        var wordCount: (blocks: [Block], showsNotes: Bool, outlineMode: Bool, words: Int)?
        var visible: (blocks: [Block], showsNotes: Bool, outlineMode: Bool, result: [Block])?
    }

    /// Word-splitting every element on every body evaluation is real work on a
    /// feature-length script, and the bar redraws with the rest of the view —
    /// every toast, every commit. Cached against the inputs that can change
    /// the answer; comparing `[Block]` hits the identity fast-path between
    /// reloads (the array's storage is untouched by typing, which writes
    /// `liveText`), so the check is O(1) per redraw. Don't "optimise" that
    /// into a hash — hashing the script is the work being avoided.
    private var memoizedWordCount: Int {
        if let cached = memo.wordCount,
           cached.blocks == model.blocks,
           cached.showsNotes == options.showsNotes,
           cached.outlineMode == settings.isOutlineMode {
            return cached.words
        }
        let words = ScriptWordCount.total(in: visibleBlocks)
        memo.wordCount = (model.blocks, options.showsNotes, settings.isOutlineMode, words)
        return words
    }

    /// The elements the writer has asked to see.
    ///
    /// Two independent narrowings. Notes can be hidden because they are
    /// annotations on the script rather than part of it. Outline mode goes much
    /// further and keeps only the story's skeleton — and it wins outright, since
    /// a note is not a scene, a section or a synopsis.
    ///
    /// Memoized on the same terms as the word count above, and for a sharper
    /// reason: the body reads this three or four times a pass — the editor's
    /// `ForEach`, the marks gutter, the word count, the selectable set — and
    /// repagination reads it again.
    private var visibleBlocks: [Block] {
        if let cached = memo.visible,
           cached.blocks == model.blocks,
           cached.showsNotes == options.showsNotes,
           cached.outlineMode == settings.isOutlineMode {
            return cached.result
        }
        let result: [Block]
        if settings.isOutlineMode {
            let outline = Set(BlockType.outlineTypes)
            result = model.blocks.filter { outline.contains($0.blockType) }
        } else if options.showsNotes {
            result = model.blocks
        } else {
            result = model.blocks.filter { $0.blockType != .note }
        }
        memo.visible = (model.blocks, options.showsNotes, settings.isOutlineMode, result)
        return result
    }

    /// The type size everything on this screen is set at, as a multiplier: the
    /// writer's own control and the system's Dynamic Type setting together.
    ///
    /// One value for every surface. The reader used to fold Dynamic Type in and
    /// the writing column ignored it, so at any OS text size but the default the
    /// two were set in different type — and text that is set differently cannot
    /// land in the same place however carefully the column is measured. Folding
    /// it in as a multiplier is safe for the column too, because the measure is
    /// resolved against it below: the type grows and the column grows with it,
    /// leaving the same characters to the line.
    private var textScale: CGFloat {
        CGFloat(settings.textScale) * dynamicTypeScale
    }

    /// What the rows should draw and where they should sit, gathered from the
    /// project's view options and the room the window has. Read by the writing
    /// column and by the reading surface alike — see `ScriptRowChrome`.
    private var rowChrome: ScriptRowChrome {
        var chrome = ScriptRowChrome()
        chrome.showsPins = options.showsPins
        chrome.showsBookmarks = options.showsBookmarks
        chrome.showsElementLabels = options.showsElementLabels
        chrome.scale = textScale
        // Separately from `scale`, and only the element labels read it — see
        // `ScriptRowChrome.dynamicTypeScale`.
        chrome.dynamicTypeScale = dynamicTypeScale
        chrome.columnWidth = ScriptRowChrome.printedMeasure * textScale
        guard availableWidth > 0, textScale > 0 else { return chrome }
        // Each row is padded by 24 either side, so that much of the window was
        // never the column's to use.
        let usable = availableWidth - 48

        // A window narrower than the printed measure — a phone, a split-view
        // slice — gives the column what room it has. Without this the 640pt
        // column overhangs the screen, and the speech boxes measured against it
        // come out wider than the window itself: dialogue then renders full
        // bleed, indistinguishable from action.
        //
        // Resolved at 100% type and scaled back up, so growing the type grows
        // the column with it rather than re-wrapping the script into a narrower
        // and narrower page — a measure is a count of characters before it is a
        // width. The `min` against `usable` is the floor case: a phone at the
        // largest type cannot pay for even the minimum measure, and text that
        // runs off the screen would be worse than text set small.
        let measure = min(ScriptRowChrome.printedMeasure, max(280, usable / textScale))
        chrome.columnWidth = min(measure * textScale, usable)

        // Full width is a request for the window rather than for a measure, so
        // it takes the room the window has and the type grows inside it. The
        // marks still sit in the margin beyond the column, so it leaves them
        // theirs rather than running the text underneath them.
        if settings.isFullWidth {
            chrome.columnWidth = max(320, usable - BlockMarkerBadges.gutter)
        }

        // Both margins now have something in them: the element labels hang off
        // the left of the column, the marks off the right. Where the centred
        // column already leaves margin enough, they live in it and the page
        // stays centred. Where it doesn't — a phone, a split-view slice — the
        // column gives up exactly the room they need, because a lopsided page
        // is better than a label printed over a scene heading or an action line
        // running under a bookmark.
        let leading = options.showsElementLabels
            ? ElementLabelTag.gutter(scale: dynamicTypeScale) : 0
        let trailing = hasVisibleMarks ? BlockMarkerBadges.gutter : 0
        let margin = (usable - chrome.columnWidth) / 2
        if margin >= max(leading, trailing) {
            // Room enough already: the marks sit in the margin the centred
            // column leaves, and the same room on the left keeps the page where
            // it was rather than nudging it off centre.
            chrome.leadingGutter = min(BlockMarkerBadges.gutter, margin)
            chrome.trailingGutter = chrome.leadingGutter
        } else {
            // Not room enough: the column gives it up — but never so much that
            // there is nothing left to write in, so a window that cannot pay
            // for both margins hands each a share of what it has.
            let wanted = leading + trailing
            let affordable = min(wanted, max(0, usable - 280))
            let share = wanted > 0 ? affordable / wanted : 0
            chrome.leadingGutter = leading * share
            chrome.trailingGutter = trailing * share
            chrome.columnWidth = usable - chrome.leadingGutter - chrome.trailingGutter
        }
        return chrome
    }

    /// Whether anything on screen is marked at all — usually nothing is. Most
    /// scripts carry a handful of marks and plenty carry none, and an empty
    /// gutter is column width thrown away, so the room is only taken once there
    /// is something to put in it.
    private var hasVisibleMarks: Bool {
        if !model.commentCounts.isEmpty { return true }
        return visibleBlocks.contains {
            ($0.isPinned && options.showsPins) || ($0.isBookmarked && options.showsBookmarks)
        }
    }

    /// Songs and Notes, where a phone can actually reach them.
    ///
    /// The toolbar is where these belong and where the iPad and the Mac keep
    /// them, but a phone's bar has no room: it draws three trailing controls,
    /// the "…" takes one of the three, and the View menu and Add Element take
    /// the other two. Every arrangement tried put Songs and Notes back in the
    /// overflow — which is the very thing wrong with them today, and no number
    /// of demotions elsewhere fixes it, because the bar's budget is the title's
    /// leftovers rather than a count of items.
    ///
    /// So they come down here, under the thumb instead of in the corner
    /// furthest from it. Icon-only, matching the toolbar the iPad and Mac
    /// keep them in — the titles stay on the `Label`s, where VoiceOver still
    /// reads them. Buttons in a `.safeAreaBar` rather than `.bottomBar`
    /// toolbar items for the reason `ProjectsSidebarView.newProjectBar`
    /// records: a bar item built from a `Label` shows the glyph and drops
    /// the title, even under `.titleAndIcon`.
    ///
    /// It draws no background of its own — the `.safeAreaBar` already floats it
    /// on Liquid Glass, and a fill under that flattens the glass into a slab.
    ///
    /// Read Aloud is drawn here rather than in the bar proper. It had a toolbar
    /// button beside Search and Outline, which on a phone was always the
    /// overflow's — the very menu this bar exists to keep things out of — and
    /// on an iPad or a Mac was a second door onto what the View menu's ⌘⇧A
    /// already opens. Listening is also the posture this bar suits best: a
    /// thumb on the bottom edge, not a reach for the corner.
    ///
    /// The same button is also named in the "…" (see `toolbar`), which is not
    /// the slot-costing toolbar button that was removed: this bar is
    /// compact-only and folds with the chrome, so every width and posture it
    /// does not cover had nowhere to start a reading from at all.
    @ViewBuilder
    private var documentsBar: some View {
        // Not while elements are being selected: the selection bar already
        // takes two rows of the phone's bottom edge, and songs, notes, and
        // listening are exactly the errand the writer is not on.
        if isCompact && !isChromeHidden && !settings.isFocusMode
            && (isReadyToEdit || model.canViewDocuments || model.hasScriptContent)
            && !selection.isSelecting {
            HStack(spacing: 8) {
                // The way out of the reader, down here for the reason
                // everything else in this bar is: measured on a 402pt iPhone,
                // the trailing side of the navigation bar draws one control
                // beside the "…", and the View menu is that control. Edit was
                // put in the View menu's own capsule to try to buy the slot and
                // the bar collapsed it anyway — so on a phone the toolbar's
                // Edit is only ever the overflow's, two taps deep, which is no
                // way to offer the one thing a reader most needs.
                //
                // Titled and filled, alone among these: the others are
                // errands a writer goes looking for, and this one is the door
                // back into their own screenplay. It leads the row because
                // that is where the eye starts, and because the icon-only
                // trio beside it reads as a set it does not belong to.
                if isReadyToEdit {
                    Button {
                        setReading(false)
                    } label: {
                        Label("Edit", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.borderedProminent)
                    .labelStyle(.titleAndIcon)
                } else if isReadyToRead {
                    // The way back to the reader, in the slot Edit vacates, so
                    // the head of this row is always the one tap to the other
                    // surface. On a phone the toolbar's own copy is the
                    // overflow's — the same measurement that put Edit down here
                    // — and a mode a writer swaps in and out of while working
                    // is the last thing that should cost a menu each way.
                    //
                    // Icon-only and plain, unlike Edit: this one is an errand
                    // like the three beside it, where Edit is a reader's door
                    // into their own screenplay. The title stays on the `Label`
                    // for VoiceOver.
                    Button {
                        setReading(true)
                    } label: {
                        Label("Read Script", systemImage: "book")
                    }
                }
                if model.canViewDocuments {
                    songsButton
                    notesButton
                }
                if model.hasScriptContent {
                    readAloudButton
                    // Beside listening because it is the other thing a reader
                    // reaches for: the reader runs continuously, and "how long
                    // is this, and where do the pages fall" is a question it
                    // deliberately cannot answer — page view is the surface
                    // that can. Reaching it meant the View menu in the far
                    // corner, which on a phone is the one control the bar
                    // draws beside the "…", so the paper was two taps and a
                    // scan of a fourteen-item menu away from the posture that
                    // most wants it.
                    //
                    // Drawn while reading, and while the paper it opened is
                    // up — that second half is the way back. It stays out of
                    // the writing posture's bar entirely: a writer has the
                    // View menu's toggle and ⌘⇧P, and the bottom bar is
                    // already the fullest thing on the screen.
                    if isReading || paperCameFromReader {
                        pageViewButton
                    }
                }
            }
            .buttonStyle(.bordered)
            .labelStyle(.iconOnly)
            .padding(.vertical, 4)
        }
    }

    /// Whether the script is up to be read and there is somewhere to type —
    /// which is exactly when an Edit button is worth drawing.
    private var isReadyToEdit: Bool { isReading && canEditScript }

    /// The mirror of it: the writing surface is up and there is something on it
    /// to read, which is exactly when a Read Script button is worth drawing.
    ///
    /// Ungated by `canEditScript` — reading is nobody's privilege, and a reader
    /// who stepped out onto the locked column needs the way back most of all.
    /// Gated by focus mode, though, where the Edit button is not: that mode
    /// keeps what a writer needs to get back to writing, and the reader is
    /// somewhere to go rather than a way back. The View menu, which stays,
    /// carries the toggle for the writer who wants it from in there.
    private var isReadyToRead: Bool {
        !isReading && model.hasScriptContent && !settings.isFocusMode
    }

    /// How wide this pane has to be before the navigation bar can draw every
    /// control at once — the View capsule, the seven-strong action capsule,
    /// the songs-and-notes pair, and a title.
    ///
    /// Measured rather than reasoned: on a 13" iPad with the projects sidebar
    /// open this pane is about 700pt and the bar came up one control short,
    /// where the same iPad with the sidebar away has 1032pt and draws them
    /// all. 900 sits between the two, and above an 11" iPad held upright —
    /// which has a little more room than the narrow case but not enough of it
    /// to trust.
    private static let fullToolbarWidth: CGFloat = 900

    /// Whether the bar has the room for its full hand.
    ///
    /// Regular width is not the same as room — the trap `BulkActionBar`
    /// already records for the selection bar. With the sidebar open, the bar
    /// ran out of room and iOS truncated it from the trailing end, which took
    /// *Notes* out of the pair it is drawn as half of and left it reachable
    /// only under the "…". Nothing said so: a toolbar that overflows looks
    /// exactly like a toolbar that was built that way.
    ///
    /// So the choice of what to lose is made here instead of by the system —
    /// see `toolbar`, where Print is what steps back.
    ///
    /// Zero until the first layout, which counts as "no room": the bar can
    /// then only gain a control as the measure arrives, never drop one.
    private var hasRoomForFullToolbar: Bool {
        availableWidth >= Self.fullToolbarWidth
    }

    /// How long the script is, while it is being written.
    ///
    /// Off until asked for, as in the web app — a word count in the corner is
    /// either exactly what a writer on a deadline wants or the last thing they
    /// want to be looking at.
    @ViewBuilder
    private var wordCountBar: some View {
        // Folded away with the rest of the chrome while the script is being
        // scrolled through: the count is a readout, not a control, and reading
        // room is the whole point of the fold.
        if settings.showsWordCount && !isChromeHidden {
            let words = memoizedWordCount
            WordCountBar(words: words, detail: pageReadout(words: words))
        }
    }

    /// The page view has really laid the script out, so it reports what it
    /// found; the editor has not, and says so with a tilde. The web draws the
    /// same distinction for the same reason.
    private func pageReadout(words: Int) -> String {
        if settings.isPageView && !pages.isEmpty {
            return pages.count == 1 ? "1 page" : "\(pages.count) pages"
        }
        return "~\(ScriptWordCount.pageEstimate(words: words)) pages"
    }

    /// Folds the chrome away while the script is scrolled down through, and
    /// brings it back the moment the direction turns — how Word's iOS app
    /// treats its ribbon, and for the same reason: on a phone the bars are a
    /// real share of the page, and someone scrolling is reading, not reaching
    /// for a control.
    ///
    /// Compact widths only. A full-size iPad has room to keep its toolbar —
    /// Word keeps its ribbon there too — and the toolbar is where that layout
    /// keeps Songs and Notes, which have no bottom bar to fall back to.
    private func respondToScroll(delta: CGFloat, fromTop: CGFloat) {
        guard isCompact else { return }
        // The top of the script is home: the bars are always dressed there,
        // whichever direction the last gesture moved.
        if fromTop < 32 {
            scrollRun = 0
            setChrome(hidden: false)
            return
        }
        guard delta != 0 else { return }
        if (delta > 0) != (scrollRun > 0) { scrollRun = 0 }
        scrollRun += delta
        // Asymmetric on purpose: folding away takes a real pull down, coming
        // back should cost barely more than the thought.
        if scrollRun > 60 {
            setChrome(hidden: true)
        } else if scrollRun < -20 {
            setChrome(hidden: false)
        }
    }

    private func setChrome(hidden: Bool) {
        guard isChromeHidden != hidden else { return }
        withAnimation(.easeInOut(duration: 0.22)) { isChromeHidden = hidden }
    }

    @ViewBuilder
    private var bulkBar: some View {
        if selection.isSelecting {
            BulkActionBar(model: model,
                          selection: selection,
                          selectableIds: selectableIds,
                          isFiltered: isSearchNarrowingSelection,
                          isCompact: isCompact)
        }
    }

    /// A live search narrows what select-all means, matching the web app,
    /// where selecting all while filtered selects only the rows on screen.
    private var isSearchNarrowingSelection: Bool {
        isSearching && search.hasQuery && search.hasMatches
    }

    /// Selecting all reaches the search hits while a search is running and the
    /// whole script otherwise. A query that matches nothing deliberately
    /// leaves the set empty rather than silently selecting everything.
    private var selectableIds: [Int] {
        // Hidden notes are off the table too: selecting all should never reach
        // an element the writer cannot see.
        guard isSearching && search.hasQuery else { return visibleBlocks.map(\.id) }
        let hits = Set(search.matches.map(\.blockId))
        return visibleBlocks.map(\.id).filter { hits.contains($0) }
    }

    /// The reading surface: the script without its chrome, in place of the
    /// column. It borrows this screen's narrator for the spotlight and its
    /// navigator for outline jumps, and trades positions through the same
    /// remembered element the column and the paper trade through.
    private var reader: some View {
        ReadScriptView(
            title: model.project.displayTitle,
            blocks: model.blocks,
            narrator: narrator,
            isLoading: model.isLoading,
            navigator: navigator,
            initialBlockId: options.rememberedBlockId,
            onTopVisibleBlock: { options.rememberBlock($0) },
            onEdit: isReadyToEdit ? { startWriting(atBlockId: $0) } : nil,
            onReadFrom: { id in
                narrator.prepare(.script(model.blocks),
                                 subject: narrationSubject,
                                 title: model.project.displayTitle)
                narrator.play(from: id)
            },
            onUserScroll: respondToScroll)
    }

    /// Puts the script up for reading, or hands it back to the writer, and —
    /// unless told otherwise — records which way it was put.
    ///
    /// Every route a writer can take between the two goes through here: the
    /// Edit button, the View menu's Read Script toggle and the menu bar's
    /// ⌘⇧R. What is remembered is a *choice*, which is why the two callers
    /// that are not one pass `remember: false` — leaving the reader because
    /// paper was asked for, and leaving it because the script turned out to be
    /// empty, are both this view getting out of the way rather than the writer
    /// saying how the script should open next time.
    private func setReading(_ reading: Bool, remember: Bool = true) {
        guard isReading != reading else { return }
        isReading = reading
        // Paper comes down with it. Page View is a posture of its own and the
        // reader covers it whole, so leaving it selected underneath means a
        // ticked menu item describing a surface nobody can see — and then a
        // script that drops back onto paper when the reading ends, which is
        // not what someone who tapped Edit was asking for. Off rather than
        // suspended, for the same reason outline mode clears it: the writer
        // asked for a different way to look at the script.
        if reading { settings.isPageView = false }
        guard remember else { return }
        readingViews.remember(reading, for: .screenplay(project: model.project.id))
    }

    /// Hands an empty screenplay straight to the writer.
    ///
    /// Whether there is anything to read is the one part of the opening
    /// decision the init cannot make, since the elements arrive later. A new
    /// project opening into "Nothing to Read" — with Start Writing sitting
    /// unreachable on the surface underneath — would be the reader at its
    /// least useful, so the script comes back the moment the load says there
    /// is nothing in it. Not remembered: the project has said nothing about
    /// how it wants to open, and once it has a scene in it the answer changes.
    private func leaveEmptyReader() {
        guard isReading, !model.isLoading, !model.hasScriptContent else { return }
        setReading(false, remember: false)
    }

    /// The paper surface: read-only sheets with a pager.
    private var pageView: some View {
        ScrollViewReader { proxy in
            ScreenplayPageView(
                pages: pages,
                cover: ScreenplayCover(project: model.project),
                setup: settings.pageSetup,
                zoomScale: settings.zoomScale,
                isFitToWidth: settings.isPageZoomFit,
                onVisiblePageChanged: { page in
                    currentPage = page
                    rememberPagePosition(page)
                },
                onFitZoomChanged: { settings.fitZoom = $0 },
                onUserScroll: respondToScroll)
            .onChange(of: pendingPageTarget, initial: true) { _, page in
                guard let page else { return }
                proxy.scrollTo(page, anchor: .top)
                pendingPageTarget = nil
            }
            // The paper follows the voice by the sheet: no per-element
            // highlight here — the pages draw themselves — but the page being
            // read is the one on screen.
            .onChange(of: narrator.currentBlockId) { _, id in
                guard let id, isReadingThisScript,
                      let page = ScriptPagination.page(containing: id, in: pages),
                      page != currentPage else { return }
                currentPage = page
                withAnimation { proxy.scrollTo(page, anchor: .top) }
            }
            .overlay(alignment: .bottom) {
                if pages.count > 0 {
                    PageNavigatorBar(
                        settings: settings,
                        pageCount: pages.count,
                        currentPage: $currentPage) { page in
                            withAnimation { proxy.scrollTo(page, anchor: .top) }
                        }
                }
            }
            .overlay { pageEmptyState }
        }
    }

    @ViewBuilder
    private var pageEmptyState: some View {
        if pages.isEmpty {
            // A script still on its way has no pages either, and saying it has
            // no elements over one that is loading is simply wrong — the
            // writing column and the reader both check this first.
            if model.isLoading {
                ProgressView()
            } else {
                ContentUnavailableView(
                    "Nothing to Paginate",
                    systemImage: "doc.richtext",
                    description: Text("This script has no elements yet."))
            }
        }
    }

    /// Scrolls to the element the writer left off at, once, the first time a
    /// script arrives.
    ///
    /// Driven off the blocks landing rather than off `.task`, because the
    /// remembered edition loads a second time and the position belongs to
    /// whichever script ends up on screen. An element that has since been
    /// deleted is not found and the script simply opens at the top.
    private func restoreRememberedPosition() {
        guard !hasRestoredPosition, !model.blocks.isEmpty else { return }
        guard let id = options.rememberedBlockId else {
            hasRestoredPosition = true
            return
        }
        // Not found yet is not the same as gone: when a remembered edition is
        // being reopened the default's elements land first, and the element
        // being looked for belongs to the script still on its way. Leaving the
        // flag unset lets the next arrival try again. An element that really
        // was deleted is never found, so this quietly stops mattering.
        guard model.blocks.contains(where: { $0.id == id }) else { return }
        hasRestoredPosition = true
        scroll(toRemembered: id)
    }

    /// Sends whichever surface is on screen to a remembered element: the column
    /// scrolls the row to the top, the paper opens the sheet that element is
    /// printed on.
    ///
    /// The column route goes through the navigator so it is the same scroll the
    /// outline and search already do — only the placement differs, since the
    /// element recorded was the one at the top of the screen and that is where
    /// it belongs on the way back.
    private func scroll(toRemembered id: Int) {
        guard settings.isPageView else {
            navigator.jump(to: id, placement: .atTop)
            return
        }
        // Notes and outline scaffolding are never printed, so an element
        // remembered from the column may be on no sheet at all. Nothing to do
        // then: the paper opens at page one, as it did before.
        guard let page = ScriptPagination.page(containing: id, in: pages) else { return }
        currentPage = page
        pendingPageTarget = page
    }

    /// Records where the paper is being read, in the same element ids the column
    /// records — so the two surfaces hand the position back and forth rather
    /// than each keeping a place of its own.
    private func rememberPagePosition(_ page: Int) {
        guard hasRestoredPosition,
              let id = ScriptPagination.firstBlockId(onPage: page, in: pages) else { return }
        options.rememberBlock(id)
    }

    // MARK: - Reading aloud

    /// Starts the script reading itself out loud, right here — no sheet, no
    /// second screen: the transport bar comes up at the bottom and the column
    /// follows the voice. Reaching for it while a reading runs pauses and
    /// resumes, so the one menu item is the whole errand.
    private func toggleReadAloud() {
        if narrator.isActive && isReadingThisScript {
            narrator.togglePlayPause()
            return
        }
        // Whatever else was being read — a song opened from this very screen,
        // say — this hands the voice to the script. `prepare` ends the other
        // reading itself, since the device has one voice.
        narrator.prepare(.script(model.blocks),
                         subject: narrationSubject,
                         title: model.project.displayTitle)
        if let id = readAloudStart {
            narrator.play(atOrAfter: id)
        } else {
            narrator.play()
        }
    }

    /// Where a reading should begin: the element being typed into if there is
    /// one, otherwise the element at the top of the screen — the same answer
    /// the position restore gives to "where was I". Nil means the top, which
    /// is where a script nobody has a place in should start.
    private var readAloudStart: Int? {
        if let id = model.focusedBlockId,
           model.blocks.contains(where: { $0.id == id }) { return id }
        if let id = options.rememberedBlockId,
           model.blocks.contains(where: { $0.id == id }) { return id }
        return nil
    }

    /// What the narrator calls this screenplay while it reads it.
    private var narrationSubject: NarrationSubject {
        .script(project: model.project.id)
    }

    /// Whether the voice on the device is reading *this* script.
    ///
    /// The narrator is shared with the song and note editors, which open over
    /// this screen — so "a reading is running" is no longer the same question
    /// as "my reading is running". Everything this screen shows about a reading
    /// hangs off this, element ids most of all: a song's line ids and a script's
    /// element ids are different numbering entirely, and a spotlight drawn from
    /// the wrong run would light up an arbitrary line of the screenplay.
    private var isReadingThisScript: Bool {
        narrator.subject == narrationSubject
    }

    /// The read-aloud transport, up only while a reading is loaded. It rides
    /// this screen rather than a sheet, so listening leaves the script — and
    /// the writing — exactly where they were.
    @ViewBuilder
    private var narrationBar: some View {
        if narrator.isActive && isReadingThisScript {
            NarrationTransportBar(narrator: narrator)
        }
    }

    /// The element being read, marked without moving anything: the wash is
    /// inset outwards so switching it on cannot reflow the column.
    @ViewBuilder
    private func spotlight(_ block: Block) -> some View {
        if isReadingThisScript && narrator.currentBlockId == block.id {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.16))
                .padding(.horizontal, -10)
                .padding(.vertical, -2)
        }
    }

    /// Republishes this screenplay's half of the Bookmarks widget.
    ///
    /// Every call is cheap when nothing changed — the store compares what it
    /// would write against what is already there and declines to spend a
    /// WidgetKit reload — which is what makes it safe to hang off a change as
    /// frequent as the elements landing.
    private func publishBookmarks() {
        BookmarksWidgetPublisher.publish(model.blocks, project: model.project,
                                         isEphemeralDemo: model.app.isEphemeralDemo)
    }

    /// Takes down the element a tapped Bookmarks row asked for, and jumps to it
    /// if the script is already in hand.
    ///
    /// Both halves are needed: a tap that opened this screenplay arrives before
    /// its elements do, and a tap for the screenplay already on screen arrives
    /// after — and nothing else would fire in that second case, since the
    /// elements do not change for it.
    private func receiveBookmarkRequest(_ blockId: Int) {
        pendingBookmarkBlockId = blockId
        openPendingBookmark()
    }

    /// Scrolls to the flagged element a widget row named, once its script has
    /// arrived.
    ///
    /// The same shape as `restoreRememberedPosition`, and for the same reason:
    /// not found yet is not the same as gone, so an element still on its way
    /// (a remembered edition loading second) leaves the request standing and
    /// tries again on the next arrival. An element really deleted is never
    /// found, and the screenplay simply opens where it otherwise would.
    ///
    /// Where it differs is that this outranks the remembered position: the
    /// writer asked for this line by tapping it, so the flag is set even though
    /// the restore never ran.
    private func openPendingBookmark() {
        guard let id = pendingBookmarkBlockId,
              model.blocks.contains(where: { $0.id == id })
        else { return }
        pendingBookmarkBlockId = nil
        hasRestoredPosition = true
        navigator.jump(to: id)
    }

    /// Puts the writer back in the edition they were last reading, which is
    /// what the web's `project/show` does by redirecting to the remembered
    /// `editionId`.
    ///
    /// Only ever loads a *non-default* edition: the default's elements are
    /// already on screen from the opening load, so restoring it would be a
    /// second round trip for the same script. An edition the server has since
    /// dropped is not found and the default simply stays.
    private func reopenRememberedEdition() async {
        guard let id = options.rememberedEditionId,
              let edition = editions.edition(withId: id),
              !edition.isTheDefault,
              let link = editions.blocksLink(for: edition) else { return }
        editions.selectedId = edition.id
        model.editionBlocksLink = link
        await model.refreshUndoRedo()
        repaginate()
    }

    /// Which screen is open over the script, as the restore record spells it.
    ///
    /// Outermost first, and only the screens a writer works in — the reader, the
    /// stats and the administrative sheets are left out on purpose, since
    /// reopening onto one of those would answer a question that was closed when
    /// the app was. Every one of these is presented from this view, so at most
    /// one of them can be up; the order below only settles which wins if two
    /// flags were ever set in the same turn.
    private var openEditor: OpenEditor? {
        if let openingDocument { return .document(id: openingDocument.id, uid: openingDocument.uid) }
        if let documentsSheet { return .songsAndNotes(documentsSheet.type) }
        if showingCharacters { return .characters }
        if showingOutline { return .outline }
        if showingTitlePage { return .titlePage }
        return nil
    }

    /// Reopens the screen the writer was in when they last put the app down.
    ///
    /// The record is claimed rather than read, so this happens once per launch
    /// and for the remembered project only — switching scripts is not an
    /// invitation to reopen the last one's songs. Every case is gated the way the
    /// toolbar gates the button that opens it: a project whose links no longer
    /// offer songs, or a script since emptied, reopens onto the script itself
    /// rather than onto a screen with nothing on it. The throwaway demo is left
    /// out for the same reason it keeps no record — it is a walkthrough, not
    /// someone's place. A signed-out device is someone's place, and gets this.
    private func reopenRememberedEditor() {
        guard !model.app.isEphemeralDemo else { return }
        let path = openEditors.claimReopenPath(forProject: model.project.id,
                                               in: model.app.workspaceScope)
        // Claimed either way, then dropped if a Home Screen quick action has
        // already opened something: tapping Songs is someone asking for the
        // songs now, which outranks where they happened to be last night — and
        // the restore is spent rather than left to fire over them later.
        guard openEditor == nil, let screen = path.first else { return }
        switch screen {
        case .songsAndNotes(let type):
            guard model.canViewDocuments else { return }
            // Whatever was open on top of the list travels with it, so a song
            // editor two screens deep comes back with its list underneath.
            // Seeded before the request, because presenting the sheet is what
            // reads it.
            reopeningInSongs = Array(path.dropFirst())
            documentsSheet = DocumentsRequest(type: type)
        case .document(let id, let uid):
            // A song deleted since is not found, and the script simply opens
            // without it.
            guard let document = model.documents.rememberedOne(id: id, uid: uid) else { return }
            openingDocument = document
        case .characters:
            guard model.canViewCharacters else { return }
            showingCharacters = true
        case .outline:
            guard model.hasScriptContent else { return }
            showingOutline = true
        case .titlePage:
            showingTitlePage = true
        case .songWorkspace:
            // Only ever reached through the songs list, so it is never the
            // outermost screen and there is nothing to open here.
            break
        }
    }

    /// Pagination walks the whole script, so it is only worth doing while the
    /// pages are actually on screen — in the editor the writer is typing and
    /// nothing would read the result.
    private func repaginate() {
        guard settings.isPageView else { return }
        pages = ScriptPagination.paginate(blocks: visibleBlocks, setup: settings.pageSetup)
        currentPage = min(max(1, currentPage), max(1, pages.count))
    }

    @ViewBuilder
    private func row(for block: Block) -> some View {
        if selection.isSelecting {
            SelectableBlockRow(block: block, isSelected: selection.isSelected(block.id)) {
                selection.toggle(block.id)
            }
            .blockReorderDrag(block, in: model)
            // The same swipe goes on working inside the mode it opened —
            // a gesture that stopped meaning anything the moment it was used
            // would read as one that had gone wrong.
            .swipeToSelect(swipeSelectAction(block))
        } else if block.isEditable && !options.isEditingLocked {
            EditableBlockRow(model: model, block: block, autocomplete: autocomplete,
                             selection: canSwipeToSelect ? selection : nil) { commented in
                commentTarget = commented
            }
        } else {
            // A locked or read-only element has no context menu, so the bubble
            // is the only way in to its thread — and commenting needs no more
            // than read access.
            // No padding of its own: the row already leaves the element the air
            // the screenplay gives it, and a locked line that sat four points
            // lower than the editable one it replaced would move the whole
            // script the moment editing was locked.
            BlockRowView(block: block,
                         commentCount: model.commentCount(for: block),
                         onComment: block.hasLink(.comments) ? { commentTarget = block } : nil)
                .doubleTapToEdit(startWriting(at: block))
                .swipeToSelect(swipeSelectAction(block))
        }
    }

    /// Whether a swipe across an element is worth offering — the same question
    /// the toolbar's Select Elements button asks, since the gesture is a second
    /// door onto the mode that button opens. A server offering no bulk action
    /// at all has nothing behind either of them.
    ///
    /// Page view and the reading surface draw their own rows and never reach
    /// this one, so neither has to be excluded here.
    private var canSwipeToSelect: Bool { model.canSelectBlocks }

    /// What a swipe across this element does, or nil where there is nothing for
    /// it to do — and then no gesture is attached to the row at all.
    private func swipeSelectAction(_ block: Block) -> (() -> Void)? {
        guard canSwipeToSelect else { return nil }
        return { selection.toggleEnteringMode(block.id) }
    }

    /// The double-tap way out of a locked script, as Pages and Word both offer
    /// it: two taps on a line take the lock off and put the caret in that line.
    ///
    /// Nil unless the lock is the only thing in the way. An element the server
    /// never made editable is read-only however this device is set, and a
    /// gesture that quietly unlocked the script around it would promise a
    /// keyboard that is not coming.
    ///
    /// The caret goes to the end of the line rather than under the finger: a
    /// locked row draws its words in an inert text view (`ScriptText`), which
    /// answers no touches and so cannot be asked which character was under one
    /// — and the end of the line tapped is where writing carries on from
    /// anyway.
    private func startWriting(at block: Block) -> (() -> Void)? {
        guard options.isEditingLocked, block.isEditable else { return nil }
        return { startWriting(atBlockId: block.id) }
    }

    /// Hands the script to the writer with the caret in one named element:
    /// whatever posture is in the way comes off, the column scrolls to the
    /// element, and the caret lands at the end of its line.
    ///
    /// Shared by the two double taps — the reader's and the locked column's —
    /// because a script can be both at once, and one gesture should not leave a
    /// writer facing the other. The display modes are left alone: page view and
    /// outline mode are not on screen when either gesture can be made.
    ///
    /// Where the writer is now is recorded before the surfaces change hands, so
    /// the handoff that follows leaving the reader scrolls to the element they
    /// tapped rather than to whatever the reading had at the top. That matters
    /// for more than the view: the column is lazy, so an element it never
    /// scrolls to is never built, and focus on a row that does not exist is a
    /// keyboard that never comes up.
    private func startWriting(atBlockId id: Int) {
        if options.isEditingLocked { options.setEditingLocked(false) }
        options.rememberBlock(id)
        pendingWriteTarget = id
        setReading(false)
    }

    /// Puts the caret in the element a double tap named, once the column is the
    /// surface on screen — see `pendingWriteTarget`. The caret goes to the end
    /// of the line, which is where writing carries on from.
    private func claimWriteTarget() {
        guard let id = pendingWriteTarget else { return }
        pendingWriteTarget = nil
        guard let block = model.blocks.first(where: { $0.id == id }), block.isEditable
        else { return }
        model.focus(id, caret: model.currentText(block).count)
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.blocks.isEmpty {
            if model.isLoading {
                ProgressView()
            } else if model.canSeedScript {
                // Outline mode is a way of starting a script, not only of
                // taking one apart, so the first element it seeds is a scene
                // heading and the button says which — see `seedInitialBlock`.
                ContentUnavailableView {
                    Label("Empty Script", systemImage: settings.isOutlineMode
                          ? "list.bullet.indent" : "doc.plaintext")
                } description: {
                    Text(settings.isOutlineMode
                         ? "Start outlining to add the first scene heading."
                         : "Start writing to add the first element.")
                } actions: {
                    Button(settings.isOutlineMode ? "Start Outlining" : "Start Writing") {
                        Task { await model.seedInitialBlock() }
                    }
                    .buttonStyle(.glassProminent)
                }
            } else {
                ContentUnavailableView(
                    "Empty Script",
                    systemImage: "doc.plaintext",
                    description: Text("This script has no elements yet."))
            }
        } else if visibleBlocks.isEmpty && settings.isOutlineMode {
            // A script with plenty in it but no skeleton yet. Saying so beats a
            // blank page that reads as "your writing is gone" — and the way out
            // is to write the skeleton, so the first offer is a scene heading
            // rather than the door back to the whole script.
            ContentUnavailableView {
                Label("No Outline Yet", systemImage: "list.bullet.indent")
            } description: {
                Text("Outline mode shows only scenes, sections and synopses. "
                     + "This script has none of them.")
            } actions: {
                if canEditScript && !options.isEditingLocked {
                    Button("Add a Scene") { Task { await model.appendBlock() } }
                        .buttonStyle(.glassProminent)
                    Button("Show Whole Script") { settings.isOutlineMode = false }
                } else {
                    Button("Show Whole Script") { settings.isOutlineMode = false }
                        .buttonStyle(.glassProminent)
                }
            }
        }
    }

    /// Formatting folds out above the element-type bar behind a toggle button,
    /// both only while a block is focused and only for the affordances the
    /// server actually advertised.
    @ViewBuilder
    private var editingBars: some View {
        // Selection mode has its own bar, and nothing is focused for typing.
        // A locked script has no text view to act on either — the last focused
        // id outlives the lock, so it has to be checked rather than trusted.
        if !selection.isSelecting, !options.isEditingLocked,
           let id = model.focusedBlockId,
           let block = model.blocks.first(where: { $0.id == id }) {
            VStack(spacing: 0) {
                if showingFormatBar, block.hasLink(.update) {
                    FormatBar(model: model, block: block)
                    Divider()
                }
                HStack(spacing: 0) {
                    if block.hasLink(.update) {
                        formatBarToggle
                    }
                    if block.hasLink(.setType) {
                        ElementTypeBar(model: model, block: block)
                    }
                    // Trailing, opposite the formatting toggle: the two are the
                    // controls that are not type chips, and keeping them at the
                    // ends leaves the chips a clear run between them. The type
                    // bar scrolls, so this stays put however long the row gets.
                    // Asked rather than left to the button, so a Mac — which has
                    // no keyboard to hide — is not left the padding either.
                    if HideKeyboardButton.isAvailable {
                        // The model lets go of the element in the same turn:
                        // the row re-grants itself first responder while it is
                        // still the focused one, so a resign alone is undone
                        // before the keyboard has finished going down.
                        HideKeyboardButton(releaseFocus: { model.focus(nil) })
                            .padding(.trailing, 12)
                            .padding(.vertical, 5)
                    }
                }
            }
        }
    }

    /// The button the format bar folded into: one chip's worth of row instead
    /// of a second row of chips, showing the bar only while formatting is the
    /// errand at hand. Styled as a chip so the row still reads as one language.
    private var formatBarToggle: some View {
        Button {
            withAnimation(.snappy(duration: 0.15)) { showingFormatBar.toggle() }
        } label: {
            Image(systemName: "textformat")
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .foregroundStyle(showingFormatBar ? Color.white : Color.primary)
        .background(Capsule().fill(showingFormatBar
                                   ? Color.accentColor
                                   : Color.secondary.opacity(0.15)))
        // Matches the 12/5 the type bar's chips inset by inside their own
        // scroll view, so the row keeps one margin all round; the same 12
        // then falls between the toggle and the first chip, a slightly wider
        // gap than the chips' own 6 — right for a control that isn't one of
        // them.
        .padding(.leading, 12)
        .padding(.vertical, 5)
        .accessibilityLabel("Formatting")
        .accessibilityAddTraits(showingFormatBar ? [.isSelected] : [])
    }

    @ViewBuilder
    private var searchBar: some View {
        if isSearching {
            ScriptSearchBar(model: model, navigator: navigator, search: search) {
                isSearching = false
            }
        }
    }

    /// What this script offers the menu bar.
    ///
    /// Gated the same way the toolbar is: an action is nil when the server
    /// never advertised the link behind it, or when there is no script yet to
    /// act on, and the menu item goes grey rather than failing on click.
    private var menuActions: ScriptActions {
        var actions = ScriptActions(title: model.project.displayTitle)

        actions.canUndo = model.canUndo
        actions.canRedo = model.canRedo
        actions.undo = { Task { await model.undo() } }
        actions.redo = { Task { await model.redo() } }

        if !options.isEditingLocked {
            actions.addElement = { Task { await model.appendBlock() } }
        }
        actions.titlePage = { showingTitlePage = true }
        // Import is offered wherever the server advertises it (editors only),
        // matching the toolbar button; the menu reaches it even in focus mode.
        if model.project.hasLink(.importScript) {
            actions.importScript = { showingScriptImporter = true }
        }
        actions.ignoredWords = { showingIgnoredWords = true }
        actions.pageSetup = { showingPageSetup = true }
        // The songs and notes the menu bar can reach: each list, and the handful
        // last edited of each, which open without going through it — what the
        // two toolbar buttons hold, for a writer whose hands are on a keyboard.
        if model.canViewDocuments {
            actions.songs = { openDocumentsScreen(.song) }
            actions.notes = { openDocumentsScreen(.notes) }
            actions.recentSongs = model.songs.mostRecentlyEdited(limit: Self.quickDocumentCount)
            actions.recentNotes = model.notes.mostRecentlyEdited(limit: Self.quickDocumentCount)
            actions.openDocument = { document in openingDocument = document }
        }
        actions.exporter = model.exportOptions.isEmpty ? nil : exporter

        // The View menu's per-project display toggles, so the keyboard reaches
        // the marks the toolbar's "Show" section shows. Lock is offered only
        // where there is something to lock, matching that section.
        actions.showsPins = options.showsPins
        actions.showsBookmarks = options.showsBookmarks
        actions.showsElementLabels = options.showsElementLabels
        actions.isEditingLocked = options.isEditingLocked
        actions.toggleShowPins = { options.showsPins.toggle() }
        actions.toggleShowBookmarks = { options.showsBookmarks.toggle() }
        actions.toggleShowElementLabels = { options.showsElementLabels.toggle() }
        if canEditScript {
            actions.toggleEditingLock = { options.setEditingLocked(!options.isEditingLocked) }
            // Gated exactly as the View menu's item is: a writer, with
            // something to come back from.
            if isAwayFromWriting {
                actions.editScreenplay = { returnToWriting() }
            }
        }

        if let focused = model.blocks.first(where: { $0.id == model.focusedBlockId }) {
            actions.focusedType = focused.blockType
            if focused.isEditable && !options.isEditingLocked {
                actions.setType = { type in
                    Task { await model.changeType(focused, to: type) }
                }
                // The Format menu's character-styling half, on the same
                // focused element the FormatBar shows — reachable now from the
                // keyboard and the menu bar, not only by tapping a chip.
                actions.isBold = focused.textBold ?? false
                actions.isItalic = focused.textItalic ?? false
                actions.isUnderline = focused.textUnderline ?? false
                actions.alignment = TextAlign(serverValue: focused.textAlign) ?? .left
                actions.toggleBold = { Task { await model.toggleBold(focused) } }
                actions.toggleItalic = { Task { await model.toggleItalic(focused) } }
                actions.toggleUnderline = { Task { await model.toggleUnderline(focused) } }
                actions.setAlign = { align in
                    Task { await model.setAlign(focused, to: align) }
                }
            }
            // Commenting sits outside the edit guard, like the context menu's
            // "Comments" entry: leaving a note needs only read access, so it is
            // offered on any focused element, locked or not.
            if focused.hasLink(.comments) {
                actions.commentOnFocused = { commentTarget = focused }
            }
            actions.copyElement = { model.copyBlocks([focused]) }
            if model.canCut(focused) && !options.isEditingLocked {
                actions.cutElement = { Task { await model.cutBlocks([focused]) } }
            }
            if model.canPaste(below: focused) && !options.isEditingLocked {
                actions.pasteElements = { Task { await model.pasteBlocks(below: focused) } }
            }
            // Drop a song's lyrics or a note's text in at the element the writer
            // is in — the block menu's "Insert Song" and "Insert Note", which
            // until now could only be reached by opening that element's menu.
            // Held to the same lock the clipboard items are, since it writes
            // elements into the script.
            if !options.isEditingLocked && model.canInsertDocuments {
                actions.insertableSongs = model.insertableSongs
                actions.insertableNotes = model.insertableNotes
                actions.insertDocument = { document in
                    Task { await model.insertDocument(document, afterBlockId: focused.id) }
                }
            }
        }

        if model.hasScriptContent {
            // Search draws its bar on the editing column, which reading mode
            // has swapped out — no offer where there is nowhere to show it.
            if !isReading {
                // A toggle, not an opener. ⌘F used to be claimed by the
                // toolbar's Search button as well, which is where the second
                // press closed the bar; now that the menu bar holds the only
                // claim, opening-only would leave the chord with no way back.
                actions.find = {
                    isSearching.toggle()
                    if !isSearching { search.clear() }
                }
            }
            actions.outline = { showingOutline = true }
            actions.stats = { showingStats = true }
            actions.readAloud = { toggleReadAloud() }
        }

        // Offered while reading even if the script has emptied under the mode,
        // so the menu bar always has the way back out.
        if model.hasScriptContent || isReading {
            actions.readScript = { setReading(!isReading) }
            actions.isReadingScript = isReading
        }

        if model.project.hasLink(.versions) {
            actions.versions = { showingVersions = true }
        }

        // Same gate as the toolbar's Editions button — offered once there is
        // more than one edition or the writer can make one.
        if editions.hasChoice || editions.canCreate {
            actions.editions = { showingEditions = true }
        }

        return actions
    }

    /// How many songs — and how many notes — the shortcuts offer. Enough that
    /// the one being worked on this week is nearly always among them, short
    /// enough that the menu is still read at a glance rather than scrolled —
    /// past that, the list with its search is the better tool and is one item
    /// away. Counted per list rather than across both, so a project heavy in
    /// songs cannot crowd its notes out of their own section.
    private static let quickDocumentCount = 5

    /// The songs, and the songs themselves hanging off them.
    private var songsButton: some View {
        documentButton("Songs", type: .song, icon: "music.note.list",
                       rowIcon: "music.note", recentsTitle: "Recent Songs",
                       recents: model.songs)
    }

    /// The notes, on the same terms.
    private var notesButton: some View {
        documentButton("Notes", type: .notes, icon: "note.text",
                       rowIcon: "note.text", recentsTitle: "Recent Notes",
                       recents: model.notes)
    }

    /// The listening button, drawn in the phone's bottom bar and named again in
    /// the "…" for the widths and postures that bar does not reach. Reading
    /// happens on this very screen:
    /// the voice starts from wherever the writer is and the transport bar comes
    /// up at the bottom, so while it runs the button is the pause it will be
    /// reached for as.
    ///
    /// It claims no keyboard shortcut: ⌘⇧A is the View menu's Read Aloud item
    /// (`ScriptCommands`), which reaches this same action through
    /// `actions.readAloud` on every platform with a keyboard. A second live
    /// claim on the same keys would be settled by responder order, with one of
    /// the two silently dead.
    private var readAloudButton: some View {
        // Only this script's own reading turns it into a pause: the voice may be
        // on a song opened from this very bar, and offering to pause the script
        // that is not being read would be a button that lies about what it does.
        let isPausing = narrator.isSpeaking && isReadingThisScript
        return Button {
            toggleReadAloud()
        } label: {
            Label(isPausing ? "Pause Reading" : "Read Aloud",
                  systemImage: isPausing ? "pause.fill" : "speaker.wave.2")
        }
    }

    /// The bottom bar's other reading surface: the screenplay on paper, and the
    /// way back off it.
    ///
    /// One button for the round trip rather than two, because it is one
    /// question — which of the two ways of reading is up — and because the trip
    /// back is not simply "paper off": the reader and the paper are exclusive,
    /// so turning paper off drops the script into the writing column, which is
    /// not what someone who was reading a moment ago asked for. It puts the
    /// reader back instead, and says so in its label rather than staying a
    /// ticked "Page View" the way a toggle would.
    ///
    /// It names the surface it goes to, as the menu bar's own pair does
    /// ("Show as Pages" / "Show as List"): a control in a bar has no tick to
    /// carry state with, so the label is the only thing that can say which way
    /// a tap goes.
    private var pageViewButton: some View {
        let onPaper = settings.isPageView
        return Button {
            if onPaper {
                // `setReading` clears the paper itself — going through it
                // rather than round it is what keeps every route between the
                // two modes in one place. Not remembered: this is a reader
                // coming back from a look at the pages, not a writer saying
                // how the screenplay should open next time.
                setReading(true, remember: false)
            } else {
                paperCameFromReader = isReading
                settings.isPageView = true
            }
        } label: {
            Label(onPaper ? "Read Script" : "Page View",
                  systemImage: onPaper ? "book" : "doc.richtext")
        }
    }

    /// One kind's door, with the handful last edited hanging off it.
    ///
    /// Songs and notes each get their own button rather than sharing one. The
    /// shared button could not say which list it opened, so it opened on songs
    /// and a note cost a segment tap on top of finding it — and its label,
    /// naming both kinds, was the widest thing in a bar that had no room to
    /// spare. Two narrow buttons that each name one list are cheaper to draw
    /// and cheaper to read, and neither one lies about where it goes.
    ///
    /// Tapping opens that list. Holding (or the arrow, on a Mac) drops the few
    /// last edited, which go straight to their editor — the screen, the picker,
    /// the search and the row-tap in between were four steps to reach something
    /// the writer already knew the name of. It stays a plain button until there
    /// is a dated document to list, so a kind with none shows no empty menu.
    ///
    /// Whether the button is offered at all is the project's `documents` link,
    /// never the count: the lists arrive a moment after the script does, and a
    /// button that appears late is a button that relays out the bar under a
    /// finger already reaching for it. A kind with nothing in it opens on its
    /// own empty state, which is where making the first one starts anyway.
    @ViewBuilder
    private func documentButton(_ title: String, type: DocumentType, icon: String,
                                rowIcon: String, recentsTitle: String,
                                recents: [TextDocument]) -> some View {
        let recent = recents.mostRecentlyEdited(limit: Self.quickDocumentCount)
        if recent.isEmpty {
            Button {
                openDocumentsScreen(type)
            } label: {
                Label(title, systemImage: icon)
            }
        } else {
            Menu {
                documentSection(recentsTitle, recent, icon: rowIcon)
            } label: {
                Label(title, systemImage: icon)
            } primaryAction: {
                openDocumentsScreen(type)
            }
        }
    }

    /// One kind's shortcuts, or nothing at all when it has none — a heading
    /// over an empty section reads as "you have no notes" when the truth is
    /// only that the server never dated them.
    @ViewBuilder
    private func documentSection(_ title: String, _ documents: [TextDocument],
                                 icon: String) -> some View {
        if !documents.isEmpty {
            Section(title) {
                ForEach(documents) { document in
                    Button {
                        openingDocument = document
                    } label: {
                        Label(document.displayTitle, systemImage: icon)
                    }
                }
            }
        }
    }

    /// Opens the Songs & Notes screen on the list asked for. Every route that
    /// reaches the whole screen goes through here; the shortcuts beside them
    /// skip it for the editor itself.
    ///
    /// The list is named rather than guessed. It used to be optional, and an
    /// unasked call fell back to whichever list the project was last left on
    /// and then to songs — the shape of a single button that had to pick one.
    /// Now every caller is a button, a menu item or a request that already
    /// knows its kind, so there is nothing left to guess at.
    private func openDocumentsScreen(_ type: DocumentType) {
        documentsSheet = DocumentsRequest(type: type)
    }

    /// The editor a document opens in, by what the server says it is: a song
    /// kept as lyric lines gets the line editor, where tinting, reordering and
    /// editions mean something, and everything else keeps the plain one. The
    /// same rule the songs list follows, so a song opens the same way whichever
    /// route reached it.
    @ViewBuilder
    private func documentEditor(for document: TextDocument) -> some View {
        // No `onInserted` here: these sheets sit directly over the script, so
        // the editor dismissing itself is already the way back to it.
        if document.kind == .song, document.hasLink(.songBlocks) {
            SongBlockEditorView(app: model.app, document: document, scriptModel: model)
        } else {
            SongEditorView(model: model, document: document, type: document.kind)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Status first, so it keeps the leading edge — beside the way back —
        // instead of joining the controls crowding the far side, which on an
        // iPhone are one item away from spilling into an overflow menu a
        // standing indicator would be no use inside of. It stays through focus
        // mode: that mode clears away what the writer does not need to look at,
        // and whether their words are safe is not that.
        //
        // Pressing it opens the detail panel, where the one useful action lives
        // — a writer watching an amber cloud should not have to find out that
        // waiting is all there is by waiting.
        if let cloud = cloudState {
            ToolbarItem(placement: .topBarLeading) {
                CloudSyncBadge(state: cloud,
                               heldCount: model.unsavedBlockIds.count + model.heldDocumentIds.count,
                               lastSyncedAt: model.lastSyncedAt,
                               sync: { await model.syncNow() },
                               conflictCount: model.conflicts.count,
                               review: { showingConflicts = true })
            }
            .sharedBackgroundVisibility(.hidden)
        }

        // The View menu stays put in focus mode — it is the way back out.
        //
        // It sits in a group of its own, divided from the rest by a
        // `ToolbarSpacer`, so Liquid Glass draws it as a separate control: it
        // changes how the script is *presented*, where everything after it acts
        // on the script itself. Pooling them in one capsule read as one set.
        ToolbarItemGroup(placement: .primaryAction) {
            viewMenu

            // The way out of the reader and into the script, in the corner
            // Pages and Word both put it in — where there is a corner to put
            // it in. On an iPad and a Mac this draws; on a phone the bar has
            // room for the View menu and the "…" and nothing else, and this
            // was collapsed into the overflow even from in here, beside the
            // one control that is always drawn. `documentsBar` carries the
            // phone's real one, under the thumb; see its note.
            //
            // In the View menu's capsule rather than the group below, which
            // is where it started: that group is the one the phone collapses
            // whole, and on the widths where both are drawn this is a change
            // of how the script is *presented*, which is what this capsule is
            // for. Ungated by focus mode for the same reason the View menu is:
            // both are ways back.
            //
            // Only where there is somewhere to type. A reader the server never
            // gave an `update` link has no edit view to be sent to, and a
            // button offering one would be a promise this app cannot keep.
            if isReadyToEdit {
                Button {
                    setReading(false)
                } label: {
                    Label("Edit", systemImage: "square.and.pencil")
                }
            } else if isReadyToRead {
                // The same slot, the other way round: whichever surface is up,
                // this corner is the one tap to the other one. The mode had
                // only ever been reachable from *inside* the View menu on the
                // way back — a writer who took the Edit button out of the
                // reader had to remember which menu the door home was in, which
                // is two taps and a hunt for the thing they had just used one
                // tap to leave.
                //
                // Titled "Read Script", not "Read": it is the View menu's own
                // words for the mode and the menu bar's, and where a short bar
                // spills this into the "…" it lands among named items beside a
                // Read Aloud it must not be mistaken for.
                Button {
                    setReading(true)
                } label: {
                    Label("Read Script", systemImage: "book")
                }
            }
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        // No "add element" button here. An empty script seeds its first element
        // as it opens (and still offers "Start Writing" when it couldn't), and
        // in a script with anything in it a return at the end of the last
        // element does the same thing without a trip to the toolbar — so the
        // button only crowded the bar. The menu bar keeps ⌘N for the keyboard.
        ToolbarItemGroup(placement: .primaryAction) {
            // Undo, up where it can be seen. The overflow was the wrong place
            // for it twice over: undoing is the one thing a writer reaches for
            // *while* mistyping, so a menu to open first is a menu in the way,
            // and the "…" gave no sign of whether there was anything to undo —
            // the greyed state that says "nothing yet" only showed after a tap.
            //
            // It leads this capsule rather than opening one of its own, and it
            // comes up without redo. Both are the phone's bar talking: it is
            // budgeted in capsules rather than buttons, so a capsule of its own
            // took the whole allowance and dropped Search *and* the View menu
            // into the "…" to pay for it, while the pair on the leading edge
            // truncated an iPad's title to "The…" and pushed Notes back into
            // the overflow a previous change had just got it out of. In here,
            // alone, it costs one glyph — Search, on a phone, which keeps ⌘F
            // and its place in the "…". Undo is the half worth that: it is
            // reached for constantly and redo hardly at all, the same reason a
            // keyboard keeps ⌘Z under a finger and hides redo behind a second
            // modifier. Redo is in the overflow below.
            //
            // Ungated by focus mode, unlike everything else in this group: the
            // mode is for writing without chrome, which is exactly when a
            // mistyped line needs taking back.
            //
            // No keyboard shortcut here: ⌘Z belongs to the menu bar's replaced
            // undo group, and a second claim on the same keys would be settled
            // by responder order with one of the two silently dead.
            // `offersUndoRedo` rather than the server status alone: a script
            // opened offline never fetched its status, and hiding the button
            // then would hide it exactly when the local steps exist.
            //
            // A hold keeps undoing — see `HistoryStepButton`, which every
            // editor's pair is now made of, for why a step back is almost never
            // one step and why the repeat drops rather than queues what the
            // server has not answered yet.
            //
            // That hold used to open a menu holding both halves, which is the
            // one thing a repeat cannot share a gesture with. It is the better
            // trade: reaching redo through it saved a trip into the "…" that
            // hardly anybody was making, where the writer walking back a
            // mistyped paragraph is doing the commonest thing there is with
            // this button and was tapping it six times to do it. The menu's
            // other job — saying *why* a live-looking Undo does nothing, when
            // the stack is empty but redo's is not — goes back to the plain
            // greying below, which is the ordinary answer and the one every
            // other button in this bar gives.
            //
            // Redo keeps its place in the overflow below, as it did while the
            // menu stood: it is one glyph this bar cannot spare up here — see
            // the paragraph above for what a second button in this capsule
            // costs. Undo is listed down there beside it now as well, which is
            // not tidiness: this control is not a `Button`, and a bar with no
            // room drops it rather than folding it into the "…" the way it
            // folds a button. The group below is what a phone is left with, and
            // a menu row cannot be held — so on a phone the screenplay's pair
            // walks one step per tap, as it always did, and the hold belongs to
            // the bars wide enough to draw this. A keyboard has ⌘Z and ⌘⇧Z, and
            // the lyric and note editors, whose pairs sit on the leading edge
            // where there is room for two, hold on either half.
            if model.offersUndoRedo, !settings.isPageView, !isReading {
                HistoryStepButton(title: "Undo",
                                  systemImage: "arrow.uturn.backward",
                                  isOffered: { model.canUndo }) {
                    await model.undo()
                }
            }

            if model.hasScriptContent && !settings.isFocusMode {
                // Not while reading: the search bar rides the editing column,
                // which the reader has swapped out.
                if !isReading {
                    Button {
                        isSearching.toggle()
                        if !isSearching { search.clear() }
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                }

                Button {
                    showingOutline = true
                } label: {
                    Label("Navigator", systemImage: "list.bullet.indent")
                }

                if model.canSelectBlocks && !settings.isPageView && !isReading {
                    Button {
                        selection.isSelecting.toggle()
                    } label: {
                        Label("Select Elements", systemImage: "checklist")
                    }
                }
            }

            if model.canViewCharacters && !settings.isFocusMode {
                Button {
                    showingCharacters = true
                } label: {
                    Label("Characters", systemImage: "person.2")
                }
            }

            if !model.exportOptions.isEmpty && !settings.isFocusMode {
                ExportButton(exporter: exporter)
                // Print gives up its place first when the bar is short. It is
                // the rarest errand in this capsule — export is the one that
                // carries a draft away, and print is the once-a-draft one —
                // and the overflow is exactly where a phone already keeps it.
                // Standing back one control is what lets Notes stay drawn.
                if hasRoomForFullToolbar {
                    PrintButton(exporter: exporter)
                }
            }
        }

        // Songs and notes take a capsule of their own, on the same reasoning as
        // the View menu's: they do neither of those things, they open other
        // documents kept beside the script. A pill of exactly two also reads as
        // a pair, which is what says they are two doors onto one screen rather
        // than two unrelated errands.
        //
        // Only where the bar has the room, which on a phone it has not: measured
        // on a 402pt iPhone, the trailing side draws three controls and the "…"
        // always claims one of them, so two buttons are all that is ever visible
        // and the View menu and Search are already those two. Adding Songs and
        // Notes here would put them straight back in the overflow this change
        // exists to get them out of. `documentsBar` carries them instead.
        //
        // Gated as a unit, spacer and all: gating the buttons inside a group
        // that is always present would leave a divider with nothing after it,
        // and a stranded gap at the end of the bar.
        if !isCompact && model.canViewDocuments && !settings.isFocusMode {
            ToolbarSpacer(.fixed, placement: .primaryAction)

            ToolbarItemGroup(placement: .primaryAction) {
                songsButton
                notesButton
            }
        }

        // Front matter, history and the occasional errands. These also hang off
        // the screenplay's name (`projectButtons` is what the title menu
        // shows), but they are declared here as well rather than only there:
        // whether the bar has the room to draw a title at all is iOS's
        // decision, and an affordance that exists only inside a menu that may
        // not appear is an affordance that may not be reachable.
        // Focus mode clears the overflow out but for redo, which the group
        // below keeps: undo is up in the bar in every mode, and a redo with no
        // way to reach it would strand a writer mid-correction.
        if !settings.isFocusMode {
            ToolbarItemGroup(placement: .secondaryAction) {
                projectButtons
            }

            ToolbarItemGroup(placement: .secondaryAction) {
                // Listening, in the menu every other surface already keeps it
                // in — the song and note editors both put Read Aloud here, and
                // the screenplay was the one document you could not start a
                // reading of from the "…".
                //
                // `documentsBar` still carries the phone's button, and this is
                // deliberately the second door to it rather than a replacement:
                // that bar is compact-only and folds away with the chrome, so
                // on an iPad or a Mac, and on a phone mid-scroll or mid-
                // selection, the menu was the only place left to look and it
                // was not there. The earlier round removed a *toolbar* button
                // for costing a slot the bar could not spare; an overflow item
                // costs no slot.
                if model.hasScriptContent {
                    readAloudButton
                }

                // Where Print waits out a bar too short to hold it. Declared
                // here rather than left to the system's own overflow so that
                // it lands among named items instead of as a bare glyph, and
                // so the bar's last slot can go to Notes.
                if !model.exportOptions.isEmpty && !hasRoomForFullToolbar {
                    PrintButton(exporter: exporter)
                }

                if model.hasScriptContent {
                    Button {
                        showingStats = true
                    } label: {
                        Label("Script Stats", systemImage: "chart.bar")
                    }
                }

                if let trash = model.blocksLinks[.trash] {
                    Button {
                        trashLink = trash
                    } label: {
                        Label("Deleted Elements", systemImage: "trash")
                    }
                }
            }
        }

        // The pair in the "…", which is where a bar with no room for them puts
        // everything. Redo has always been here — it is the half the bar cannot
        // spare a glyph for. Undo is here as well now, and has to be: the
        // control up in the bar is not a `Button` (see `HistoryStepButton` for
        // why a hold leaves no other choice), and an item that is not a button
        // is *dropped* rather than collapsed when the bar runs out of room.
        // Measured on a 390pt iPhone, where that whole capsule goes into the
        // "…": without this, the screenplay's Undo was reachable nowhere on the
        // one device where it collapses.
        //
        // So the phone gets what it had before — one step per tap, from a menu
        // row, which is a menu row's limit — and the bars with the room to draw
        // the control get the hold. A duplicate where both are drawn, which is
        // what `projectButtons` already accepts for the same reason: an
        // affordance that exists only in a place that may not appear is an
        // affordance that may not be reachable.
        //
        // Both carry the reader's gate as well: the bar's Undo is drawn
        // `!isReading`, and without the same test here the reader's overflow
        // offered a lone Redo — half a pair, on a screen with nothing to redo
        // into. And both stay through focus mode, where undo is still up in the
        // bar: the two are useless apart.
        if model.offersUndoRedo, !settings.isPageView, !isReading {
            ToolbarItemGroup(placement: .secondaryAction) {
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
    }

    /// The project's own affairs, as against the script on screen: its front
    /// matter, its named drafts, its history, who else can see it.
    ///
    /// Gathered so they can hang off the screenplay's name as well as sit in
    /// the overflow — a document app has taught everyone to look under the
    /// title for these, and the same list serves both places. See `toolbar`
    /// for why they are in both rather than only under the title.
    @ViewBuilder
    private var projectButtons: some View {
        // First, and first for a reason: this list hangs off the screenplay's
        // name, and renaming is what a name is most often tapped for — the web
        // header renames on a click of the title itself. Gated on the same
        // `update` link the list's Rename is, so a reader is offered nothing.
        if model.canRenameProject {
            Button {
                showingRename = true
            } label: {
                Label("Rename Screenplay…", systemImage: "pencil")
            }
        }

        Button {
            showingTitlePage = true
        } label: {
            Label("Title Page…", systemImage: "doc.text")
        }

        // Only worth surfacing once there is more than one edition, or the
        // writer can make one. A single-edition project should show no sign
        // of the feature.
        if editions.hasChoice || editions.canCreate {
            Button {
                showingEditions = true
            } label: {
                Label("Editions…", systemImage: "doc.on.doc")
            }
        }

        if model.project.hasLink(.versions) {
            Button {
                showingVersions = true
            } label: {
                Label("Version History…", systemImage: "clock.arrow.circlepath")
            }
        }

        if model.project.hasLink(.invitations) || model.project.hasLink(.access) {
            Button {
                showingShare = true
            } label: {
                Label("Share…", systemImage: "person.badge.plus")
            }
        }

        if let activity = model.project.link(.activity) {
            Button {
                activityLink = activity
            } label: {
                Label("Recent Activity…", systemImage: "clock")
            }
        }

        if model.project.hasLink(.importScript) {
            Button {
                showingScriptImporter = true
            } label: {
                Label("Import Script…", systemImage: "square.and.arrow.down.on.square")
            }
        }
    }

    /// How the script is presented, gathered into one menu the way the web
    /// editor gathers them under View.
    /// None of these carry a chord, though every one of them has one. The keys
    /// live in `ScriptCommands`, which is mounted once at the scene and stays
    /// mounted through focus mode — this menu comes and goes with the toolbar,
    /// and two views binding one chord means whichever loses the responder race
    /// silently does nothing. The shortcuts sheet documents the single claim.
    private var viewMenu: some View {
        Menu {
            Section {
                Toggle(isOn: pageViewBinding) {
                    Label("Page View", systemImage: "doc.richtext")
                }

                Toggle(isOn: focusModeBinding) {
                    Label("Focus Mode", systemImage: "moon")
                }

                Toggle(isOn: outlineModeBinding) {
                    Label("Outline Mode", systemImage: "list.bullet.indent")
                }

                // A mode among the modes, not a screen: the toggle swaps the
                // column for the reader in place, and toggling it off —
                // or asking for page or outline mode — puts the writing back.
                // Read Aloud is not beside it: that one is a button of its own
                // — the phone's bottom bar and the "…" — and reading aloud
                // never needs this mode.
                Toggle(isOn: readingBinding) {
                    Label("Read Script", systemImage: "book")
                }
                .disabled(!model.hasScriptContent && !isReading)

                // The way back out of all of them at once. Each mode above
                // names its own exit, but a writer three modes deep — reading,
                // in outline, on paper — has to remember which ones are on and
                // turn them off one at a time. This is the one item that means
                // "just let me write", and it clears the editing lock with
                // them, since a lock left on would make it a lie. Offered only
                // to a writer who has somewhere to type, matching the lock's
                // own section, and greyed when the plain column is already up.
                // It carries no chord of its own: ⌘⇧E is centre alignment, and
                // everything it clears already answers to a chord.
                if canEditScript {
                    Button {
                        returnToWriting()
                    } label: {
                        Label("Edit Screenplay", systemImage: "pencil.line")
                    }
                    .disabled(!isAwayFromWriting)
                }
            }

            // Only offered where it changes anything: the page view lays the
            // script out on paper, which has a width of its own, and the
            // reader holds to its own measure.
            if !settings.isPageView && !isReading {
                Section {
                    Toggle(isOn: fullWidthBinding) {
                        Label("Full Page Width", systemImage: "arrow.left.and.right")
                    }
                }
            }

            // Pins and bookmarks used to head this section. They now live on
            // the Outline panel's own Pins and Bookmarks tabs, beside the list
            // of the marks each switch hides. ⌘⇧N and ⌘⇧B still reach them
            // from anywhere, through the View commands.
            Section("Show") {
                Toggle(isOn: option(\.showsElementLabels,
                                    set: { options.showsElementLabels = $0 })) {
                    Label("Element Labels", systemImage: "tag")
                }
                Toggle(isOn: option(\.showsNotes, set: { options.showsNotes = $0 })) {
                    Label("Notes", systemImage: "note.text")
                }
                // The odd one out in this section: the readout is a device
                // preference, where the marks are per project. It sits here
                // anyway because "what is on the page" is how a writer looks
                // for it, and it is where the web app keeps it too.
                Toggle(isOn: wordCountBinding) {
                    Label("Word Count", systemImage: "number")
                }
            }

            // A lock is only worth offering where there is something to lock:
            // a reader who was never given editing rights has one already.
            // Spellcheck keeps it company for the same reason — both are about
            // typing, and neither means anything to someone who cannot.
            if canEditScript {
                Section {
                    Toggle(isOn: spellcheckBinding) {
                        Label("Check Spelling", systemImage: "textformat.abc.dottedunderline")
                    }
                    Button {
                        showingIgnoredWords = true
                    } label: {
                        Label("Ignored Words…", systemImage: "character.book.closed")
                    }
                    Toggle(isOn: lockBinding) {
                        Label("Lock Editing", systemImage: "lock")
                    }
                }
            }

            Section("Text Size") {
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
            }

            Section {
                Button {
                    showingPageSetup = true
                } label: {
                    Label("Page Setup…", systemImage: "ruler")
                }
            }
        } label: {
            Label("View", systemImage: "eye")
        }
    }

    /// The reader, as a Toggle can use it. Through `setReading` rather than
    /// straight at the state, so choosing the mode here is remembered the same
    /// way choosing it with the Edit button is.
    private var readingBinding: Binding<Bool> {
        Binding(get: { isReading }, set: { setReading($0) })
    }

    private var pageViewBinding: Binding<Bool> {
        Binding(get: { settings.isPageView }, set: { settings.isPageView = $0 })
    }

    private var focusModeBinding: Binding<Bool> {
        Binding(get: { settings.isFocusMode }, set: { settings.isFocusMode = $0 })
    }

    private var outlineModeBinding: Binding<Bool> {
        Binding(get: { settings.isOutlineMode }, set: { settings.isOutlineMode = $0 })
    }

    /// Whether the server gave this writer somewhere to type. A reader is
    /// locked already, so offering them the lock would only be noise. Asks the
    /// links rather than the lock, which is a choice about this device.
    private var canEditScript: Bool {
        model.blocks.contains(where: \.isEditable) || model.canSeedScript
    }

    /// Whether anything at all stands between the writer and the plain writing
    /// column — one of the display modes, or the lock. False when the script is
    /// already open the way it is written in, which is when "Edit Screenplay"
    /// has nothing left to do.
    private var isAwayFromWriting: Bool {
        settings.isPageView || settings.isFocusMode || settings.isOutlineMode
            || isReading || options.isEditingLocked
    }

    /// Put the script back the way it is written in: every display mode off,
    /// and the lock with them.
    ///
    /// The lock is cleared through `options` rather than written directly,
    /// because which edition it belongs to is the setter's business. Only
    /// called from a menu item the reader never sees, so unlocking here cannot
    /// hand editing to someone the server never gave it to — the elements stay
    /// read-only whatever this device thinks.
    private func returnToWriting() {
        settings.isPageView = false
        settings.isFocusMode = false
        settings.isOutlineMode = false
        // Through `setReading`, not by writing the flag: it is the only place
        // the choice is remembered, so setting `isReading` here left the
        // script opening for reading again next time — the one route out of
        // the reader that did not count as a decision. A no-op when the reader
        // was not up, which is right: leaving page view says nothing about how
        // the script should open.
        setReading(false)
        if options.isEditingLocked {
            options.setEditingLocked(false)
        }
    }

    private var wordCountBinding: Binding<Bool> {
        Binding(get: { settings.showsWordCount }, set: { settings.showsWordCount = $0 })
    }

    private var spellcheckBinding: Binding<Bool> {
        Binding(get: { settings.isSpellcheckEnabled },
                set: { settings.isSpellcheckEnabled = $0 })
    }

    private var fullWidthBinding: Binding<Bool> {
        Binding(get: { settings.isFullWidth }, set: { settings.isFullWidth = $0 })
    }

    /// The lock's setter is a method rather than a property, because what it
    /// writes depends on which edition is open.
    private var lockBinding: Binding<Bool> {
        Binding(get: { options.isEditingLocked }, set: { options.setEditingLocked($0) })
    }

    /// One of the view options, as a Toggle can use it.
    private func option(_ keyPath: KeyPath<ScriptViewOptions, Bool>,
                        set: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: { options[keyPath: keyPath] }, set: set)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })
    }
}
