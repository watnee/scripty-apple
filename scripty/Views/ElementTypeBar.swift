//
//  ElementTypeBar.swift
//  scripty
//
//  The element-type strip pinned above the keyboard while a block is being
//  edited — the iOS counterpart of the web editor's element bar. Tapping a
//  type retypes the focused block in place; the common Final Draft cycle is
//  laid out first, with the rest tucked into a menu.
//

import SwiftUI

struct ElementTypeBar: View {
    let model: ScriptModel
    /// The block currently holding the keyboard.
    let block: Block

    /// Types shown as buttons, in Tab-cycle order; the rest live in "More".
    private static let primary = BlockType.tabCycle
    private static let more: [BlockType] = BlockType.allCases.filter { !primary.contains($0) }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.primary) { type in
                        typeButton(type)
                    }
                    Menu {
                        ForEach(Self.more) { type in
                            Button(type.label) { change(to: type) }
                        }
                    } label: {
                        Text("More")
                            .font(.callout)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.quaternary, in: Capsule())
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            Divider().frame(height: 28)

            Button {
                model.focusedBlockId = nil
            } label: {
                Text("Done").fontWeight(.semibold)
            }
            .padding(.horizontal, 16)
        }
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func typeButton(_ type: BlockType) -> some View {
        let selected = block.blockType == type
        return Button {
            change(to: type)
        } label: {
            Text(type.label)
                .font(.callout)
                .fontWeight(selected ? .semibold : .regular)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? AnyShapeStyle(Color.accentColor)
                                     : AnyShapeStyle(.quaternary),
                            in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func change(to type: BlockType) {
        guard type != block.blockType else { return }
        Task { await model.changeType(block, to: type) }
    }
}
