//
//  ScriptModel.swift
//  scripty
//
//  State for one open screenplay: its blocks, characters, undo/redo
//  status, and a background sync-polling task that picks up edits made
//  elsewhere (e.g. in the web app).
//

import Foundation
import Observation

@Observable @MainActor
final class ScriptModel {
    let app: AppModel
    private(set) var project: Project

    /// Adopt a project resource the server just returned — a title-page save
    /// or a script import answers with the refreshed project, and the header
    /// would otherwise keep showing the old title.
    func adopt(_ updated: Project) {
        guard updated.id == project.id else { return }
        project = updated
    }

    private(set) var blocks: [Block] = []
    private(set) var blocksLinks = HALLinks()
    private(set) var characters: [Person] = []
    private(set) var charactersLinks = HALLinks()
    private(set) var canViewCharacters = true
    private(set) var documents: [TextDocument] = []
    private(set) var documentsLinks = HALLinks()
    /// The project's folders, both lists in one array — each says which list it
    /// belongs to, and the two screens filter it themselves.
    private(set) var documentFolders: [TextDocumentFolder] = []
    private(set) var documentFoldersLinks = HALLinks()
    /// Comments per element, keyed by block id. Empty until the server offers
    /// the rel, so a deployment that doesn't simply shows no badges.
    private(set) var commentCounts: [Int: Int] = [:]
    private(set) var undoRedo: UndoRedoStatus?

    /// Undo/redo for the changes the server never saw — see `LocalHistory`.
    /// Non-empty exactly while offline work is on screen; cleared the moment
    /// the sync lands and server history speaks for those changes instead.
    private(set) var localHistory = LocalHistory()

    private(set) var isLoading = false
    var errorMessage: String?

    /// A one-off confirmation shown after an undo/redo, mirroring the web
    /// editor's history toast — and shared with the lyric editor, which keeps
    /// the same kind of history and says so the same way. See `HistoryToast`.
    private(set) var historyToast: HistoryToast?

    /// Set while the writer is typing so a sync refresh doesn't clobber
    /// in-progress edits.
    var hasActiveEdit = false

    // MARK: - Inline editing state

    /// The block whose text view currently holds the caret, if any.
    var focusedBlockId: Int?
    /// Uncommitted per-block text; the source of truth while a block is
    /// focused, before the debounced PUT lands.
    private(set) var liveText: [Int: String] = [:]
    /// One-shot caret placements the text views apply and clear (used after a
    /// split or merge moves focus to a specific offset).
    var caretRequests: [Int: Int] = [:]

    /// Blocks whose latest text failed to reach the server. Their entry in
    /// `liveText` is the *only* copy of those words, so it is held rather than
    /// cleared until a retry lands — otherwise the row would snap back to the
    /// stale server content and the writing would be gone.
    private(set) var unsavedBlockIds: Set<Int> = []

    /// True while any element is holding text the server hasn't accepted.
    var hasUnsavedChanges: Bool { !unsavedBlockIds.isEmpty }

    /// Blocks whose latest write the server *refused* — a failure no retry
    /// fixes, as opposed to one that clears up when the route returns. Their
    /// words are still held (they are in `unsavedBlockIds` too, and the
    /// reconnect sweep retries them in case the refusal was about access that
    /// has since been restored), but the badge must stop saying "saving":
    /// nothing is in flight, and a writer who reads "saving" walks away.
    private(set) var failedBlockIds: Set<Int> = []

    /// True when something on screen needs the writer's attention rather than
    /// patience.
    var hasFailedSaves: Bool { !failedBlockIds.isEmpty }

    /// Elements whose removal is already on its way to the server.
    ///
    /// Backspace at the head of a line repeats for as long as the key is held,
    /// and a repeat comes round far faster than a round trip: every one of them
    /// used to start a whole fresh removal of the same element. Two merges of
    /// one line into the line above wrote the words there twice, and the second
    /// DELETE asked the server to remove something the first had already taken
    /// away — which it cannot tell from an element this writer may not touch,
    /// so it answers 403 and the writer is told they haven't permission to do
    /// the thing they just did. A press that lands on an element already on its
    /// way out is dropped: the caret has not moved yet, so the key is aimed at
    /// a line that is already gone.
    private var removingBlockIds: Set<Int> = []

    private var commitTasks: [Int: Task<Void, Never>] = [:]
    private static let commitDebounce: Duration = .milliseconds(600)

    private var retryTasks: [Int: Task<Void, Never>] = [:]
    private var retryAttempts: [Int: Int] = [:]
    /// Backoff for re-sending a failed commit. Runs out rather than retrying
    /// forever: past this the banner keeps saying the work is unsaved, and the
    /// next keystroke re-arms the whole cycle anyway.
    private static let retryDelays: [Duration] =
        [.seconds(2), .seconds(5), .seconds(15), .seconds(30), .seconds(60)]

    private var lastRevision: Int64 = 0
    private var syncTask: Task<Void, Never>?

    private static let syncInterval: Duration = .seconds(5)

    /// True when the server let us start an empty script — the only editable
    /// affordance an untouched project advertises.
    var canSeedScript: Bool { blocksLinks.contains(.createInitial) }

    /// Where unsaved text is kept across a relaunch. Ignored by observation:
    /// nothing draws from it — `liveText`/`unsavedBlockIds` stay the
    /// presentation truth, the store just makes them durable. Injectable so
    /// the tests can point it at a scratch directory; nil (signed out, demo)
    /// means unsaved work is held in memory only, as before.
    @ObservationIgnored private let draftStore: UnsavedDraftStore?

    /// The offline copies of this account's documents, refreshed on every
    /// successful load and read back when a load fails for want of a
    /// connection. Nil exactly when the draft store is (signed out, demo).
    @ObservationIgnored private let offlineStore: OfflineStore?

    /// Elements written while offline, waiting to be sent. Nil exactly when
    /// the draft store is (signed out, demo) — the demo backend answers
    /// offline anyway, so nothing there ever needs queueing.
    @ObservationIgnored private let createQueue: OfflineBlockQueue?

    /// Where a note's unsaved title and content wait out a lost connection.
    /// Nil exactly when the draft store is (signed out, demo).
    @ObservationIgnored private let documentDrafts: UnsavedDocumentStore?

    /// Documents whose latest save is held on this device — the note editor's
    /// status bar and the reconnect sweep both read this.
    private(set) var heldDocumentIds: Set<Int> = []

    /// Where words that cannot be sent *without a decision* wait. Nil exactly
    /// when the draft store is (signed out, demo), in which case `conflicts`
    /// below is the whole memory and lasts the session.
    @ObservationIgnored private let conflictStore: ConflictStore?

    /// The disagreements between this device's copy and the server's that are
    /// waiting on the writer. Held here as well as on disk because this is
    /// what the banner counts and the review sheet draws — the store only
    /// makes it outlive the launch.
    ///
    /// Deliberately *not* part of `hasHeldWork`: nothing retries a conflict.
    /// A sweep that treated these as work to push would either clobber the
    /// other version or spin forever, and the badge would promise a
    /// connection could finish something only a person can.
    private(set) var conflicts: [SyncConflict] = []

    var hasConflicts: Bool { !conflicts.isEmpty }

    /// Set when the script on screen is the offline copy rather than the
    /// server's answer, with when that copy was saved.
    private(set) var offlineCopySavedAt: Date?
    var isShowingOfflineCopy: Bool { offlineCopySavedAt != nil }

    /// The same answer for one document's words, by document id: set when
    /// `fetchDocument` fell back to the copy on this device, cleared when the
    /// server itself answered. A lyric editor has had this since offline
    /// reading landed; a note is prose fetched the same way and needs it for
    /// the same reason — and needs it *told*, since an out-of-date note must
    /// not look current, and words typed over a copy this device is only
    /// guessing at must not be sent as if they were an edit to the real thing.
    private(set) var documentCopySavedAt: [Int: Date] = [:]

    /// The last moment this script was known to be in step with the server —
    /// a load that came off the network, or the save that emptied the held
    /// set. The cloud badge's detail panel says it, because "saving…" alone
    /// leaves open whether that has been true for two seconds or since
    /// yesterday. Nil until the first round trip lands; a fallback to the
    /// offline copy deliberately does not set it, since nothing synced.
    private(set) var lastSyncedAt: Date?

    /// How many elements on screen exist only on this device. Drives the
    /// banner's count alongside the unsaved-text one.
    var pendingCreateCount: Int { blocks.filter(\.isLocal).count }

    init(app: AppModel, project: Project, draftStore: UnsavedDraftStore? = nil,
         offlineStore: OfflineStore? = nil, createQueue: OfflineBlockQueue? = nil,
         documentDrafts: UnsavedDocumentStore? = nil, conflictStore: ConflictStore? = nil) {
        self.app = app
        self.project = project
        self.draftStore = draftStore ?? app.draftScope.map { UnsavedDraftStore(scope: $0) }
        self.offlineStore = offlineStore ?? app.offlineStore
        self.createQueue = createQueue ?? app.draftScope.map { OfflineBlockQueue(scope: $0) }
        self.documentDrafts = documentDrafts ?? app.draftScope.map { UnsavedDocumentStore(scope: $0) }
        self.conflictStore = conflictStore ?? app.draftScope.map { ConflictStore(scope: $0) }
        // Left by an earlier run; the sweep's flags come up with the model so
        // the badge never claims "synced" over words still only on this device.
        heldDocumentIds = Set(self.documentDrafts?.drafts(projectId: project.id).keys.map { $0 } ?? [])
        // Same reason, one step further: a conflict nobody answered before the
        // app was last put down is still unanswered, and the version it holds
        // exists nowhere else.
        conflicts = self.conflictStore?.conflicts(collectionId: project.id) ?? []
    }

    // MARK: - Loading

