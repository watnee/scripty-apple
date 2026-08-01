//
//  SongBlockModel.swift
//  scripty
//
//  The lyric of one song, as ordered lines.
//
//  Follows the screenplay editor's shape because the problems are the same:
//  typing is debounced so every keystroke is not a request, a live-text buffer
//  shields the line being typed into from a reload landing underneath it, and
//  every affordance waits on a link the server advertised.
//
//  A line whose save cannot get out is *held*, the same way a screenplay
//  element is: the words stay live on screen, go to disk so a relaunch keeps
//  them, retry on a backoff, and are pushed the moment the connection returns.
//  Only edits get this treatment — creating, deleting and reordering lines
//  still need the server, exactly as the lyric structure always has. Undo and
//  Redo cover those held edits too: the server's history is unreachable with
//  no connection, so `localHistory` walks back what it never saw.
//
//  Which edition's lyric is being read travels as a link rather than an id the
//  client assembles — the editions collection hands over the `songBlocks` link
//  for each one.
//

import Foundation
import Observation

@Observable
@MainActor
final class SongBlockModel {
    let app: AppModel
    let document: TextDocument

    private(set) var blocks: [SongBlock] = []
    private(set) var links = HALLinks()
    private(set) var isLoading = false
    var errorMessage: String?

    /// Which line is being typed into, reported by the row that has it.
    ///
    /// Kept here rather than read from the host's `@FocusState` for the reason
    /// `focusRequest` below is: SwiftUI discards a focus value no view has
    /// claimed with `.focused()`, so a host cannot ask its own state whether
    /// the keyboard is up. Both editors draw the hide-keyboard bar from this.
    var focusedBlockId: Int?
    private(set) var liveText: [Int: String] = [:]

    /// Where the caret should land in a line the model has just rewritten,
    /// by line id. A merge is the only thing that asks: the writer's Backspace
    /// has to leave the caret at the seam rather than wherever UIKit puts it
    /// when the line takes focus. Read and cleared by the row that owns the
    /// line, exactly as the screenplay's `caretRequests` is.
    var caretRequests: [Int: Int] = [:]

    /// The line the model wants typed into next: the one Return just made, or
    /// the one a Backspace just folded another into.
    ///
    /// Held here rather than in the host's `@FocusState` because SwiftUI will
    /// not keep a focus value no view has claimed with `.focused()` — and these
    /// rows deliberately do not, since a lyric line is a bridged UITextView
    /// that grants itself first responder. Written from a host, the value was
    /// discarded before the new row could read it, and the keyboard stayed on
    /// the line the writer had just left. Cleared by whichever row takes it.
    var focusRequest: Int?

    /// Which edition's lyric to read. Nil means whichever the server calls
    /// default, which is what a song with one edition always resolves to.
    var editionBlocksLink: HALLink? {
        didSet {
            guard editionBlocksLink != oldValue else { return }
            // Another edition's lyric is about to be on screen; steps recorded
            // against this one must not be applied to it.
            localHistory.clear()
            Task { await load() }
        }
    }

    private var commitTasks: [Int: Task<Void, Never>] = [:]
    private static let commitDebounce: Duration = .milliseconds(600)

    /// Lines whose latest text failed to reach the server. Their entry in
    /// `liveText` is the *only* copy of those words, so it is held rather than
    /// cleared until a retry lands — the same rule the screenplay follows.
    private(set) var unsavedBlockIds: Set<Int> = []
    var hasUnsavedChanges: Bool { !unsavedBlockIds.isEmpty }

    /// Lines whose latest write the server *refused* — a failure no retry
    /// fixes. Their words are still held, but nothing is in flight, and any
    /// badge must stop saying "saving".
    private(set) var failedBlockIds: Set<Int> = []
    var hasFailedSaves: Bool { !failedBlockIds.isEmpty }

    private var retryTasks: [Int: Task<Void, Never>] = [:]
    private var retryAttempts: [Int: Int] = [:]
    /// The screenplay's backoff, unchanged: past the last delay the words stay
    /// held and the next keystroke — or the reconnect sweep — re-arms it.
    private static let retryDelays: [Duration] =
        [.seconds(2), .seconds(5), .seconds(15), .seconds(30), .seconds(60)]

    /// Where held lyric text is kept across a relaunch. Keyed by *document* id,
    /// in a folder of its own — song line drafts and screenplay block drafts
    /// live in different id spaces. Nil (signed out, demo) means held words
    /// survive this session only, as before.
    @ObservationIgnored private let draftStore: UnsavedDraftStore?

