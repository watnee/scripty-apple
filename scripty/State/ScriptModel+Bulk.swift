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

    // MARK: - Clipboard

    /// Copying needs no link: it reads elements already on screen and writes
    /// to the device. A reader with no edit rights can still take a copy.
    func copyToClipboard(_ ids: [Int]) {
        let wanted = Set(ids)
        let elements = blocks
            .filter { wanted.contains($0.id) }
            .map { FountainElement(type: $0.blockType, content: currentText($0)) }
        guard !elements.isEmpty else { return }
        ScriptClipboard.copy(elements)
    }

    /// True when a paste is worth offering: the server must allow inserting,
    /// and the pasteboard must hold something.
    ///
    /// Deliberately asks the cheap, non-prompting question. This gates a menu
    /// entry, and iOS prompts for permission whenever the pasteboard is
    /// actually read — so the precise check would make merely opening an
    /// element's menu ask the writer for clipboard access.
    var canPasteElements: Bool {
        blocks.contains { $0.hasLink(.createBelow) } && ScriptClipboard.mayHoldElements
    }

    /// Insert the pasteboard's elements below `block`, keeping their types.
    ///
    /// One request per element, walking down: the server has no bulk create,
    /// and each element has to land after the one before it or the paste comes
    /// out reversed. Deliberately not a `TaskGroup` for that reason — order is
    /// the whole point.
    @discardableResult
    func pasteElements(after block: Block) async -> Int {
        // Read at the moment of pasting, where the permission prompt belongs.
        // Text that turned out not to be a screenplay still pastes — as the
        // one element it is — because the writer asked for a paste and getting
        // nothing at all would read as a bug.
        var elements = ScriptClipboard.elements() ?? []
        if elements.isEmpty, let text = ScriptClipboard.plainText() {
            let detected = FountainDetector.detect(text)
            elements = [FountainElement(type: detected?.type ?? .action,
                                        content: detected?.content ?? text)]
        }
        guard !elements.isEmpty else { return 0 }
        var anchor = block
        var inserted = 0
        for element in elements {
            guard let link = anchor.link(.createBelow) else { break }
            do {
                let created: Block = try await app.client.fetch(
                    from: link, method: "POST",
                    body: CreateBelowCommand(content: element.content,
                                             personId: nil,
                                             type: element.type.rawValue))
                anchor = created
                inserted += 1
            } catch {
                report(error)
                break
            }
        }
        if inserted > 0 {
            await loadBlocks()
            await refreshUndoRedo()
            // Land the caret at the end of what was pasted, which is where a
            // writer carries on from.
            focus(anchor.id, caret: currentText(anchor).count)
            errorMessage = nil
        }
        return inserted
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
