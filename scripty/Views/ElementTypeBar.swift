//
//  ElementTypeBar.swift
//  scripty
//
//  The element-type bar from the web editor: while a block is focused, a
//  row of type chips retypes it in place (rel `setType`). The current type
//  is highlighted; Tab / Shift-Tab on a hardware keyboard walk the same set.
//

import SwiftUI

struct ElementTypeBar: View {
    let model: ScriptModel
    let block: Block

    /// The types offered on the bar — the logical Tab cycle plus the handful
    /// of extras a writer reaches for often.
    private static let types: [BlockType] =
        [.scene, .action, .character, .dialogue, .parenthetical,
         .transition, .shot, .centered, .lyrics, .section, .synopsis, .note]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.types) { type in
                    Button {
                        Task { await model.changeType(block, to: type) }
                    } label: {
                        Text(type.label)
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(type == block.blockType ? Color.white : Color.primary)
                    .background(
                        Capsule().fill(type == block.blockType
                                       ? Color.accentColor
                                       : Color.secondary.opacity(0.15)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }
}
