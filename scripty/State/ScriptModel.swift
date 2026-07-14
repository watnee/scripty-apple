//
//  ScriptModel.swift
//  scripty
//
//  State for one open screenplay: its blocks, characters, undo/redo status,
//  the caret, and a background sync-polling task that picks up edits made
//  elsewhere (e.g. in the web app).
//
//  Editing is local-first. Keystrokes land in `drafts` and render immediately;
//  the server sees them a beat later (see `scheduleSave`). Structural edits —
//  Enter, Tab, Backspace — flush the pending draft first so the server never
//  applies them to stale text.
//

import Foundation
import Observation

/// Where the caret is. Enter and Backspace move it between blocks, so it lives
/// in the model rather than in any one row's view.
struct BlockFocus: Equatable {
    enum Caret: Equatable {
        case start
        case end
        case offset(Int)
    }

    var blockId: Int
    var caret: Caret = .end
    /// Bumped on every focus change so a row can tell "focus me again, with a
    /// new caret" apart from "you already have focus".
    var generation: Int = 0
}

@Observable @MainActor
final class ScriptModel {
    let app: AppModel
    private(set) var project: Project

    private(set) var blocks: [Block] = []
    private(set) var blocksLinks = HALLinks()
    private(set) var characters: [Person] = []
    private(set) var charactersLinks = HALLinks()
    private(set) var canViewCharacters = true
    private(set) var undoRedo: UndoRedoStatus?
    private(set) var isLoading = false
    var errorMessage: String?

    /// Content the writer has typed but the server has not stored yet, keyed by
    /// block id. Reads go through `content(of:)` so the page shows the draft.
    private(set) var drafts: [Int: String] = [:]

    var focus: BlockFocus?
    private var focusCounter = 0

    private var saveTasks: [Int: Task<Void, Never>] = [:]
    private var lastRevision: Int64 = 0
    private var syncTask: Task<Void, Never>?

    private static let syncInterval: Duration = .seconds(5)
    /// How long typing pauses before the draft goes to the server.
    private static let saveDebounce: Duration = .milliseconds(700)

    init(app: AppModel, project: Project) {
        self.app = app
        self.project = project
    }

    /// Pause sync while the writer is mid-thought, so a poll cannot overwrite
    /// text that has not been saved yet.
    var hasActiveEdit: Bool {
        focus != nil || !drafts.isEmpty
    }

    // MARK: - Loading

    func loadEverything() async {
        isLoading = true
        defer { isLoading = false }
        await loadBlocks()
        await loadCharacters()
        await refreshUndoRedo()
    }