    /// The offline copies of this account's lyrics, refreshed on every
    /// successful default-edition load and read back when a load fails for
    /// want of a connection — the same fallback the screenplay's elements
    /// have. Nil exactly when the draft store is (signed out, demo).
    @ObservationIgnored private let offlineStore: OfflineStore?

    /// Set when the lyric on screen is the offline copy rather than the
    /// server's answer, with when that copy was saved.
    private(set) var offlineCopySavedAt: Date?
    var isShowingOfflineCopy: Bool { offlineCopySavedAt != nil }

    /// The last moment this lyric was known to match the server's copy — the
    /// screenplay's `lastSyncedAt` under a different set of lines, and read by
    /// the same badge. A fallback to the offline copy leaves it alone: showing
    /// yesterday's words is not a sync.
    private(set) var lastSyncedAt: Date?

    var canAddLine: Bool { links.contains(.create) }

    /// The song's snapshot history, when the server keeps one. Advertised on
    /// the line collection rather than on the document, so it is only known
    /// once the lyric has loaded.
    var versionsLink: HALLink? { links[.versions] }

    /// The lines deleted from this song, still restorable. Advertised to
    /// readers too — seeing what was cut is reading — so this is not gated on
    /// being able to type.
    var trashLink: HALLink? { links[.trash] }

    /// Whether stepping back and forward is available, and where. Only an
    /// editor is offered the status link, since the checkpoints are made by
    /// their own edits.
    private(set) var undoRedo: UndoRedoStatus?

    /// Undo/redo for the lyric edits the server never saw — `LocalHistory`,
    /// which the screenplay editor keeps for the same reason: with no
    /// connection the server's `undo` link is unreachable, which used to leave
    /// ⌘Z dead exactly when the writer was most on their own.
    ///
    /// Only text steps are ever recorded here. A lyric's structure — new
    /// lines, deletes, moves — needs the server and fails cleanly offline, so
    /// held words are the only change this device can be holding to take back.
    private(set) var localHistory = LocalHistory()

    /// Local steps first: they are strictly newer than anything in the
    /// server's history — they exist precisely because they never reached it —
    /// so they are what "undo the last change" means while any of them stand.
    var canUndo: Bool {
        localHistory.canUndo ||
            ((app.connectivity.isOnline || app.isDemo) && undoRedo?.canUndo == true)
    }

    var canRedo: Bool {
        localHistory.canRedo ||
            ((app.connectivity.isOnline || app.isDemo) && undoRedo?.canRedo == true)
    }

    /// Whether the pair belongs in the toolbar at all. Without the second
    /// half, a lyric opened offline — its status never fetched, from a cached
    /// collection that may predate the link — would hide the buttons exactly
    /// when the local steps exist.
    var hasUndoStack: Bool { links.contains(.undoRedoStatus) }

    /// Whether the pair belongs in the editor's chrome at all: the server keeps
    /// a history for this song, or this device is holding steps of its own.
    /// Without the second half, a song opened offline for the first time — its
    /// links never fetched — would hide the pair exactly when the local steps
    /// are the only undo there is. `ScriptModel.offersUndoRedo` is the same
    /// question about the screenplay.
    var offersUndoRedo: Bool {
        hasUndoStack || undoRedo != nil || !localHistory.isEmpty
    }

    init(app: AppModel, document: TextDocument, draftStore: UnsavedDraftStore? = nil,
         offlineStore: OfflineStore? = nil) {
        self.app = app
        self.document = document
        self.draftStore = draftStore
            ?? app.draftScope.map { UnsavedDraftStore(scope: $0, folder: "SongDrafts") }
        self.offlineStore = offlineStore ?? app.offlineStore
    }

    // MARK: - Loading

