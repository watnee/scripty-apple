//
//  BlockRowView.swift
//  scripty
//
//  Typographic rendering of one screenplay element, roughly following
//  screenplay page conventions inside a centered page column.
//

import SwiftUI

struct BlockRowView: View {
    let block: Block

    private static let pageWidth: CGFloat = 640
    private static let dialogueWidth: CGFloat = 400
    private static let parentheticalWidth: CGFloat = 320

    var body: some View {
        elementView
            .frame(maxWidth: Self.pageWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topTrailing) { badges }
    }

    @ViewBuilder
    private var elementView: some View {
        switch block.blockType {
        case .scene:
            styledText(displayContent.uppercased())
                .fontWeight(.bold)
                .frame(maxWidth: .infinity, alignment: alignment)
                .padding(.top, 18)

        case .character, .dualDialogue:
            styledText(displayContent.uppercased())
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 10)

        case .dialogue:
            styledText(displayContent)
                .frame(maxWidth: Self.dialogueWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)

        case .parenthetical:
            styledText(parenthesized(displayContent))
                .italic()
                .frame(maxWidth: Self.parentheticalWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)

        case .transition:
            styledText(displayContent.uppercased())
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 10)

        case .shot:
            styledText(displayContent.uppercased())
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: alignment)
                .padding(.top, 10)

        case .centered:
            styledText(displayContent)
                .frame(maxWidth: .infinity, alignment: .center)

        case .lyrics:
            styledText(displayContent)
                .italic()
                .frame(maxWidth: Self.dialogueWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)

        case .section:
            styledText(displayContent)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 14)

        case .synopsis:
            styledText(displayContent)
                .italic()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .note:
            styledText(displayContent)
                .font(.callout)
                .padding(8)
                .background(Color.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: .infinity, alignment: .leading)

        case .pageBreak:
            HStack(spacing: 12) {
                line
                Text("PAGE BREAK")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                line
            }
            .padding(.vertical, 8)

        case .action, .text:
            styledText(displayContent)
                .frame(maxWidth: .infinity, alignment: alignment)
        }
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
    /// linked character when the content is empty.
    private var displayContent: String {
        let content = block.content ?? ""
        if content.isEmpty, block.blockType.isCharacterCue, let name = block.personName {
            return name
        }
        return content
    }

    private func parenthesized(_ text: String) -> String {
        text.hasPrefix("(") ? text : "(\(text))"
    }

    private var alignment: Alignment {
        switch block.textAlign {
        case "CENTER": return .center
        case "RIGHT": return .trailing
        default: return .leading
        }
    }

    private func styledText(_ string: String) -> Text {
        var text = Text(string.isEmpty ? " " : string)
            .font(baseFont)
        if block.textBold ?? false { text = text.bold() }
        if block.textItalic ?? false { text = text.italic() }
        if block.textUnderline ?? false { text = text.underline() }
        return text
    }

    private var baseFont: Font {
        switch block.font {
        case "ARIAL", "TIMES_NEW_ROMAN":
            return .system(size: 16)
        default:
            // Screenplay convention: Courier-style monospace.
            return .system(size: 16, design: .monospaced)
        }
    }
}
