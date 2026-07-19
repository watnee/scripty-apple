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
    func commit(_ block: SongBlock) async {
        commitTasks[block.id]?.cancel()
        commitTasks[block.id] = nil
        guard let pending = liveText[block.id], let link = block.link(.update) else { return }
        guard pending != block.text else {
            liveText[block.id] = nil
            return
        }
        do {
            let updated: SongBlock = try await app.client.fetch(
                from: link, method: "PUT", body: EditSongBlockCommand(content: pending))
            liveText[block.id] = nil
            replace(updated)
            errorMessage = nil
        } catch {
            report(error)
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
    @discardableResult
    func appendLine() async -> Int? {
        guard let link = links[.create] else { return nil }
        return await create(from: link)
    }

    /// Adds a line directly below another — what Return does.
    @discardableResult
    func addLine(below block: SongBlock) async -> Int? {
        guard let link = block.link(.createBelow) else { return nil }
        await commit(block)
        return await create(from: link)
    }

    private func create(from link: HALLink) async -> Int? {
        do {
            let created: SongBlock = try await app.client.fetch(
                from: link, method: "POST", body: CreateSongBlockCommand(content: ""))
            await load()
            errorMessage = nil
            return created.id
        } catch {
            report(error)
            return nil
        }
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
        guard let link = block.link(.move), let index = index(of: block) else { return }
        let target = index + offset
        guard blocks.indices.contains(target) else { return }
        await commitAll()
        do {
            // Positions are absolute and 1-based, as the collection reports.
            let _: HALCollection<SongBlock> = try await app.client.fetch(
                from: link, method: "POST", body: MoveSongBlockCommand(position: target + 1))
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
        } catch {
            report(error)
        }
    }

    // MARK: - Plumbing

    private func index(of block: SongBlock) -> Int? {
        blocks.firstIndex { $0.id == block.id }
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