    func load() async {
        guard let link = editionBlocksLink ?? document.link(.songBlocks) else { return }
        isLoading = true
        defer { isLoading = false }
        // Only the default edition is cached (and only it falls back), for the
        // screenplay's reason: a chosen edition travels as a link that means
        // nothing offline, and edition A's copy under edition B's banner is
        // worse than saying the switch needs a connection.
        let cacheKind: OfflineStore.Kind? = (editionBlocksLink == nil)
            ? document.projectId.map { .songBlocks(projectId: $0, documentId: document.id) }
            : nil
        do {
            let data = try await app.client.data(for: link)
            let collection: HALCollection<SongBlock> = try app.client.decode(from: data)
            adopt(collection)
            offlineCopySavedAt = nil
            errorMessage = nil
            adoptPersistedDrafts()
            noteSyncedIfSettled()
            if let cacheKind { offlineStore?.save(data, cacheKind) }
        } catch {
            // The network failed — fall back to the copy saved last time this
            // lyric loaded. Held drafts lay on top exactly as on a live load,
            // so words typed offline stay the newest thing on screen.
            if let cacheKind, error.isRetryableAPIError,
               let snapshot = offlineStore?.load(cacheKind),
               let collection: HALCollection<SongBlock> = try? app.client.decode(from: snapshot.data) {
                adopt(collection)
                offlineCopySavedAt = snapshot.savedAt
                errorMessage = nil
                adoptPersistedDrafts()
            } else {
                report(error)
            }
        }
        // After adopt, so the status link this round advertised is the one used.
        await refreshUndoRedo()
    }

    /// Internal, like `ScriptModel.adopt`, so the logic suites can seed a
    /// lyric without a server.
    func adopt(_ collection: HALCollection<SongBlock>) {
        blocks = collection.items.sorted { ($0.order ?? 0) < ($1.order ?? 0) }
        links = collection.links
    }

    // MARK: - Typing

    /// The text a line should show: what is being typed if anything, else what
    /// the server last said.
    func currentText(_ block: SongBlock) -> String {
        liveText[block.id] ?? block.text
    }

    /// Records a keystroke and schedules the save. Replacing the pending task
    /// is what makes this a debounce rather than a request per character.
    func edit(_ block: SongBlock, text: String) {
        liveText[block.id] = text
        scheduleCommit(block.id)
    }

