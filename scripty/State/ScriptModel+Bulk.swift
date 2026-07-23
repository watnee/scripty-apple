//
//  ScriptModel+Bulk.swift
//  scripty
//
//  Operations over a set of elements: retype, tag, delete, format, and find &
//  replace. Each is one request that lands as one undo checkpoint, which is
//  the whole reason these are endpoints rather than a loop — a writer who
//  retypes twenty elements expects one press of undo to put them back.
//
//  Every one is gated on a link the block *collection* advertises, since these
//  act on a set rather than on any single block. A server that doesn't offer
//  them renders no controls.
//

import Foundation

extension ScriptModel {

    // MARK: - Affordances

    var canBulkRetype: Bool { blocksLinks.contains(.bulkSetType) }
    var canBulkTag: Bool { blocksLinks.contains(.bulkAddTags) }
    var canBulkFormat: Bool { blocksLinks.contains(.bulkFormat) }
    var canBulkDelete: Bool { blocksLinks.contains(.bulkDelete) }
    var canReplace: Bool { blocksLinks.contains(.bulkReplace) }

    /// True when the server offers any bulk action, i.e. when entering
    /// selection mode could lead anywhere.
    var canSelectBlocks: Bool {
        canBulkRetype || canBulkTag || canBulkFormat || canBulkDelete
    }

    // MARK: - Operations

    @discardableResult
    func bulkRetype(_ ids: [Int], to type: BlockType) async -> Bool {
        await perform(.bulkSetType, ids: ids) { projectId in
            BulkSetTypeCommand(ids: ids, projectId: projectId, type: type.rawValue)
        }
    }

    @discardableResult
    func bulkAddTags(_ ids: [Int], tags: String) async -> Bool {
        let trimmed = tags.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return await perform(.bulkAddTags, ids: ids) { projectId in
            BulkAddTagsCommand(ids: ids, projectId: projectId, tags: trimmed)
        }
    }

    @discardableResult
    func bulkDelete(_ ids: [Int]) async -> Bool {
        await perform(.bulkDelete, ids: ids) { projectId in
            BulkDeleteCommand(ids: ids, projectId: projectId)
        }
    }

    @discardableResult
    func bulkSetAlign(_ ids: [Int], align: TextAlign) async -> Bool {
        await perform(.bulkFormat, ids: ids) { projectId in
            BulkFormatCommand(ids: ids, projectId: projectId, align: align.rawValue)
        }
    }

    @discardableResult
    func bulkSetFont(_ ids: [Int], font: ScriptFont) async -> Bool {
        await perform(.bulkFormat, ids: ids) { projectId in
            BulkFormatCommand(ids: ids, projectId: projectId, font: font.rawValue)
        }
    }

    /// Flips the style on each block independently, so a mixed selection comes
    /// back inverted rather than uniform — the web behaviour, kept on purpose.
    @discardableResult
    func bulkToggleStyle(_ ids: [Int], style: BlockTextStyle) async -> Bool {
        await perform(.bulkFormat, ids: ids) { projectId in
            BulkFormatCommand(ids: ids, projectId: projectId, style: style.rawValue)
        }
    }

    /// A nil `highlight` clears the tint. Because an omitted field means
    /// "leave alone", clearing has to say so explicitly.
    @discardableResult
    func bulkSetHighlight(_ ids: [Int], highlight: BlockHighlight?) async -> Bool {
        await perform(.bulkFormat, ids: ids) { projectId in
            BulkFormatCommand(ids: ids, projectId: projectId,
                              highlight: highlight?.rawValue,
                              clearHighlight: highlight == nil ? true : nil)
        }
    }

    /// Replaces every match across `ids`. Returns how many elements actually
    /// changed, worked out by comparing what came back with what we held —
    /// the server answers with the collection, not a count.
    func bulkReplace(_ ids: [Int],
                     find: String,
                     replace: String,
                     matchCase: Bool,
                     wholeWord: Bool,
                     includeCharacterCues: Bool) async -> Int? {
        guard !find.isEmpty else { return nil }
        let before = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0.content ?? "") })

        let succeeded = await perform(.bulkReplace, ids: ids) { projectId in
            BulkReplaceCommand(ids: ids,
                               projectId: projectId,
                               find: find,
                               replace: replace,
                               matchCase: matchCase,
                               wholeWord: wholeWord,
                               includeCharacterCues: includeCharacterCues)
        }
        guard succeeded else { return nil }

        return blocks.reduce(into: 0) { total, block in
            if let old = before[block.id], old != (block.content ?? "") { total += 1 }
        }
    }

    /// Replaces a single occurrence in one block — the "Replace" that steps
    /// through a find, as against "Replace All". Answers with the one block the
    /// server rewrote, so unlike the bulk calls it patches that block in place
    /// rather than adopting the whole collection.
    ///
    /// Always the first occurrence: the client navigates block by block, so the
    /// current match *is* the block, and its first remaining occurrence is the
    /// one to take next. Pressing Replace again lands on the next. The web sends
    /// the highlighted occurrence's index instead, because it highlights each
    /// one separately; the result of repeated presses is the same.
    @discardableResult
    func replaceOne(_ block: Block,
                    find: String,
                    replace: String,
                    matchCase: Bool,
                    wholeWord: Bool) async -> Bool {
        let needle = find.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, let link = block.link(.replace) else { return false }
        do {
            let updated: Block = try await app.client.fetch(
                from: link, method: "POST",
                body: ReplaceOneCommand(find: needle, replace: replace,
                                        matchCase: matchCase, wholeWord: wholeWord,
                                        occurrence: 0))
            adoptRewritten(updated)
            await refreshUndoRedo()
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    // MARK: - Shared plumbing

    /// Posts a bulk command and adopts the collection the server returns.
    ///
    /// Bulk endpoints answer with the whole refreshed collection rather than a
    /// single resource, so the result replaces `blocks` outright — a bulk
    /// retype or delete renumbers and removes things, and patching that
    /// locally would be guesswork.
    private func perform(_ rel: Rel,
                         ids: [Int],
                         command: (Int) -> any Encodable) async -> Bool {
        guard let link = blocksLinks[rel], !ids.isEmpty else { return false }
        do {
            let collection: HALCollection<Block> = try await app.client.fetch(
                from: link, method: "POST", body: command(project.id))
            adopt(collection)
            await refreshUndoRedo()
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }
}
