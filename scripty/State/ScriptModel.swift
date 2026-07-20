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
    /// One-shot text replacements the text views apply and clear.
    ///
    /// `liveText` means "the view is authoritative, leave it alone", which is
    /// right for typing and wrong for anything that rewrites the field out
    /// from under the writer. Accepting a completion does exactly that, so it
    /// needs a way to say "and this time, take the model's word for it".
    var textRequests: [Int: String] = [:]

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

    /// Words in the screenplay right now.
    ///
    /// Runs the same `ScriptStats` the report runs rather than counting
    /// separately, so the running total and Script Stats cannot disagree —
    /// which element types count toward the total is a real rule (cues do not,
    /// lyrics do) and having it written down twice would be having it written
    /// down wrong. The blocks are handed over carrying their *live* text, so
    /// the number moves as the writer types instead of lurching when the
    /// debounced save lands.
    var liveWordCount: Int {
        let live = blocks.map { block -> Block in
            var copy = block
            copy.content = currentText(block)
            return copy
        }
        return ScriptStats(blocks: live).totalWords
    }

    // MARK: - Autocomplete

    /// Completions for whatever holds the caret. Empty unless a block is
    /// focused, since there is nothing to complete into otherwise.
    var suggestions: [ScriptAutocomplete.Suggestion] {
        guard let id = focusedBlockId,
              let block = blocks.first(where: { $0.id == id }),
              block.hasLink(.update)
        else { return [] }
        return ScriptAutocomplete.suggestions(for: currentText(block),
                                              type: block.blockType,
                                              blocks: blocks,
                                              characters: characters)
    }

    /// Accept a completion: the element becomes the suggestion's replacement
    /// line and the caret lands at the end of it, ready to keep typing.
    ///
    /// Goes through `liveEdit` rather than straight to the server so the text
    /// view picks the new text up the same way it picks up typing, and the
    /// existing debounce does the saving. Accepting a completion is not a
    /// different kind of edit from making it by hand.
    func accept(_ suggestion: ScriptAutocomplete.Suggestion) {
        guard let id = focusedBlockId,
              blocks.contains(where: { $0.id == id }) else { return }
        // Only a request. The text view applies it and then reports it back
        // through `liveEdit`, exactly as if it had been typed — so there is
        // one source of truth for the field's text at every moment, and the
        // existing debounce does the saving.
        textRequests[id] = suggestion.replacement
        caretRequests[id] = suggestion.replacement.count
    }

    // MARK: - Duplicating

    /// True when this element can be copied below itself.
    ///
    /// Gated on `createBelow` rather than on a `duplicate` rel: the server
    /// advertises duplicate for documents but not for elements, and a copy is
    /// exactly a create-below carrying the original's text and type. Asking
    /// the server for a rel it has no reason to add would leave the affordance
    /// permanently out of reach.
    func canDuplicate(_ block: Block) -> Bool { block.hasLink(.createBelow) }

    /// Insert a copy of `block` directly beneath it and focus the copy — the
    /// writer duplicated it to change something, so the caret goes to the copy
    /// rather than leaving them to find it.
    func duplicateBlock(_ block: Block) async {
        guard let link = block.link(.createBelow) else { return }
        do {
            let created: Block = try await app.client.fetch(
                from: link, method: "POST",
                body: CreateBelowCommand(content: currentText(block),
                                         personId: block.personId,
                                         type: block.blockType.rawValue))
            await loadBlocks()
            await refreshUndoRedo()
            focus(created.id, caret: 0)
            errorMessage = nil
        } catch {
            report(error)
        }
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

        /// Whether the format has pages at all. Fountain and Final Draft are
        /// unpaginated text — paper size and margins mean nothing to them, so
        /// they take the link exactly as advertised.
        var isPaged: Bool { rel == .exportPdf }
    }

    /// Every export the server offered, in menu order.
    ///
    /// The archive is deliberately last and named for what it is for rather
    /// than for its format: it is the only entry here that is not a copy of
    /// the screenplay to send someone, and a writer looking for "Word" should
    /// not have to read past a `.scripty.json` to find it.
    var exportOptions: [ExportOption] {
        let all: [(Rel, String, String)] = [
            (.exportPdf, "PDF", "pdf"),
            (.export, "Fountain", "fountain"),
            (.exportDocx, "Word", "docx"),
            (.exportFdx, "Final Draft", "fdx"),
            (.exportEpub, "EPUB", "epub"),
            (.exportArchive, "Project Archive", "scripty.json"),
        ]
        return all.compactMap { rel, label, ext in
            project.link(rel).map { ExportOption(rel: rel, label: label, fileExtension: ext, link: $0) }
        }
    }

    /// The formats this song can be taken away in.
    ///
    /// Advertised on the document rather than the project, and outside the
    /// server's edit gate, so a view-only collaborator still gets the menu.
    func songExportOptions(for document: TextDocument) -> [ExportOption] {
        let all: [(Rel, String, String)] = [
            (.exportSongPdf, "PDF", "pdf"),
            (.exportSongTxt, "Text", "txt"),
            (.exportSongDocx, "Word", "docx"),
            (.exportSongEpub, "EPUB", "epub"),
        ]
        return all.compactMap { rel, label, ext in
            document.link(rel).map { ExportOption(rel: rel, label: label, fileExtension: ext, link: $0) }
        }
    }

    /// The PDF export, when the server offers one — what Print renders from.
    var printOption: ExportOption? {
        exportOptions.first { $0.rel == .exportPdf }
    }

    /// Downloads an export with auth and writes it to a shareable temp file.
    ///
    /// A paged export carries the writer's own page setup, so the PDF matches
    /// the sheets they were just looking at in page view rather than falling
    /// back to the server's defaults. Page setup is a device preference, so it
    /// is read from the shared presentation settings at the moment of export.
    ///
    /// `named` is what the file is called before its extension — the project
    /// title for a screenplay, the song's title for a song. A song exported
    /// under the screenplay's name is indistinguishable from the screenplay
    /// once it is sitting in Files.
    func export(_ option: ExportOption, named: String? = nil) async throws -> URL {
        let link = option.isPaged
            ? option.link.addingQuery(PresentationSettings.shared.pageSetup.exportQuery)
            : option.link
        let data = try await app.client.data(for: link)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.fileName(named ?? project.displayTitle,
                                                  fallback: "script",
                                                  extension: option.fileExtension))
        try data.write(to: url, options: .atomic)
        return url
    }

    /// A title turned into something a file system will accept.
    private static func fileName(_ title: String, fallback: String, extension ext: String) -> String {
        let safe = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (safe.isEmpty ? fallback : safe) + "." + ext
    }
}
