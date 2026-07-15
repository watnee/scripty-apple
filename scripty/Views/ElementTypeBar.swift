//
//  ElementTypeBar.swift
//  scripty
//
//  The element-type bar the web editor shows for changing the current block's
//  type. On a touch keyboard there is no Tab, so this bar is how you retype an
//  element in place; it mirrors the same set and order Tab cycles through.
//

import SwiftUI

struct ElementTypeBar: View {
    let model: ScriptModel
    let block: Block

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(BlockType.tabCycle) { type in
                    Button {
                        Task { await model.retype(block.id, to: type) }
                    } label: {
                        Text(type.label)
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(background(for: type), in: Capsule())
                            .foregroundStyle(foreground(for: type))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private var current: BlockType { block.blockType }

    private func background(for type: BlockType) -> Color {
        type == current ? Color.accentColor : Color.secondary.opacity(0.15)
    }

    private func foreground(for type: BlockType) -> Color {
        type == current ? Color.white : Color.primary
    }
}
