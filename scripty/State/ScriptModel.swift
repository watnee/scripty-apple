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
    private(set) var documents: [TextDocument] = []
    private(set) var documentsLinks = HALLinks()
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

    private var commitTasks: [Int: Task<Void, Never>] = [:]
    private static let commitDebounce: Duration = .milliseconds(600)

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
        scheduleCommit(block.id)
    }

    /// Focus left this block — flush any pending text and stop treating its live
    /// value as authoritative.
    func blur(_ block: Block) async {
        await commit(block.id)
        if focusedBlockId == block.id { focusedBlockId = nil }
        liveText[block.id] = nil
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
        guard text != (block.content ?? ""), let link = block.link(.update) else { return block }
        do {
            let updated: Block = try await app.client.fetch(
                from: link, method: "PUT",
                body: EditBlockCommand(content: text, personId: block.personId, tags: block.tags))
            replace(updated)
            await refreshUndoRedo()
            errorMessage = nil
            return updated
        } catch {
            report(error)
            return nil
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
        liveText[block.id] = before
        let source: Block
        if currentType != block.blockType {
            source = await retype(block, to: currentType, content: before) ?? block
        } else {
            source = await commit(block.id) ?? block
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

    /// Backspace at offset 0: merge this block into the previous editable one
    /// and place the caret at the seam.
    func mergeIntoPrevious(_ block: Block) async {
        guard let index = blocks.firstIndex(where: { $0.id == block.id }), index > 0,
              let previous = blocks[..<index].last(where: { $0.hasLink(.update) }) else { return }
        let seam = currentText(previous).count
        let merged = currentText(previous) + currentText(block)

        liveText[previous.id] = merged
        let updatedPrevious = await commit(previous.id) ?? previous
        liveText[previous.id] = nil   // model value is now authoritative for the merged row

        if let deleteLink = block.link(.delete) {
            do {
                try await app.client.data(for: deleteLink, method: "DELETE")
            } catch {
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
            replace(updated)
            liveText[block.id] = nil
            await refreshUndoRedo()
            errorMessage = nil
            return updated
        } catch {
            report(error)
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
