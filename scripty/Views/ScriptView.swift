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
    @State private var showingOutline = false
    @State private var showingStats = false
    @State private var showingIgnoredWords = false
    /// Whether the format bar is unfolded above the element-type bar. Off by
    /// default and deliberately not persisted: formatting is an occasional
    /// errand, and each session should start with the screen it saves.
    @State private var showingFormatBar = false
    @State private var isSearching = false
    /// Whether the reader sheet — the script as prose, for reading silently —
    /// is up. Reading *aloud* no longer opens it: the voice runs right here,
    /// with a transport bar at the bottom and the element being read
    /// spotlighted in the column, so listening costs no screen at all.
    @State private var showingReader = false
    /// The voice that reads the script out loud, owned by the script screen
    /// so a reading survives the reader sheet opening and closing. The
    /// preferences it carries are stored, so voice and speed outlive it.
    @State private var narrator = ScriptNarrator()
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

    /// Which screen the writer had open above the script when they last put the
    /// app down. The project list owns the project half of that record; this
    /// view owns the screen sitting on top of it.
    private let openEditors = OpenEditorState.shared
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
    /// An element a Bookmarks widget row asked for, held until the script it
    /// belongs to has actually arrived. Nil the rest of the time.
    @State private var pendingBookmarkBlockId: Int?

    /// How much room the writing column actually has, for full-width mode.
    /// Zero until the first layout, which reads as "use the printed measure".
    @State private var availableWidth: CGFloat = 0

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

    /// The undo/redo confirmation currently on screen, if any, and the task
    /// that clears it. Kept in the view because how long it stays up is pure
    /// presentation — the model only says what happened.
    @State private var toastText: String?
    @State private var toastHideTask: Task<Void, Never>?

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
    }

    var body: some View {
        presentations(over: scriptSurface)
    }

    /// The script with its chrome, banners and lifecycle hooks — everything
    /// short of the sheets, which `presentations` carries. Split because one
    /// expression carrying every modifier is more than the type-checker will
    /// finish in reasonable time.
    private var scriptSurface: some View {
        Group {
            if settings.isPageView {
                pageView
            } else {
                editor
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                unsavedBanner
                editionBanner
            }
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
        .overlay(alignment: .bottom) { historyToastOverlay }
        .onChange(of: model.historyToast?.token) { _, token in
            guard token != nil, let toast = model.historyToast else { return }
            toastHideTask?.cancel()
            withAnimation(.spring(duration: 0.3)) { toastText = toast.text }
            toastHideTask = Task {
                // Matches the web toast's 3.2s visible span.
                try? await Task.sleep(for: .seconds(3.2))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.3)) { toastText = nil }
            }
        }
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
            narrator.stop()
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
        .remembersOpenEditor(openEditor, atDepth: 0, isEnabled: !model.app.isDemo)
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
            // A reading in progress follows the script it is reading — an
            // edit, a sync, a restore all reshape the run, and the narrator
            // keeps its place across the rebuild. Idle, there is nothing to
            // keep in step; the run is built fresh when reading starts.
            if narrator.isActive {
                narrator.prepare(model.blocks, title: model.project.displayTitle)
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
        .onChange(of: settings.isPageView) { _, _ in
            repaginate()
            // Changing surface is not leaving the page: the paper opens on the
            // sheet the column was showing, and the column comes back to the
            // element the sheet started with. Both read the position the other
            // has been keeping, so the switch is where it changes hands.
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
        .sheet(isPresented: $showingReader) {
            ReadScriptView(
                title: model.project.displayTitle,
                blocks: model.blocks,
                textScale: settings.textScale,
                narrator: narrator)
        }
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
        .sheet(item: $documentsSheet, onDismiss: { reopeningInSongs = [] }) { request in
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
        .sheet(item: $openingDocument, onDismiss: {
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
        if !model.app.connectivity.isOnline { return .offline }
        // Refused beats retrying: with both on screen, the one that will not
        // fix itself is the one the badge must name.
        if model.hasFailedSaves { return .failed }
        return model.hasUnsavedChanges ? .holding : .synced
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
        if isOffline {
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
        }
        .font(.footnote)
        .foregroundStyle(tint)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(tint.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibility)
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
            // Follow the voice, as the reader sheet does. Centred rather than
            // at the top, because a line read at the very top of the screen
            // has no context above it and the next one is always a jump. The
            // scroll spy drops programmatic moves, so following cannot fold
            // the chrome away.
            .onChange(of: narrator.currentBlockId) { _, id in
                guard let id else { return }
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .overlay { emptyState }
        // Each writing bar is mounted with `.safeAreaBar`, so the three stack
        // as Liquid Glass strips over the script instead of opaque slabs.
        .safeAreaBar(edge: .bottom) { editingBars }
        .safeAreaBar(edge: .bottom) { searchBar }
        .safeAreaBar(edge: .bottom) { bulkBar }
        .environment(\.scriptTextScale, settings.textScale)
        .environment(\.scriptRowChrome, rowChrome)
    }

    /// Word-splitting every element on every body evaluation is real work on a
    /// feature-length script, and the bar redraws with the rest of the view —
    /// every toast, every commit. Cached against the inputs that can change
    /// the answer; comparing `[Block]` hits the identity fast-path between
    /// reloads, so the check is O(1) per redraw. A static rather than @State
    /// because body may not write view state, and the cache is presentation-
    /// independent anyway (the fontCache precedent in EditableBlockRow).
    @MainActor private static var wordCountMemo:
        (blocks: [Block], showsNotes: Bool, outlineMode: Bool, words: Int)?

    private var memoizedWordCount: Int {
        if let memo = Self.wordCountMemo,
           memo.blocks == model.blocks,
           memo.showsNotes == options.showsNotes,
           memo.outlineMode == settings.isOutlineMode {
            return memo.words
        }
        let words = ScriptWordCount.total(in: visibleBlocks)
        Self.wordCountMemo = (model.blocks, options.showsNotes, settings.isOutlineMode, words)
        return words
    }

    /// The elements the writer has asked to see.
    ///
    /// Two independent narrowings. Notes can be hidden because they are
    /// annotations on the script rather than part of it. Outline mode goes much
    /// further and keeps only the story's skeleton — and it wins outright, since
    /// a note is not a scene, a section or a synopsis.
    private var visibleBlocks: [Block] {
        if settings.isOutlineMode {
            let outline = Set(PresentationSettings.outlineTypes)
            return model.blocks.filter { outline.contains($0.blockType) }
        }
        guard !options.showsNotes else { return model.blocks }
        return model.blocks.filter { $0.blockType != .note }
    }

    /// What the rows should draw, gathered from the project's view options and
    /// the room the window has.
    private var rowChrome: ScriptRowChrome {
        var chrome = ScriptRowChrome()
        chrome.showsPins = options.showsPins
        chrome.showsBookmarks = options.showsBookmarks
        chrome.showsElementLabels = options.showsElementLabels
        guard availableWidth > 0 else { return chrome }
        // Each row is padded by 24 either side, so that much of the window was
        // never the column's to use.
        let usable = availableWidth - 48

        // A window narrower than the printed measure — a phone, a split-view
        // slice — gives the column what room it has. Without this the 640pt
        // column overhangs the screen, and the speech boxes measured against it
        // come out wider than the window itself: dialogue then renders full
        // bleed, indistinguishable from action.
        chrome.columnWidth = min(chrome.columnWidth, max(280, usable))

        // The marks sit in the margin beyond the column, so full width leaves
        // them room rather than running the text underneath them.
        if settings.isFullWidth {
            chrome.columnWidth = max(320, usable - BlockMarkerBadges.gutter)
            chrome.isFullWidth = true
        }

        // Both margins now have something in them: the element labels hang off
        // the left of the column, the marks off the right. Where the centred
        // column already leaves margin enough, they live in it and the page
        // stays centred. Where it doesn't — a phone, a split-view slice — the
        // column gives up exactly the room they need, because a lopsided page
        // is better than a label printed over a scene heading or an action line
        // running under a bookmark.
        let leading = options.showsElementLabels ? ElementLabelTag.gutter : 0
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

    /// The transient confirmation after an undo/redo, as the web editor shows.
    /// Non-interactive so it never swallows a tap on the writing underneath.
    ///
    /// Liquid Glass rather than the web's flat dark capsule: it floats over the
    /// writing, which is exactly what the material is for, and it stays legible
    /// against a light page or a dark one without a hardcoded pair of colours.
    @ViewBuilder
    private var historyToastOverlay: some View {
        if let text = toastText {
            Text(text)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding(.bottom, 12)
                .allowsHitTesting(false)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityAddTraits(.isStaticText)
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
    /// Read Aloud rides along for the same reason the documents do: it has a
    /// toolbar button now, and on a phone that button is always the overflow's
    /// — the very menu it just moved out of. Listening is also the posture this
    /// bar suits best: a thumb on the bottom edge, not a reach for the corner.
    @ViewBuilder
    private var documentsBar: some View {
        // Not while elements are being selected: the selection bar already
        // takes two rows of the phone's bottom edge, and songs, notes, and
        // listening are exactly the errand the writer is not on.
        if isCompact && !isChromeHidden && !settings.isFocusMode
            && (model.canViewDocuments || model.hasScriptContent)
            && !selection.isSelecting {
            HStack(spacing: 8) {
                if model.canViewDocuments {
                    songsButton
                    notesButton
                }
                if model.hasScriptContent {
                    readAloudButton
                }
            }
            .buttonStyle(.bordered)
            .labelStyle(.iconOnly)
            .padding(.vertical, 4)
        }
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
                          isFiltered: isSearchNarrowingSelection)
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
                guard let id,
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
            ContentUnavailableView(
                "Nothing to Paginate",
                systemImage: "doc.richtext",
                description: Text("This script has no elements yet."))
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
        if narrator.isActive {
            narrator.togglePlayPause()
            return
        }
        narrator.prepare(model.blocks, title: model.project.displayTitle)
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

    /// The read-aloud transport, up only while a reading is loaded. It rides
    /// this screen rather than a sheet, so listening leaves the script — and
    /// the writing — exactly where they were.
    @ViewBuilder
    private var narrationBar: some View {
        if narrator.isActive {
            NarrationTransportBar(narrator: narrator, showsOptions: true)
        }
    }

    /// The element being read, marked without moving anything: the wash is
    /// inset outwards so switching it on cannot reflow the column.
    @ViewBuilder
    private func spotlight(_ block: Block) -> some View {
        if narrator.currentBlockId == block.id {
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
                                         isDemo: model.app.isDemo)
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
        if let openingDocument { return .document(openingDocument.id) }
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
    /// rather than onto a screen with nothing on it. The demo is left out for the
    /// same reason it keeps no record — it is a walkthrough, not someone's place.
    private func reopenRememberedEditor() {
        guard !model.app.isDemo else { return }
        let path = openEditors.claimReopenPath(forProject: model.project.id)
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
        case .document(let id):
            // A song deleted since is not found, and the script simply opens
            // without it.
            guard let document = model.documents.first(where: { $0.id == id }) else { return }
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
        } else if block.isEditable && !options.isEditingLocked {
            EditableBlockRow(model: model, block: block, autocomplete: autocomplete) { commented in
                commentTarget = commented
            }
        } else {
            // A locked or read-only element has no context menu, so the bubble
            // is the only way in to its thread — and commenting needs no more
            // than read access.
            BlockRowView(block: block,
                         commentCount: model.commentCount(for: block),
                         onComment: block.hasLink(.comments) ? { commentTarget = block } : nil)
                .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.blocks.isEmpty {
            if model.isLoading {
                ProgressView()
            } else if model.canSeedScript {
                ContentUnavailableView {
                    Label("Empty Script", systemImage: "doc.plaintext")
                } description: {
                    Text("Start writing to add the first element.")
                } actions: {
                    Button("Start Writing") {
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
            // blank page that reads as "your writing is gone".
            ContentUnavailableView {
                Label("No Outline Yet", systemImage: "list.bullet.indent")
            } description: {
                Text("Outline mode shows only scenes, sections and synopses. "
                     + "This script has none of them.")
            } actions: {
                Button("Show Whole Script") { settings.isOutlineMode = false }
                    .buttonStyle(.glassProminent)
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
            actions.find = {
                isSearching = true
            }
            actions.outline = { showingOutline = true }
            actions.stats = { showingStats = true }
            actions.readScript = { showingReader = true }
            actions.readAloud = { toggleReadAloud() }
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

    /// One definition for its two homes — the toolbar capsule where an iPad
    /// or a Mac has the width, and the phone's bottom bar — so the two cannot
    /// drift. Reading happens on this very screen: the voice starts from
    /// wherever the writer is and the transport bar comes up at the bottom,
    /// so while it runs the button is the pause it will be reached for as.
    /// The ⌘⇧A shortcut is the toolbar's alone; a second claim from the
    /// bottom bar would leave one of them silently dead.
    private var readAloudButton: some View {
        Button {
            toggleReadAloud()
        } label: {
            Label(narrator.isSpeaking ? "Pause Reading" : "Read Aloud",
                  systemImage: narrator.isSpeaking ? "pause.fill" : "speaker.wave.2")
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
        if document.kind == .song, document.hasLink(.songBlocks) {
            SongBlockEditorView(app: model.app, document: document)
        } else {
            SongEditorView(model: model, document: document, type: document.kind)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Status rather than an action, so it keeps the leading edge — beside
        // the way back — instead of joining the controls crowding the far side,
        // which on an iPhone are one item away from spilling into an overflow
        // menu a standing indicator would be no use inside of. It stays through
        // focus mode: that mode clears away what the writer does not need to
        // look at, and whether their words are safe is not that.
        if let cloud = cloudState {
            ToolbarItem(placement: .topBarLeading) {
                CloudSyncBadge(state: cloud, heldCount: model.unsavedBlockIds.count)
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
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        // No "add element" button here. An empty script offers "Start Writing",
        // and in a script with anything in it a return at the end of the last
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
            // A menu rather than a plain button so a long press offers Redo —
            // the same hold-for-the-other-half gesture Safari's back button
            // taught. That puts redo one gesture from undo instead of a trip
            // into the "…", without spending the capsule budget a second
            // button would (see above). The overflow keeps its Redo item too:
            // a hold is not discoverable, so the menu is the fast path for
            // those who know it, not the only path.
            //
            // The control greys out only when *both* halves are empty. Undo
            // alone running dry must not take redo down with it — undoing back
            // to the start is exactly the moment redo is wanted — so a tap
            // with nothing to undo guards itself instead.
            if model.offersUndoRedo, !settings.isPageView {
                Menu {
                    Button {
                        Task { await model.redo() }
                    } label: {
                        Label("Redo", systemImage: "arrow.uturn.forward")
                    }
                    .disabled(!model.canRedo)
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                } primaryAction: {
                    guard model.canUndo else { return }
                    Task { await model.undo() }
                }
                .disabled(!model.canUndo && !model.canRedo)
            }

            if model.hasScriptContent && !settings.isFocusMode {
                // Out of the View menu, where it was a listening feature filed
                // under presentation toggles and cost a menu trip every time.
                // It joins this capsule rather than opening one of its own for
                // the reason undo does, and sits where an iPad and a Mac will
                // draw it as a button. A phone will not — everything past Undo
                // is the "…"'s — so `documentsBar` gives the phone a real one
                // down under the thumb, which is also why the shortcut lives
                // here and not there: two live claims on ⌘⇧A would be settled
                // by responder order with one of them silently dead.
                readAloudButton
                    .keyboardShortcut("a", modifiers: [.command, .shift])

                Button {
                    isSearching.toggle()
                    if !isSearching { search.clear() }
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("f", modifiers: .command)

                Button {
                    showingOutline = true
                } label: {
                    Label("Outline", systemImage: "list.bullet.indent")
                }
                // ⌘⇧O is outline *mode*, in the View menu below and in the Mac
                // menu bar. The panel took the same keys until now, which meant
                // one of the two won by responder order and the other silently
                // did nothing.
                .keyboardShortcut("o", modifiers: [.command, .option])

                if model.canSelectBlocks && !settings.isPageView {
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
                PrintButton(exporter: exporter)
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

        // Redo, the half of the pair the bar had no room to draw. A long press
        // on Undo reaches it too, but a hold is not a gesture anyone is told
        // about, so this stays as the visible path. It stays in the overflow
        // in focus mode too, where undo is still up in the bar — the two are
        // useless apart.
        if model.offersUndoRedo, !settings.isPageView {
            ToolbarItem(placement: .secondaryAction) {
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
    private var viewMenu: some View {
        Menu {
            Section {
                Toggle(isOn: pageViewBinding) {
                    Label("Page View", systemImage: "doc.richtext")
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Toggle(isOn: focusModeBinding) {
                    Label("Focus Mode", systemImage: "moon")
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                Toggle(isOn: outlineModeBinding) {
                    Label("Outline Mode", systemImage: "list.bullet.indent")
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                // Read Aloud is not beside it: that one is a button out in the
                // bar now, and the silent reader keeps its seat here because
                // its play button reaches the voice anyway — one tap inside
                // the same sheet, which is also what keeps the voice reachable
                // in focus mode after the bar button bows out.
                Button {
                    showingReader = true
                } label: {
                    Label("Read Script", systemImage: "book")
                }
                .disabled(!model.hasScriptContent)
            }

            // Only offered where it changes anything: the page view lays the
            // script out on paper, which has a width of its own.
            if !settings.isPageView {
                Section {
                    Toggle(isOn: fullWidthBinding) {
                        Label("Full Page Width", systemImage: "arrow.left.and.right")
                    }
                    .keyboardShortcut("\\", modifiers: .command)
                }
            }

            Section("Show") {
                Toggle(isOn: option(\.showsPins, set: { options.showsPins = $0 })) {
                    Label("Pins", systemImage: "pin")
                }
                Toggle(isOn: option(\.showsBookmarks, set: { options.showsBookmarks = $0 })) {
                    Label("Bookmarks", systemImage: "bookmark")
                }
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
                .keyboardShortcut("+", modifiers: .command)

                Button {
                    settings.decreaseTextSize()
                } label: {
                    Label("Smaller", systemImage: "textformat.size.smaller")
                }
                .disabled(!settings.canDecreaseTextSize)
                .keyboardShortcut("-", modifiers: .command)

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