    /// Everything a freshly opened screenplay needs: its elements, its cast,
    /// its history, its songs and notes, and the poll that keeps them current.
    ///
    /// Owned here and run unstructured, rather than left to the view's `.task`.
    /// SwiftUI cancels a `.task` the moment it takes that build of the view
    /// down, and opening a screenplay does exactly that — the detail pane is
    /// built and rebuilt as the navigation settles, so the load the first build
    /// started dies in flight. A cancelled request is deliberately silent (see
    /// `report`), which left nothing said, nothing cached and nothing retrying:
    /// the writer read "Empty Script" over a screenplay that was perfectly
    /// intact, until a pull-to-refresh — a load nothing cancels — fetched it.
    ///
    /// Held here, the load outlives whichever build of the view began it and
    /// lands in the model the surviving build is reading. A second caller joins
    /// the load already in flight rather than starting another alongside it.
    func open() async {
        if let openTask { return await openTask.value }
        openGeneration += 1
        let generation = openGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await loadEverything()
            // Before the sheets that need them: a remembered song editor is
            // reopened from this list the moment this returns.
            await loadDocuments()
            // Started here rather than in the view, so a screenplay whose open
            // was interrupted still has the one thing that keeps it current.
            startSyncPolling()
            // Work held by an earlier run must not wait for the network to
            // flap — before this, a queue written yesterday sat on disk until
            // connectivity happened to change with the script on screen. If
            // there is a route now, send it now; offline, the writes fail
            // fast at the client's own gate and stay held exactly as saved.
            if app.connectivity.isOnline, hasHeldWork { await syncHeldWork() }
        }
        openTask = task
        await task.value
        // Only if it is still ours: a view that came back has since started its
        // own, and that one is the load in charge.
        if generation == openGeneration { openTask = nil }
    }

    /// The opening load, so it can be joined rather than duplicated, and a
    /// count of them so the one that finishes clears only its own. See
    /// `open()`, which is the only thing that sets either.
    private var openTask: Task<Void, Never>?
    private var openGeneration = 0

    /// Private on purpose: awaiting this from a view's `.task` is the shape
    /// that stranded the writer on an empty script. Go through `open()`.
    private func loadEverything() async {
        isLoading = true
        defer { isLoading = false }
        await loadBlocks()
        await seedInitialBlockIfEmpty()
        await loadCharacters()
        await refreshUndoRedo()
    }

    /// Which edition's blocks to read, when the writer has chosen one other
    /// than the default. The server takes an `editionId` on the block
    /// collection; this is the link it advertised for that edition, so the
    /// choice travels as a link rather than as a parameter assembled here.
    var editionBlocksLink: HALLink? {
        didSet {
            guard editionBlocksLink != oldValue else { return }
            // Another edition's script is about to be on screen; steps
            // recorded against this one must not be applied to it.
            localHistory.clear()
            Task { await loadBlocks() }
        }
    }

    /// Bumped per load so a slow response can be recognised as superseded.
    /// Switching editions fires an unmanaged load per switch; without this,
    /// edition A's blocks can land after edition B's and the writer types
    /// into the wrong draft.
    private var blockLoadGeneration = 0

    func loadBlocks() async {
        guard let link = editionBlocksLink ?? project.link(.blocks) else { return }
        blockLoadGeneration += 1
        let generation = blockLoadGeneration
        // Only the default edition is cached (and only it falls back): a
        // chosen edition travels as a link that means nothing offline, and
        // showing edition A's copy under edition B's banner would be worse
        // than saying the switch needs a connection.
        let isDefaultEdition = editionBlocksLink == nil
        do {
            let data = try await app.client.data(for: link)
            let collection: HALCollection<Block> = try app.client.decode(from: data)
            guard generation == blockLoadGeneration else { return }
            adopt(collection)
            offlineCopySavedAt = nil
            errorMessage = nil
            wasAbandoned = false
            noteSyncedIfSettled()
            if isDefaultEdition, let store = offlineStore {
                store.save(data, .blocks(projectId: project.id))
                store.prune(keeping: project.id)
            }
        } catch {
            guard generation == blockLoadGeneration else { return }
            // The network failed — fall back to the copy saved last time the
            // script loaded. `adopt` lays persisted drafts and queued creates
            // on top exactly as it does on a live load, so words typed offline
            // stay the newest thing on screen and the retry machinery keeps
            // holding them.
            if isDefaultEdition, error.isRetryableAPIError,
               let snapshot = offlineStore?.load(.blocks(projectId: project.id)),
               let collection: HALCollection<Block> = try? app.client.decode(from: snapshot.data) {
                adopt(collection)
                offlineCopySavedAt = snapshot.savedAt
                errorMessage = nil
                wasAbandoned = false
            } else {
                // A cancelled load is the one failure nobody hears about: no
                // alert, no cached copy, no retry behind it. Remember it, so
                // the sync poll can put the script on screen rather than
                // leaving the writer to work out that a refresh would.
                wasAbandoned = error.isCancelledRequest
                report(error)
            }
        }
        await loadCommentCounts()
    }

    /// True when the last attempt at this script's elements was abandoned
    /// mid-flight rather than answered — see the catch above, which is the only
    /// place it is set. A load that genuinely failed is not abandoned: the
    /// writer was told, or was given the copy saved on this device.
    private var wasAbandoned = false

    /// Fetches how many comments each element carries, so the script can mark
    /// the discussed lines. Advertised on the block collection, so this is a
    /// no-op against a server that doesn't offer it — and a failure is silent:
    /// a missing badge is not worth an error banner over the writer's script.
    func loadCommentCounts() async {
        guard let link = blocksLinks[.commentCounts] else {
            commentCounts = [:]
            return
        }
        if let counts: BlockCommentCounts = try? await app.client.fetch(from: link) {
            commentCounts = counts.byBlockId
        }
    }

    /// How many comments one element carries; zero when it has none, since the
    /// server leaves the uncommented elements out of the map entirely.
    func commentCount(for block: Block) -> Int {
        commentCounts[block.id] ?? 0
    }

    /// Replace the script with a block collection the server just returned.
    ///
    /// The bulk endpoints answer with the whole refreshed collection rather
    /// than one resource, since retyping or deleting a set renumbers the rest;
    /// adopting it wholesale saves a follow-up GET and keeps the advertised
    /// affordances in step with the new contents.
    func adopt(_ collection: HALCollection<Block>) {
        blocks = collection.items.sorted { ($0.order ?? 0) < ($1.order ?? 0) }
        blocksLinks = collection.links
        // Every wholesale replacement threatens the same two things: text not
        // yet accepted, and elements the server has never seen. Re-applied
        // here rather than only on the loads that remembered to, so a bulk
        // retype answering with the fresh collection no longer wipes the
        // offline-written rows off the screen (they stayed queued on disk,
        // but invisible). Both are idempotent — work already on screen, or a
        // block already being edited, is left alone.
        adoptPersistedDrafts()
        adoptPendingCreates()
    }

    func loadCharacters() async {
        guard let link = project.link(.characters) else { return }
        do {
            let data = try await app.client.data(for: link)
            let collection: HALCollection<Person> = try app.client.decode(from: data)
            adoptCharacters(collection)
            canViewCharacters = true
            offlineStore?.save(data, .characters(projectId: project.id))
        } catch APIError.forbidden {
            canViewCharacters = false
        } catch {
            // Secondary to the script itself: fall back to the offline copy,
            // and failing that degrade quietly when the device is offline —
            // the offline banner explains everything; an alert over the
            // cached script the writer *can* read would not.
            if error.isRetryableAPIError,
               let snapshot = offlineStore?.load(.characters(projectId: project.id)),
               let collection: HALCollection<Person> = try? app.client.decode(from: snapshot.data) {
                adoptCharacters(collection)
            } else if error.isRetryableAPIError, !app.connectivity.isOnline {
                // Leave whatever was on screen.
            } else {
                report(error)
            }
        }
    }

    private func adoptCharacters(_ collection: HALCollection<Person>) {
        characters = collection.items.sorted { $0.displayName < $1.displayName }
        charactersLinks = collection.links
    }

    // MARK: - Block mutations (all gated by link presence)

    @discardableResult
    func createBlock(content: String, type: BlockType, personId: Int?) async -> Bool {
        guard let link = blocksLinks[.selfRel] ?? project.link(.blocks) else { return false }
        do {
            let _: Block = try await app.client.fetch(
                from: link, method: "POST",
                body: CreateBlockCommand(content: content,
                                         personId: personId,
                                         projectId: project.id,
                                         type: type.rawValue))
            await loadBlocks()
            await refreshUndoRedo()
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    @discardableResult
    func updateBlock(_ block: Block, content: String, personId: Int?, tags: String?) async -> Bool {
        guard let link = block.link(.update) else { return false }
        do {
            let updated: Block = try await app.client.fetch(
                from: link, method: "PUT",
                body: EditBlockCommand(content: content, personId: personId, tags: tags))
            replace(updated)
            await refreshUndoRedo()
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    func deleteBlock(_ block: Block) async {
        // An element that only ever existed on this device is deleted by
        // forgetting it — there is nothing to ask the server to remove, and
        // anything the writer anchored to it goes the same way. Recorded, so
        // the one delete that CAN be taken back offline can be.
        if block.isLocal {
            if let queue = createQueue { removeRecordingHistory(block.id, from: queue) }
            errorMessage = nil
            return
        }
        guard let link = block.link(.delete) else { return }
        // Only once, however fast the writer asks — see `removingBlockIds`.
        guard !removingBlockIds.contains(block.id) else { return }
        removingBlockIds.insert(block.id)
        defer { removingBlockIds.remove(block.id) }
        let held = liveText[block.id]
        stopWrites(to: block.id)
        do {
            try await app.client.data(for: link, method: "DELETE")
            blocks.removeAll { $0.id == block.id }
            // Nothing left to save it into.
            liveText[block.id] = nil
            markSaved(block.id)
            await refreshUndoRedo()
            errorMessage = nil
        } catch {
            // The element is still there, and so are any words it was holding:
            // put the write called off above back on its timer.
            if held != nil { scheduleCommit(block.id) }
            report(error)
        }
    }

    func toggleBookmark(_ block: Block) async {
        await toggle(block, rel: .toggleBookmark)
    }

    func togglePinned(_ block: Block) async {
        await toggle(block, rel: .togglePinned)
    }

    private func toggle(_ block: Block, rel: Rel) async {
        guard let link = block.link(rel) else { return }
        do {
            let updated: Block = try await app.client.fetch(from: link, method: "POST")
            replace(updated)
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    /// Internal (not private) so `ScriptModel+Formatting` can reuse it.
    func replace(_ updated: Block) {
        if let index = blocks.firstIndex(where: { $0.id == updated.id }) {
            blocks[index] = updated
        }
    }

    /// Put a block the server just created on screen below its anchor. The
    /// create answers with the one new element, not the renumbered collection,
    /// so this shows the reply without the full reload the caret would have to
    /// wait behind — Return has to feel like a keystroke, not a request. Any
    /// orders the server shifted underneath are adopted by the next full load
    /// (the sync poll, once focus leaves), exactly as edits from another
    /// device are.
    private func insert(_ created: Block, below source: Block) {
        guard !blocks.contains(where: { $0.id == created.id }) else { return }
        let index = blocks.firstIndex { $0.id == source.id }.map { $0 + 1 } ?? blocks.count
        blocks.insert(created, at: index)
    }

    /// Adopt a single block the server just rewrote: swap it in, drop any live
    /// edit buffer for it, and clear its unsaved flag. The tail shared by the
    /// per-block writes that answer with one block — a retype, a single replace
    /// — and the seam that lets those live in another file, where `liveText`
    /// and `markSaved` are out of reach.
    func adoptRewritten(_ block: Block) {
        replace(block)
        liveText[block.id] = nil
        markSaved(block.id)
    }

    // MARK: - Inline editing (continuous typing, like the web editor)

    /// The text to show for a block: the uncommitted live value while it is
    /// being edited, otherwise the last value the server confirmed.
    func currentText(_ block: Block) -> String {
        liveText[block.id] ?? block.content ?? ""
    }

    /// Move the caret to `block`, optionally requesting a specific offset. A nil
    /// block clears focus and resumes sync polling.
    func focus(_ blockId: Int?, caret: Int? = nil) {
        focusedBlockId = blockId
        hasActiveEdit = blockId != nil
        if let blockId, let caret { caretRequests[blockId] = caret }
    }

    /// Called on every keystroke: stash the text and (re)arm the debounced PUT.
    func liveEdit(_ block: Block, text: String) {
        liveText[block.id] = text
        // Fresh typing earns a fresh set of retries: the backoff having run
        // out ten minutes ago shouldn't leave this keystroke with none. A
        // refusal is re-judged the same way — new words are a new write.
        retryAttempts[block.id] = nil
        failedBlockIds.remove(block.id)
        scheduleCommit(block.id)
    }

    /// Put text on screen for a block without arming a save.
    ///
    /// For a caller that is about to persist the text itself — accepting a
    /// suggestion, say — where `liveEdit` would arm a second, racing write of
    /// the same words. Passing nil hands the model's own value back.
    func showLive(_ block: Block, text: String?) {
        liveText[block.id] = text
    }

    /// Focus left this block — flush any pending text and stop treating its live
    /// value as authoritative.
    ///
    /// The live copy survives a failed flush: it is the writer's only copy of
    /// those words until the retry lands.
    func blur(_ block: Block) async {
        // An element a merge or a delete has already claimed is not the caret
        // leaving a line — it is the line going, and whoever claimed it owns
        // its words and its flags until it has. A merge hands the caret to the
        // seam before it sends its DELETE, so this now fires *during* one; left
        // to run it would clear the live copy the rollback still has to put
        // back. See `removingBlockIds`.
        guard !removingBlockIds.contains(block.id) else { return }
        await commit(block.id)
        if focusedBlockId == block.id { focusedBlockId = nil }
        if !unsavedBlockIds.contains(block.id) { liveText[block.id] = nil }
        hasActiveEdit = focusedBlockId != nil
    }

    /// Call off everything still trying to *write* to an element, ahead of
    /// asking the server to remove it.
    ///
    /// A debounce armed by the last keystroke before a delete used to fire into
    /// the gap the DELETE was already in, and the PUT reached a server that had
    /// just removed the element. That comes back as the same refusal a delete
    /// of something already gone does — and it lands after the delete has
    /// tidied up, so the element that is no longer on screen is flagged as
    /// holding unsaved words for the rest of the session and the badge says the
    /// script has work in hand that nothing can ever save.
    ///
    /// The callers put it back if the delete fails: the element is still there
    /// in that case, and so are the words.
    private func stopWrites(to id: Int) {
        commitTasks[id]?.cancel()
        commitTasks[id] = nil
        retryTasks[id]?.cancel()
        retryTasks[id] = nil
        retryAttempts[id] = nil
    }

    private func scheduleCommit(_ id: Int) {
        commitTasks[id]?.cancel()
        commitTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.commitDebounce)
            guard !Task.isCancelled else { return }
            // Give the slot back before committing. `commit` cancels whatever
            // is parked there to supersede a debounce still counting down —
            // and what is parked there right now is *this* task, running this
            // very line. Leaving it would cancel the caller from inside the
            // call: the PUT below would go out on an already-cancelled task,
            // fail instantly as cancelled, and every debounced save would
            // reach the server only on the retry that follows it.
            self?.commitTasks[id] = nil
            await self?.commit(id)
        }
    }

    /// How a write of a block's text ended up — the distinction the callers
    /// that build on a write (Return's split, Backspace's merge) need and a
    /// plain `Block?` cannot carry: a write that was *refused* is not the
    /// same thing as a write that couldn't get out but left the words safe.
    private enum WriteOutcome {
        /// The server stored it — or a queued local create absorbed it, which
        /// is as stored as an offline element gets. Safe to build on.
        case saved(Block)
        /// The write couldn't get out, but the words are held on this device:
        /// flagged unsaved, snapshotted as a draft, and retrying. Offline, in
        /// practice — the footing every line written offline stands on.
        case held(Block)
        /// Refused for a reason a retry won't fix, or nothing to write with.
        case failed
    }

    /// PUT the block's live text if it differs from what the server has.
    @discardableResult
    private func commit(_ id: Int) async -> Block? {
        if case .saved(let block) = await commitOutcome(id) { return block }
        return nil
    }

    private func commitOutcome(_ id: Int) async -> WriteOutcome {
        // Nothing is written to an element already on its way out. A merge
        // hands the caret to the line above before it sends the DELETE, and
        // focus leaving is a flush (`blur`) — so without this the absorbed
        // element's last words went out as a PUT that reached the server just
        // after the DELETE had removed the element, which comes back as the
        // same refusal a delete of something already gone does, and flags a
        // row nobody can see as holding unsaved work for the rest of the
        // session. See `removingBlockIds` and `stopWrites(to:)`.
        guard !removingBlockIds.contains(id) else { return .failed }
        commitTasks[id]?.cancel()
        commitTasks[id] = nil
        guard let text = liveText[id],
              let block = blocks.first(where: { $0.id == id }) else { return .failed }
        // An element written offline has nothing to PUT to. Its words go into
        // the queue entry instead, so the create that eventually goes out
        // carries the newest version — and it stays flagged unsaved, because
        // it genuinely is. Returning the block lets Return chain off it.
        if block.isLocal {
            if let change = localHistory.textChange(blockId: id, to: text,
                                                    lastSaved: block.content ?? "") {
                localHistory.record([change])
            }
            createQueue?.updateContent(tempId: id, to: text, projectId: project.id)
            var updated = block
            updated.content = text
            replace(updated)
            unsavedBlockIds.insert(id)
            return .saved(updated)
        }
        if text == (block.content ?? "") {
            markSaved(id)
            return .saved(block)
        }
        // Changed words with nowhere to PUT them. `isEditable` is
        // `hasLink(.update) || isLocal`, so reaching here means the link went
        // away *while* the writer was typing — the element was locked, or their
        // access to the project narrowed. Not a network condition, so nothing
        // will clear up by itself; the words are held and flagged rather than
        // marked saved, which is what this used to do. `markSaved` would have
        // deleted the draft, and the only copy of that sentence with it.
        guard let link = block.link(.update) else {
            markUnsaved(id, after: APIError.forbidden)
            report(APIError.forbidden)
            return .failed
        }
        // Snapshot before the attempt, not only after a failure: between here
        // and the response the words exist nowhere but this process, and a
        // kill mid-flight (or right after the debounce fired) used to be the
        // end of them. Success removes the draft again in `markSaved`.
        persistDraft(id)
        do {
            let updated: Block = try await app.client.fetch(
                from: link, method: "PUT",
                body: EditBlockCommand(content: text, personId: block.personId, tags: block.tags))
            replace(updated)
            markSaved(id)
            refreshUndoRedoSoon()
            errorMessage = nil
            return .saved(updated)
        } catch {
            markUnsaved(id, after: error)
            reportUnlessRetrying(error)
            return error.isRetryableAPIError ? .held(block) : .failed
        }
    }

    /// Set (or clear) the tags on a single block — the web block editor's
    /// "Tags (comma separated)" field. The client otherwise only reached tags
    /// by entering selection mode and bulk-adding, which could append but never
    /// edit or remove them on one element. Rides the same `update` PUT the text
    /// auto-save uses, carrying the block's freshest text so a pending edit is
    /// not lost. An empty string *clears* the tags: the server (and demo) leave
    /// an absent field alone, so clearing must send "" rather than nil.
    @discardableResult
    func setTags(_ block: Block, to tags: String) async -> Block? {
        guard let link = block.link(.update) else { return nil }
        // Normalise the comma list the way the badges show it: trimmed, no
        // empties, single ", " separators. Empty collapses to "" to clear.
        let normalised = tags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        // Flush any debounced text commit first, then send the live text with
        // the new tags in one write so the two do not race.
        commitTasks[block.id]?.cancel()
        commitTasks[block.id] = nil
        let text = liveText[block.id] ?? block.content ?? ""
        do {
            let updated: Block = try await app.client.fetch(
                from: link, method: "PUT",
                body: EditBlockCommand(content: text, personId: block.personId, tags: normalised))
            replace(updated)
            markSaved(block.id)
            await refreshUndoRedo()
            errorMessage = nil
            return updated
        } catch {
            // The PUT carried the block's freshest words, and the debounced
            // commit that would have saved them was cancelled above — so when
            // the failure is the kind that clears up by itself, hold them
            // exactly as a failed auto-save would. Only the tag change is
            // dropped. A pure tag edit (no live text) has no words to hold.
            if liveText[block.id] != nil, error.isRetryableAPIError {
                markUnsaved(block.id, after: error)
                reportUnlessRetrying(error)
            } else {
                report(error)
            }
            return nil
        }
    }

    // MARK: - Unsaved-work bookkeeping

    /// The server has this block's text; the live copy is no longer precious.
    private func markSaved(_ id: Int) {
        localHistory.noteSaved(blockId: id)
        unsavedBlockIds.remove(id)
        failedBlockIds.remove(id)
        retryTasks[id]?.cancel()
        retryTasks[id] = nil
        retryAttempts[id] = nil
        draftStore?.remove(blockId: id, projectId: project.id)
        noteSyncedIfSettled()
    }

    /// Stamp "last synced" — but only when there is genuinely nothing left
    /// behind. A save that lands while four other elements are still held has
    /// not put this script in step with the server, and a timestamp claiming
    /// otherwise is worse than none.
    private func noteSyncedIfSettled() {
        guard !hasHeldWork else { return }
        lastSyncedAt = .now
    }

    /// A write failed. Flag the block so its live text is held, and — when the
    /// failure was the kind that might clear up by itself — try again on a
    /// backoff rather than making the writer notice and retype.
    ///
    /// This is also where an edit to a real element enters the local history:
    /// a write the server refused is a change only this device knows, which is
    /// exactly what local undo exists to take back. `textChange` returns nil
    /// when nothing moved since the last record, so the retries that land back
    /// here every backoff never duplicate a step.
    private func markUnsaved(_ id: Int, after error: Error) {
        if let text = liveText[id],
           let change = localHistory.textChange(
               blockId: id, to: text,
               lastSaved: blocks.first(where: { $0.id == id })?.content ?? "") {
            localHistory.record([change])
        }
        unsavedBlockIds.insert(id)
        persistDraft(id)
        guard error.isRetryableAPIError else {
            // Refused, not delayed. The words stay held — they are still the
            // only copy — but nothing is retrying on a timer, and the badge
            // has to say so rather than pulse "saving" forever.
            failedBlockIds.insert(id)
            return
        }
        failedBlockIds.remove(id)
        let attempt = retryAttempts[id] ?? 0
        guard attempt < Self.retryDelays.count else { return }
        retryAttempts[id] = attempt + 1
        let delay = Self.retryDelays[attempt]
        retryTasks[id]?.cancel()
        retryTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.commit(id)
        }
    }

    /// Snapshot a block's live text to disk, with the server's current content
    /// as the base — the restore path's evidence of whether the draft is still
    /// the newest thing anyone wrote.
    private func persistDraft(_ id: Int) {
        guard let store = draftStore, let text = liveText[id] else { return }
        store.save(UnsavedDraft(blockId: id, text: text,
                                baseText: blocks.first { $0.id == id }?.content,
                                savedAt: .now),
                   projectId: project.id)
    }

    /// Pick up whatever drafts a previous run left behind: re-adopt each as
    /// live text and arm the ordinary debounced commit, so the existing
    /// retry machinery and the unsaved-work banner take over. Idempotent —
    /// a block already being edited (or already restored) is left alone.
    ///
    /// A draft whose base no longer matches the server is not adopted and not
    /// thrown away either: someone edited that element elsewhere since the save
    /// failed, the server is last-write-wins, and pushing the old draft would
    /// clobber their newer words. Both versions go to `conflicts`, where the
    /// writer picks one. See `SyncConflict`.
    func adoptPersistedDrafts() {
        guard let store = draftStore else { return }
        var conflicted = 0
        for (id, draft) in store.drafts(projectId: project.id) {
            guard liveText[id] == nil, !unsavedBlockIds.contains(id) else { continue }
            guard let block = blocks.first(where: { $0.id == id }) else {
                // Not in this collection — possibly another edition's element.
                // Left on disk for the load that can see it.
                continue
            }
            let server = block.content ?? ""
            if draft.text == server {
                store.remove(blockId: id, projectId: project.id)
                continue
            }
            guard draft.baseText == nil || draft.baseText == server else {
                // Someone edited this element elsewhere since the save failed,
                // and the server is last-write-wins: pushing the draft would
                // clobber the newer words. Neither version is this client's to
                // discard, so the draft leaves the retry machinery — nothing
                // here is going to be sent on a timer — and both copies wait
                // together for the one person who can choose between them.
                store.remove(blockId: id, projectId: project.id)
                recordConflict(SyncConflict(
                    subject: .block(id: id), reason: .changedElsewhere,
                    mine: draft.text, theirs: server, base: draft.baseText,
                    label: block.blockType.label, detectedAt: draft.savedAt))
                conflicted += 1
                continue
            }
            liveText[id] = draft.text
            unsavedBlockIds.insert(id)
            scheduleCommit(id)
        }
        if conflicted > 0 {
            presentToast(conflicted == 1
                ? "An offline edit needs your choice — that line changed elsewhere"
                : "\(conflicted) offline edits need your choice — those lines changed elsewhere")
        }
    }

    // MARK: - Conflicts

    /// File a disagreement, or bring one already filed for the same thing up
    /// to date. The store is the durable copy; `conflicts` is what the screen
    /// reads, and stays right even signed out, where there is no store.
    private func recordConflict(_ conflict: SyncConflict) {
        if let store = conflictStore {
            store.record(conflict, collectionId: project.id)
            conflicts = store.conflicts(collectionId: project.id)
            return
        }
        var entry = conflict
        if let index = conflicts.firstIndex(where: { $0.id == conflict.id }) {
            // The store's rule, kept by hand: a repeat is the same
            // disagreement seen again, and when it began does not move.
            entry.detectedAt = conflicts[index].detectedAt
            entry.base = conflicts[index].base ?? conflict.base
            conflicts[index] = entry
        } else {
            conflicts.append(entry)
        }
        conflicts.sort { $0.detectedAt < $1.detectedAt }
    }

    private func forgetConflict(_ id: String) {
        conflictStore?.remove(id: id, collectionId: project.id)
        conflicts.removeAll { $0.id == id }
    }

    /// Keep the words typed on this device, over whatever the server has now.
    ///
    /// The choice is made once, here — after this the words go back into the
    /// ordinary held-work machinery (live on screen, snapshotted as a draft,
    /// retried on the usual backoff), which exists precisely so that words
    /// waiting on a connection are never lost. So the conflict is resolved
    /// even when this particular write does not land: a second copy of the
    /// same words sitting in `conflicts` would be counted twice by the banner
    /// and answered twice by the writer.
    ///
    /// Returns what became of the write, so the sheet can say "sent" or "kept
    /// on this device" rather than guessing.
    @discardableResult
    func keepMine(_ conflict: SyncConflict) async -> ConflictResolution {
        switch conflict.subject {
        case let .block(id):
            guard blocks.contains(where: { $0.id == id }) else { return .failed }
            forgetConflict(conflict.id)
            liveText[id] = conflict.mine
            unsavedBlockIds.insert(id)
            failedBlockIds.remove(id)
            // A decision is a fresh start, not a continuation of whatever
            // backoff this element had run out of days ago.
            retryAttempts[id] = nil
            switch await commitOutcome(id) {
            case .saved:
                // The words are the server's now; nothing on screen is
                // holding them and the live copy can go back to being a
                // mirror rather than the only copy.
                if !unsavedBlockIds.contains(id) { liveText[id] = nil }
                return .sent
            case .held: return .held
            case .failed: return .failed
            }
        case let .document(id):
            guard let document = documents.first(where: { $0.id == id }) else { return .failed }
            forgetConflict(conflict.id)
            // The base handed in is the copy this conflict was found against —
            // what the server said a moment ago — so if the write has to wait
            // and the note moves on again, the next sweep judges it against
            // the right thing rather than against a state from before the
            // divergence.
            switch await saveDocumentOutcome(document,
                                             title: conflict.mineTitle ?? document.title ?? "",
                                             content: conflict.mine,
                                             baseTitle: conflict.theirsTitle,
                                             baseContent: conflict.hasTheirs ? conflict.theirs : nil) {
            case .saved: return .sent
            case .held: return .held
            case .failed: return .failed
            }
        case .lyricLine:
            // A lyric line belongs to `SongBlockModel`, which keeps its own
            // conflicts against its own collection. Nothing to apply here.
            return .failed
        }
    }

    /// Let the server's version stand and drop this device's. Nothing to send:
    /// the words on screen already are the server's — this only stops asking.
    func keepTheirs(_ conflict: SyncConflict) {
        forgetConflict(conflict.id)
        // Belt and braces: if anything left a stale live copy over the row,
        // the server's words take the screen back.
        if case let .block(id) = conflict.subject, !unsavedBlockIds.contains(id) {
            liveText[id] = nil
        }
    }

    /// Answer every open conflict the same way. Offered because the common
    /// shape of this is a batch — one offline stretch, one other person
    /// working through the same scene — and going one by one to say the same
    /// thing ten times is its own small punishment.
    func keepAllMine() async {
        for conflict in conflicts where conflict.canKeepMine {
            await keepMine(conflict)
        }
    }

    func keepAllTheirs() {
        for conflict in conflicts { keepTheirs(conflict) }
    }

    // MARK: - Elements written offline

    /// Put a new element on screen that the server has never seen, and queue
    /// the create for the next time there is a connection.
    ///
    /// This is what Return, the + button and "Add Element Below" fall back to
    /// when the create request can't get out. Without it the writer simply
    /// cannot start a new line while offline — they can keep editing the lines
    /// that already exist, which is a strange half-offline to be in.
    ///
    /// Returns the stand-in so the caller can focus it, exactly as it would
    /// have focused the server's answer.
    @discardableResult
    private func createLocalBlock(below anchor: Block?, type: BlockType,
                                  content: String, personId: Int?) -> Block? {
        guard let queue = createQueue else { return nil }
        let tempId = queue.nextTempId(projectId: project.id)
        let insertAt = anchor
            .flatMap { a in blocks.firstIndex(where: { $0.id == a.id }).map { $0 + 1 } }
            ?? blocks.count
        let block = Block.local(tempId: tempId, projectId: project.id,
                                order: anchor?.order, content: content,
                                type: type, personId: personId)
        blocks.insert(block, at: insertAt)
        let entry = PendingBlockCreate(tempId: tempId,
                                       anchorId: anchor?.id ?? PendingBlockCreate.appendAnchor,
                                       type: type.rawValue,
                                       content: content,
                                       personId: personId,
                                       createdAt: .now)
        queue.enqueue(entry, projectId: project.id)
        localHistory.record([.create(row: LocalHistory.Row(entry: entry, index: insertAt))])
        // Counted as unsaved work so the banner speaks for it, and so the
        // reconnect sweep has a reason to look.
        unsavedBlockIds.insert(tempId)
        if !content.isEmpty { liveText[tempId] = content }
        errorMessage = nil
        return block
    }

    /// Re-materialise the elements queued by an earlier run (or held across a
    /// reload) on top of whatever the server just gave us.
    ///
    /// Runs after every adopt, for the same reason `adoptPersistedDrafts` does:
    /// a load replaces the collection wholesale, and the writer's un-sent lines
    /// have to survive that. Entries are walked in creation order so a chain of
    /// them lands in the order it was written.
    private func adoptPendingCreates() {
        guard let queue = createQueue else { return }
        for entry in queue.pending(projectId: project.id) {
            guard !blocks.contains(where: { $0.id == entry.tempId }) else { continue }
            // The anchor may be a real element, an earlier pending one, or
            // gone entirely (deleted elsewhere) — in which case the line still
            // belongs in the script, so it goes at the end rather than being
            // silently dropped.
            let insertAt = entry.isAppend
                ? blocks.count
                : (blocks.firstIndex { $0.id == entry.anchorId }.map { $0 + 1 } ?? blocks.count)
            let type = BlockType(rawValue: entry.type) ?? .action
            let precedingOrder = insertAt > 0 ? blocks[insertAt - 1].order : nil
            blocks.insert(Block.local(tempId: entry.tempId, projectId: project.id,
                                      order: precedingOrder,
                                      content: entry.content, type: type,
                                      personId: entry.personId),
                          at: insertAt)
            unsavedBlockIds.insert(entry.tempId)
        }
    }

    /// Send everything written offline, oldest first.
    ///
    /// Order is not an optimisation here: a later element may be anchored to an
    /// earlier one, so each create has to land (and have its real id recorded)
    /// before the next can name it. A failure that could clear up stops the
    /// drain and leaves the rest queued; one that never will drops that element
    /// alone — anything anchored to it re-anchors one link up and still lands —
    /// rather than blocking the queue forever or, worse, taking a night's
    /// writing with it.
    private func replayPendingCreates() async {
        guard let queue = createQueue else { return }
        var refused: [String] = []
        var resolvedAny = false
        // Once anything here lands or is given up on, the local steps describe
        // elements that no longer exist under their temp identities — history
        // belongs to the server again. Cleared on the way out, whatever mix of
        // successes the drain managed.
        defer { if resolvedAny || !refused.isEmpty { localHistory.clear() } }
        while let entry = queue.pending(projectId: project.id).first {
            // Resolve the anchor: a temp anchor has by now been sent and
            // mapped, since the queue is drained in order.
            var anchor: Block?
            if !entry.isAppend {
                let realId = entry.anchorId < 0
                    ? queue.realId(for: entry.anchorId, projectId: project.id)
                    : entry.anchorId
                anchor = realId.flatMap { id in blocks.first { $0.id == id } }
            }
            // No anchor (append, or the anchor is gone) means the end of the
            // script — the last element the server actually knows about.
            let source = anchor ?? blocks.last { !$0.isLocal }
            guard let link = source?.link(.createBelow) ?? blocksLinks[.createInitial] else {
                // Nothing on this script can take a new element: no edit
                // access any more, or an empty script with no seed link.
                refused.append(dropRefusedCreate(entry, from: queue))
                continue
            }
            // The words as they stand now, not as they stood when the line was
            // first typed — the writer has probably kept going.
            let content = liveText[entry.tempId] ?? entry.content
            do {
                let created: Block = try await app.client.fetch(
                    from: link, method: "POST",
                    body: CreateBelowCommand(content: content,
                                             personId: entry.personId,
                                             type: entry.type))
                queue.resolve(tempId: entry.tempId, realId: created.id, projectId: project.id)
                resolvedAny = true
                // Swap the real element in where the stand-in stood, rather
                // than just dropping it. The next entry in the queue may be
                // anchored to this one, and it resolves that anchor by looking
                // the real id up in `blocks` — so the created element has to be
                // there, with its `createBelow` link, before the loop goes on.
                // Removing it here instead would send the rest of a chain to
                // the end of the script.
                if let index = blocks.firstIndex(where: { $0.id == entry.tempId }) {
                    blocks[index] = created
                } else {
                    blocks.append(created)
                }
                // The caret may be sitting in the element that just changed id.
                if focusedBlockId == entry.tempId { focusedBlockId = created.id }
                if let caret = caretRequests.removeValue(forKey: entry.tempId) {
                    caretRequests[created.id] = caret
                }
                liveText[entry.tempId] = nil
                markSaved(entry.tempId)
            } catch {
                if error.isRetryableAPIError {
                    // Still no usable connection. Everything stays queued.
                    return
                }
                refused.append(dropRefusedCreate(entry, from: queue))
            }
        }
        if !refused.isEmpty {
            // Not `report`: this is not a failure the writer can retry, it is
            // news about work that could not be placed. The banner and the
            // alert both belong to things still in flight.
            presentToast(refusalToast(for: refused))
        }
    }

    /// Abandon one element the server refused: off the queue (its dependents
    /// re-anchor one link up and stay queued), off the screen, out of the
    /// bookkeeping. Returns the words it was holding, so the toast can quote
    /// what was lost rather than just admit that something was.
    private func dropRefusedCreate(_ entry: PendingBlockCreate,
                                   from queue: OfflineBlockQueue) -> String {
        let words = liveText[entry.tempId] ?? entry.content
        queue.dropSingle(tempId: entry.tempId, projectId: project.id)
        blocks.removeAll { $0.id == entry.tempId }
        liveText[entry.tempId] = nil
        markSaved(entry.tempId)
        return words
    }

    /// One refused line quotes itself — those words exist nowhere else any
    /// more, and a writer shown *which* line went missing can retype it.
    /// Several fall back to the count; a toast can't hold a scene.
    private func refusalToast(for refused: [String]) -> String {
        if refused.count == 1 {
            let words = refused[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else {
                return "An element written offline couldn't be added"
            }
            let snippet = words.count > 60
                ? words.prefix(60).trimmingCharacters(in: .whitespaces) + "…"
                : words
            return "This line couldn't be added: “\(snippet)”"
        }
        return "\(refused.count) elements written offline couldn't be added"
    }

    /// Abandon a queued element and anything anchored to it, on screen as well
    /// as on disk. Returns what went, for the callers that record the removal.
    @discardableResult
    private func dropPendingCreate(_ tempId: Int, from queue: OfflineBlockQueue) -> [Int] {
        let dropped = queue.drop(tempId: tempId, projectId: project.id)
        for id in dropped {
            blocks.removeAll { $0.id == id }
            liveText[id] = nil
            markSaved(id)
        }
        return dropped
    }

    /// Flush every pending debounced commit right now — the app is heading to
    /// the background, and the debounce window may outlive its execution time.
    /// Each block's text is snapshotted to disk first, so even a commit that
    /// never gets to run is covered by the restore path on next launch.
    func flushPendingCommits() async {
        let pending = Array(commitTasks.keys)
        for id in pending { persistDraft(id) }
        for id in pending { await commit(id) }
    }

    /// Whether anything is waiting to be sent — the question the opportunistic
    /// sync triggers ask before starting a drain, so a script with nothing
    /// held doesn't reload itself on every trip to the foreground.
    var hasHeldWork: Bool {
        hasUnsavedChanges || !heldDocumentIds.isEmpty
            || createQueue?.hasPending(projectId: project.id) == true
    }

    /// The same sweep below, asked for by hand from the cloud badge. It differs
    /// from the automatic one in a single way that matters to someone pressing
    /// a button: the debounce is not waited out. A writer who taps "Sync Now"
    /// half a second after their last keystroke means *that* word too, and
    /// watching the badge sit on "up to date" while the debounce runs would
    /// read as the button having done nothing.
    func syncNow() async {
        await flushPendingCommits()
        await syncHeldWork()
    }

    /// Push everything held on this device right now — unsaved text first,
    /// then the queued creates — rather than waiting out whatever backoff each
    /// element is on, then pull whatever changed elsewhere while we were away.
    /// Mirrors the web client's sync-on-reconnect, including its confirmation
    /// once everything lands.
    ///
    /// This used to run only when the connection flapped with the script on
    /// screen, which left a queue written yesterday waiting for the network to
    /// change its mind: opening the app online never sent it. Now every moment
    /// that could make sending possible lands here — the online edge, the app
    /// coming to the foreground, the script being opened with held work on
    /// disk — and the single-flight join keeps two of those coinciding (an
    /// online edge firing under a foreground sweep, say) from double-posting a
    /// queued create: the second caller waits out the first drain instead of
    /// starting its own beside it.
    func syncHeldWork() async {
        if let heldWorkSync { return await heldWorkSync.value }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.drainHeldWork()
        }
        heldWorkSync = task
        await task.value
        heldWorkSync = nil
    }

    private var heldWorkSync: Task<Void, Never>?

    private func drainHeldWork() async {
        let pending = unsavedBlockIds.sorted()
        // Existing elements first: a queued create is anchored to one of them,
        // and its own words ride on the create rather than on a PUT.
        for id in pending where id > 0 {
            // The sweep is a fresh chance, not a continuation: whatever
            // backoff an element had run out of, it earns a new budget here.
            retryAttempts[id] = nil
            await commit(id)
        }
        await replayPendingCreates()
        // Held notes ride the same sweep — their store outlives the editor
        // sheet, so a note written offline yesterday sends today with the
        // sheet long closed.
        await drainDocumentDrafts()
        // Not over active typing — the sync poll reloads after the writer
        // blurs (the commits above bumped the revision), clearing the
        // offline-copy flag with it.
        if !hasActiveEdit {
            await loadBlocks()
            await refreshUndoRedo()
        }
        if !pending.isEmpty, unsavedBlockIds.isEmpty {
            presentToast("All offline changes synced")
        }
        // Everything made it: those changes are the server's history now, and
        // ⌘Z should walk that rather than replay the offline session locally.
        // A drain that fell short keeps its steps — the writer is still
        // effectively offline, and they are still the only undo there is.
        if unsavedBlockIds.isEmpty { localHistory.clear() }
    }

    /// Give up on a speculative write (a merge that couldn't be persisted) and
    /// put the block's live text back the way it was. The failed write already
    /// recorded itself as a local step (see `markUnsaved`); the screen is
    /// being rolled back, so the record has to go with it.
    private func rollback(_ id: Int, to previous: String?) {
        if let attempted = liveText[id] {
            localHistory.unrecordText(blockId: id, after: attempted)
        }
        liveText[id] = previous
        if previous == nil {
            markSaved(id)
        } else {
            // The attempt that just failed snapshotted words the writer never
            // kept — the merged line, or the head of an abandoned split. The
            // draft is the crash-recovery copy, so it has to be rewound too or
            // a relaunch restores a version of the sentence nobody typed.
            persistDraft(id)
        }
    }

    /// Surface a failure the writer has to do something about. A failure we
    /// are already retrying is not one of those: the unsaved-work banner says
    /// so continuously, which beats a modal alert interrupting every keystroke
    /// for as long as the connection is down.
    private func reportUnlessRetrying(_ error: Error) {
        if error.isRetryableAPIError {
            app.handle(error)
        } else {
            report(error)
        }
    }

    /// Whether the script is collapsed to its outline right now.
    ///
    /// Writing has to know: outline mode narrows what may be *created* as well
    /// as what is shown, or Return, Tab and the + button would each put a fresh
    /// element into a script the writer cannot see and hand them a caret in
    /// mid-air. Read off the shared settings rather than threaded down from the
    /// view, the way `ScriptExportModel` reads the page setup — there is one
    /// script on screen and one answer.
    private var isOutlining: Bool { PresentationSettings.shared.isOutlineMode }

    /// The type a fresh element gets below one of `type`, honouring the mode.
    private func typeFollowing(_ type: BlockType) -> BlockType {
        isOutlining ? type.followingOutlineType : type.followingType
    }

    /// Return at `caret`: the text before the caret stays (with Fountain
    /// detection applied), the text after moves into a new element below whose
    /// type follows screenplay convention. Mirrors the web editor's Enter.
    func splitBlock(_ block: Block, caret: Int) async {
        let full = currentText(block)
        let clamped = max(0, min(caret, full.count))
        let splitIndex = full.index(full.startIndex, offsetBy: clamped)
        var before = String(full[..<splitIndex])
        let after = String(full[splitIndex...])

        var currentType = block.blockType
        // A detection that would leave the outline is dropped while outlining,
        // not applied and then hidden: `.`, `#` and `=` are exactly the markers
        // an outliner reaches for and all three land inside the mode, while the
        // rest would take the line the writer is on off the screen. The typed
        // text stays as typed, so nothing is lost — only unconverted.
        if let detected = FountainDetector.detect(before),
           !isOutlining || detected.type.isOutlineType {
            before = detected.content
            currentType = detected.type
        }

        // Persist the (possibly retyped, possibly trimmed) current block.
        //
        // If that write is refused, abandon the split rather than pressing
        // on: the text after the caret only belongs in a new element once the
        // text before it is safely stored. `before` stays in `liveText`
        // (flagged unsaved) and `after` stays on screen as part of this
        // block, so the writer's line is intact and Return can simply be
        // pressed again.
        liveText[block.id] = before
        let outcome = currentType != block.blockType
            ? await retypeOutcome(block, to: currentType, content: before)
            : await commitOutcome(block.id)
        let source: Block
        switch outcome {
        case .saved(let updated):
            source = updated
        case .held(let heldBlock):
            // The head couldn't be written, but its words are held on this
            // device and retrying — the same footing every line written
            // offline stands on, so Return keeps working: the tail becomes a
            // queued element behind the held head, and `before` stays live.
            // Only when there is nowhere to queue the tail does the split
            // back out whole, exactly as a refused write does.
            if let created = createLocalBlock(below: heldBlock,
                                              type: typeFollowing(currentType),
                                              content: after, personId: nil) {
                focus(created.id, caret: 0)
            } else {
                localHistory.unrecordText(blockId: block.id, after: before)
                liveText[block.id] = full
                // The refused write snapshotted `before`; the whole line is
                // what is on screen now, so the draft has to say so or a crash
                // here restores the writer to half their sentence.
                persistDraft(block.id)
            }
            return
        case .failed:
            // The failed write recorded itself (see markUnsaved); the split
            // is being abandoned, so the record goes too.
            localHistory.unrecordText(blockId: block.id, after: before)
            liveText[block.id] = full
            persistDraft(block.id)
            return
        }
        liveText[block.id] = nil

        let newType = typeFollowing(currentType)
        // A source that is itself pending has no createBelow link to use, so
        // the new line is queued behind it rather than refused.
        if source.isLocal {
            if let created = createLocalBlock(below: source, type: newType,
                                              content: after, personId: nil) {
                focus(created.id, caret: 0)
            }
            return
        }
        // No link on a *real* element means no permission to add one, which is
        // not something a queue can fix — deliberately still a silent no-op,
        // not an offline create that could never be sent.
        guard let link = source.link(.createBelow) else { return }
        do {
            let created: Block = try await app.client.fetch(
                from: link, method: "POST",
                body: CreateBelowCommand(content: after,
                                         personId: nil,
                                         type: newType.rawValue))
            insert(created, below: source)
            refreshUndoRedoSoon()
            focus(created.id, caret: 0)
            errorMessage = nil
        } catch {
            // Return has to keep working with no connection — this is the
            // whole of writing. Hold the line locally and send it later.
            guard error.isRetryableAPIError,
                  let created = createLocalBlock(below: source, type: newType,
                                                 content: after, personId: nil) else {
                report(error)
                return
            }
            focus(created.id, caret: 0)
        }
    }

    /// Create a new, empty element of `type` immediately below `block` — the
    /// element half of the web's create-below "+" menu (its Songs/Notes half
    /// is `insertDocument`). The type rides `CreateBelowCommand`, which the
    /// `createBelow` endpoint already honours; Return uses the same call with
    /// the following-type convention. This is the only touch route to the
    /// types the element-type bar leaves off (Text, Dual Dialogue, Page Break).
    func insertBlock(below block: Block, type: BlockType) async {
        if block.isLocal {
            if let created = createLocalBlock(below: block, type: type,
                                              content: "", personId: nil) {
                focus(created.id, caret: 0)
            }
            return
        }
        // As in `splitBlock`: a missing link is a permission answer, not a
        // connection one, so it stays a no-op rather than becoming a queued
        // create that the server would never accept.
        guard let link = block.link(.createBelow) else { return }
        do {
            let created: Block = try await app.client.fetch(
                from: link, method: "POST",
                body: CreateBelowCommand(content: "", personId: nil, type: type.rawValue))
            insert(created, below: block)
            refreshUndoRedoSoon()
            focus(created.id, caret: 0)
            errorMessage = nil
        } catch {
            guard error.isRetryableAPIError,
                  let created = createLocalBlock(below: block, type: type,
                                                 content: "", personId: nil) else {
                report(error)
                return
            }
            focus(created.id, caret: 0)
        }
    }

    /// Backspace at offset 0: merge this block into the previous editable one
    /// and place the caret at the seam.
    func mergeIntoPrevious(_ block: Block) async {
        // `isEditable`, not `hasLink(.update)`: a line written offline has no
        // links at all, but it is exactly the line Backspace should merge into
        // — skipping it would splice this block's text into an earlier,
        // wrong element.
        guard let index = blocks.firstIndex(where: { $0.id == block.id }), index > 0,
              let previous = blocks[..<index].last(where: { $0.isEditable }) else { return }
        // The key repeats faster than the round trip it starts. Held down, this
        // used to fold the same line into the one above once per repeat — the
        // words written there twice over, and a DELETE sent for an element
        // already deleted. See `removingBlockIds`.
        guard !removingBlockIds.contains(block.id) else { return }
        removingBlockIds.insert(block.id)
        defer { removingBlockIds.remove(block.id) }
        let previousText = currentText(previous)
        let seam = previousText.count
        let merged = previousText + currentText(block)

        // A merge that can't be persisted must leave both elements exactly as
        // they were — half a merge would show the writer their own words twice.
        let restore = liveText[previous.id]
        liveText[previous.id] = merged

        // The caret moves to the seam now, before anything is awaited — not
        // after the round trip, which is where it used to move.
        //
        // The absorbed element is the one holding first responder, and taking
        // its row off screen resigns that with nothing standing ready to take
        // it: UIKit reads a first responder that goes nowhere as the writer
        // being finished and starts putting the keyboard away, so the keyboard
        // dropped and then came straight back up as the line above claimed it
        // a turn later. Handing the caret over while both rows are still on
        // screen makes it an ordinary handoff — the keyboard never moves.
        //
        // It is also what the seam is *for*: Backspace has to land like a
        // keystroke, not like a request, and the merged words are already on
        // screen above (`liveText`, set just now) for the caret to sit in.
        //
        // The absorbed element's own words are in that line now, so a debounce
        // still counting down for it has nothing left to say — and saying it
        // into the gap the DELETE below opens gets the whole merge refused.
        // Called off here rather than after the PUT, because focus leaving is
        // itself a flush (`blur`); `commitOutcome` turns that one away while
        // the element is claimed. See `stopWrites(to:)` and `removingBlockIds`.
        let held = liveText[block.id]
        stopWrites(to: block.id)
        focus(previous.id, caret: seam)
        // Every way out from here that leaves the absorbed element on screen
        // has to put the caret back where the writer left it, at the head of
        // the line they pressed Backspace in, and give its unflushed words
        // back the write that was called off above.
        func restoreAbsorbed() {
            liveText[block.id] = held
            if held != nil { scheduleCommit(block.id) }
            // Withdrawn, not just overruled: a caret request is answered by
            // taking first responder (`applyCaret`), so one left standing for
            // the line above would pull the keyboard straight back off the
            // element being restored.
            caretRequests[previous.id] = nil
            focus(block.id, caret: 0)
        }

        switch await commitOutcome(previous.id) {
        case .saved:
            liveText[previous.id] = nil   // model value is now authoritative for the merged row
        case .held:
            // The merged words are held on this device and retrying — footing
            // enough when the absorbed element is one the server has never
            // seen, because taking it off screen needs no DELETE. A server
            // element does need one, and a held merge over a failed delete
            // would show the words twice, so that case backs out whole. The
            // merged text stays in `liveText`: it is the writer's only copy.
            guard block.isLocal else {
                rollback(previous.id, to: restore)
                restoreAbsorbed()
                return
            }
        case .failed:
            rollback(previous.id, to: restore)
            restoreAbsorbed()
            return
        }

        if block.isLocal {
            // Nothing to delete on the server: the absorbed element only ever
            // existed here, so dropping its queued create is the whole of it —
            // it takes the stand-in off screen too. Recorded as its own step
            // behind the text one — undoing a merge offline is two presses,
            // the same two changes it was made of.
            if let queue = createQueue { removeRecordingHistory(block.id, from: queue) }
            liveText[block.id] = nil
            refreshUndoRedoSoon()
            return
        }
        // No delete link is the refusal arriving early rather than late, and it
        // needs the same answer: the merged text has already been written to
        // the previous block, so taking this one off screen anyway would show
        // the writer their own words twice the next time the script loaded.
        guard let deleteLink = block.link(.delete) else {
            liveText[previous.id] = previousText
            await commit(previous.id)
            restoreAbsorbed()
            report(APIError.forbidden)
            return
        }
        do {
            try await app.client.data(for: deleteLink, method: "DELETE")
        } catch {
            // The absorbed element is still there, so the merged text now
            // appears twice. Put the previous block back and leave the
            // script as it was before the Backspace — including the write
            // called off just above, since those words are unsaved again.
            liveText[previous.id] = previousText
            await commit(previous.id)
            restoreAbsorbed()
            report(error)
            return
        }
        // The merged row was already swapped in by the commit above, so the
        // absorbed element just comes off screen — no reload the caret would
        // have to wait behind, and no caret to move either: it left for the
        // seam before the round trip started. The server's renumbering is
        // adopted by the next full load (the sync poll, once focus leaves).
        blocks.removeAll { $0.id == block.id }
        liveText[block.id] = nil
        markSaved(block.id)
        refreshUndoRedoSoon()
    }

    /// Retype a block in place (the element-type bar and Tab cycling).
    func changeType(_ block: Block, to type: BlockType) async {
        _ = await retype(block, to: type, content: liveText[block.id])
    }

    /// Tab / Shift-Tab: advance the focused block through the logical cycle.
    func cycleType(_ block: Block, backward: Bool) async {
        let type = block.blockType
        await changeType(block, to: isOutlining
                         ? type.cyclingOutlineType(backward: backward)
                         : type.cyclingType(backward: backward))
    }

    @discardableResult
    private func retype(_ block: Block, to type: BlockType, content: String?) async -> Block? {
        if case .saved(let updated) = await retypeOutcome(block, to: type, content: content) {
            return updated
        }
        return nil
    }

    private func retypeOutcome(_ block: Block, to type: BlockType,
                               content: String?) async -> WriteOutcome {
        // A local element's type is just another field of its queued create,
        // so Tab cycling and the element-type bar work offline on the line the
        // writer is actually typing.
        if block.isLocal {
            // One step for the whole gesture: a split that retypes the line
            // carries text and type together, and one undo should too.
            var changes: [LocalChange] = []
            if let content,
               let change = localHistory.textChange(blockId: block.id, to: content,
                                                    lastSaved: block.content ?? "") {
                changes.append(change)
            }
            if block.type != type.rawValue {
                changes.append(.retype(blockId: block.id,
                                       before: block.type ?? BlockType.action.rawValue,
                                       after: type.rawValue))
            }
            localHistory.record(changes)
            createQueue?.updateType(tempId: block.id, to: type.rawValue, projectId: project.id)
            if let content {
                liveText[block.id] = content
                createQueue?.updateContent(tempId: block.id, to: content, projectId: project.id)
            }
            var updated = block
            updated.type = type.rawValue
            if let content { updated.content = content }
            replace(updated)
            return .saved(updated)
        }
        guard let link = block.link(.setType) else {
            // Server without setType: fall back to a content-only commit.
            if let content { liveText[block.id] = content; return await commitOutcome(block.id) }
            return .saved(block)
        }
        do {
            let updated: Block = try await app.client.fetch(
                from: link, method: "POST",
                body: SetTypeCommand(type: type.rawValue, content: content,
                                     personId: block.personId, tags: block.tags))
            adoptRewritten(updated)
            refreshUndoRedoSoon()
            errorMessage = nil
            return .saved(updated)
        } catch {
            // The retype carried the writer's text with it, so a failure here
            // loses words just as a failed commit would. Hold the live copy
            // and retry it as a plain content save — the type change is the
            // part worth dropping, not the writing.
            if content != nil {
                markUnsaved(block.id, after: error)
                reportUnlessRetrying(error)
                return error.isRetryableAPIError ? .held(block) : .failed
            }
            report(error)
            return .failed
        }
    }

    /// Live force-marker retype: the writer just typed a leading `.`/`@`/`>`/…
    /// and the element must change *now*, mid-keystroke — the reflow the web
    /// editor's `input` handler does. Unlike `changeType`, this must not clobber
    /// keystrokes that arrive while the retype is in flight: whatever text is
    /// live when the server answers wins over the (older) content the retype
    /// carried, so typing straight through a `.INT` never loses the letters
    /// typed after the marker.
    func retypeLive(_ block: Block, to type: BlockType) async {
        // A line written offline reflows the same way: its type is a field of
        // its queued create, so the force marker works mid-keystroke there
        // too, instead of dying on the missing server link below.
        if block.isLocal {
            _ = await retype(block, to: type, content: liveText[block.id])
            return
        }
        guard let link = block.link(.setType) else { return }
        // The keystroke that triggered this already armed a content commit;
        // cancel it so it does not race the retype with a type-less write.
        commitTasks[block.id]?.cancel()
        commitTasks[block.id] = nil
        let content = liveText[block.id] ?? block.content ?? ""
        do {
            let updated: Block = try await app.client.fetch(
                from: link, method: "POST",
                body: SetTypeCommand(type: type.rawValue, content: content,
                                     personId: block.personId, tags: block.tags))
            replace(updated)
            // Keep any letters that landed during the round-trip; only when the
            // live copy still matches what we sent is the server value the
            // authoritative one and the buffer can be dropped.
            if let newer = liveText[block.id], newer != content {
                scheduleCommit(block.id)
            } else {
                liveText[block.id] = nil
                markSaved(block.id)
            }
            await refreshUndoRedo()
            errorMessage = nil
        } catch {
            // Losing the type change is acceptable; losing the writing is not,
            // so hold the live copy and let the backoff retry it as a plain save.
            markUnsaved(block.id, after: error)
            reportUnlessRetrying(error)
        }
    }

    /// Seed the single element an untouched script needs before there is
    /// anything to type into.
    ///
    /// The server decides what that element is, and it makes an action line —
    /// which outline mode does not show, so a writer starting a script while
    /// outlining would press the button and be left staring at the same empty
    /// page. Turn it into a scene heading before handing over the caret; a
    /// refused retype leaves the seeded element as it is rather than losing it.
    func seedInitialBlock() async {
        guard let link = blocksLinks[.createInitial] else { return }
        do {
            let created: Block = try await app.client.fetch(from: link, method: "POST")
            await loadBlocks()
            if isOutlining, let seeded = blocks.first(where: { $0.id == created.id }),
               !seeded.blockType.isOutlineType {
                await retype(seeded, to: .scene, content: nil)
            }
            await refreshUndoRedo()
            focus(created.id, caret: 0)
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    /// The same seed, done as part of opening rather than waiting to be asked.
    ///
    /// A brand new screenplay used to land on an empty state whose only move
    /// was "Start Writing" — a button that answers its own question, standing
    /// between naming a screenplay and typing into it. Naming one is the writer
    /// saying they want to write it, so the first element is theirs already.
    ///
    /// Called from `loadEverything` so it runs inside the opening load: the
    /// spinner is still up, and the writer never sees the empty state blink
    /// past. The button stays for every case this deliberately skips.
    ///
    /// Only on a live load that worked. Offline the create would fail at the
    /// client's own gate and turn opening a script into an error alert; a
    /// cached copy's links are last session's; and a load that already failed
    /// has told the writer once, which is enough. The demo backend is always
    /// reachable whatever the route says, as elsewhere.
    private func seedInitialBlockIfEmpty() async {
        guard blocks.isEmpty, canSeedScript,
              errorMessage == nil, !isShowingOfflineCopy,
              app.connectivity.isOnline || app.isDemo else { return }
        await seedInitialBlock()
    }

    /// Append an empty element at the end and focus it (the toolbar +).
    ///
    /// An action line ordinarily, a scene heading while outlining: the + is the
    /// one way to add an element with nothing focused, and in outline mode it
    /// is the way a writer starts a script's outline from nothing at all.
    func appendBlock() async {
        if blocks.isEmpty {
            await seedInitialBlock()
            return
        }
        guard let last = blocks.last else { return }
        let type: BlockType = isOutlining ? .scene : .action
        // A pending last element can't anchor a server create, but it can
        // anchor another pending one.
        if last.isLocal {
            if let created = createLocalBlock(below: last, type: type,
                                              content: "", personId: nil) {
                focus(created.id, caret: 0)
            }
            return
        }
        guard let link = last.link(.createBelow) else {
            await createBlock(content: "", type: type, personId: nil)
            return
        }
        do {
            let created: Block = try await app.client.fetch(
                from: link, method: "POST",
                body: CreateBelowCommand(content: "", personId: nil, type: type.rawValue))
            insert(created, below: last)
            refreshUndoRedoSoon()
            focus(created.id, caret: 0)
            errorMessage = nil
        } catch {
            guard error.isRetryableAPIError,
                  let created = createLocalBlock(below: last, type: type,
                                                 content: "", personId: nil) else {
                report(error)
                return
            }
            focus(created.id, caret: 0)
        }
    }

    // MARK: - Undo / redo

    func refreshUndoRedo() async {
        guard let link = project.link(.undoRedoStatus) else { return }
        do {
            undoRedo = try await app.client.fetch(UndoRedoStatus.self, from: link)
        } catch {
            // Non-critical; leave stale status rather than surfacing an alert.
        }
    }

    /// Refresh the undo/redo status without making the caller wait for the
    /// round trip. The status only feeds the toolbar buttons, so nothing on
    /// the typing path — Return above all — should ever queue behind it.
    private func refreshUndoRedoSoon() {
        Task { await refreshUndoRedo() }
    }

    /// Whether there is anything to undo right now. Local steps count whatever
    /// the route says — they need no server. The server's own history only
    /// counts while a request could plausibly reach it (the demo backend
    /// always can); offline, a button armed by a stale status would just be a
    /// button that raises an alert.
    var canUndo: Bool {
        localHistory.canUndo ||
            ((app.connectivity.isOnline || app.isDemo) && undoRedo?.canUndo == true)
    }

    var canRedo: Bool {
        localHistory.canRedo ||
            ((app.connectivity.isOnline || app.isDemo) && undoRedo?.canRedo == true)
    }

    /// Whether the undo/redo pair belongs in the toolbar at all: the server
    /// advertised its history, or this device is holding steps of its own.
    /// Without the second half, a script opened offline (its status never
    /// fetched) would hide the pair exactly when the local steps exist.
    var offersUndoRedo: Bool { undoRedo != nil || !localHistory.isEmpty }

    /// Local steps first: they are strictly newer than anything in the server's
    /// history — they exist precisely because they never reached it — so they
    /// are what "undo the last change" means while any of them stand.
    func undo() async {
        if applyLocalStep(.undo) { return }
        await performUndoRedo(rel: .undo)
    }

    func redo() async {
        if applyLocalStep(.redo) { return }
        await performUndoRedo(rel: .redo)
    }

    private func performUndoRedo(rel: Rel) async {
        guard let link = undoRedo?.link(rel) else { return }
        // The web's toast reads a server `blockDelta`, defined there as the net
        // change in block count across the step; the count on hand before and
        // after the reload is the same number, so no server field is needed.
        let before = blocks.count
        // A step is not an edit to the elements on screen. The server rebuilds
        // the whole edition from its snapshot — every existing element is
        // deleted and re-inserted — so every id on this screen is about to stop
        // existing, and anything still aimed at one of them has to be settled
        // before the step goes out.
        //
        // Flushed rather than cancelled, and flushed *first*: the words typed in
        // the last half second are a change like any other, and a writer
        // reaching for undo means to take them back — which only works if the
        // server has them when it takes its own checkpoint. The lyric editor's
        // `step` opens with `commitAll()` for exactly this reason.
        //
        // Left running instead, a debounce fires into the gap the rebuild opens
        // and PUTs to an element the server has just destroyed. It cannot tell
        // that from an element this writer may not touch, so it answers 403 —
        // and the writer is told "You don't have permission to do that" over an
        // undo that worked. See `stopWrites(to:)`, which is the same hazard
        // around a delete.
        await flushPendingCommits()
        do {
            undoRedo = try await app.client.fetch(UndoRedoStatus.self, from: link, method: "POST")
            await loadBlocks()
            settleWritesAfterStep()
            // The reload rewrote the script under any local steps (only the
            // redo side can still hold them here — undo drains local first).
            localHistory.clear()
            errorMessage = nil
            presentHistoryToast(rel: rel, delta: blocks.count - before)
        } catch {
            report(error)
        }
    }

    /// Put the writing state back in step with a script the server has just
    /// rebuilt underneath it.
    ///
    /// Two things are stale after a step, and both are the writer's problem
    /// rather than bookkeeping. An element the step took away is gone for good:
    /// a backoff still counting down for its id raises the refusal this whole
    /// path exists to avoid, a moment later and with nothing on screen to
    /// explain it, and its unsaved flag leaves the badge claiming held work for
    /// an element that is not there. And an element that survived now says what
    /// the snapshot says — but the live copy taken off the screen still holds
    /// the words the step was pressed to be rid of, so the line the writer was
    /// typing in would sit there unchanged, as though undo had missed it, and
    /// put those words back on the next keystroke.
    ///
    /// Held words are the exception on both counts: they exist nowhere else, so
    /// a block still flagged unsaved keeps its live copy, exactly as it does
    /// across an ordinary reload.
    private func settleWritesAfterStep() {
        let present = Set(blocks.map(\.id))
        let aimedAt = Set(liveText.keys)
            .union(unsavedBlockIds)
            .union(failedBlockIds)
            .union(commitTasks.keys)
            .union(retryTasks.keys)
        for id in aimedAt {
            guard present.contains(id) else {
                stopWrites(to: id)
                liveText[id] = nil
                unsavedBlockIds.remove(id)
                failedBlockIds.remove(id)
                draftStore?.remove(blockId: id, projectId: project.id)
                continue
            }
            if !unsavedBlockIds.contains(id) { liveText[id] = nil }
        }
        noteSyncedIfSettled()
    }

    // MARK: - Local history (undoing what the server never saw)

    private enum HistoryDirection { case undo, redo }

    /// Pop and apply one local step. Returns false when that side of the
    /// history is empty and the caller should try the server instead.
    private func applyLocalStep(_ direction: HistoryDirection) -> Bool {
        let popped = direction == .undo ? localHistory.popUndo() : localHistory.popRedo()
        guard let step = popped else { return false }
        let countBefore = blocks.count
        // A step's changes were recorded in the order they happened, so undo
        // walks them backwards and redo forwards. Applying hands back a
        // refreshed copy of each change: a queued element's words keep moving
        // after its create was recorded, and the snapshot that crosses to the
        // other stack has to be the words as they stand now.
        let ordered = direction == .undo ? step.changes.reversed() : step.changes
        let applied = ordered.map { apply($0, direction) }
        let refreshed = LocalStep(changes: direction == .undo ? applied.reversed() : applied)
        if direction == .undo {
            localHistory.pushUndone(refreshed)
        } else {
            localHistory.pushRedone(refreshed)
        }
        presentHistoryToast(rel: direction == .undo ? .undo : .redo,
                            delta: blocks.count - countBefore)
        return true
    }

    /// Apply one side of one change, returning the change refreshed with the
    /// state it just captured off the screen (see `applyLocalStep`).
    private func apply(_ change: LocalChange, _ direction: HistoryDirection) -> LocalChange {
        switch change {
        case .text(let blockId, let before, let after):
            applyText(blockId, to: direction == .undo ? before : after)
            return change
        case .retype(let blockId, let before, let after):
            applyType(blockId, to: direction == .undo ? before : after)
            return change
        case .create(var row):
            if direction == .undo {
                row = refreshedRow(row)
                removePendingRows([row])
            } else {
                restorePendingRows([row])
            }
            return .create(row: row)
        case .remove(var rows):
            if direction == .undo {
                restorePendingRows(rows)
            } else {
                rows = rows.map(refreshedRow)
                removePendingRows(rows)
            }
            return .remove(rows: rows)
        }
    }

    /// Put `text` back on a block, through the same channels the words
    /// originally travelled: a queued element's entry is updated in place, a
    /// real element's text becomes the live copy and re-arms the ordinary
    /// debounced save — which succeeds, retries or queues exactly as typing
    /// the restoration by hand would have.
    private func applyText(_ blockId: Int, to text: String) {
        guard let block = blocks.first(where: { $0.id == blockId }) else { return }
        localHistory.noteApplied(blockId: blockId, text: text)
        if block.isLocal {
            createQueue?.updateContent(tempId: blockId, to: text, projectId: project.id)
            var updated = block
            updated.content = text
            replace(updated)
            liveText[blockId] = text
            unsavedBlockIds.insert(blockId)
        } else {
            liveEdit(block, text: text)
        }
    }

    /// Retype steps are only ever recorded for queued elements (a real
    /// element's retype needs the server and fails cleanly offline), so a
    /// block that is no longer local has nothing to apply to.
    private func applyType(_ blockId: Int, to raw: String) {
        guard let block = blocks.first(where: { $0.id == blockId }), block.isLocal else { return }
        createQueue?.updateType(tempId: blockId, to: raw, projectId: project.id)
        var updated = block
        updated.type = raw
        replace(updated)
    }

    /// The row as it stands right now — freshest queued words, current screen
    /// position — for the copy that crosses to the other stack.
    private func refreshedRow(_ row: LocalHistory.Row) -> LocalHistory.Row {
        var row = row
        if let live = createQueue?.pending(projectId: project.id)
            .first(where: { $0.tempId == row.entry.tempId }) {
            row.entry = live
        }
        if let index = blocks.firstIndex(where: { $0.id == row.entry.tempId }) {
            row.index = index
        }
        return row
    }

    private func removePendingRows(_ rows: [LocalHistory.Row]) {
        guard let queue = createQueue else { return }
        for row in rows { dropPendingCreate(row.entry.tempId, from: queue) }
    }

    /// Re-materialise removed rows: entries back in the outbox in the order
    /// they were first written (a later one may be anchored to an earlier
    /// one), stand-ins back on screen by position, exactly as
    /// `adoptPendingCreates` rebuilds them after a reload.
    private func restorePendingRows(_ rows: [LocalHistory.Row]) {
        guard let queue = createQueue else { return }
        for row in rows
        where !queue.pending(projectId: project.id).contains(where: { $0.tempId == row.entry.tempId }) {
            queue.enqueue(row.entry, projectId: project.id)
        }
        for row in rows.sorted(by: { $0.index < $1.index }) {
            let tempId = row.entry.tempId
            guard !blocks.contains(where: { $0.id == tempId }) else { continue }
            let at = min(max(row.index, 0), blocks.count)
            let precedingOrder = at > 0 ? blocks[at - 1].order : nil
            blocks.insert(Block.local(tempId: tempId, projectId: project.id,
                                      order: precedingOrder,
                                      content: row.entry.content,
                                      type: BlockType(rawValue: row.entry.type) ?? .action,
                                      personId: row.entry.personId),
                          at: at)
            unsavedBlockIds.insert(tempId)
            localHistory.noteApplied(blockId: tempId, text: row.entry.content)
        }
    }

    /// Drop a pending element (with its anchored chain, as always) and record
    /// the removal, so the deletion a writer asked for can be undone.
    private func removeRecordingHistory(_ tempId: Int, from queue: OfflineBlockQueue) {
        let pendingBefore = queue.pending(projectId: project.id)
        let indices = Dictionary(uniqueKeysWithValues: blocks.enumerated().map { ($1.id, $0) })
        let dropped = Set(dropPendingCreate(tempId, from: queue))
        let rows = pendingBefore
            .filter { dropped.contains($0.tempId) }
            .map { LocalHistory.Row(entry: $0, index: indices[$0.tempId] ?? blocks.count) }
        guard !rows.isEmpty else { return }
        localHistory.record([.remove(rows: rows)])
    }

    /// Mirrors the web's `historyToastMessage`: a positive delta means the step
    /// brought elements back (an undone delete or a redone insert), which is
    /// worth naming; anything else gets the generic confirmation. "Element" is
    /// the client's word for a block throughout its menus.
    private func presentHistoryToast(rel: Rel, delta: Int) {
        presentToast(HistoryToast.message(undoing: rel == .undo, restored: delta,
                                          noun: "element"))
    }

    /// The transient confirmation capsule the view floats over the script —
    /// undo/redo acknowledgements and the offline sync's all-clear share it.
    private func presentToast(_ text: String) {
        historyToast = .next(after: historyToast, text)
    }

    // MARK: - Sync polling

    func startSyncPolling() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.syncInterval)
                // Gone as well as cancelled: `stopSyncPolling` is what normally
                // ends this, and it is the screen closing that calls it — but
                // the opening load can now outlive that screen and start a poll
                // just after it left. Left to `self?`, that poll would tick
                // every five seconds against nothing for the life of the app.
                guard !Task.isCancelled, let self else { return }
                await pollSync()
            }
        }
    }

    func stopSyncPolling() {
        syncTask?.cancel()
        syncTask = nil
    }

    private func pollSync() async {
        guard !hasActiveEdit else { return }
        // The script never arrived, and nothing else is going to fetch it. Take
        // the tick as the retry rather than reading a revision off a screen
        // with nothing on it — the baseline below would settle against an empty
        // script and every later tick would then agree that nothing had
        // changed. Ahead of the sync link, and not behind it: a screenplay the
        // server offers no sync rel for still has to arrive.
        if wasAbandoned {
            await loadBlocks()
            await refreshUndoRedo()
            return
        }
        guard let base = project.link(.syncStatus) else { return }
        let link = base.addingQuery(["since": String(lastRevision)])
        do {
            let status: SyncStatus = try await app.client.fetch(from: link)
            guard status.exists ?? true else { return }
            let revision = status.revision ?? lastRevision
            if lastRevision == 0 {
                // First poll establishes the baseline; the blocks were just loaded.
                lastRevision = revision
                return
            }
            if (status.changed ?? false) && revision != lastRevision {
                lastRevision = revision
                await loadBlocks()
                await refreshUndoRedo()
            }
        } catch {
            // Transient polling errors are ignored; the next tick retries.
        }
    }

    /// Internal (not private) so `ScriptModel+Formatting` can reuse it.
    func report(_ error: Error) {
        // Nothing cancelled is ever shown — see `isCancelledRequest`.
        guard !error.isCancelledRequest else { return }
        app.handle(error)
        errorMessage = error.localizedDescription
    }

    // MARK: - The project itself

    /// Whether the screenplay can be renamed from this screen — the same
    /// `update` affordance the list's Rename is gated on, so a reader is
    /// offered nothing.
    var canRenameProject: Bool { project.hasLink(.update) }

    /// Renames the screenplay without leaving it, as the web header's
    /// click-to-rename does. Only the name is sent: every title-page field and
    /// the team assignment are left out, and left out means unchanged (see
    /// `EditProjectCommand`), so a rename never disturbs the front matter.
    ///
    /// Returns the refreshed project so the caller can hand it to the list
    /// behind this screen, which is still showing the old name.
    @discardableResult
    func renameProject(to title: String) async -> Project? {
        guard let link = project.link(.update) else { return nil }
        do {
            let updated: Project = try await app.client.fetch(
                from: link, method: "PUT", body: EditProjectCommand(title: title))
            adopt(updated)
            errorMessage = nil
            return updated
        } catch {
            report(error)
            return nil
        }
    }

    /// Retitles the screenplay from the heading at the top of the script —
    /// which is not always the project's own name.
    ///
    /// `displayTitle`, what both the writing column and the reader head the
    /// page with, shows the screenplay title where the title page sets one and
    /// the project name otherwise. So the field this writes to follows the one
    /// on screen: typing over a heading that reads "THE LONG WAY HOME" edits
    /// the title page's field and leaves the filing name alone, and typing
    /// over one showing the project name is the ordinary rename above. Either
    /// way the writer changed the words they were looking at, which is the only
    /// rule an edit made in place can be judged by — the alternative is a
    /// heading that visibly does not take.
    ///
    /// The project name still rides along, because `EditProjectCommand`
    /// requires it; sending back the one already stored leaves it unchanged.
    @discardableResult
    func retitleScreenplay(to title: String) async -> Project? {
        let screenplay = (project.screenplayTitle ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !screenplay.isEmpty else { return await renameProject(to: title) }
        guard let link = project.link(.update) else { return nil }
        do {
            let updated: Project = try await app.client.fetch(
                from: link, method: "PUT",
                body: EditProjectCommand(title: project.title ?? title,
                                         screenplayTitle: title))
            adopt(updated)
            errorMessage = nil
            return updated
        } catch {
            report(error)
            return nil
        }
    }

    // MARK: - Characters

    @discardableResult
    func createCharacter(name: String, fullName: String) async -> Bool {
        guard let link = charactersLinks[.selfRel] ?? project.link(.characters) else { return false }
        do {
            let _: Person = try await app.client.fetch(
                from: link, method: "POST",
                body: CreatePersonCommand(name: name, fullName: fullName,
                                          actorId: nil, projectId: project.id))
            await loadCharacters()
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    @discardableResult
    func updateCharacter(_ person: Person, name: String, fullName: String) async -> Bool {
        guard let link = person.link(.update) else { return false }
        do {
            let _: Person = try await app.client.fetch(
                from: link, method: "PUT",
                body: EditPersonCommand(name: name, fullName: fullName,
                                        actorId: person.actorId, projectId: person.projectId))
            await loadCharacters()
            await loadBlocks()   // dialogue rows show personName
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    func deleteCharacter(_ person: Person) async {
        guard let link = person.link(.delete) else { return }
        do {
            try await app.client.data(for: link, method: "DELETE")
            characters.removeAll { $0.id == person.id }
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    // MARK: - Documents (songs & notes)

    /// The project advertises a `documents` link only when songs/notes are
    /// reachable for this user; the toolbar entry is gated on it.
    var canViewDocuments: Bool { project.hasLink(.documents) }

    var songs: [TextDocument] { documents.filter { $0.kind == .song } }
    var notes: [TextDocument] { documents.filter { $0.kind != .song } }

    func loadDocuments() async {
        guard let link = documentsLinks[.selfRel] ?? project.link(.documents) else { return }
        do {
            let data = try await app.client.data(for: link)
            let collection: HALCollection<TextDocument> = try app.client.decode(from: data)
            adoptDocuments(collection)
            errorMessage = nil
            offlineStore?.save(data, .documents(projectId: project.id))
        } catch {
            // Same shape as loadCharacters: the offline copy, else quiet
            // degradation while offline, else the writer hears about it.
            if error.isRetryableAPIError,
               let snapshot = offlineStore?.load(.documents(projectId: project.id)),
               let collection: HALCollection<TextDocument> = try? app.client.decode(from: snapshot.data) {
                adoptDocuments(collection)
                errorMessage = nil
            } else if error.isRetryableAPIError, !app.connectivity.isOnline {
                // Leave whatever was on screen.
            } else {
                report(error)
            }
        }
    }

    private func adoptDocuments(_ collection: HALCollection<TextDocument>) {
        documents = collection.items.sorted { ($0.sortOrder ?? 0) < ($1.sortOrder ?? 0) }
        documentsLinks = collection.links
    }

    // MARK: - Document folders

    /// The folders of one list, in the order their headings should read.
    func folders(for kind: DocumentType) -> [TextDocumentFolder] {
        documentFolders.forList(kind)
    }

    /// Whether this reader may make a folder — advertised on the folder
    /// collection for an editor, empty list or not, so it doubles as the "may
    /// arrange" gate the whole folder UI hangs off.
    var canCreateFolder: Bool { documentFoldersLinks.contains(.createFolder) }

    /// Whether a ticked selection can be filed in one call.
    var canBulkMoveDocuments: Bool { documentsLinks.contains(.bulkMoveToFolder) }

    /// Loads the project's folders.
    ///
    /// Both lists at once, unlike the web, which asks per page: this screen
    /// switches between Songs and Notes without another round trip, and a
    /// folder is four small fields. That is what an unscoped fetch means to the
    /// server — the same rule the document listing follows, where no `type` is
    /// every type.
    func loadDocumentFolders() async {
        guard let link = documentFoldersLinks[.selfRel] ?? documentsLinks[.folders] else { return }
        let cache = OfflineStore.Kind.documentFolders(projectId: project.id)
        do {
            let data = try await app.client.data(for: link)
            let collection: HALCollection<TextDocumentFolder> = try app.client.decode(from: data)
            adoptFolders(collection)
            errorMessage = nil
            offlineStore?.save(data, cache)
        } catch {
            // The same three-way fallback `loadDocuments` makes: this device's
            // copy, else quiet degradation while offline, else say so. A list
            // drawn without its folders is not wrong, only flatter.
            if error.isRetryableAPIError,
               let snapshot = offlineStore?.load(cache),
               let collection: HALCollection<TextDocumentFolder> = try? app.client.decode(from: snapshot.data) {
                adoptFolders(collection)
                errorMessage = nil
            } else if error.isRetryableAPIError, !app.connectivity.isOnline {
                // Leave whatever was on screen.
            } else {
                report(error)
            }
        }
    }

    private func adoptFolders(_ collection: HALCollection<TextDocumentFolder>) {
        documentFolders = collection.items
        documentFoldersLinks = collection.links
    }

    /// Makes a folder in one of the two lists, and hands it back.
    ///
    /// Returned rather than acknowledged, because the one gesture worth having
    /// is "put this song in a new folder called…" — which needs the folder that
    /// was just made to file the song into. Found by name after the reload: the
    /// server refuses a duplicate name in a list, so within one list a name
    /// identifies exactly one folder.
    ///
    /// nil for a refusal, which the server explains in words meant to be read;
    /// `errorMessage` carries them.
    @discardableResult
    func createFolder(named name: String, for kind: DocumentType) async -> TextDocumentFolder? {
        guard let link = documentFoldersLinks[.createFolder] else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            // `type` says which list the folder lands in. The answer is then
            // scoped to that one list — which is why it is thrown away and the
            // folders re-read unscoped: adopting it would drop the other
            // list's folders on the floor until the next full load.
            _ = try await app.client.data(
                for: link.addingQuery(["type": kind.rawValue]),
                method: "POST", body: FolderNameCommand(name: trimmed))
            await loadDocumentFolders()
            errorMessage = nil
            return folders(for: kind).first { $0.name == trimmed }
        } catch {
            report(error)
            return nil
        }
    }

    @discardableResult
    func renameFolder(_ folder: TextDocumentFolder, to name: String) async -> Bool {
        guard let link = folder.link(.renameFolder) else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != folder.name else { return false }
        do {
            let collection: HALCollection<TextDocumentFolder> = try await app.client.fetch(
                from: link, method: "PUT", body: FolderNameCommand(name: trimmed))
            adoptFolders(collection)
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Removes a folder. Nothing filed under it is deleted, so the documents
    /// have to be re-read: each one that was in here comes back unfiled.
    @discardableResult
    func deleteFolder(_ folder: TextDocumentFolder) async -> Bool {
        guard let link = folder.link(.deleteFolder) else { return false }
        do {
            let data = try await app.client.data(for: link, method: "DELETE")
            let collection: HALCollection<TextDocumentFolder> = try app.client.decode(from: data)
            adoptFolders(collection)
            await loadDocuments()
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Files one document under a folder, or takes it out of the one it is in
    /// when `folder` is nil.
    @discardableResult
    func moveDocument(_ document: TextDocument, to folder: TextDocumentFolder?) async -> Bool {
        guard let link = document.link(.moveToFolder) else { return false }
        do {
            let collection: HALCollection<TextDocument> = try await app.client.fetch(
                from: link, method: "POST", body: MoveToFolderCommand(folderId: folder?.id))
            adoptDocuments(collection)
            // The counts on the headings came from the folder collection, and
            // one of them just changed.
            await loadDocumentFolders()
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Files the ticked rows in one call.
    @discardableResult
    func bulkMoveDocuments(_ ids: [Int], to folder: TextDocumentFolder?) async -> Bool {
        guard let link = documentsLinks[.bulkMoveToFolder], !ids.isEmpty else { return false }
        do {
            let collection: HALCollection<TextDocument> = try await app.client.fetch(
                from: link, method: "POST",
                body: BulkMoveToFolderCommand(ids: ids, folderId: folder?.id))
            adoptDocuments(collection)
            await loadDocumentFolders()
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Fetches the full document (list items carry only a preview).
    func fetchDocument(_ document: TextDocument) async -> TextDocument? {
        guard let link = document.link(.selfRel) else { return document }
        let cache = OfflineStore.Kind.document(projectId: document.projectId ?? project.id,
                                               documentId: document.id)
        do {
            let data = try await app.client.data(for: link)
            let full: TextDocument = try app.client.decode(from: data)
            errorMessage = nil
            documentCopySavedAt[document.id] = nil
            offlineStore?.save(data, cache)
            return full
        } catch {
            // The copy this device kept, as `loadDocuments` and the lyric
            // loader both fall back to theirs — and stamped, so the editor can
            // say whose words these are and refuse to treat them as the base
            // an offline edit will be judged against.
            if error.isRetryableAPIError,
               let snapshot = offlineStore?.load(cache),
               let cached: TextDocument = try? app.client.decode(from: snapshot.data) {
                errorMessage = nil
                documentCopySavedAt[document.id] = snapshot.savedAt
                return cached
            }
            report(error)
            return nil
        }
    }

    /// What became of a document being created. The editor needs the middle
    /// case kept apart from a refusal: a create that couldn't get out is worth
    /// trying again on the next keystroke and says nothing alarming, while one
    /// the server turned down is neither.
    ///
    /// There is deliberately no `held` here, as there is for a save. Holding
    /// means "on disk, and the reconnect sweep will send it", and the sweep
    /// works document by document against the server's copy — of which a
    /// document that was never created has none. The words stay where they
    /// are, on screen, in an editor that will not let itself be dismissed
    /// without asking.
    enum DocumentCreateOutcome {
        case created(TextDocument)
        /// Carries the failure, because not every caller has an editor to put
        /// a status line in — an intent asked to take a note by voice has only
        /// the sentence it says back.
        case unreachable(Error)
        case failed
    }

    /// Creates a document and says how it went. What the editor's autosave
    /// uses: the first save of a new song or note is a POST rather than a PUT,
    /// and a create that fails while the writer is still typing must not raise
    /// an alert per debounce.
    func createDocumentOutcome(title: String, content: String,
                               type: DocumentType) async -> DocumentCreateOutcome {
        guard let link = documentsLinks[.selfRel] ?? project.link(.documents) else { return .failed }
        do {
            let created: TextDocument = try await app.client.fetch(
                from: link, method: "POST",
                body: CreateDocumentCommand(projectId: project.id, title: title,
                                            documentType: type.rawValue, content: content))
            await loadDocuments()
            errorMessage = nil
            return .created(created)
        } catch {
            // Abandoned, or offline: nothing was refused, so there is nothing
            // to tell the writer beyond what the editor's own status line
            // already says.
            guard !error.isCancelledRequest, !error.isRetryableAPIError else {
                return .unreachable(error)
            }
            report(error)
            return .failed
        }
    }

    /// The optional-shaped create, for callers with nowhere to put a status
    /// line: every failure is reported, as it was before the editor needed to
    /// tell "not sent" apart from "refused".
    @discardableResult
    func createDocument(title: String, content: String, type: DocumentType) async -> TextDocument? {
        switch await createDocumentOutcome(title: title, content: content, type: type) {
        case .created(let document):
            return document
        case .unreachable(let error):
            report(error)
            return nil
        case .failed:
            return nil
        }
    }

    /// What became of a document save. The note editor's status bar needs the
    /// middle case: "held" is not "failed" — the words are on disk and the
    /// sweep will send them, so leaving the sheet loses nothing.
    enum DocumentSaveOutcome {
        case saved
        /// The write couldn't get out, but the title and content are on this
        /// device and the reconnect sweep will push them.
        case held
        /// Refused for a reason a retry won't fix, or nothing to write with.
        case failed
    }

    /// Writes a document and disturbs nothing else. What the note editor's
    /// autosave uses: a save every second of typing cannot also pull the
    /// documents list and the script's blocks down each time, and while the
    /// editor is open neither of them is on screen to be stale. The editor asks
    /// for that refresh once, on its way out.
    @discardableResult
    func saveDocument(_ document: TextDocument, title: String, content: String) async -> Bool {
        await saveDocumentOutcome(document, title: title, content: content) == .saved
    }

    /// The outcome-shaped save. `baseTitle`/`baseContent` are what the caller
    /// last saw the server hold — the staleness evidence a held draft carries
    /// so a later restore or drain can refuse to clobber newer words. A draft
    /// already held for this document keeps its original base: the divergence
    /// began there, not at the latest keystroke.
    @discardableResult
    func saveDocumentOutcome(_ document: TextDocument, title: String, content: String,
                             baseTitle: String? = nil, baseContent: String? = nil)
        async -> DocumentSaveOutcome {
        guard let link = document.link(.update) else { return .failed }
        // Snapshot before the attempt, like the block path: between here and
        // the response the words exist nowhere but this process.
        holdDocument(document.id, title: title, content: content,
                     baseTitle: baseTitle, baseContent: baseContent)
        do {
            let _: TextDocument = try await app.client.fetch(
                from: link, method: "PUT",
                body: EditDocumentCommand(projectId: project.id, title: title,
                                          documentType: document.kind.rawValue, content: content))
            documentDrafts?.remove(documentId: document.id, projectId: project.id)
            heldDocumentIds.remove(document.id)
            errorMessage = nil
            return .saved
        } catch {
            // An abandoned request is not a failed one, and it must not read
            // as a refusal either — the drain sets refused drafts aside for
            // good. The pre-flight snapshot is on disk, which is exactly what
            // held means.
            guard !error.isCancelledRequest else { return .held }
            guard error.isRetryableAPIError else {
                // Refused. The draft stays on disk — the words are still the
                // writer's only copy — but the sheet must say "couldn't save",
                // and the alert is earned.
                report(error)
                return .failed
            }
            // Held, quietly: the sheet's own status line says where the words
            // are, and an alert per debounced autosave would bury the writer.
            return .held
        }
    }

    /// Record a document's words as held on this device. Keeps an existing
    /// draft's base — the server state when divergence began — over the one
    /// passed now.
    private func holdDocument(_ id: Int, title: String, content: String,
                              baseTitle: String?, baseContent: String?) {
        heldDocumentIds.insert(id)
        guard let store = documentDrafts else { return }
        let existing = store.draft(documentId: id, projectId: project.id)
        store.save(UnsavedDocumentDraft(documentId: id, title: title, content: content,
                                        baseTitle: existing?.baseTitle ?? baseTitle,
                                        baseContent: existing?.baseContent ?? baseContent,
                                        savedAt: .now),
                   projectId: project.id)
    }

    /// The held words for a document, if any — what the editor sheet opens
    /// with instead of the server's copy, so a relaunch resumes the writing
    /// rather than silently showing the words the writer already replaced.
    func heldDocumentDraft(for document: TextDocument) -> UnsavedDocumentDraft? {
        documentDrafts?.draft(documentId: document.id, projectId: project.id)
    }

    /// The editor sheet found what the sweep looks for: it opened over a note
    /// this device is holding words for, and the server's copy has moved on
    /// since. Same treatment as the sweep's, from the other side — the draft
    /// stops being work to send, and both versions wait for the answer.
    func quarantineDocumentDraft(_ draft: UnsavedDocumentDraft,
                                 serverTitle: String, serverContent: String) {
        discardDocumentDraft(for: draft.documentId)
        recordConflict(SyncConflict(
            subject: .document(id: draft.documentId), reason: .changedElsewhere,
            mine: draft.content, mineTitle: draft.title,
            theirs: serverContent, theirsTitle: serverTitle,
            base: draft.baseContent,
            label: serverTitle.isEmpty ? draft.title : serverTitle,
            detectedAt: draft.savedAt))
    }

    /// The conflicts filed against one document — what its editor sheet shows,
    /// where the script's own banner shows all of them.
    func conflicts(forDocument id: Int) -> [SyncConflict] {
        conflicts.filter { $0.subject == .document(id: id) }
    }

    /// Drop a document's held words — the editor adopting a draft found stale,
    /// or a writer discarding their own edits.
    func discardDocumentDraft(for id: Int) {
        documentDrafts?.remove(documentId: id, projectId: project.id)
        heldDocumentIds.remove(id)
    }

    /// Send every held document now. Runs inside the reconnect sweep, after
    /// the blocks: same promise, different store.
    ///
    /// The staleness gate needs the server's current copy (the list carries
    /// only a preview), fetched quietly — a sweep that still can't reach the
    /// server must leave the drafts held, not raise alerts.
    private func drainDocumentDrafts() async {
        guard let store = documentDrafts else { return }
        var landed = false
        // The list is what the drain judges "deleted" against, so it must be
        // a loaded one: before the first load every draft would read as a
        // ghost. `open()` loads documents before the sweep runs, but a sweep
        // can also arrive from a connectivity flap on a screen that never
        // needed the list.
        let listIsLoaded = documentsLinks[.selfRel] != nil || !documents.isEmpty
        for draft in store.drafts(projectId: project.id).values.sorted(by: { $0.documentId < $1.documentId }) {
            guard let document = documents.first(where: { $0.id == draft.documentId }),
                  let link = document.link(.selfRel) else {
                if listIsLoaded {
                    // The note is gone — deleted here or elsewhere. Held
                    // words for a document that no longer exists cannot ever
                    // land; carrying them as held work means a badge that
                    // counts a ghost forever. They stop being work to send
                    // and become something to read: a whole note's writing is
                    // too much to drop on a toast's say-so, and copying it
                    // somewhere else is the only rescue left.
                    discardDocumentDraft(for: draft.documentId)
                    recordConflict(SyncConflict(
                        subject: .document(id: draft.documentId), reason: .targetDeleted,
                        mine: draft.content, mineTitle: draft.title, theirs: "",
                        base: draft.baseContent, label: draft.title,
                        detectedAt: draft.savedAt))
                    presentToast("Your edit to “\(draft.title)” is kept here — that note was deleted")
                }
                continue
            }
            guard let full: TextDocument = try? await app.client.fetch(from: link) else { continue }
            let serverTitle = full.title ?? ""
            let serverContent = full.content ?? ""
            if draft.title == serverTitle && draft.content == serverContent {
                // Finished business — the server already says this.
                discardDocumentDraft(for: draft.documentId)
                continue
            }
            let baseMatches = (draft.baseContent == nil && draft.baseTitle == nil)
                || (draft.baseContent == serverContent && (draft.baseTitle ?? serverTitle) == serverTitle)
            guard baseMatches else {
                // Someone edited this note elsewhere since the save failed,
                // and the server is last-write-wins: pushing the draft would
                // clobber the newer words. Neither version is the sweep's to
                // throw away, so both wait for the writer.
                discardDocumentDraft(for: draft.documentId)
                recordConflict(SyncConflict(
                    subject: .document(id: draft.documentId), reason: .changedElsewhere,
                    mine: draft.content, mineTitle: draft.title,
                    theirs: serverContent, theirsTitle: serverTitle,
                    base: draft.baseContent, label: serverTitle.isEmpty ? draft.title : serverTitle,
                    detectedAt: draft.savedAt))
                presentToast("“\(draft.title)” needs your choice — it changed elsewhere")
                continue
            }
            switch await saveDocumentOutcome(full, title: draft.title, content: draft.content) {
            case .saved:
                landed = true
            case .failed:
                // Refused — a failure no sweep will fix, and a draft that
                // stays would re-raise the same alert on every reconnect. It
                // leaves the sweep, but the words themselves stay: a refusal
                // is the one case where the writer's copy may be the only one
                // that exists, and they get to keep or copy it.
                discardDocumentDraft(for: draft.documentId)
                recordConflict(SyncConflict(
                    subject: .document(id: draft.documentId), reason: .refused,
                    mine: draft.content, mineTitle: draft.title,
                    theirs: serverContent, theirsTitle: serverTitle,
                    base: draft.baseContent, label: serverTitle.isEmpty ? draft.title : serverTitle,
                    detectedAt: draft.savedAt))
                presentToast("“\(draft.title)” couldn't be saved — your version is kept here")
            case .held:
                break
            }
        }
        if landed { await loadDocuments() }
    }

    /// Writes a document and brings everything that shows it back into step.
    func updateDocument(_ document: TextDocument, title: String, content: String) async -> Bool {
        guard await saveDocument(document, title: title, content: content) else { return false }
        await refreshAfterDocumentEdit()
        return true
    }

    /// The two lists an edited document can appear in: the songs & notes list
    /// itself, and the script, where an inserted note's blocks may have been
    /// re-synced by the same save.
    func refreshAfterDocumentEdit() async {
        await loadDocuments()
        await loadBlocks()
    }

    /// Renames without touching content — fetches the full document first so
    /// the PUT preserves the existing lyrics/notes.
    @discardableResult
    func renameDocument(_ document: TextDocument, title: String) async -> Bool {
        guard let full = await fetchDocument(document),
              // Only the server's own copy will do here. A rename is a whole
              // -document PUT, so renaming from the copy kept on this device
              // would send words that may be days old back over the current
              // ones — the fetch failing is exactly when that is likeliest.
              documentCopySavedAt[document.id] == nil else { return false }
        return await updateDocument(full, title: title, content: full.content ?? "")
    }

    /// Whether songs & notes can be dragged into a new order — advertised on
    /// the collection for an editor, so it doubles as the "may reorder" gate.
    var canReorderDocuments: Bool { documentsLinks.contains(.reorder) }

    /// Reorders songs & notes to the given sequence. The local list settles
    /// first so the drag lands without a flicker; the server's answer then
    /// replaces it, or a failure reloads the order it actually kept.
    @discardableResult
    func reorderDocuments(_ ordered: [TextDocument]) async -> Bool {
        guard let link = documentsLinks[.reorder] else { return false }
        let orderedIds = ordered.map(\.id)
        applyLocalOrder(orderedIds)
        do {
            let collection: HALCollection<TextDocument> = try await app.client.fetch(
                from: link, method: "POST", body: ReorderDocumentsCommand(orderedIds: orderedIds))
            documents = collection.items.sorted { ($0.sortOrder ?? 0) < ($1.sortOrder ?? 0) }
            documentsLinks = collection.links
            errorMessage = nil
            return true
        } catch {
            report(error)
            await loadDocuments()   // fall back to the order the server kept
            return false
        }
    }

    /// Applies a new sequence to the in-memory list by rewriting the moved
    /// documents' sort order to their position, mirroring the server so the
    /// optimistic view matches what comes back.
    private func applyLocalOrder(_ orderedIds: [Int]) {
        for (position, id) in orderedIds.enumerated() {
            if let index = documents.firstIndex(where: { $0.id == id }) {
                documents[index].sortOrder = position
            }
        }
        documents.sort { ($0.sortOrder ?? 0) < ($1.sortOrder ?? 0) }
    }

    /// Copies a song or note. The server titles the copy "… (copy)" and puts it
    /// last, so the list is reloaded rather than patched locally.
    @discardableResult
    func duplicateDocument(_ document: TextDocument) async -> TextDocument? {
        guard let link = document.link(.duplicate) else { return nil }
        do {
            let copy: TextDocument = try await app.client.fetch(from: link, method: "POST")
            await loadDocuments()
            errorMessage = nil
            return copy
        } catch {
            report(error)
            return nil
        }
    }

    /// Switches a document between song and note. Changing the type changes
    /// which editor opens and which affordances the server advertises next, so
    /// the reload is what refreshes the row's links.
    @discardableResult
    func changeDocumentType(_ document: TextDocument, to type: DocumentType) async -> Bool {
        guard let link = document.link(.changeType) else { return false }
        do {
            let _: TextDocument = try await app.client.fetch(
                from: link, method: "POST", body: ChangeDocumentTypeCommand(type: type.rawValue))
            await loadDocuments()
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    func deleteDocument(_ document: TextDocument) async {
        guard let link = document.link(.delete) else { return }
        do {
            try await app.client.data(for: link, method: "DELETE")
            documents.removeAll { $0.id == document.id }
            // Deleting the note means dropping the words held for it —
            // otherwise the badge counts a ghost forever and the sweep keeps
            // trying to write to a document that is gone.
            discardDocumentDraft(for: document.id)
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    /// Whether a selection can be sent to the trash in one call — advertised
    /// on the collection for an editor of a project that has any document at
    /// all, so it doubles as the "may select several" gate.
    ///
    /// It used to require a *song*, because the service behind it skipped
    /// anything that was not one. It no longer does: a ticked note is trashed
    /// like a ticked song, which is what let the notes list grow the same
    /// checkbox column.
    var canBulkDeleteDocuments: Bool { documentsLinks.contains(.bulkDelete) }

    /// Trashes several documents at once. The server answers with what is left,
    /// so the list settles from its reply rather than from local guesswork
    /// about which of the chosen ids it accepted.
    @discardableResult
    func bulkDeleteDocuments(_ ids: [Int]) async -> Bool {
        guard let link = documentsLinks[.bulkDelete], !ids.isEmpty else { return false }
        do {
            let collection: HALCollection<TextDocument> = try await app.client.fetch(
                from: link, method: "POST", body: BulkDeleteDocumentsCommand(ids: ids))
            documents = collection.items.sorted { ($0.sortOrder ?? 0) < ($1.sortOrder ?? 0) }
            documentsLinks = collection.links
            // Only the ones the server actually removed. It takes songs and
            // notes alike now, but an id it declined — one already gone, or
            // from another project — must keep its held words.
            let kept = Set(documents.map(\.id))
            for id in ids where !kept.contains(id) { discardDocumentDraft(for: id) }
            errorMessage = nil
            return true
        } catch {
            report(error)
            await loadDocuments()   // fall back to the list the server kept
            return false
        }
    }

    /// Where this project's archived songs and notes are, when the signed-in
    /// user may put things there. Advertised even when the archive is empty —
    /// a list can be empty precisely because everything in it is archived — so
    /// the UI gates the *entry* on the count it reads back, not on this link.
    var archivedDocumentsLink: HALLink? { documentsLinks[.archived] }

    /// Whether a selection can be archived in one call. Like
    /// ``canBulkDeleteDocuments``, and for the same reason: the server archives
    /// notes just as readily as songs, so a project of notes is offered it too.
    var canBulkArchiveDocuments: Bool { documentsLinks.contains(.bulkArchive) }

    /// Archives one song or note. The server answers with the refreshed list,
    /// which is what settles the collection — the archived document is no longer
    /// in it, and its links may have changed with the count.
    @discardableResult
    func archiveDocument(_ document: TextDocument) async -> Bool {
        // No body: the id is in the path, unlike the bulk form.
        await adoptDocuments(from: document.link(.archive), body: nil, removing: [document.id])
    }

    /// Archives several documents at once.
    @discardableResult
    func bulkArchiveDocuments(_ ids: [Int]) async -> Bool {
        guard !ids.isEmpty else { return false }
        return await adoptDocuments(
            from: documentsLinks[.bulkArchive],
            body: BulkArchiveDocumentsCommand(ids: ids),
            removing: ids)
    }

    /// Brings one song or note back from the archive, from an editor holding it.
    ///
    /// The archive sheet has its own way to do this — see ``ArchiveModel`` —
    /// and this is the other one: an archived document opens in place, so the
    /// editor can be the only thing on screen when the question comes up.
    ///
    /// Unlike ``archiveDocument`` the reply is not adopted. This link answers
    /// with the refreshed *archive*, which is the collection the caller is not
    /// looking at; what has to settle here is the document list, so it is
    /// re-read instead.
    @discardableResult
    func unarchiveDocument(_ document: TextDocument) async -> Bool {
        guard let link = document.link(.unarchive) else { return false }
        do {
            _ = try await app.client.data(for: link, method: "POST")
            await loadDocuments()
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Shared tail of the two archive calls: POST, settle the list from the
    /// reply, and hand back any held words for documents that actually left it.
    ///
    /// `expected` is what the caller asked to archive; the drafts dropped are
    /// only those the server really did remove, the same rule
    /// ``bulkDeleteDocuments`` follows — a stale id the server skipped keeps its
    /// unsaved words.
    private func adoptDocuments(from link: HALLink?,
                                body: (any Encodable)?,
                                removing expected: [Int]) async -> Bool {
        guard let link else { return false }
        do {
            let collection: HALCollection<TextDocument> = try await app.client.fetch(
                from: link, method: "POST", body: body)
            documents = collection.items.sorted { ($0.sortOrder ?? 0) < ($1.sortOrder ?? 0) }
            documentsLinks = collection.links
            let kept = Set(documents.map(\.id))
            // An archived note's words are not lost — they were saved before it
            // left the list — but the outbox has no live document to write to
            // any more, so a pending draft for one is dropped like a deleted
            // note's. Unarchiving re-reads the document from the server.
            for id in expected where !kept.contains(id) { discardDocumentDraft(for: id) }
            errorMessage = nil
            return true
        } catch {
            report(error)
            await loadDocuments()   // fall back to the list the server kept
            return false
        }
    }

    /// Inserts a document into the screenplay as blocks; returns the count.
    @discardableResult
    func insertDocument(_ document: TextDocument, afterBlockId: Int? = nil, asType: String? = nil) async -> Int? {
        guard let link = document.link(.insert) else { return nil }
        do {
            let result: InsertResult = try await app.client.fetch(
                from: link, method: "POST",
                body: InsertDocumentCommand(afterBlockId: afterBlockId, asType: asType))
            await loadBlocks()
            await refreshUndoRedo()
            errorMessage = nil
            return result.inserted
        } catch {
            report(error)
            return nil
        }
    }

    /// Songs that can be dropped into the screenplay — the ones the server
    /// advertised an `insert` link on, i.e. those the caller may edit. Split
    /// from notes so the block menu can offer the web's two create-below
    /// sections ("Songs" / "Notes").
    var insertableSongs: [TextDocument] {
        documents.filter { $0.kind == .song && $0.link(.insert) != nil }
    }

    /// Notes (anything that is not a song) that can be dropped into the
    /// screenplay, gated the same way — an `insert` link the caller can use.
    var insertableNotes: [TextDocument] {
        documents.filter { $0.kind != .song && $0.link(.insert) != nil }
    }

    /// Whether there is anything to insert, so the block menu can drop the
    /// whole section when the project has no songs or notes, or the caller
    /// cannot edit.
    var canInsertDocuments: Bool {
        !insertableSongs.isEmpty || !insertableNotes.isEmpty
    }

    @discardableResult
    func shareDocument(_ document: TextDocument, email: String) async -> Bool {
        guard let link = document.link(.shareEmail) else { return false }
        do {
            try await app.client.data(for: link, method: "POST", body: ShareEmailCommand(email: email))
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Advertised on the collection for an editor with something to send, the
    /// same pair of conditions the bulk delete rides on.
    var canBulkShareDocuments: Bool { documentsLinks.contains(.bulkShareEmail) }

    /// Emails several documents in one message — songs, notes, or a mix, which
    /// the server's subject line names honestly. Returns how many actually
    /// went, since an id it declined means "sent 3" is not the same as "you
    /// chose 3" and the caller says which it means.
    func bulkShareDocuments(_ ids: [Int], email: String) async -> Int? {
        guard let link = documentsLinks[.bulkShareEmail], !ids.isEmpty else { return nil }
        do {
            let result: BulkShareResult = try await app.client.fetch(
                from: link, method: "POST",
                body: BulkShareEmailCommand(ids: ids, email: email))
            errorMessage = nil
            return result.shared ?? result.titles?.count ?? 0
        } catch {
            report(error)
            return nil
        }
    }

    @discardableResult
    func importDocument(fileName: String, data: Data, type: DocumentType,
                        mimeType: String = "application/octet-stream") async -> TextDocument? {
        guard let link = documentsLinks[.importDocument] else { return nil }
        do {
            let created: TextDocument = try await app.client.upload(
                to: link,
                fields: ["projectId": String(project.id), "type": type.rawValue],
                fileName: fileName, fileData: data, mimeType: mimeType)
            await loadDocuments()
            errorMessage = nil
            return created
        } catch {
            report(error)
            return nil
        }
    }

    // MARK: - Export

    struct ExportOption: Identifiable {
        let rel: Rel
        let label: String
        let fileExtension: String
        let link: HALLink

        var id: String { rel.rawValue }

        /// Whether the format has pages at all. Fountain and Final Draft are
        /// unpaginated text — paper size and margins mean nothing to them, so
        /// they take the link exactly as advertised.
        var isPaged: Bool { rel == .exportPdf }
    }

    var exportOptions: [ExportOption] {
        let all: [(Rel, String, String)] = [
            (.exportPdf, "PDF", "pdf"),
            (.export, "Fountain", "fountain"),
            (.exportDocx, "Word", "docx"),
            (.exportFdx, "Final Draft", "fdx"),
            (.exportEpub, "EPUB", "epub"),
            (.exportArchive, "Scripty Archive", "scripty.json"),
        ]
        return all.compactMap { rel, label, ext in
            project.link(rel).map { ExportOption(rel: rel, label: label, fileExtension: ext, link: $0) }
        }
    }

    /// The option to print from, when the server can render one.
    ///
    /// Printing goes through the PDF export rather than drawing the blocks
    /// again on the device, so the paper coming out of the printer is the same
    /// document the writer would have exported — one pagination, not two.
    /// Offline is the exception: with no route to the server, the exporter
    /// falls back to ScreenplayPDF, which shares the paginator's arithmetic
    /// precisely so that the fallback stays the same document too.
    var printableOption: ExportOption? {
        exportOptions.first { $0.rel == .exportPdf }
    }

    /// The formats a single document advertises.
    ///
    /// A note now carries the first four. The server's renderer only ever laid
    /// out a title and its lines — and already fell back to a document's own
    /// text for songs with no blocks, which is precisely what a note is — so
    /// what was song-only about it was the guard, not the layout. MusicXML is
    /// the exception and stays song-only, which is why this reads the links
    /// rather than the kind: the note simply arrives without that one.
    func songExportOptions(for document: TextDocument) -> [ExportOption] {
        let all: [(Rel, String, String)] = [
            (.exportSongTxt, "Text", "txt"),
            (.exportSongPdf, "PDF", "pdf"),
            (.exportSongDocx, "Word", "docx"),
            (.exportSongEpub, "EPUB", "epub"),
            // The odd one out: the others are documents to read, this is a
            // score to open in a notation program — and it is the format the
            // song importer reads back.
            (.exportSongMusicXml, "MusicXML", "musicxml"),
        ]
        return all.compactMap { rel, label, ext in
            document.link(rel).map { ExportOption(rel: rel, label: label, fileExtension: ext, link: $0) }
        }
    }

    /// The formats the project's songs are offered in as one songbook. These
    /// ride on the document collection, so they appear once there is a song to
    /// put in the book — a project of notes alone advertises none of them.
    var songbookExportOptions: [ExportOption] {
        let all: [(Rel, String, String)] = [
            (.exportSongsTxt, "Text", "txt"),
            (.exportSongsPdf, "PDF", "pdf"),
            (.exportSongsDocx, "Word", "docx"),
            (.exportSongsEpub, "EPUB", "epub"),
            // Every song as sections of one score; MusicXML has no second piece.
            (.exportSongsMusicXml, "MusicXML", "musicxml"),
        ]
        return all.compactMap { rel, label, ext in
            documentsLinks[rel].map { ExportOption(rel: rel, label: label, fileExtension: ext, link: $0) }
        }
    }

    /// The formats the project's notes are offered in as one file — the
    /// songbook's counterpart, advertised once there is a note to put in it.
    ///
    /// Four rather than five: MusicXML is a score, and the server refuses a
    /// note one rather than handing back an empty stave.
    var notesExportOptions: [ExportOption] {
        let all: [(Rel, String, String)] = [
            (.exportNotesTxt, "Text", "txt"),
            (.exportNotesPdf, "PDF", "pdf"),
            (.exportNotesDocx, "Word", "docx"),
            (.exportNotesEpub, "EPUB", "epub"),
        ]
        return all.compactMap { rel, label, ext in
            documentsLinks[rel].map { ExportOption(rel: rel, label: label, fileExtension: ext, link: $0) }
        }
    }

    /// Whichever collection export belongs to the list on screen. The two sets
    /// are separate rels rather than one templated href, so this is the single
    /// place that has to know which is which.
    func collectionExportOptions(for type: DocumentType) -> [ExportOption] {
        type == .song ? songbookExportOptions : notesExportOptions
    }

    /// The same file narrowed to the chosen documents. The server's endpoint
    /// reads an `ids` list — the rel documents it, and the web's own export
    /// menu appends the checked ids to the very same href — so a selection is a
    /// query on the advertised link rather than a second rel.
    func collectionExportOptions(for type: DocumentType, ids: [Int]) -> [ExportOption] {
        let base = collectionExportOptions(for: type)
        guard !ids.isEmpty else { return base }
        let list = ids.map(String.init).joined(separator: ",")
        return base.map {
            ExportOption(rel: $0.rel, label: $0.label, fileExtension: $0.fileExtension,
                         link: $0.link.addingQuery(["ids": list]))
        }
    }

    /// The songbook narrowed to the chosen songs.
    func songbookExportOptions(for ids: [Int]) -> [ExportOption] {
        collectionExportOptions(for: .song, ids: ids)
    }

    /// What one song or note prints from, when the server can render it.
    ///
    /// The screenplay's rule, applied to a document: printing goes through the
    /// PDF export rather than drawing the words again on the device, so the
    /// paper is the file the writer would have exported. `DocumentPDF` is the
    /// offline exception, and mirrors the server's song layout for the same
    /// reason `ScreenplayPDF` mirrors the paginator's.
    ///
    /// A note has this too — the server's renderer lays out a title and its
    /// lines, which is what a note is.
    func documentPrintOption(for document: TextDocument) -> ExportOption? {
        songExportOptions(for: document).first { $0.rel == .exportSongPdf }
    }

    /// What a whole list prints from — the songbook as a PDF, or the same file
    /// made of notes — narrowed to the ticked rows where there are any.
    func collectionPrintOption(for type: DocumentType, ids: [Int] = []) -> ExportOption? {
        collectionExportOptions(for: type, ids: ids)
            .first { $0.rel == .exportSongsPdf || $0.rel == .exportNotesPdf }
    }

    /// The words this device last saw for a song or a note, for the print that
    /// cannot reach the server.
    ///
    /// Three places to look, newest first: a song's cached lyric lines, a
    /// document's cached full text, and — for the caller holding a row rather
    /// than a fetched document — whatever content the row itself carries. The
    /// row's `preview` is deliberately not among them: it is truncated, and
    /// half a note on paper looking like the whole of it is worse than saying
    /// the print needs a connection.
    ///
    /// Nil when this device has never held the document's words.
    func cachedDocumentLines(_ document: TextDocument) -> [String]? {
        let projectId = document.projectId ?? project.id
        if let snapshot = offlineStore?.load(
                .songBlocks(projectId: projectId, documentId: document.id)),
           let lines: HALCollection<SongBlock> = try? app.client.decode(from: snapshot.data),
           !lines.items.isEmpty {
            return lines.items.sorted { ($0.order ?? 0) < ($1.order ?? 0) }.map(\.text)
        }
        if let snapshot = offlineStore?.load(
                .document(projectId: projectId, documentId: document.id)),
           let cached: TextDocument = try? app.client.decode(from: snapshot.data),
           let content = cached.content, !content.isEmpty {
            return content.components(separatedBy: "\n")
        }
        if let content = document.content, !content.isEmpty {
            return content.components(separatedBy: "\n")
        }
        return nil
    }

    /// Downloads an export with auth and writes it to a shareable temp file,
    /// named after whatever is being exported.
    ///
    /// A paged export carries the writer's own page setup, so the PDF matches
    /// the sheets they were just looking at in page view rather than falling
    /// back to the server's defaults. Page setup is a device preference, so it
    /// is read from the shared presentation settings at the moment of export.
    /// A song's own PDF is not `exportPdf`, so it keeps the server's song
    /// layout untouched — page setup applies to the screenplay, not a lyric.
    func downloadExport(_ option: ExportOption, named baseName: String) async throws -> URL {
        let link = option.isPaged
            ? option.link.addingQuery(PresentationSettings.shared.pageSetup.exportQuery)
            : option.link
        let data = try await app.client.data(for: link)
        let url = shareableFileURL(named: baseName, fileExtension: option.fileExtension)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Where a shareable file goes, named after whatever is being exported
    /// with the characters no filename can carry stripped out. Shared with the
    /// offline print path, which writes a PDF nobody downloaded.
    func shareableFileURL(named baseName: String, fileExtension: String) -> URL {
        let safeTitle = baseName
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined()
        let name = (safeTitle.isEmpty ? "export" : safeTitle) + "." + fileExtension
        return FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    /// The script export, named after the project.
    func export(_ option: ExportOption) async throws -> URL {
        try await downloadExport(option, named: project.displayTitle.isEmpty ? "script" : project.displayTitle)
    }
}
