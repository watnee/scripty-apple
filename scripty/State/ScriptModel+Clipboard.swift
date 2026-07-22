//
//  ScriptModel+Clipboard.swift
//  scripty
//
//  Cut, copy and paste for whole elements.
//
//  The system clipboard already handles the text *inside* an element — that is
//  the text view's job and nothing here touches it. What it cannot do is carry
//  the element itself: copy a scene heading and a cue as plain text and you get
//  two lines of prose back. So a copy puts two representations on the
//  pasteboard, the readable text and the structured payload in
//  `ScriptClipboard`, and a paste prefers the second.
//
//  Text from anywhere else still pastes usefully: if it reads like a
//  screenplay it goes through the Fountain parser and arrives as typed
//  elements, and if it doesn't it arrives as one element, matching the type of
//  the line it was dropped under.
//

import Foundation
import UIKit
import UniformTypeIdentifiers

extension ScriptModel {

    // MARK: - Affordances

    /// Copying is a read, so it needs no link at all — a reader looking at
    /// someone else's script can still take a scene away with them.
    func canCopy(_ block: Block) -> Bool { true }

    /// Cutting is a copy plus a delete, and only the delete needs permission.
    func canCut(_ block: Block) -> Bool { block.hasLink(.delete) }

    /// Whether pasting below `block` could do anything: the server has to offer
    /// somewhere to put the elements, and the pasteboard has to hold something.
    ///
    /// Deliberately asks only whether the pasteboard *has* text rather than
    /// reading it — reading raises the system's paste banner, and a menu that
    /// merely opened would have raised it for nothing.
    func canPaste(below block: Block) -> Bool {
        guard block.hasLink(.createBelow) else { return false }
        let pasteboard = UIPasteboard.general
        return pasteboard.hasStrings
            || pasteboard.contains(pasteboardTypes: [ScriptClipboard.pasteboardType])
    }

    // MARK: - Copy and cut

    func copyBlocks(_ blocks: [Block]) {
        let payload = blocks.map(clipboardBlock)
        guard !payload.isEmpty else { return }

        var item: [String: Any] = [
            UTType.utf8PlainText.identifier: ScriptClipboard.plainText(payload)
        ]
        // A second representation the web editor also writes and reads. Any
        // other app ignores it and takes the text.
        if let data = ScriptClipboard.encode(payload) {
            item[ScriptClipboard.pasteboardType] = data
        }
        UIPasteboard.general.setItems([item])
    }

    /// Copies, then removes — in that order, so a delete that fails leaves the
    /// writer holding their words rather than nothing.
    func cutBlocks(_ blocks: [Block]) async {
        let removable = blocks.filter { $0.hasLink(.delete) }
        guard !removable.isEmpty else { return }
        copyBlocks(blocks)

        if canBulkDelete && removable.count > 1 {
            // One checkpoint, so one press of undo puts the whole cut back.
            await bulkDelete(removable.map(\.id))
        } else {
            for block in removable {
                await deleteBlock(block)
            }
        }
    }

    // MARK: - Paste

    /// Inserts whatever is on the pasteboard below `block`, and returns how
    /// many elements arrived.
    @discardableResult
    func pasteBlocks(below block: Block) async -> Int {
        guard let payload = readPasteboard(fallbackType: block.blockType), !payload.isEmpty else {
            return 0
        }

        // Each element is created below the one before it, so the passage lands
        // in the order it was copied. The server answers with the block it
        // made, which is what carries the link for the next one.
        var anchor = block
        var created = 0
        for item in payload {
            guard let link = anchor.link(.createBelow) else { break }
            do {
                let made: Block = try await app.client.fetch(
                    from: link, method: "POST",
                    body: CreateBelowCommand(content: item.content,
                                             personId: personId(for: item),
                                             type: item.blockType.rawValue))
                anchor = made
                created += 1
            } catch {
                // Stop at the first failure rather than pressing on: the rest
                // of the passage would arrive out of order under a gap.
                report(error)
                break
            }
        }

        if created > 0 {
            await loadBlocks()
            await refreshUndoRedo()
            errorMessage = nil
        }
        return created
    }

    /// Reads the pasteboard, in order of how much it tells us: the structured
    /// payload, then a payload fenced inside plain text, then the text itself.
    private func readPasteboard(fallbackType: BlockType) -> [ClipboardBlock]? {
        let pasteboard = UIPasteboard.general

        if let data = pasteboard.data(forPasteboardType: ScriptClipboard.pasteboardType),
           let blocks = ScriptClipboard.decode(data) {
            return blocks
        }

        guard let raw = pasteboard.string, !raw.isEmpty else { return nil }
        let (text, embedded) = ScriptClipboard.parseEmbedded(raw)
        if let embedded { return embedded }

        // Text from elsewhere. Splitting it is only an improvement when it
        // really is a screenplay — see `looksLikeScreenplay` — and when the
        // parser found more than the single action element that any prose
        // would come back as.
        if FountainDetector.looksLikeScreenplay(text) {
            let parsed = FountainDetector.parseBlocks(text)
            if parsed.count > 1 || (parsed.count == 1 && parsed[0].blockType != .action) {
                return parsed
            }
        }
        return [ClipboardBlock(type: fallbackType, content: text)]
    }

    // MARK: - Conversions

    private func clipboardBlock(_ block: Block) -> ClipboardBlock {
        ClipboardBlock(type: block.blockType,
                       content: block.content ?? "",
                       personId: block.personId,
                       characterName: block.personName ?? "",
                       tags: block.tags ?? "")
    }

    /// The speaker a pasted cue should point at.
    ///
    /// The id on the clipboard belongs to whichever project it was copied from,
    /// so it is only trusted when this project already has that character;
    /// otherwise the name is matched against the cast. A cue with neither still
    /// pastes — it just carries the name as text until someone links it.
    private func personId(for item: ClipboardBlock) -> Int? {
        if let id = Int(item.personId), characters.contains(where: { $0.id == id }) {
            return id
        }
        let name = (item.characterName.isEmpty ? item.content : item.characterName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return characters.first {
            $0.displayName.caseInsensitiveCompare(name) == .orderedSame
        }?.id
    }
}
