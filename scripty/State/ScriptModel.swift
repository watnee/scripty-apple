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
    /// editor's history toast. The token changes on every issue so re-showing
    /// the same text (two "Change undone" in a row) still re-triggers the view.
    struct HistoryToast: Equatable {
        var token: Int
        var text: String
    }
    private(set) var historyToast: HistoryToast?
    private var historyToastToken = 0

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

    /// Set when the script on screen is the offline copy rather than the
    /// server's answer, with when that copy was saved.
    private(set) var offlineCopySavedAt: Date?
    var isShowingOfflineCopy: Bool { offlineCopySavedAt != nil }

    /// How many elements on screen exist only on this device. Drives the
    /// banner's count alongside the unsaved-text one.
    var pendingCreateCount: Int { blocks.filter(\.isLocal).count }

    init(app: AppModel, project: Project, draftStore: UnsavedDraftStore? = nil,
         offlineStore: OfflineStore? = nil, createQueue: OfflineBlockQueue? = nil) {
        self.app = app
        self.project = project
        self.draftStore = draftStore ?? app.draftScope.map { UnsavedDraftStore(scope: $0) }
        self.offlineStore = offlineStore ?? app.offlineStore
        self.createQueue = createQueue ?? app.draftScope.map { OfflineBlockQueue(scope: $0) }
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
            adoptPersistedDrafts()
            adoptPendingCreates()
            offlineCopySavedAt = nil
            errorMessage = nil
            wasAbandoned = false
            if isDefaultEdition, let store = offlineStore {
                store.save(data, .blocks(projectId: project.id))
                store.prune(keeping: project.id)
            }
        } catch {
            guard generation == blockLoadGeneration else { return }
            // The network failed — fall back to the copy saved last time the
            // script loaded. Persisted drafts are adopted on top exactly as
            // they are on a live load, so words typed offline stay the newest
            // thing on screen and the retry machinery keeps holding them.
            if isDefaultEdition, error.isRetryableAPIError,
               let snapshot = offlineStore?.load(.blocks(projectId: project.id)),
               let collection: HALCollection<Block> = try? app.client.decode(from: snapshot.data) {
                adopt(collection)
                adoptPersistedDrafts()
                adoptPendingCreates()
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
        do {
            try await app.client.data(for: link, method: "DELETE")
            blocks.removeAll { $0.id == block.id }
            // Nothing left to save it into.
            liveText[block.id] = nil
            markSaved(block.id)
            await refreshUndoRedo()
            errorMessage = nil
        } catch {
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
        // out ten minutes ago shouldn't leave this keystroke with none.
        retryAttempts[block.id] = nil
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
        await commit(block.id)
        if focusedBlockId == block.id { focusedBlockId = nil }
        if !unsavedBlockIds.contains(block.id) { liveText[block.id] = nil }
        hasActiveEdit = focusedBlockId != nil
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

    /// PUT the block's live text if it differs from what the server has.
    @discardableResult
    private func commit(_ id: Int) async -> Block? {
        commitTasks[id]?.cancel()
        commitTasks[id] = nil
        guard let text = liveText[id],
              let block = blocks.first(where: { $0.id == id }) else { return nil }
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
            return updated
        }
        guard text != (block.content ?? ""), let link = block.link(.update) else {
            markSaved(id)
            return block
        }
        do {
            let updated: Block = try await app.client.fetch(
                from: link, method: "PUT",
                body: EditBlockCommand(content: text, personId: block.personId, tags: block.tags))
            replace(updated)
            markSaved(id)
            await refreshUndoRedo()
            errorMessage = nil
            return updated
        } catch {
            markUnsaved(id, after: error)
            reportUnlessRetrying(error)
            return nil
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
            report(error)
            return nil
        }
    }

    // MARK: - Unsaved-work bookkeeping

    /// The server has this block's text; the live copy is no longer precious.
    private func markSaved(_ id: Int) {
        localHistory.noteSaved(blockId: id)
        unsavedBlockIds.remove(id)
        retryTasks[id]?.cancel()
        retryTasks[id] = nil
        retryAttempts[id] = nil
        draftStore?.remove(blockId: id, projectId: project.id)
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
        guard error.isRetryableAPIError else { return }
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
    /// A draft whose base no longer matches the server is *dropped*: someone
    /// edited that element elsewhere since the save failed, and the server is
    /// last-write-wins, so pushing the old draft would clobber newer words.
    func adoptPersistedDrafts() {
        guard let store = draftStore else { return }
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
                store.remove(blockId: id, projectId: project.id)
                continue
            }
            liveText[id] = draft.text
            unsavedBlockIds.insert(id)
            scheduleCommit(id)
        }
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
    /// and everything hanging off it, rather than blocking the queue forever.
    private func replayPendingCreates() async {
        guard let queue = createQueue else { return }
        var droppedAny = false
        var resolvedAny = false
        // Once anything here lands or is given up on, the local steps describe
        // elements that no longer exist under their temp identities — history
        // belongs to the server again. Cleared on the way out, whatever mix of
        // successes the drain managed.
        defer { if resolvedAny || droppedAny { localHistory.clear() } }
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
                dropPendingCreate(entry.tempId, from: queue)
                droppedAny = true
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
                dropPendingCreate(entry.tempId, from: queue)
                droppedAny = true
            }
        }
        if droppedAny {
            // Not `report`: this is not a failure the writer can retry, it is
            // news about work that could not be placed. The banner and the
            // alert both belong to things still in flight.
            presentToast("Some elements written offline couldn't be added")
        }
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

    /// The connection is back: push every element still holding unsaved words
    /// right now rather than waiting out whatever backoff each is on — in
    /// session the live copy is authoritative, exactly as the retry loop
    /// treats it — then pull whatever changed elsewhere while we were away.
    /// Mirrors the web client's sync-on-reconnect, including its confirmation
    /// once everything lands.
    func connectionRestored() async {
        let pending = unsavedBlockIds.sorted()
        // Existing elements first: a queued create is anchored to one of them,
        // and its own words ride on the create rather than on a PUT.
        for id in pending where id > 0 { await commit(id) }
        await replayPendingCreates()
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
        if previous == nil { markSaved(id) }
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
        if let detected = FountainDetector.detect(before) {
            before = detected.content
            currentType = detected.type
        }

        // Persist the (possibly retyped, possibly trimmed) current block.
        //
        // If that write fails, abandon the split rather than pressing on: the
        // text after the caret only belongs in a new element once the text
        // before it is safely stored. `before` stays in `liveText` (flagged
        // unsaved) and `after` stays on screen as part of this block, so the
        // writer's line is intact and Return can simply be pressed again.
        liveText[block.id] = before
        let source: Block
        if currentType != block.blockType {
            guard let retyped = await retype(block, to: currentType, content: before) else {
                // The failed write recorded itself (see markUnsaved); the
                // split is being abandoned, so the record goes too.
                localHistory.unrecordText(blockId: block.id, after: before)
                liveText[block.id] = full
                return
            }
            source = retyped
        } else {
            guard let committed = await commit(block.id) else {
                localHistory.unrecordText(blockId: block.id, after: before)
                liveText[block.id] = full
                return
            }
            source = committed
        }
        liveText[block.id] = nil

        let newType = currentType.followingType
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
            await loadBlocks()
            await refreshUndoRedo()
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
            await loadBlocks()
            await refreshUndoRedo()
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
        guard let index = blocks.firstIndex(where: { $0.id == block.id }), index > 0,
              let previous = blocks[..<index].last(where: { $0.hasLink(.update) }) else { return }
        let previousText = currentText(previous)
        let seam = previousText.count
        let merged = previousText + currentText(block)

        // A merge that can't be persisted must leave both elements exactly as
        // they were — half a merge would show the writer their own words twice.
        let restore = liveText[previous.id]
        liveText[previous.id] = merged
        guard let updatedPrevious = await commit(previous.id) else {
            rollback(previous.id, to: restore)
            return
        }
        liveText[previous.id] = nil   // model value is now authoritative for the merged row

        if block.isLocal {
            // Nothing to delete on the server: the absorbed element only ever
            // existed here, so dropping its queued create is the whole of it.
            // Done before the reload so the stand-in doesn't come back.
            // Recorded as its own step behind the text one — undoing a merge
            // offline is two presses, the same two changes it was made of.
            if let queue = createQueue { removeRecordingHistory(block.id, from: queue) }
            liveText[block.id] = nil
            await loadBlocks()
            await refreshUndoRedo()
            focus(updatedPrevious.id, caret: seam)
            return
        }
        if let deleteLink = block.link(.delete) {
            do {
                try await app.client.data(for: deleteLink, method: "DELETE")
            } catch {
                // The absorbed element is still there, so the merged text now
                // appears twice. Put the previous block back and leave the
                // script as it was before the Backspace.
                liveText[previous.id] = previousText
                await commit(previous.id)
                report(error)
                return
            }
        }
        liveText[block.id] = nil
        await loadBlocks()
        await refreshUndoRedo()
        focus(updatedPrevious.id, caret: seam)
    }

    /// Retype a block in place (the element-type bar and Tab cycling).
    func changeType(_ block: Block, to type: BlockType) async {
        _ = await retype(block, to: type, content: liveText[block.id])
    }

    /// Tab / Shift-Tab: advance the focused block through the logical cycle.
    func cycleType(_ block: Block, backward: Bool) async {
        await changeType(block, to: block.blockType.cyclingType(backward: backward))
    }

    @discardableResult
    private func retype(_ block: Block, to type: BlockType, content: String?) async -> Block? {
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
            return updated
        }
        guard let link = block.link(.setType) else {
            // Server without setType: fall back to a content-only commit.
            if let content { liveText[block.id] = content; return await commit(block.id) }
            return block
        }
        do {
            let updated: Block = try await app.client.fetch(
                from: link, method: "POST",
                body: SetTypeCommand(type: type.rawValue, content: content,
                                     personId: block.personId, tags: block.tags))
            adoptRewritten(updated)
            await refreshUndoRedo()
            errorMessage = nil
            return updated
        } catch {
            // The retype carried the writer's text with it, so a failure here
            // loses words just as a failed commit would. Hold the live copy
            // and retry it as a plain content save — the type change is the
            // part worth dropping, not the writing.
            if content != nil {
                markUnsaved(block.id, after: error)
                reportUnlessRetrying(error)
            } else {
                report(error)
            }
            return nil
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
    func seedInitialBlock() async {
        guard let link = blocksLinks[.createInitial] else { return }
        do {
            let created: Block = try await app.client.fetch(from: link, method: "POST")
            await loadBlocks()
            await refreshUndoRedo()
            focus(created.id, caret: 0)
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    /// Append an empty element at the end and focus it (the toolbar +).
    func appendBlock() async {
        if blocks.isEmpty {
            await seedInitialBlock()
            return
        }
        guard let last = blocks.last else { return }
        // A pending last element can't anchor a server create, but it can
        // anchor another pending one.
        if last.isLocal {
            if let created = createLocalBlock(below: last, type: .action,
                                              content: "", personId: nil) {
                focus(created.id, caret: 0)
            }
            return
        }
        guard let link = last.link(.createBelow) else {
            await createBlock(content: "", type: .action, personId: nil)
            return
        }
        do {
            let created: Block = try await app.client.fetch(
                from: link, method: "POST",
                body: CreateBelowCommand(content: "", personId: nil, type: BlockType.action.rawValue))
            await loadBlocks()
            await refreshUndoRedo()
            focus(created.id, caret: 0)
            errorMessage = nil
        } catch {
            guard error.isRetryableAPIError,
                  let created = createLocalBlock(below: last, type: .action,
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
        do {
            undoRedo = try await app.client.fetch(UndoRedoStatus.self, from: link, method: "POST")
            await loadBlocks()
            // The reload rewrote the script under any local steps (only the
            // redo side can still hold them here — undo drains local first).
            localHistory.clear()
            errorMessage = nil
            presentHistoryToast(rel: rel, delta: blocks.count - before)
        } catch {
            report(error)
        }
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
        if delta > 0 {
            presentToast("Restored \(delta) element\(delta == 1 ? "" : "s")")
        } else {
            presentToast(rel == .undo ? "Change undone" : "Change redone")
        }
    }

    /// The transient confirmation capsule the view floats over the script —
    /// undo/redo acknowledgements and the offline sync's all-clear share it.
    private func presentToast(_ text: String) {
        historyToastToken += 1
        historyToast = HistoryToast(token: historyToastToken, text: text)
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

    /// Fetches the full document (list items carry only a preview).
    func fetchDocument(_ document: TextDocument) async -> TextDocument? {
        guard let link = document.link(.selfRel) else { return document }
        do {
            let full: TextDocument = try await app.client.fetch(from: link)
            errorMessage = nil
            return full
        } catch {
            report(error)
            return nil
        }
    }

    @discardableResult
    func createDocument(title: String, content: String, type: DocumentType) async -> TextDocument? {
        guard let link = documentsLinks[.selfRel] ?? project.link(.documents) else { return nil }
        do {
            let created: TextDocument = try await app.client.fetch(
                from: link, method: "POST",
                body: CreateDocumentCommand(projectId: project.id, title: title,
                                            documentType: type.rawValue, content: content))
            await loadDocuments()
            errorMessage = nil
            return created
        } catch {
            report(error)
            return nil
        }
    }

    /// Writes a document and disturbs nothing else. What the note editor's
    /// autosave uses: a save every second of typing cannot also pull the
    /// documents list and the script's blocks down each time, and while the
    /// editor is open neither of them is on screen to be stale. The editor asks
    /// for that refresh once, on its way out.
    @discardableResult
    func saveDocument(_ document: TextDocument, title: String, content: String) async -> Bool {
        guard let link = document.link(.update) else { return false }
        do {
            let _: TextDocument = try await app.client.fetch(
                from: link, method: "PUT",
                body: EditDocumentCommand(projectId: project.id, title: title,
                                          documentType: document.kind.rawValue, content: content))
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
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
        guard let full = await fetchDocument(document) else { return false }
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
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    /// Whether a selection of songs can be sent to the trash in one call —
    /// advertised on the collection for an editor of a project that has songs,
    /// so it doubles as the "may select several" gate.
    var canBulkDeleteDocuments: Bool { documentsLinks.contains(.bulkDelete) }

    /// Trashes several songs at once. The server answers with what is left, so
    /// the list settles from its reply rather than from local guesswork about
    /// which of the chosen ids it accepted — a note caught in the selection is
    /// skipped there, not here.
    @discardableResult
    func bulkDeleteDocuments(_ ids: [Int]) async -> Bool {
        guard let link = documentsLinks[.bulkDelete], !ids.isEmpty else { return false }
        do {
            let collection: HALCollection<TextDocument> = try await app.client.fetch(
                from: link, method: "POST", body: BulkDeleteDocumentsCommand(ids: ids))
            documents = collection.items.sorted { ($0.sortOrder ?? 0) < ($1.sortOrder ?? 0) }
            documentsLinks = collection.links
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

    /// Advertised on the collection for an editor with a song to send, the
    /// same pair of conditions the bulk delete rides on.
    var canBulkShareDocuments: Bool { documentsLinks.contains(.bulkShareEmail) }

    /// Emails several songs in one message. Returns how many actually went —
    /// a note caught in the selection is skipped by the server, so "sent 3"
    /// is not the same as "you chose 3" and the caller says which it means.
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
    var printableOption: ExportOption? {
        exportOptions.first { $0.rel == .exportPdf }
    }

    /// The formats a single song advertises. Song-only, matching the server:
    /// SongExportService lays lyrics out as a song, which is not what a note
    /// wants, so a note carries none of these links.
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

    /// The same songbook narrowed to the chosen songs. The server's songbook
    /// endpoint reads an `ids` list — the rel documents it, and the web's own
    /// export menu appends the checked ids to the very same href — so a
    /// selection is a query on the advertised link rather than a second rel.
    func songbookExportOptions(for ids: [Int]) -> [ExportOption] {
        guard !ids.isEmpty else { return songbookExportOptions }
        let list = ids.map(String.init).joined(separator: ",")
        return songbookExportOptions.map {
            ExportOption(rel: $0.rel, label: $0.label, fileExtension: $0.fileExtension,
                         link: $0.link.addingQuery(["ids": list]))
        }
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
        let safeTitle = baseName
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined()
        let name = (safeTitle.isEmpty ? "export" : safeTitle) + "." + option.fileExtension
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// The script export, named after the project.
    func export(_ option: ExportOption) async throws -> URL {
        try await downloadExport(option, named: project.displayTitle.isEmpty ? "script" : project.displayTitle)
    }
}
