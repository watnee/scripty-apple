//
//  EditableBlockRow.swift
//  scripty
//
//  One editable screenplay element on the page. Wraps BlockTextView in the
//  same centered page column the read-only view uses, and routes the
//  structural keystrokes into ScriptModel. The affordances that have no place
//  on the page — tags, speaker, pin, bookmark, delete — live in a context menu.
//

import SwiftUI

struct EditableBlockRow: View {
    let model: ScriptModel
    let block: Block
    var onShowDetails: () -> Void

    private static let pageWidth: CGFloat = 640
    private static let dialogueWidth: CGFloat = 400
    private static let parentheticalWidth: CGFloat = 320

    var body: some View {
        editor
            .frame(maxWidth: Self.pageWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topTrailing) { badges }
            .padding(.top, topPadding)
            .padding(.vertical, 2)
            .padding(.horizontal, 24)
            .contentShape(Rectangle())
            .contextMenu { menu }
    }

    private var editor: some View {
        let textView = BlockTextView(
            block: block,
            text: model.displayText(for: block),
            isFocused: model.focusedBlockId == block.id,
            caretRequest: model.caretRequest,
            onText: { model.edit(block.id, text: $0) },
            onReturn: { caret in Task { await model.splitBlock(block.id, caret: caret) } },
            onBackspaceAtStart: { Task { await model.mergeIntoPrevious(block.id) } },
            onTab: { backward in Task { await model.cycleType(block.id, backward: backward) } },
            onFocus: { model.beginEditing(block.id) },
            onBlur: { model.endEditing(block.id) },
            onCaretConsumed: { model.consumeCaretRequest($0) })

        return Group {
            if let width = innerWidth {
                textView
                    .frame(maxWidth: width, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: innerAlignment)
            } else {
                textView
                    .frame(maxWidth: .infinity, alignment: innerAlignment)
            }
        }
    }

    /// Narrower sub-columns for the elements that are indented on a real page.
    private var innerWidth: CGFloat? {
        switch block.blockType {
        case .dialogue, .lyrics: return Self.dialogueWidth
        case .parenthetical: return Self.parentheticalWidth
        default: return nil
        }
    }

    private var innerAlignment: Alignment {
        switch block.blockType {
        case .character, .dualDialogue, .centered: return .center
        case .transition: return .trailing
        case .dialogue, .lyrics, .parenthetical: return .center
        default: return .leading
        }
    }

    private var topPadding: CGFloat {
        switch block.blockType {
        case .scene: return 16
        case .section: return 12
        case .character, .dualDialogue, .transition, .shot: return 8
        default: return 0
        }
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
        Button {
            onShowDetails()
        } label: {
            Label("Details…", systemImage: "slider.horizontal.3")
        }

        if block.hasLink(.toggleBookmark) {
            Button {
                Task { await model.toggleBookmark(block) }
            } label: {
                Label(block.isBookmarked ? "Remove Bookmark" : "Bookmark",
                      systemImage: block.isBookmarked ? "bookmark.slash" : "bookmark")
            }
        }
        if block.hasLink(.togglePinned) {
            Button {
                Task { await model.togglePinned(block) }
            } label: {
                Label(block.isPinned ? "Unpin" : "Pin",
                      systemImage: block.isPinned ? "pin.slash" : "pin")
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
}
