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

    private(set) var blocks: [Block] = []
    private(set) var blocksLinks = HALLinks()
    private(set) var characters: [Person] = []
    private(set) var charactersLinks = HALLinks()
    private(set) var canViewCharacters = true

    /// Whether the writer can add or edit elements: true when the server
    /// offers to seed an empty script, or any existing block is editable.
    var canEditScript: Bool {
        blocksLinks[.createInitial] != nil || blocks.contains { $0.isEditable }
    }
    private(set) var undoRedo: UndoRedoStatus?
    private(set) var isLoading = false
    var errorMessage: String?

    /// Set while an editor sheet is open so a sync refresh doesn't clobber
    /// in-progress typing.
    var hasActiveEdit = false

    // MARK: - Inline editing state

    /// The block whose text field currently holds the keyboard, or nil when
    /// the editor is idle. Drives the element-type bar and pauses sync.
    var focusedBlockId: Int?

    /// Uncommitted text per block as the writer types — the source of truth
    /// for the visible field until a PUT persists it. Keyed by block id.
    var liveText: [Int: String] = [:]

    /// A one-shot request to place the caret at a character offset in a block
    /// after a programmatic change (split, merge, retype). Consumed by the
    /// text view, then cleared via `caretApplied`.
    var caretRequests: [Int: Int] = [:]

    /// Per-block debounced save tasks, cancelled and rescheduled on each keystroke.
    private var saveTasks: [Int: Task<Void, Never>] = [:]
    private static let saveDebounce: Duration = .milliseconds(600)

    private var lastRevision: Int64 = 0
    private var syncTask: Task<Void, Never>?

    private static let syncInterval: Duration = .seconds(5)

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

    func loadBlocks() async {
        guard let link = project.link(.blocks) else { return }
        do {
            let collection: HALCollection<Block> = try await app.client.fetch(from: link)
            blocks = collection.items.sorted { ($0.order ?? 0) < ($1.order ?? 0) }
            blocksLinks = collection.links
            syncLiveText()
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
            liveText[updated.id] = updated.content ?? content
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
        saveTasks[block.id]?.cancel()
        saveTasks[block.id] = nil
        do {
            try await app.client.data(for: link, method: "DELETE")
            blocks.removeAll { $0.id == block.id }
            liveText[block.id] = nil
            if focusedBlockId == block.id { focusedBlockId = nil }
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

    private func replace(_ updated: Block) {
        if let index = blocks.firstIndex(where: { $0.id == updated.id }) {
            blocks[index] = updated
        }
    }

    // MARK: - Inline editing

    /// Live text for a block, falling back to its persisted content.
    func text(for block: Block) -> String {
        liveText[block.id] ?? block.content ?? ""
    }

    /// Reset every block's live text to its persisted content, preserving the
    /// block currently being typed into so a background reload can't wipe it.
    private func syncLiveText() {
        var refreshed: [Int: String] = [:]
        for block in blocks {
            if block.id == focusedBlockId, let inFlight = liveText[block.id] {
                refreshed[block.id] = inFlight
            } else {
                refreshed[block.id] = block.content ?? ""
            }
        }
        liveText = refreshed
    }

    /// The text view reports every keystroke here: hold it in memory and
    /// schedule a debounced save so typing stays snappy.
    func noteEdit(_ block: Block, text: String) {
        liveText[block.id] = text
        scheduleSave(block)
    }

    private func scheduleSave(_ block: Block) {
        saveTasks[block.id]?.cancel()
        let id = block.id
        saveTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDebounce)
            guard !Task.isCancelled else { return }
            await self?.commitContent(id)
            self?.saveTasks[id] = nil
        }
    }

    /// Persist a block's live text if it differs from what the server holds.
    @discardableResult
    private func commitContent(_ blockId: Int) async -> Bool {
        saveTasks[blockId]?.cancel()
        saveTasks[blockId] = nil
        guard let block = blocks.first(where: { $0.id == blockId }),
              let link = block.link(.update) else { return true }
        let content = liveText[blockId] ?? block.content ?? ""
        guard content != (block.content ?? "") else { return true }
        do {
            let updated: Block = try await app.client.fetch(
                from: link, method: "PUT",
                body: EditBlockCommand(content: content,
                                       personId: block.personId,
                                       tags: block.tags))
            replace(updated)
            if focusedBlockId != blockId {
                liveText[blockId] = updated.content ?? content
            }
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Focus moved onto a block: pause sync and remember which one.
    func beginEditing(_ block: Block) {
        focusedBlockId = block.id
    }

    /// Focus left a block: flush its pending edits and, if nothing else took
    /// focus, mark the editor idle.
    func endEditing(_ block: Block) {
        if focusedBlockId == block.id {
            focusedBlockId = nil
        }
        Task { await commitContent(block.id) }
    }

    /// Enter inside a block: the text before the caret stays, the text after
    /// moves into a new element below whose type follows screenplay flow.
    func splitBlock(_ block: Block, before: String, after: String) async {
        guard let link = block.link(.createBelow) else { return }
        liveText[block.id] = before
        await commitContent(block.id)
        let newType = block.blockType.followingType
        let personId = newType == .dialogue ? block.personId : nil
        do {
            let created: Block = try await app.client.fetch(
                from: link, method: "POST",
                body: CreateBelowCommand(content: after, personId: personId,
                                         type: newType.rawValue))
            insertAfter(block.id, created)
            liveText[created.id] = created.content ?? after
            focusedBlockId = created.id
            caretRequests[created.id] = 0
            await refreshUndoRedo()
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    /// Backspace at the very start of a block: merge its text onto the end of
    /// the previous editable block and remove this one, matching the web editor.
    func mergeIntoPrevious(_ block: Block) async {
        guard let index = blocks.firstIndex(where: { $0.id == block.id }), index > 0 else { return }
        let previous = blocks[index - 1]
        guard previous.link(.update) != nil, block.link(.delete) != nil else { return }
        let previousText = liveText[previous.id] ?? previous.content ?? ""
        let currentText = liveText[block.id] ?? block.content ?? ""
        let joinOffset = previousText.count

        liveText[previous.id] = previousText + currentText
        await commitContent(previous.id)
        await removeBlock(block)
        focusedBlockId = previous.id
        caretRequests[previous.id] = joinOffset
        await refreshUndoRedo()
    }

    /// Retype the focused block in place (the element-type bar / Tab key).
    func changeType(_ block: Block, to type: BlockType) async {
        guard let link = block.link(.setType) else { return }
        let content = liveText[block.id] ?? block.content ?? ""
        do {
            let updated: Block = try await app.client.fetch(
                from: link, method: "POST",
                body: SetTypeCommand(type: type.rawValue, content: content,
                                     personId: block.personId, tags: nil))
            replace(updated)
            let newText = updated.content ?? ""
            liveText[updated.id] = newText
            caretRequests[updated.id] = newText.count
            await refreshUndoRedo()
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    /// Create the first element of an untouched script, then focus it. The
    /// server advertises `createInitial` on the block collection only while the
    /// script is empty; otherwise fall back to a plain create.
    func createFirstBlock() async {
        if let link = blocksLinks[.createInitial] {
            do {
                let created: Block = try await app.client.fetch(from: link, method: "POST")
                blocks.append(created)
                liveText[created.id] = created.content ?? ""
                focusedBlockId = created.id
                caretRequests[created.id] = 0
                await refreshUndoRedo()
                errorMessage = nil
            } catch {
                report(error)
            }
        } else if await createBlock(content: "", type: .action, personId: nil),
                  let created = blocks.last {
            focusedBlockId = created.id
            caretRequests[created.id] = 0
        }
    }

    /// Append a new element after the last block and focus it (the toolbar +).
    func appendBlock() async {
        if let last = blocks.last, last.link(.createBelow) != nil {
            await splitBlock(last, before: text(for: last), after: "")
        } else {
            await createFirstBlock()
        }
    }

    func caretApplied(_ blockId: Int) {
        caretRequests[blockId] = nil
    }

    private func insertAfter(_ anchorId: Int, _ block: Block) {
        if let index = blocks.firstIndex(where: { $0.id == anchorId }) {
            blocks.insert(block, at: index + 1)
        } else {
            blocks.append(block)
        }
    }

    private func removeBlock(_ block: Block) async {
        guard let link = block.link(.delete) else { return }
        saveTasks[block.id]?.cancel()
        saveTasks[block.id] = nil
        do {
            try await app.client.data(for: link, method: "DELETE")
            blocks.removeAll { $0.id == block.id }
            liveText[block.id] = nil
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
        guard !hasActiveEdit, focusedBlockId == nil, saveTasks.isEmpty,
              let base = project.link(.syncStatus) else { return }
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
