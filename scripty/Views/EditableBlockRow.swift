//
//  EditableBlockRow.swift
//  scripty
//
//  One editable screenplay element inside the inline editor: the block's text
//  field laid out in the same page column the read-only renderer uses, with
//  pin/bookmark badges and a context menu for the affordances that don't fit
//  the keyboard flow (tags, character, pin, bookmark, delete).
//

import SwiftUI

struct EditableBlockRow: View {
    let model: ScriptModel
    let block: Block
    /// Opens the details sheet (tags / character / flags) for this block.
    let onOpenDetails: () -> Void

    private static let pageWidth: CGFloat = 640
    private static let dialogueWidth: CGFloat = 400
    private static let parentheticalWidth: CGFloat = 320

    var body: some View {
        editor
            .frame(maxWidth: columnWidth, alignment: .leading)
            .frame(maxWidth: Self.pageWidth, alignment: isNarrowColumn ? .center : .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, topPadding)
            .overlay(alignment: .topTrailing) { badges }
            .contentShape(Rectangle())
            .contextMenu { menu }
    }

    private var editor: some View {
        BlockTextView(
            blockType: block.blockType,
            text: model.text(for: block),
            isFocused: model.focusedBlockId == block.id,
            caretRequest: model.caretRequests[block.id],
            onChange: { model.noteEdit(block, text: $0) },
            onReturn: { before, after in
                Task { await model.splitBlock(block, before: before, after: after) }
            },
            onBackspaceAtStart: {
                Task { await model.mergeIntoPrevious(block) }
            },
            onTab: { backward in
                Task { await model.changeType(block, to: block.blockType.cycled(backward: backward)) }
            },
            onFocusChange: { focused in
                if focused { model.beginEditing(block) } else { model.endEditing(block) }
            },
            onCaretApplied: { model.caretApplied(block.id) })
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 4) {
            if block.isPinned { Image(systemName: "pin.fill") }
            if block.isBookmarked { Image(systemName: "bookmark.fill") }
        }
        .font(.caption2)
        .foregroundStyle(.orange)
    }

    @ViewBuilder
    private var menu: some View {
        Button { onOpenDetails() } label: {
            Label("Details & Tags", systemImage: "tag")
        }
        if block.hasLink(.togglePinned) {
            Button {
                Task { await model.togglePinned(block) }
            } label: {
                Label(block.isPinned ? "Unpin" : "Pin",
                      systemImage: block.isPinned ? "pin.slash" : "pin")
            }
        }
        if block.hasLink(.toggleBookmark) {
            Button {
                Task { await model.toggleBookmark(block) }
            } label: {
                Label(block.isBookmarked ? "Remove Bookmark" : "Bookmark",
                      systemImage: block.isBookmarked ? "bookmark.slash" : "bookmark")
            }
        }
        if block.hasLink(.delete) {
            Button(role: .destructive) {
                Task { await model.deleteBlock(block) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Layout by element type

    private var columnWidth: CGFloat {
        switch block.blockType {
        case .dialogue, .lyrics: return Self.dialogueWidth
        case .parenthetical: return Self.parentheticalWidth
        default: return Self.pageWidth
        }
    }

    private var isNarrowColumn: Bool {
        switch block.blockType {
        case .dialogue, .parenthetical, .lyrics: return true
        default: return false
        }
    }

    private var topPadding: CGFloat {
        switch block.blockType {
        case .scene: return 18
        case .character, .dualDialogue, .transition, .shot, .section: return 10
        default: return 2
        }
    }
}