    private func scheduleCommit(_ id: Int) {
        commitTasks[id]?.cancel()
        commitTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.commitDebounce)
            guard !Task.isCancelled else { return }
            // The slot goes back before the save, not after: `commit` cancels
            // whatever is in it to supersede a debounce still counting down,
            // and that is this task. See `ScriptModel.scheduleCommit`.
            self?.commitTasks[id] = nil
            // By id at fire time, not a block captured at key time: the line's
            // links may have been replaced by a reload in between.
            guard let self, let line = self.block(id) else { return }
            await self.commit(line)
        }
    }

    /// Saves a line now — on blur, or before an action that would reload.
    ///
    /// Reports whether the line and the server now agree, which a merge has to
    /// know before it deletes the line it just folded away. Nothing to save
    /// counts as agreeing.
    @discardableResult
    func commit(_ block: SongBlock) async -> Bool {
        commitTasks[block.id]?.cancel()
        commitTasks[block.id] = nil
        // No live words means nothing is held, whatever the flags say — a
        // failure that raced a success can leave the unsaved flag set with
        // the text already landed and cleared, and this is where that flag
        // gets put right rather than pulsing "saving" forever.
        guard let pending = liveText[block.id] else {
            markSaved(block.id)
            return true
        }
        // No link is different from no words: the words are still precious,
        // so the flags and the draft stay — a reload may bring the link back.
        guard let link = block.link(.update) else { return true }
        guard pending != block.text else {
            liveText[block.id] = nil
            markSaved(block.id)
            return true
        }
        // Snapshot before the attempt, not only after a failure: between here
        // and the response the words exist nowhere but this process, and a
        // kill mid-flight would otherwise be the end of them. Success removes
        // the draft again in `markSaved`.
        persistDraft(block.id)
        do {
            let updated: SongBlock = try await app.client.fetch(
                from: link, method: "PUT", body: EditSongBlockCommand(content: pending))
            liveText[block.id] = nil
            replace(updated)
            markSaved(block.id)
            errorMessage = nil
            // The edit left a checkpoint behind it, so there is now somewhere
            // to step back to even though the list did not reload. Refreshed
            // without making the caller wait: the status only feeds the
            // toolbar buttons, and Return awaits this commit before it can
            // make its line — a keystroke should never queue behind a status.
            refreshUndoRedoSoon()
            return true
        } catch {
            markUnsaved(block.id, after: error)
            return false
        }
    }

    /// Flushes every pending edit. Called before anything that reloads the
    /// list, so a half-typed line is not lost to its own refresh.
    func commitAll() async {
        for block in blocks where liveText[block.id] != nil {
            await commit(block)
        }
    }

    /// The backgrounding flush: every line's words go to disk *before* any
    /// commit is awaited, so even the commits the system never lets run are
    /// covered by the restore path on next launch — `commit` persists only
    /// as each PUT starts, and a process killed mid-flush would take every
    /// line after the first with it. Same shape as the screenplay's
    /// `flushPendingCommits`.
    func flushPendingCommits() async {
        for id in liveText.keys { persistDraft(id) }
        await commitAll()
    }

    // MARK: - Held work

    /// The server has this line's text; the live copy is no longer precious.
    private func markSaved(_ id: Int) {
        localHistory.noteSaved(blockId: id)
        unsavedBlockIds.remove(id)
        failedBlockIds.remove(id)
        retryTasks[id]?.cancel()
        retryTasks[id] = nil
        retryAttempts[id] = nil
        draftStore?.remove(blockId: id, projectId: document.id)
        noteSyncedIfSettled()
    }

    /// Stamp "last synced", but only with nothing left held — the screenplay's
    /// rule, for its reason: one line landing while three others are stranded
    /// is not this song being in step with the server.
    private func noteSyncedIfSettled() {
        guard unsavedBlockIds.isEmpty else { return }
        lastSyncedAt = .now
    }

    /// A write failed. Hold the line's words — flagged unsaved, snapshotted to
    /// disk — and, when the failure is the kind that clears up by itself, try
    /// again on a backoff rather than making the writer notice and retype.
    /// Only a *refusal* is worth an alert; a lost route has the badge.
    private func markUnsaved(_ id: Int, after error: Error) {
        unsavedBlockIds.insert(id)
        persistDraft(id)
        // An abandoned request is not a failed one: the debounce was
        // superseded or the screen was left, and whatever did that will
        // write the words again. See `isCancelledRequest`.
        guard !error.isCancelledRequest else { return }
        // A write the server never took is a change only this device knows,
        // which is exactly what local undo exists to take back. `textChange`
        // returns nil when nothing has moved since the last record, so the
        // retries that land back here every backoff never duplicate a step.
        if let text = liveText[id],
           let change = localHistory.textChange(blockId: id, to: text,
                                                lastSaved: block(id)?.text ?? "") {
            localHistory.record([change])
        }
        guard error.isRetryableAPIError else {
            failedBlockIds.insert(id)
            report(error)
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
            guard let self, let line = self.block(id) else { return }
            await self.commit(line)
        }
    }

    /// Snapshot a line's live text to disk, with the server's current content
    /// as the base — the restore path's evidence of whether the draft is still
    /// the newest thing anyone wrote.
    private func persistDraft(_ id: Int) {
        guard let store = draftStore, let text = liveText[id] else { return }
        store.save(UnsavedDraft(blockId: id, text: text,
                                baseText: block(id)?.content,
                                savedAt: .now),
                   projectId: document.id)
    }

    /// Pick up whatever drafts a previous run left behind: re-adopt each as
    /// live text and arm the ordinary debounced commit, so the retry machinery
    /// takes over. Idempotent — a line already being edited is left alone.
    ///
    /// A draft whose base no longer matches the server is *dropped*: someone
    /// edited that line elsewhere since the save failed, and the server is
    /// last-write-wins, so pushing the old draft would clobber newer words.
    ///
    /// That gate needs the server's word for what a line says, so it is only
    /// applied over a live load. Over the *offline copy* the comparison would
    /// be against however old that copy is — a line whose save landed after
    /// the cache was written reads as "changed elsewhere", and the draft is
    /// the writer's own newer words being thrown away for it. There every
    /// draft whose line exists is adopted and nothing is removed; the words
    /// stay held, and the reconnect push is last-write-wins, the same
    /// in-session rule the screenplay's reconnect deliberately follows.
    func adoptPersistedDrafts() {
        guard let store = draftStore else { return }
        var setAside = 0
        for (id, draft) in store.drafts(projectId: document.id) {
            guard liveText[id] == nil, !unsavedBlockIds.contains(id) else { continue }
            guard let line = block(id) else {
                // Not in this collection — possibly another edition's line.
                // Left on disk for the load that can see it.
                continue
            }
            if isShowingOfflineCopy {
                liveText[id] = draft.text
                unsavedBlockIds.insert(id)
                scheduleCommit(id)
                continue
            }
            let server = line.content ?? ""
            if draft.text == server {
                store.remove(blockId: id, projectId: document.id)
                continue
            }
            guard draft.baseText == nil || draft.baseText == server else {
                store.remove(blockId: id, projectId: document.id)
                setAside += 1
                continue
            }
            liveText[id] = draft.text
            unsavedBlockIds.insert(id)
            scheduleCommit(id)
        }
        if setAside > 0 {
            // These are words the writer typed and never saw land, so they
            // must not go silently. The editor's error alert is the only
            // mouth this model has.
            errorMessage = setAside == 1
                ? "An offline edit was set aside — that line changed elsewhere"
                : "\(setAside) offline edits were set aside — those lines changed elsewhere"
        }
    }

    /// The badge's "Sync Now": push what is typed but not yet sent, drain what
    /// is held, then pull. The sweep below skips that last step unless it was
    /// showing the offline copy — reasonable for a reconnect nobody asked for,
    /// wrong for a button whose whole promise in the healthy state is to check
    /// for changes.
    func syncNow() async {
        await commitAll()
        // Read before the sweep, not after: a sweep that succeeds clears the
        // flag, so asking afterwards would say "was never stale" every time
        // the reload it just did worked — and load twice for its trouble.
        let wasStale = isShowingOfflineCopy
        await syncHeldWork()
        if !wasStale { await load() }
    }

    /// Push every held line right now — the connection is back, or the editor
    /// has come to the foreground with work still on this device. Restarts
    /// each line's backoff: this push is prompted by a route returning, not by
    /// a timer that has already run its course.
    ///
    /// Single-flight, like the screenplay's sweep and for the same reason: the
    /// online edge and the foreground often fire together, and the second
    /// caller must join the drain already running rather than PUT every held
    /// line a second time beside it.
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
        for id in unsavedBlockIds.sorted() {
            guard let line = block(id) else { continue }
            retryAttempts[id] = nil
            await commit(line)
        }
        // The route is back and the lyric on screen may be the old copy: a
        // successful load replaces it and takes the banner down with it.
        if isShowingOfflineCopy { await load() }
        // Everything made it: those edits are the server's history now, and
        // ⌘Z should walk that rather than replay the offline session locally.
        // A drain that fell short keeps its steps — the writer is still
        // effectively offline, and they are still the only undo there is.
        if unsavedBlockIds.isEmpty { localHistory.clear() }
    }

    // MARK: - Structure

    /// Adds a line at the end.
    ///
    /// Empty for the editor, which adds a line so it can be typed into. A
    /// dictated one arrives already written — there is no cursor to put in it —
    /// and sending the words with the line that carries them is one request
    /// rather than a create followed by an edit that could fail on its own and
    /// leave a blank line behind.
    @discardableResult
    func appendLine(content: String = "") async -> Int? {
        guard let link = links[.create] else { return nil }
        return await create(from: link, content: content)
    }

    /// Adds a line directly below another — what Return does.
    @discardableResult
    func addLine(below block: SongBlock) async -> Int? {
        guard let link = block.link(.createBelow) else { return nil }
        await commit(block)
        return await create(from: link, below: block)
    }

    private func create(from link: HALLink, below anchor: SongBlock? = nil,
                        content: String = "") async -> Int? {
        do {
            let created: SongBlock = try await app.client.fetch(
                from: link, method: "POST", body: CreateSongBlockCommand(content: content))
            insert(created, below: anchor)
            errorMessage = nil
            focusRequest = created.id
            refreshUndoRedoSoon()
            return created.id
        } catch {
            report(error)
            return nil
        }
    }

    /// Put a line the server just created on screen below its anchor — at the
    /// end, when there is none. The create answers with the one new line, not
    /// the renumbered collection, so this shows the reply without the full
    /// reload the caret would have to wait behind: Return has to feel like a
    /// keystroke, not a request. The margin numbers are kept right locally —
    /// the anchor's plus one, everything after bumped along — rather than
    /// trusted from the reply, since the server numbers the collection after
    /// answering.
    private func insert(_ created: SongBlock, below anchor: SongBlock?) {
        guard !blocks.contains(where: { $0.id == created.id }) else { return }
        let index = anchor.flatMap { self.index(of: $0) }.map { $0 + 1 } ?? blocks.count
        var block = created
        block.order = index > 0 ? (blocks[index - 1].order ?? index) + 1 : 1
        blocks.insert(block, at: index)
        for following in blocks.indices.dropFirst(index + 1) {
            blocks[following].order = (blocks[following].order ?? following) + 1
        }
    }

    /// Backspace with the caret at the very start of a line: fold the line into
    /// the one above and leave the caret at the seam. Returns the line the
    /// caret should move to, or nil when there is nowhere to fold into — the
    /// first line of the lyric, or one the server will not let this writer
    /// change.
    ///
    /// The screenplay has done this since it shipped, and a lyric is the same
    /// shape: lines a writer walks through with the caret, where the way out of
    /// a Return pressed by mistake should be the key that undoes typing
    /// everywhere else. An empty line is the ordinary case and falls out of the
    /// same arithmetic — nothing is added to the line above, and the empty one
    /// goes.
    @discardableResult
    func mergeIntoPrevious(_ block: SongBlock) async -> Int? {
        guard block.hasLink(.delete),
              let index = index(of: block), index > 0,
              let previous = blocks[..<index].last(where: { $0.hasLink(.update) })
        else { return nil }

        let previousText = currentText(previous)
        let seam = previousText.count
        let merged = previousText + currentText(block)

        // A merge that cannot be persisted has to leave both lines exactly as
        // they were: half of one would show the writer their own words twice.
        let restore = liveText[previous.id]
        liveText[previous.id] = merged
        guard await commit(previous) else {
            unmerge(previous.id, restoring: restore)
            return nil
        }

        commitTasks[block.id]?.cancel()
        commitTasks[block.id] = nil
        liveText[block.id] = nil
        guard await delete(block) else {
            // The folded-away line is still there, so the merged words now
            // appear twice. Put the line above back the way it was and leave
            // the lyric as it stood before the Backspace.
            if let current = self.block(previous.id) {
                liveText[previous.id] = previousText
                await commit(current)
            }
            return nil
        }
        caretRequests[previous.id] = seam
        focusRequest = previous.id
        return previous.id
    }

    /// A merge whose PUT did not land must leave the line above exactly as it
    /// was — including the held-work bookkeeping `commit`'s failure just wrote
    /// for the *merged* text, which is not something the writer typed and must
    /// not survive as a draft. What they had typed before the merge, if
    /// anything, goes back to being held on its own.
    private func unmerge(_ id: Int, restoring text: String?) {
        // The failed write recorded itself as a local step (see `markUnsaved`);
        // the merged words are being taken off the screen, so the record has to
        // come off with them or undo would replay a merge nobody kept.
        if let attempted = liveText[id] {
            localHistory.unrecordText(blockId: id, after: attempted)
        }
        liveText[id] = text
        retryTasks[id]?.cancel()
        retryTasks[id] = nil
        retryAttempts[id] = nil
        failedBlockIds.remove(id)
        if text == nil {
            unsavedBlockIds.remove(id)
            draftStore?.remove(blockId: id, projectId: document.id)
        } else {
            persistDraft(id)
            scheduleCommit(id)
        }
    }

    @discardableResult
    func delete(_ block: SongBlock) async -> Bool {
        guard let link = block.link(.delete) else { return false }
        commitTasks[block.id]?.cancel()
        liveText[block.id] = nil
        // Deleting a line means dropping the words typed into it — the held
        // copy and its retry go with them, whatever the request then does.
        markSaved(block.id)
        do {
            // The delete answers with the renumbered collection, so adopting
            // it is the reload — fetching the same list again only made the
            // caret wait twice, which Backspace-at-the-seam felt.
            let collection: HALCollection<SongBlock> = try await app.client.fetch(
                from: link, method: "DELETE")
            adopt(collection)
            errorMessage = nil
            refreshUndoRedoSoon()
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Puts a line at an absolute index in the lyric — what a drag lands on.
    /// Out-of-range targets are dropped rather than clamped: a drop past
    /// the end of the list is the list refusing it, not a request to move to
    /// the end.
    func move(_ block: SongBlock, to index: Int) async {
        guard let link = block.link(.move),
              blocks.indices.contains(index),
              index != self.index(of: block) else { return }
        await commitAll()
        do {
            // Positions are absolute and 1-based, as the collection reports.
            let _: HALCollection<SongBlock> = try await app.client.fetch(
                from: link, method: "POST", body: MoveSongBlockCommand(position: index + 1))
            await load()
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    /// A nil colour clears the tint.
    func setHighlight(_ block: SongBlock, to highlight: BlockHighlight?) async {
        guard let link = block.link(.setHighlight) else { return }
        do {
            let updated: SongBlock = try await app.client.fetch(
                from: link, method: "POST",
                body: SetSongBlockHighlightCommand(highlight: highlight?.rawValue))
            replace(updated)
            errorMessage = nil
            await refreshUndoRedo()
        } catch {
            report(error)
        }
    }

    // MARK: - Undo / redo

    /// Re-reads whether there is anywhere to step. Quiet on failure: a stale
    /// pair of buttons is a smaller intrusion than an alert about a status.
    func refreshUndoRedo() async {
        guard let link = links[.undoRedoStatus] else { return }
        undoRedo = try? await app.client.fetch(UndoRedoStatus.self, from: link)
    }

    /// The same refresh without making the caller wait for the round trip —
    /// for the typing path, where the caret must not queue behind a status.
    /// `ScriptModel.refreshUndoRedoSoon` is the same seam for the screenplay.
    private func refreshUndoRedoSoon() {
        Task { await refreshUndoRedo() }
    }

    /// Local steps are drained before the server is asked, in both directions:
    /// a change the server never saw sits on top of everything it did see.
    func undo() async {
        if applyLocalStep(.undo) { return }
        await step(.undo)
    }

    func redo() async {
        if applyLocalStep(.redo) { return }
        await step(.redo)
    }

    private func step(_ rel: Rel) async {
        guard let link = undoRedo?.link(rel) else { return }
        // A half-typed line would be undone out from under itself otherwise —
        // the checkpoint it belongs to has not been recorded yet.
        await commitAll()
        do {
            let collection: HALCollection<SongBlock> = try await app.client.fetch(
                from: link, method: "POST")
            adopt(collection)
            // The server's answer rewrote the lyric under whatever local steps
            // are left on the other side — they describe a document that is no
            // longer on screen, so they go.
            localHistory.clear()
            await refreshUndoRedo()
            errorMessage = nil
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
        // A step's changes were recorded in the order they happened, so undo
        // walks them backwards and redo forwards. A lyric only ever records
        // one change per step today, but the ordering is the screenplay's and
        // costs nothing to keep.
        let ordered = direction == .undo ? step.changes.reversed() : step.changes
        for change in ordered { apply(change, direction) }
        // The step crosses to the other stack unchanged: a text change holds
        // both sides of itself, so the same value describes the way back.
        if direction == .undo {
            localHistory.pushUndone(step)
        } else {
            localHistory.pushRedone(step)
        }
        return true
    }

    private func apply(_ change: LocalChange, _ direction: HistoryDirection) {
        // Text is the only kind this model records — see `localHistory`.
        guard case let .text(blockId, before, after) = change else { return }
        applyText(blockId, to: direction == .undo ? before : after)
    }

    /// Put text back on a line, through the same channel the words originally
    /// travelled: it becomes the live copy and re-arms the ordinary debounced
    /// save — which lands, retries or holds exactly as typing the restoration
    /// by hand would have. A line the collection no longer carries has nothing
    /// to apply to; offline nothing can leave the lyric, so this is the
    /// reloaded-underneath case rather than a step going missing.
    private func applyText(_ id: Int, to text: String) {
        guard block(id) != nil else { return }
        localHistory.noteApplied(blockId: id, text: text)
        liveText[id] = text
        // Fresh words earn a fresh set of retries, as typing them would.
        retryAttempts[id] = nil
        failedBlockIds.remove(id)
        // The copy on disk is out of date the moment the screen changes: a
        // relaunch before the debounce fires must not bring back the words this
        // step has just walked away from.
        persistDraft(id)
        scheduleCommit(id)
    }

    // MARK: - Plumbing

    private func index(of block: SongBlock) -> Int? {
        blocks.firstIndex { $0.id == block.id }
    }

    /// The line as the model currently holds it. A snapshot taken before a
    /// round trip is stale afterwards, and the links a rollback needs live on
    /// the current one.
    private func block(_ id: Int) -> SongBlock? {
        blocks.first { $0.id == id }
    }

    private func replace(_ block: SongBlock) {
        guard let index = index(of: block) else { return }
        blocks[index] = block
    }

    private func report(_ error: Error) {
        // Nothing cancelled is ever shown — see `isCancelledRequest`.
        guard !error.isCancelledRequest else { return }
        app.handle(error)
        errorMessage = error.localizedDescription
    }
}
