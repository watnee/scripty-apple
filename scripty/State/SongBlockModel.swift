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

    /// Set while a line is being typed into, so a refresh does not clobber it.
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
            Task { await load() }
        }
    }

    private var commitTasks: [Int: Task<Void, Never>] = [:]
    private static let commitDebounce: Duration = .milliseconds(600)

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

    var canUndo: Bool { undoRedo?.canUndo ?? false }
    var canRedo: Bool { undoRedo?.canRedo ?? false }
    var hasUndoStack: Bool { links.contains(.undoRedoStatus) }

    init(app: AppModel, document: TextDocument) {
        self.app = app
        self.document = document
    }

    // MARK: - Loading

    func load() async {
        guard let link = editionBlocksLink ?? document.link(.songBlocks) else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let collection: HALCollection<SongBlock> = try await app.client.fetch(from: link)
            adopt(collection)
            errorMessage = nil
        } catch {
            report(error)
        }
        // After adopt, so the status link this round advertised is the one used.
        await refreshUndoRedo()
    }

    private func adopt(_ collection: HALCollection<SongBlock>) {
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
        commitTasks[block.id]?.cancel()
        commitTasks[block.id] = Task { [weak self] in
            try? await Task.sleep(for: Self.commitDebounce)
            guard !Task.isCancelled else { return }
            await self?.commit(block)
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
        guard let pending = liveText[block.id], let link = block.link(.update) else { return true }
        guard pending != block.text else {
            liveText[block.id] = nil
            return true
        }
        do {
            let updated: SongBlock = try await app.client.fetch(
                from: link, method: "PUT", body: EditSongBlockCommand(content: pending))
            liveText[block.id] = nil
            replace(updated)
            errorMessage = nil
            // The edit left a checkpoint behind it, so there is now somewhere
            // to step back to even though the list did not reload.
            await refreshUndoRedo()
            return true
        } catch {
            report(error)
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
        return await create(from: link)
    }

    private func create(from link: HALLink, content: String = "") async -> Int? {
        do {
            let created: SongBlock = try await app.client.fetch(
                from: link, method: "POST", body: CreateSongBlockCommand(content: content))
            await load()
            errorMessage = nil
            focusRequest = created.id
            return created.id
        } catch {
            report(error)
            return nil
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
            liveText[previous.id] = restore
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

    @discardableResult
    func delete(_ block: SongBlock) async -> Bool {
        guard let link = block.link(.delete) else { return false }
        commitTasks[block.id]?.cancel()
        liveText[block.id] = nil
        do {
            let _: HALCollection<SongBlock> = try await app.client.fetch(from: link, method: "DELETE")
            await load()
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    func canMoveUp(_ block: SongBlock) -> Bool {
        guard block.hasLink(.move), let index = index(of: block) else { return false }
        return index > 0
    }

    func canMoveDown(_ block: SongBlock) -> Bool {
        guard block.hasLink(.move), let index = index(of: block) else { return false }
        return index + 1 < blocks.count
    }

    func move(_ block: SongBlock, by offset: Int) async {
        guard let index = index(of: block) else { return }
        await move(block, to: index + offset)
    }

    /// Puts a line at an absolute index in the lyric — what a drag lands on,
    /// where the menu's Move Up and Move Down are the same journey a step at a
    /// time. Out-of-range targets are dropped rather than clamped: a drop past
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

    func undo() async { await step(.undo) }
    func redo() async { await step(.redo) }

    private func step(_ rel: Rel) async {
        guard let link = undoRedo?.link(rel) else { return }
        // A half-typed line would be undone out from under itself otherwise —
        // the checkpoint it belongs to has not been recorded yet.
        await commitAll()
        do {
            let collection: HALCollection<SongBlock> = try await app.client.fetch(
                from: link, method: "POST")
            adopt(collection)
            await refreshUndoRedo()
            errorMessage = nil
        } catch {
            report(error)
        }
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
        app.handle(error)
        errorMessage = error.localizedDescription
    }
}
