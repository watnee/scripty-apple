//
//  ScriptModel+Formatting.swift
//  scripty
//
//  Reordering and character formatting for screenplay elements — the two
//  affordances the web editor puts beside the element-type bar. Both are
//  gated on the links the server advertises (`move`, `update`); a server
//  that doesn't offer them simply renders no controls.
//
//  Formatting rides on `EditBlockCommand`, whose formatting fields are all
//  optional: nil means "leave unchanged". So a formatting change sends the
//  block's current text plus only the field being changed, and the debounced
//  content auto-save in ScriptModel sends only content — the two never
//  clobber each other.
//

import Foundation

extension ScriptModel {

    // MARK: - Reordering

    /// The block immediately above `block` in document order, if any.
    func blockAbove(_ block: Block) -> Block? {
        guard let index = blocks.firstIndex(where: { $0.id == block.id }), index > 0 else { return nil }
        return blocks[index - 1]
    }

    /// The block immediately below `block` in document order, if any.
    func blockBelow(_ block: Block) -> Block? {
        guard let index = blocks.firstIndex(where: { $0.id == block.id }),
              index + 1 < blocks.count else { return nil }
        return blocks[index + 1]
    }

    /// True when the server offers `move` *and* there is somewhere to go.
    func canMoveUp(_ block: Block) -> Bool {
        block.hasLink(.move) && blockAbove(block)?.order != nil
    }

    func canMoveDown(_ block: Block) -> Bool {
        block.hasLink(.move) && blockBelow(block)?.order != nil
    }

    /// Move `block` to the absolute `order` value `position`. The server
    /// renumbers the rest of the script, so the collection is reloaded rather
    /// than patched locally.
    ///
    /// The response body is deliberately not decoded. Moving renumbers every
    /// element, so the server answers with the whole refreshed collection —
    /// decoding that as a single `Block` threw before the reload below could
    /// run, and every move failed with "the data couldn't be read". Since the
    /// reload is what this method relies on either way, reading the body only
    /// ever created a way to fail.
    func moveBlock(_ block: Block, to position: Int) async {
        guard let link = block.link(.move) else { return }
        do {
            try await app.client.data(
                for: link, method: "POST", body: MoveBlockCommand(position: position))
            await loadBlocks()
            await refreshUndoRedo()
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    /// Swap `block` with the element above it.
    func moveBlockUp(_ block: Block) async {
        guard let target = blockAbove(block), let position = target.order else { return }
        await moveBlock(block, to: position)
    }

    /// Swap `block` with the element below it.
    func moveBlockDown(_ block: Block) async {
        guard let target = blockBelow(block), let position = target.order else { return }
        await moveBlock(block, to: position)
    }

    /// Drop `source` at the row `destination` currently occupies — the shape a
    /// drag-and-drop or `.onMove` handler wants.
    func moveBlock(_ source: Block, before destination: Block) async {
        guard source.id != destination.id, let position = destination.order else { return }
        await moveBlock(source, to: position)
    }

    // MARK: - Formatting

    func setAlign(_ block: Block, to align: TextAlign) async {
        var optimistic = block
        optimistic.textAlign = align.rawValue
        await applyFormatting(block, optimistic: optimistic, textAlign: align.rawValue)
    }

    func setFont(_ block: Block, to font: ScriptFont) async {
        var optimistic = block
        optimistic.font = font.rawValue
        await applyFormatting(block, optimistic: optimistic, font: font.rawValue)
    }

    func toggleBold(_ block: Block) async {
        let value = !(block.textBold ?? false)
        var optimistic = block
        optimistic.textBold = value
        await applyFormatting(block, optimistic: optimistic, textBold: value)
    }

    func toggleItalic(_ block: Block) async {
        let value = !(block.textItalic ?? false)
        var optimistic = block
        optimistic.textItalic = value
        await applyFormatting(block, optimistic: optimistic, textItalic: value)
    }

    func toggleUnderline(_ block: Block) async {
        let value = !(block.textUnderline ?? false)
        var optimistic = block
        optimistic.textUnderline = value
        await applyFormatting(block, optimistic: optimistic, textUnderline: value)
    }

    /// Shows the row in its new state immediately, then PUTs the change.
    /// `content` is the *live* text so a formatting tap mid-sentence doesn't
    /// roll typing back; every formatting field the caller leaves nil is
    /// omitted from the JSON and so is untouched on the server.
    private func applyFormatting(_ block: Block,
                                 optimistic: Block,
                                 textAlign: String? = nil,
                                 font: String? = nil,
                                 textBold: Bool? = nil,
                                 textItalic: Bool? = nil,
                                 textUnderline: Bool? = nil) async {
        guard let link = block.link(.update) else { return }
        replace(optimistic)
        do {
            let updated: Block = try await app.client.fetch(
                from: link, method: "PUT",
                body: EditBlockCommand(content: currentText(block),
                                       personId: block.personId,
                                       tags: block.tags,
                                       textAlign: textAlign,
                                       font: font,
                                       textBold: textBold,
                                       textItalic: textItalic,
                                       textUnderline: textUnderline))
            replace(updated)
            await refreshUndoRedo()
            errorMessage = nil
        } catch {
            replace(block)   // roll the optimistic change back
            report(error)
        }
    }
}

// MARK: - Tolerant decoding of the server's formatting strings

extension TextAlign {
    /// The server has used both `left` and `LEFT` over the years; accept either.
    init?(serverValue: String?) {
        guard let serverValue, !serverValue.isEmpty else { return nil }
        self.init(rawValue: serverValue.lowercased())
    }
}

extension ScriptFont {
    /// Accepts either the display name (`Times New Roman`) or the enum-style
    /// name (`TIMES_NEW_ROMAN`) the server may report.
    init?(serverValue: String?) {
        guard let serverValue, !serverValue.isEmpty else { return nil }
        if let exact = ScriptFont(rawValue: serverValue) {
            self = exact
            return
        }
        let key = serverValue.uppercased().replacingOccurrences(of: " ", with: "_")
        switch key {
        case "ARIAL": self = .arial
        case "TIMES_NEW_ROMAN", "TIMES": self = .timesNewRoman
        case "COURIER_PRIME", "COURIER", "COURIER_NEW": self = .courierPrime
        default: return nil
        }
    }
}
