//
//  ReadScriptView.swift
//  scripty
//
//  Read Script mode: the screenplay as prose, for reading rather than writing.
//  Ported from the web app's reader template, which drops the editing chrome,
//  sets the script in a serif face at a comfortable measure, and leaves out the
//  working annotations — synopses and notes are for the writer, not the reader.
//
//  Deliberately not a page-accurate view; that is what page view is for. This
//  one optimises for reading on a screen.
//

import SwiftUI

struct ReadScriptView: View {
    let title: String
    let blocks: [Block]
    let textScale: Double

    @Environment(\.dismiss) private var dismiss

    /// The reader's measure: roughly the 40rem column the web app uses.
    private let measure: CGFloat = 640

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title.isEmpty ? "Untitled Project" : title)
                        .font(.system(size: 28 * textScale, weight: .bold, design: .serif))
                        .padding(.bottom, 24)

                    ForEach(Array(readableBlocks.enumerated()), id: \.element.id) { index, block in
                        row(block, isFirst: index == 0)
                    }
                }
                .frame(maxWidth: measure, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .textSelection(.enabled)
            }
            .overlay { emptyState }
            .navigationTitle("Read Script")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Notes, synopses and page breaks are working marks that the reader view
    /// leaves out, matching the reader template and the print stylesheet.
    private var readableBlocks: [Block] {
        blocks.filter { block in
            switch block.blockType {
            case .synopsis, .note, .pageBreak: return false
            default: return true
            }
        }
    }

    @ViewBuilder
    private func row(_ block: Block, isFirst: Bool) -> some View {
        let text = displayText(for: block)

        switch block.blockType {
        case .scene:
            VStack(alignment: .leading, spacing: 0) {
                if !isFirst {
                    Divider().padding(.bottom, 16)
                }
                Text(text.uppercased())
                    .font(.system(size: 17 * textScale, weight: .bold, design: .serif))
                    .tracking(0.7)
            }
            .padding(.top, isFirst ? 0 : 16)
            .padding(.bottom, 16)

        case .section:
            Text(text)
                .font(.system(size: 20 * textScale, weight: .semibold, design: .serif))
                .padding(.top, 20)
                .padding(.bottom, 12)

        case .character, .dualDialogue:
            Text(text.uppercased())
                .font(.system(size: 16 * textScale, weight: .bold, design: .serif))
                .tracking(0.9)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 12)
                .padding(.bottom, 4)

        case .parenthetical:
            prose(text.hasPrefix("(") ? text : "(\(text))", block: block)
                .italic()
                .frame(maxWidth: .infinity, alignment: .center)

        case .dialogue, .lyrics:
            prose(text, block: block)
                .italic(block.blockType == .lyrics)
                .padding(.horizontal, 32)
                .padding(.bottom, 14)

        case .transition:
            prose(text.uppercased(), block: block)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.vertical, 10)

        case .centered:
            prose(text, block: block)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 14)

        default:
            VStack(alignment: .leading, spacing: 4) {
                // The reader labels a speaker that is attached to a non-cue
                // element, since there is no cue line to carry the name.
                if let name = block.personName, !name.isEmpty,
                   !block.blockType.isCharacterCue {
                    Text(name.uppercased())
                        .font(.system(size: 15 * textScale, weight: .bold, design: .serif))
                        .tracking(0.9)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                prose(text, block: block)
            }
            .padding(.bottom, 14)
        }
    }

    /// Body copy shared by the prose-like elements, honouring the writer's
    /// character formatting but not the screenplay indents.
    private func prose(_ text: String, block: Block) -> Text {
        var result = Text(text.isEmpty ? " " : text)
            .font(.system(size: 17 * textScale, design: .serif))
        if block.textBold ?? false { result = result.bold() }
        if block.textItalic ?? false { result = result.italic() }
        if block.textUnderline ?? false { result = result.underline() }
        return result
    }

    private func displayText(for block: Block) -> String {
        let content = block.content ?? ""
        if content.isEmpty, block.blockType.isCharacterCue, let name = block.personName {
            return name
        }
        return content
    }

    @ViewBuilder
    private var emptyState: some View {
        if readableBlocks.isEmpty {
            ContentUnavailableView(
                "Nothing to Read",
                systemImage: "book",
                description: Text("This script has no elements yet."))
        }
    }
}
