//
//  BlockReorderDrag.swift
//  scripty
//
//  Drag one script element onto another to move it there — the touch
//  equivalent of dragging a row in the web editor.
//
//  Reordering is offered in selection mode rather than while typing. The
//  editing rows are live text views, where a long press has to mean "select
//  text"; selection mode already renders every row read-only, so a long press
//  there is free to mean "pick this up". Move Up and Move Down stay in the
//  editing row's context menu for nudging a single element.
//
//  The move itself is the server's: dropping posts to the element's `move`
//  link and reloads, because the server renumbers the rest of the script.
//

import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Declared in Info.plist. A private type rather than plain text so that
    /// text dragged in from another app can't be mistaken for an element.
    static let scriptyBlock = UTType(exportedAs: "scripty.scripty.block")
}

/// What actually crosses the drag session: just the id. The block itself is
/// re-read from the model on drop, so a drag held while a sync lands moves the
/// element as it now is rather than as it was when picked up.
struct BlockDragPayload: Codable, Transferable {
    let blockId: Int

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .scriptyBlock)
    }
}

private struct BlockReorderModifier: ViewModifier {
    let model: ScriptModel
    let block: Block

    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) { insertionLine }
            .dropDestination(for: BlockDragPayload.self) { payloads, _ in
                guard let dropped = payloads.first,
                      let source = model.blocks.first(where: { $0.id == dropped.blockId })
                else { return false }
                Task { await model.moveBlock(source, before: block) }
                return true
            } isTargeted: { targeted in
                isTargeted = targeted
            }
            .draggable(BlockDragPayload(blockId: block.id))
    }

    /// Where the element will land. Drawn at the top edge because a drop puts
    /// the dragged element *at* this row's position, pushing this one down.
    @ViewBuilder
    private var insertionLine: some View {
        if isTargeted {
            Rectangle()
                .fill(.tint)
                .frame(height: 2)
                .transition(.opacity)
        }
    }
}

extension View {
    /// Makes the row a drag source and a drop target for reordering, but only
    /// when the server advertised a `move` link for it — a read-only script,
    /// or a locked element, stays put.
    @ViewBuilder
    func blockReorderDrag(_ block: Block, in model: ScriptModel) -> some View {
        if block.hasLink(.move) {
            modifier(BlockReorderModifier(model: model, block: block))
        } else {
            self
        }
    }
}
