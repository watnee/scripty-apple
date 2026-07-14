//
//  EditableBlockRow.swift
//  scripty
//
//  One element of the script, edited where it sits. Tapping puts the caret in
//  the block instead of opening a sheet, so writing a scene is typing, not a
//  sequence of forms.
//

import SwiftUI

struct EditableBlockRow: View {
    let model: ScriptModel
    let block: Block

    @State private var text: String

    init(model: ScriptModel, block: Block) {
        self.model = model
        self.block = block
        _text = State(initialValue: block.content ?? "")
    }

    private var style: BlockStyle { BlockStyle.of(block.blockType) }
    private var isFocused: Bool { model.focusedBlockID == block.id }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            typeGutter
            editor
        }
        .padding(.top, style.topPadding)
        .frame(maxWidth: BlockStyle.pageWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) { badges }
        .contentShape(Rectangle())
        .onTapGesture { model.focusedBlockID = block.id }
        // A retype or a sync refresh rewrites the block under us — e.g. typing
        // "INT. BAR" turns it into a Scene and drops nothing, but "> CUT TO:"
        // loses its marker. Take the server's text unless we're mid-keystroke.
        .onChange(of: block.content) { _, new in
            let stored = new ?? ""
            if !isFocused || stored != text {
                text = stored
            }
        }
        .onChange(of: text) { _, new in
            if isFocused { model.draft = new }
        }
        .onChange(of: isFocused) { _, focused in
            if focused { model.draft = text }
        }
    }

    @ViewBuilder
    private var editor: some View {
        ZStack(alignment: placeholderAlignment) {
            if text.isEmpty {
                Text(BlockStyle.placeholder(for: block.blockType))
                    .font(.system(size: 16, design: .monospaced))
                    .foregroundStyle(.quaternary)
                    .allowsHitTesting(false)
            }
            BlockTextView(
                text: $text,
                type: block.blockType,
                isFocused: isFocused,
                onFocus: { model.focusedBlockID = block.id },
                onReturn: { typed in
                    Task { await model.insertBelow(block, content: typed) }
                },
                onBackspaceIntoPrevious: {
                    Task { await model.deleteEmptyAndFocusPrevious(block) }
                },
                onCycleType: { backward in
                    let next = FountainRules.cycle(from: block.blockType, backward: backward)
                    Task { await model.setType(block, to: next, content: text) }
                },
                onSetType: { type in
                    Task { await model.setType(block, to: type, content: text) }
                },
                onCommit: { typed in
                    Task { await model.commit(block, content: typed) }
                })
        }
        .frame(maxWidth: style.maxWidth ?? .infinity, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: style.columnAlignment)
    }

    /// The element's name, shown only for the block being written, the way the
    /// web editor labels the active row.
    @ViewBuilder
    private var typeGutter: some View {
        Text(isFocused ? block.blockType.label : "")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(width: 68, alignment: .trailing)
            .padding(.top, 2)
    }

    private var placeholderAlignment: Alignment {
        switch style.alignment {
        case .center: return .top
        case .trailing: return .topTrailing
        default: return .topLeading
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
}
