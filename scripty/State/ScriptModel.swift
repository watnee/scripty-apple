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
    private(set) var undoRedo: UndoRedoStatus?
    private(set) var isLoading = false
    var errorMessage: String?

    /// Set while an editor sheet is open so a sync refresh doesn't clobber
    /// in-progress typing.
    var hasActiveEdit = false

    // MARK: - Inline editing state

    /// The block that currently holds the keyboard, if any. Sync polling
    /// pauses while a block is focused so a background refresh never yanks
    /// text out from under the caret.
    private(set) var focusedBlockId: Int?

    /// Uncommitted text keyed by block id. A row renders `liveText[id]` in
    /// preference to the last-loaded `content`, so typing is never lost to a
    /// slow save or a concurrent reload.
    private(set) var liveText: [Int: String] = [:]

    /// A one-shot request to move a block's caret (used after a split or merge
    /// creates/relocates the caret). Carries a token so the same
    /// block+offset can be requested twice in a row and still fire.
    struct CaretRequest: Equatable {
        var blockId: Int
        var offset: Int
        var token: Int
    }
    private(set) var caretRequest: CaretRequest?
    private var caretToken = 0

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

    /// The text a row should display: uncommitted keystrokes if any, else the
    /// last value loaded from the server.
    func displayText(for block: Block) -> String {
        liveText[block.id] ?? block.content ?? ""
    }

    func beginEditing(_ blockId: Int) {
        focusedBlockId = blockId
    }

    /// Called when a block gives up the keyboard: stop treating it as focused
    /// and flush any pending save immediately so nothing is lost.
    func endEditing(_ blockId: Int) {
        if focusedBlockId == blockId { focusedBlockId = nil }
        flushSave(blockId)
    }

    /// Records a keystroke and schedules a debounced save.
    func edit(_ blockId: Int, text: String) {
        liveText[blockId] = text
        scheduleSave(blockId)
    }

    func requestFocus(blockId: Int, caret offset: Int) {
        caretToken += 1
        caretRequest = CaretRequest(blockId: blockId, offset: offset, token: caretToken)
        focusedBlockId = blockId
    }

    /// A row applies its caret request, then calls this to clear it so it
    /// doesn't reapply on the next render.
    func consumeCaretRequest(_ token: Int) {
        if caretRequest?.token == token { caretRequest = nil }
    }

    private func scheduleSave(_ blockId: Int) {
        saveTasks[blockId]?.cancel()
        saveTasks[blockId] = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDebounce)
            guard !Task.isCancelled else { return }
            await self?.commitLiveText(blockId)
        }
    }

    private func flushSave(_ blockId: Int) {
        saveTasks[blockId]?.cancel()
        saveTasks[blockId] = nil
        Task { await commitLiveText(blockId) }
    }

    /// PUTs a block's uncommitted text. No-ops when nothing changed. Leaves
    /// `liveText` in place if the user kept typing while the request was in
    /// flight, so the newest keystrokes still win.
    private func commitLiveText(_ blockId: Int) async {
        guard let text = liveText[blockId],
              let block = blocks.first(where: { $0.id == blockId }),
              let link = block.link(.update) else { return }
        if (block.content ?? "") == text {
            liveText[blockId] = nil
            return
        }
        do {
            let updated: Block = try await app.client.fetch(
                from: link, method: "PUT",
                body: EditBlockCommand(content: text, personId: block.personId, tags: block.tags))
            if liveText[blockId] == text { liveText[blockId] = nil }
            replace(updated)
            await refreshUndoRedo()
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    /// Return in the middle of a block: the text before the caret stays, the
    /// text after it moves into a new element below whose type follows the web
    /// editor's rules (cue → dialogue, otherwise action).
    func splitBlock(_ blockId: Int, caret: Int) async {
        guard let block = blocks.first(where: { $0.id == blockId }),
              let belowLink = block.link(.createBelow) else { return }
        let full = liveText[blockId] ?? block.content ?? ""
        let clampedCaret = max(0, min(caret, full.count))
        let splitIndex = full.index(full.startIndex, offsetBy: clampedCaret)
        let head = String(full[..<splitIndex])
        let tail = String(full[splitIndex...])
        let newType = block.blockType.followingType
        let carryPerson = block.blockType.isCharacterCue ? block.personId : nil

        saveTasks[blockId]?.cancel()
        saveTasks[blockId] = nil
        do {
            // Commit the head to the anchor block first so the split is clean.
            if (block.content ?? "") != head, let update = block.link(.update) {
                let updated: Block = try await app.client.fetch(
                    from: update, method: "PUT",
                    body: EditBlockCommand(content: head, personId: block.personId, tags: block.tags))
                replace(updated)
            }
            liveText[blockId] = nil
            let created: Block = try await app.client.fetch(
                from: belowLink, method: "POST",
                body: CreateBelowCommand(content: tail, personId: carryPerson, type: newType.rawValue))
            await loadBlocks()
            requestFocus(blockId: created.id, caret: 0)
            await refreshUndoRedo()
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    /// Backspace at the very start of a block merges it into the previous
    /// editable element, leaving the caret at the seam.
    func mergeIntoPrevious(_ blockId: Int) async {
        guard let idx = blocks.firstIndex(where: { $0.id == blockId }),
              let prevIdx = previousEditableIndex(before: idx) else { return }
        let current = blocks[idx]
        let prev = blocks[prevIdx]
        guard let prevUpdate = prev.link(.update),
              let curDelete = current.link(.delete) else { return }
        let prevText = liveText[prev.id] ?? prev.content ?? ""
        let curText = liveText[blockId] ?? current.content ?? ""
        let boundary = prevText.count

        saveTasks[blockId]?.cancel(); saveTasks[blockId] = nil
        saveTasks[prev.id]?.cancel(); saveTasks[prev.id] = nil
        do {
            let updated: Block = try await app.client.fetch(
                from: prevUpdate, method: "PUT",
                body: EditBlockCommand(content: prevText + curText,
                                       personId: prev.personId, tags: prev.tags))
            try await app.client.data(for: curDelete, method: "DELETE")
            liveText[blockId] = nil
            liveText[prev.id] = nil
            replace(updated)
            blocks.removeAll { $0.id == blockId }
            requestFocus(blockId: prev.id, caret: boundary)
            await refreshUndoRedo()
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    /// Retypes a block in place (Tab or the element-type bar), keeping its text
    /// and keeping the keyboard where it is.
    func retype(_ blockId: Int, to type: BlockType) async {
        guard let block = blocks.first(where: { $0.id == blockId }),
              let link = block.link(.setType) else { return }
        let content = liveText[blockId] ?? block.content
        do {
            let updated: Block = try await app.client.fetch(
                from: link, method: "POST",
                body: SetTypeCommand(type: type.rawValue, content: content,
                                     personId: block.personId, tags: block.tags))
            liveText[blockId] = nil
            replace(updated)
            await refreshUndoRedo()
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    func cycleType(_ blockId: Int, backward: Bool) async {
        guard let block = blocks.first(where: { $0.id == blockId }) else { return }
        await retype(blockId, to: block.blockType.cycled(backward: backward))
    }

    /// Adds an element to the end of the script (or seeds the very first one
    /// for an empty script) and drops the caret into it.
    func appendBlock() async {
        if blocks.isEmpty {
            await seedInitialBlock()
            return
        }
        guard let last = blocks.last, let belowLink = last.link(.createBelow) else { return }
        do {
            let created: Block = try await app.client.fetch(
                from: belowLink, method: "POST",
                body: CreateBelowCommand(content: "", personId: nil, type: BlockType.action.rawValue))
            await loadBlocks()
            requestFocus(blockId: created.id, caret: 0)
            await refreshUndoRedo()
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    /// The first element an untouched script needs before there is anything to
    /// type into. The `createInitial` link is advertised only on an empty,
    /// editable block collection.
    func seedInitialBlock() async {
        guard let link = blocksLinks[.createInitial] else { return }
        do {
            let created: Block = try await app.client.fetch(from: link, method: "POST")
            await loadBlocks()
            requestFocus(blockId: created.id, caret: 0)
            await refreshUndoRedo()
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    /// True when the empty-script placeholder should offer to seed a first
    /// element (i.e. the server says this user may write).
    var canSeedInitial: Bool {
        blocksLinks.contains(.createInitial)
    }

    private func previousEditableIndex(before idx: Int) -> Int? {
        guard idx > 0 else { return nil }
        for i in stride(from: idx - 1, through: 0, by: -1) where blocks[i].isEditable {
            return i
        }
        return nil
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
        // Never reload while the user holds the keyboard or a sheet is open —
        // a background refresh would clobber in-progress typing.
        guard focusedBlockId == nil, liveText.isEmpty, !hasActiveEdit,
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
