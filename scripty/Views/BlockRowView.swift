//
//  BlockRowView.swift
//  scripty
//
//  Typographic rendering of one screenplay element, roughly following
//  screenplay page conventions inside a centered page column.
//
//  The same `BlockLayout` drives both this read-only row and the inline
//  editor field, so the text does not shift when a writer taps into a block.
//

import SwiftUI

/// How one element type sits on the page: its column, casing and emphasis.
struct BlockLayout {
    var font: Font = .system(size: 16, design: .monospaced)
    var weight: Font.Weight?
    var uppercase = false
    var italic = false
    /// Dialogue and parentheticals occupy narrower columns than action does.
    var columnWidth: CGFloat?
    /// Where that column sits inside the page.
    var columnAlignment: Alignment = .leading
    /// Where text sits inside the column.
    var textAlignment: TextAlignment = .leading
    var topPadding: CGFloat = 0
    var secondary = false

    static let pageWidth: CGFloat = 640
    private static let dialogueWidth: CGFloat = 400
    private static let parentheticalWidth: CGFloat = 320

    /// The block's own font and alignment overrides win over the type
    /// defaults, matching how the web app renders per-block formatting.
    static func of(_ block: Block) -> BlockLayout {
        var layout = base(for: block.blockType)

        switch block.font {
        case "ARIAL", "TIMES_NEW_ROMAN":
            layout.font = .system(size: 16)
        default:
            break   // Screenplay convention: Courier-style monospace.
        }
        if block.blockType == .section {
            layout.font = .title3
        }

        switch block.textAlign {
        case "CENTER":
            layout.columnAlignment = .center
            layout.textAlignment = .center
        case "RIGHT":
            layout.columnAlignment = .trailing
            layout.textAlignment = .trailing
        default:
            break
        }
        return layout
    }

    private static func base(for type: BlockType) -> BlockLayout {
        switch type {
        case .scene:
            return BlockLayout(weight: .bold, uppercase: true, topPadding: 18)
        case .character, .dualDialogue:
            return BlockLayout(uppercase: true, columnWidth: dialogueWidth,
                               columnAlignment: .center, textAlignment: .center,
                               topPadding: 10)
        case .dialogue:
            return BlockLayout(columnWidth: dialogueWidth, columnAlignment: .center)
        case .parenthetical:
            return BlockLayout(italic: true, columnWidth: parentheticalWidth,
                               columnAlignment: .center)
        case .transition:
            return BlockLayout(uppercase: true, columnAlignment: .trailing,
                               textAlignment: .trailing, topPadding: 10)
        case .shot:
            return BlockLayout(weight: .semibold, uppercase: true, topPadding: 10)
        case .centered:
            return BlockLayout(columnAlignment: .center, textAlignment: .center)
        case .lyrics:
            return BlockLayout(italic: true, columnWidth: dialogueWidth,
                               columnAlignment: .center)
        case .section:
            return BlockLayout(weight: .semibold, topPadding: 14, secondary: true)
        case .synopsis:
            return BlockLayout(italic: true, secondary: true)
        case .note:
            return BlockLayout(font: .callout)
        case .action, .text, .pageBreak:
            return BlockLayout()
        }
    }

    /// The column alignment a text view needs to honour `textAlignment`.
    var frameAlignment: Alignment {
        switch textAlignment {
        case .center: return .center
        case .trailing: return .trailing
        case .leading: return .leading
        }
    }
}

struct BlockRowView: View {
    let block: Block

    private var layout: BlockLayout { .of(block) }

    var body: some View {
        elementView
            .frame(maxWidth: BlockLayout.pageWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topTrailing) { badges }
    }

    @ViewBuilder
    private var elementView: some View {
        switch block.blockType {
        case .pageBreak:
            HStack(spacing: 12) {
                line
                Text("PAGE BREAK")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                line
            }
            .padding(.vertical, 8)

        case .note:
            text
                .padding(8)
                .background(Color.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))

        default:
            text
        }
    }

    private var text: some View {
        styledText(displayContent)
            .foregroundStyle(layout.secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .multilineTextAlignment(layout.textAlignment)
            .frame(maxWidth: layout.columnWidth, alignment: layout.frameAlignment)
            .frame(maxWidth: .infinity, alignment: layout.columnAlignment)
            .padding(.top, layout.topPadding)
    }

    private var line: some View {
        Rectangle()
            .fill(.tertiary)
            .frame(height: 1)
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 4) {
            if block.isPinned {
                Image(systemName: "pin.fill")
            }
            if block.isBookmarked {
                Image(systemName: "bookmark.fill")
            }
        }
        .font(.caption2)
        .foregroundStyle(.orange)
    }

    /// Character cues carry the speaker name as content; fall back to the
    /// linked character when the content is empty. Parentheticals are shown
    /// wrapped even when the stored text omits the brackets.
    private var displayContent: String {
        let content = block.content ?? ""
        if content.isEmpty, block.blockType.isCharacterCue, let name = block.personName {
            return name
        }
        if block.blockType == .parenthetical, !content.isEmpty, !content.hasPrefix("(") {
            return "(\(content))"
        }
        return content
    }

    private func styledText(_ string: String) -> Text {
        let shown = layout.uppercase ? string.uppercased() : string
        var text = Text(shown.isEmpty ? " " : shown)
            .font(layout.font)
        if let weight = layout.weight { text = text.fontWeight(weight) }
        if layout.italic || (block.textItalic ?? false) { text = text.italic() }
        if block.textBold ?? false { text = text.bold() }
        if block.textUnderline ?? false { text = text.underline() }
        return text
    }
}
