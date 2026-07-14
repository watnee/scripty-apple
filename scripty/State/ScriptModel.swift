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

    /// The block holding the caret. Writing the script is a matter of moving
    /// this from one block to the next, so most editing actions end by setting it.
    var focusedBlockID: Int?

    /// What's currently typed into the focused block, before it's saved. The
    /// element bar reads it so retyping a block carries the in-progress text.
    var draft: String = ""

    /// True while the caret is anywhere in the script; sync refreshes hold off
    /// so a poll can't renumber blocks out from under the writer.
    var isEditing: Bool { hasActiveEdit || focusedBlockID != nil }

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

    // MARK: - Inline writing
    //
    // These four are the whole writing loop: commit what was typed, Return for
    // the next element, Tab to retype this one, Backspace to take an empty one
    // back. Each is gated on the link the server advertised for that block.

    /// Saves what the writer typed, letting Fountain shorthand retype the block
    /// (`INT. BAR - NIGHT` becomes a Scene, `(beat)` a Parenthetical). Returns
    /// the stored block, whose content may differ from `content` — the marker
    /// characters are stripped once the element carries the meaning.
    @discardableResult
    func commit(_ block: Block, content: String) async -> Block? {
        let detected = FountainRules.detect(content)

        // A retype needs the setType endpoint; content alone can go through PUT.
        if let detected, detected.type != block.blockType, block.hasLink(.setType) {
            return await applyType(detected.type, to: block, content: detected.content)
        }
        let resolved = cased(detected.map(\.content) ?? content, for: block.blockType)
        guard resolved != (block.content ?? "") else { return block }
        guard let link = block.link(.update) else { return nil }
        do {
            let updated: Block = try await app.client.fetch(
                from: link, method: "PUT",
                body: EditBlockCommand(content: resolved,
                                       personId: block.personId,
                                       tags: block.tags))
            replace(updated)
            errorMessage = nil
            return updated
        } catch {
            report(error)
            return nil
        }
    }

    /// Return: commit the current block, then open the element that logically
    /// follows it (a cue is followed by dialogue; everything else by action)
    /// and put the caret there.
    func insertBelow(_ block: Block, content: String) async {
        guard let link = block.link(.createBelow) else { return }
        let source = await commit(block, content: content) ?? block
        let next = FountainRules.nextType(after: source.blockType)
        do {
            let created: Block = try await app.client.fetch(
                from: link, method: "POST",
                body: CreateBlockBelowCommand(content: "", personId: nil,
                                              type: next.rawValue))
            insertLocally(created, below: source)
            focusedBlockID = created.id
            await refreshUndoRedo()
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    /// Tab / Shift-Tab / ⌘1–7 / the element bar. Content is carried across
    /// unchanged so retyping a block never loses what's in it.
    func setType(_ block: Block, to type: BlockType, content: String) async {
        guard block.hasLink(.setType) else { return }
        await applyType(type, to: block, content: content)
    }

    /// A heading typed in lower case is still a heading; the page prints it in
    /// caps either way, so that's how it's stored.
    private func cased(_ content: String, for type: BlockType) -> String {
        type.isUppercased ? content.uppercased() : content
    }

    @discardableResult
    private func applyType(_ type: BlockType, to block: Block,
                           content: String) async -> Block? {
        guard let link = block.link(.setType) else { return nil }
        do {
            let updated: Block = try await app.client.fetch(
                from: link, method: "POST",
                body: SetBlockTypeCommand(type: type.rawValue,
                                          content: cased(content, for: type),
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

    /// Backspace at the top of an empty block: take it back and put the caret at
    /// the end of the one above, the way deleting an empty line in a document does.
    /// The first block of a script has nowhere to retreat to, so it stays.
    func deleteEmptyAndFocusPrevious(_ block: Block) async {
        guard block.hasLink(.delete),
              let index = blocks.firstIndex(where: { $0.id == block.id }),
              index > 0 else { return }
        let previous = blocks[index - 1]
        await deleteBlock(block)
        focusedBlockID = previous.id
    }

    /// The server offers createInitial only while the script is empty and we may
    /// write to it, so this doubles as "may this reader start the script".
    var canStartScript: Bool {
        blocksLinks.contains(.createInitial)
    }

    var canAppendBlock: Bool {
        canStartScript || (blocks.last?.hasLink(.createBelow) ?? false)
    }

    /// The toolbar's +: a new element at the end, with the caret in it.
    func appendBlock() async {
        guard let last = blocks.last else {
            await createInitialBlock()
            return
        }
        await insertBelow(last, content: last.content ?? "")
    }

    /// An untouched script has nothing to type into. The server hands out a
    /// createInitial link only while the script is empty.
    func createInitialBlock() async {
        guard let link = blocksLinks[.createInitial] else { return }
        do {
            let created: Block = try await app.client.fetch(from: link, method: "POST")
            blocks.append(created)
            focusedBlockID = created.id
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    /// Mirrors the server's renumbering so the page doesn't have to be refetched
    /// mid-keystroke — a refetch here would drop the caret.
    private func insertLocally(_ block: Block, below source: Block) {
        guard let index = blocks.firstIndex(where: { $0.id == source.id }) else {
            blocks.append(block)
            return
        }
        let newOrder = block.order ?? ((source.order ?? index) + 1)
        for position in blocks.indices where (blocks[position].order ?? 0) >= newOrder {
            blocks[position].order = (blocks[position].order ?? 0) + 1
        }
        blocks.insert(block, at: index + 1)
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
        guard !isEditing, let base = project.link(.syncStatus) else { return }
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