    func loadBlocks() async {
        guard let link = project.link(.blocks) else { return }
        do {
            let collection: HALCollection<Block> = try await app.client.fetch(from: link)
            blocks = collection.items.sorted { ($0.order ?? 0) < ($1.order ?? 0) }
            blocksLinks = collection.links
            errorMessage = nil
        } catch {
            report(error)
        }
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

    // MARK: - Caret

    func focus(_ blockId: Int, caret: BlockFocus.Caret = .end) {
        focusCounter += 1
        focus = BlockFocus(blockId: blockId, caret: caret, generation: focusCounter)
    }

    /// The keyboard landed on a block by itself (a tap), so follow it.
    func focusArrived(at blockId: Int) {
        guard focus?.blockId != blockId else { return }
        focusCounter += 1
        focus = BlockFocus(blockId: blockId, caret: .end, generation: focusCounter)
    }

    func endEditing() {
        focus = nil
        Task { await flushDrafts() }
    }

    // MARK: - Typing

    /// What the page should show for a block: the unsaved draft if there is one.
    func content(of block: Block) -> String {
        drafts[block.id] ?? block.content ?? ""
    }

    /// A keystroke. Renders now, saves shortly.
    func edit(_ block: Block, content: String) {
        guard content != (block.content ?? "") || drafts[block.id] != nil else { return }
        drafts[block.id] = content
        scheduleSave(block.id)
    }

    private func scheduleSave(_ blockId: Int) {
        saveTasks[blockId]?.cancel()
        saveTasks[blockId] = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDebounce)
            guard !Task.isCancelled else { return }
            await self?.save(blockId: blockId)
        }
    }

    /// Persists one block's draft, retyping it first if what was typed is
    /// unambiguously another element ("INT. HOUSE - DAY" is a scene heading).
    @discardableResult
    private func save(blockId: Int) async -> Block? {
        saveTasks[blockId]?.cancel()
        saveTasks[blockId] = nil
        guard let draft = drafts[blockId],
              let block = blocks.first(where: { $0.id == blockId }) else { return nil }
        drafts[blockId] = nil
        return await commit(block, content: draft)
    }

    /// Flushes every pending draft. Call before anything structural.
    func flushDrafts() async {
        for id in Array(drafts.keys) {
            await save(blockId: id)
        }
    }

    /// Stores `content` on a block, retyping it first if the text says so.
    @discardableResult
    private func commit(_ block: Block, content: String) async -> Block? {
        if let detection = Fountain.detect(content),
           Fountain.shouldApply(detection, to: block.blockType),
           block.hasLink(.setType) {
            return await retype(block, to: detection.type, content: detection.content)
        }
        return await store(block, content: content)
    }

    private func store(_ block: Block, content: String) async -> Block? {
        guard let link = block.link(.update) else { return nil }
        do {
            let updated: Block = try await app.client.fetch(
                from: link, method: "PUT",
                body: EditBlockCommand(content: content,
                                       personId: block.personId,
                                       tags: block.tags))
            replace(updated)
            await refreshUndoRedo()
            errorMessage = nil
            return updated
        } catch {
            report(error)
            return nil
        }
    }

    // MARK: - Retyping (Tab, and the element bar)

    @discardableResult
    func retype(_ block: Block, to type: BlockType, content: String? = nil) async -> Block? {
        guard let link = block.link(.setType) else { return nil }
        // A pending draft is newer than `block.content`; send it rather than
        // letting the server keep the stale text.
        var text = content ?? drafts[block.id]
        // Retyping into a caps element (Tab from action to a cue, say) has to
        // carry the existing words up into caps with it.
        if ScreenplayLayout.of(type).isUppercase {
            let existing = text ?? block.content ?? ""
            if !existing.isEmpty { text = existing.uppercased() }
        }
        saveTasks[block.id]?.cancel()
        drafts[block.id] = nil

        do {
            let updated: Block = try await app.client.fetch(
                from: link, method: "POST",
                body: SetBlockTypeCommand(type: type.rawValue,
                                          content: text,
                                          personId: block.personId,
                                          tags: block.tags))
            replace(updated)
            await refreshUndoRedo()
            errorMessage = nil
            return updated
        } catch {
            report(error)
            return nil
        }
    }

    /// Tab / Shift-Tab on the focused block.
    func cycleType(_ block: Block, backward: Bool) async {
        await retype(block, to: Fountain.cycle(block.blockType, backward: backward))
        focus(block.id, caret: .end)
    }

    // MARK: - Enter

    /// Splits a block at the caret: `before` stays, `after` moves into a new
    /// element below. The new element's type follows the screenplay convention —
    /// a cue is followed by dialogue, everything else by action.
    func splitBlock(_ block: Block, before: String, after: String) async {
        saveTasks[block.id]?.cancel()
        drafts[block.id] = nil

        // Save the text left of the caret first. This may also retype the
        // block, which is what decides the new block's type.
        let anchor = await commit(block, content: before) ?? block

        let newType = Fountain.nextType(after: anchor.blockType)
        // Dialogue belongs to whoever the cue above it named.
        let speaker = newType == .dialogue ? anchor.personId : nil

        guard let link = anchor.link(.createBelow) else { return }
        do {
            let created: Block = try await app.client.fetch(
                from: link, method: "POST",
                body: CreateBlockBelowCommand(content: after,
                                              personId: speaker,
                                              type: newType.rawValue))
            await loadBlocks()
            await refreshUndoRedo()
            focus(created.id, caret: .start)
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    // MARK: - Backspace

    /// Backspace with the caret at the start of a block: fold it into the one
    /// above. An empty block simply disappears.
    func backspaceAtStart(of block: Block) async {
        guard let index = blocks.firstIndex(where: { $0.id == block.id }),
              index > 0,                       // nothing above to fold into
              block.hasLink(.delete) else { return }
        let previous = blocks[index - 1]

        let tail = content(of: block)
        saveTasks[block.id]?.cancel()
        drafts[block.id] = nil

        if tail.isEmpty {
            await deleteBlock(block)
            focus(previous.id, caret: .end)
            return
        }

        // Non-empty: append this block's text to the one above, caret at the seam.
        let head = content(of: previous)
        await deleteBlock(block)
        await commit(previous, content: head + tail)
        focus(previous.id, caret: .offset((head as NSString).length))
    }

    // MARK: - Block mutations (all gated by link presence)

    /// The first element of an untouched script. The server only offers this
    /// link while the script is empty.
    func createInitialBlock() async {
        guard let link = blocksLinks[.createInitial] else { return }
        do {
            let created: Block = try await app.client.fetch(from: link, method: "POST")
            await loadBlocks()
            await refreshUndoRedo()
            focus(created.id, caret: .end)
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    /// Appends an element after the last one — the "+" in the toolbar.
    func appendBlock() async {
        await flushDrafts()
        guard let last = blocks.last else {
            await createInitialBlock()
            return
        }
        await splitBlock(last, before: content(of: last), after: "")
    }

    func deleteBlock(_ block: Block) async {
        guard let link = block.link(.delete) else { return }
        saveTasks[block.id]?.cancel()
        drafts[block.id] = nil
        do {
            try await app.client.data(for: link, method: "DELETE")
            blocks.removeAll { $0.id == block.id }
            if focus?.blockId == block.id { focus = nil }
            await refreshUndoRedo()
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    /// Drag-to-reorder. `position` is an absolute order, matching the collection.
    func move(_ block: Block, to position: Int) async {
        guard let link = block.link(.move) else { return }
        await flushDrafts()
        do {
            let _: Block = try await app.client.fetch(
                from: link, method: "POST", body: MoveBlockCommand(position: position))
            await loadBlocks()
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

    /// Links a block to a character — the speaker of a cue or a line.
    @discardableResult
    func setSpeaker(_ block: Block, personId: Int?) async -> Bool {
        guard let link = block.link(.update) else { return false }
        do {
            let updated: Block = try await app.client.fetch(
                from: link, method: "PUT",
                body: EditBlockCommand(content: content(of: block),
                                       personId: personId,
                                       tags: block.tags))
            replace(updated)
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    @discardableResult
    func setTags(_ block: Block, tags: String?) async -> Bool {
        guard let link = block.link(.update) else { return false }
        do {
            let updated: Block = try await app.client.fetch(
                from: link, method: "PUT",
                body: EditBlockCommand(content: content(of: block),
                                       personId: block.personId,
                                       tags: tags))
            replace(updated)
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    private func replace(_ updated: Block) {
        if let index = blocks.firstIndex(where: { $0.id == updated.id }) {
            blocks[index] = updated
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
        await flushDrafts()
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

    private func report(_ error: Error) {
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

    // MARK: - Export

    struct ExportOption: Identifiable {
        let rel: Rel
        let label: String
        let fileExtension: String
        let link: HALLink

        var id: String { rel.rawValue }
    }

    var exportOptions: [ExportOption] {
        let all: [(Rel, String, String)] = [
            (.exportPdf, "PDF", "pdf"),
            (.export, "Fountain", "fountain"),
            (.exportDocx, "Word", "docx"),
            (.exportFdx, "Final Draft", "fdx"),
        ]
        return all.compactMap { rel, label, ext in
            project.link(rel).map { ExportOption(rel: rel, label: label, fileExtension: ext, link: $0) }
        }
    }

    /// Downloads an export with auth and writes it to a shareable temp file.
    func export(_ option: ExportOption) async throws -> URL {
        await flushDrafts()
        let data = try await app.client.data(for: option.link)
        let safeTitle = project.displayTitle
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined()
        let name = (safeTitle.isEmpty ? "script" : safeTitle) + "." + option.fileExtension
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }
}
