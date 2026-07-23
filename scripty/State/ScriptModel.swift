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
    private(set) var isLoading = false
    var errorMessage: String?

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

    init(app: AppModel, project: Project) {
        self.app = app
        self.project = project
    }

    // MARK: - Loading

    func loadEverything() async {
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
            Task { await loadBlocks() }
        }
    }

    func loadBlocks() async {
        guard let link = editionBlocksLink ?? project.link(.blocks) else { return }
        do {
            let collection: HALCollection<Block> = try await app.client.fetch(from: link)
            adopt(collection)
            errorMessage = nil
        } catch {
            report(error)
        }
        await loadCommentCounts()
    }

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
            let collection: HALCollection<Person> = try await app.client.fetch(from: link)
            characters = collection.items.sorted { $0.displayName < $1.displayName }
            charactersLinks = collection.links
            canViewCharacters = true
        } catch APIError.forbidden {
            canViewCharacters = false
        } catch {
            report(error)
        }
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

    // MARK: - Unsaved-work bookkeeping

    /// The server has this block's text; the live copy is no longer precious.
    private func markSaved(_ id: Int) {
        unsavedBlockIds.remove(id)
        retryTasks[id]?.cancel()
        retryTasks[id] = nil
        retryAttempts[id] = nil
    }

    /// A write failed. Flag the block so its live text is held, and — when the
    /// failure was the kind that might clear up by itself — try again on a
    /// backoff rather than making the writer notice and retype.
    private func markUnsaved(_ id: Int, after error: Error) {
        unsavedBlockIds.insert(id)
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

    /// Give up on a speculative write (a merge that couldn't be persisted) and
    /// put the block's live text back the way it was.
    private func rollback(_ id: Int, to previous: String?) {
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
                liveText[block.id] = full
                return
            }
            source = retyped
        } else {
            guard let committed = await commit(block.id) else {
                liveText[block.id] = full
                return
            }
            source = committed
        }
        liveText[block.id] = nil

        guard let link = source.link(.createBelow) else { return }
        do {
            let created: Block = try await app.client.fetch(
                from: link, method: "POST",
                body: CreateBelowCommand(content: after,
                                         personId: nil,
                                         type: currentType.followingType.rawValue))
            await loadBlocks()
            await refreshUndoRedo()
            focus(created.id, caret: 0)
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    /// Create a new, empty element of `type` immediately below `block` — the
    /// element half of the web's create-below "+" menu (its Songs/Notes half
    /// is `insertDocument`). The type rides `CreateBelowCommand`, which the
    /// `createBelow` endpoint already honours; Return uses the same call with
    /// the following-type convention. This is the only touch route to the
    /// types the element-type bar leaves off (Text, Dual Dialogue, Page Break).
    func insertBlock(below block: Block, type: BlockType) async {
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
            report(error)
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
        guard let last = blocks.last, let link = last.link(.createBelow) else {
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
            report(error)
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

    func undo() async {
        await performUndoRedo(rel: .undo)
    }

    func redo() async {
        await performUndoRedo(rel: .redo)
    }

    private func performUndoRedo(rel: Rel) async {
        guard let link = undoRedo?.link(rel) else { return }
        do {
            undoRedo = try await app.client.fetch(UndoRedoStatus.self, from: link, method: "POST")
            await loadBlocks()
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    // MARK: - Sync polling

    func startSyncPolling() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.syncInterval)
                guard !Task.isCancelled else { return }
                await self?.pollSync()
            }
        }
    }

    func stopSyncPolling() {
        syncTask?.cancel()
        syncTask = nil
    }

    private func pollSync() async {
        guard !hasActiveEdit, let base = project.link(.syncStatus) else { return }
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
            let collection: HALCollection<TextDocument> = try await app.client.fetch(from: link)
            documents = collection.items.sorted { ($0.sortOrder ?? 0) < ($1.sortOrder ?? 0) }
            documentsLinks = collection.links
            errorMessage = nil
        } catch {
            report(error)
        }
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

    @discardableResult
    func updateDocument(_ document: TextDocument, title: String, content: String) async -> Bool {
        guard let link = document.link(.update) else { return false }
        do {
            let _: TextDocument = try await app.client.fetch(
                from: link, method: "PUT",
                body: EditDocumentCommand(projectId: project.id, title: title,
                                          documentType: document.kind.rawValue, content: content))
            await loadDocuments()
            await loadBlocks()   // an edit may have re-synced inserted blocks
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
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
