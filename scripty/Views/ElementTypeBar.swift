//
//  ElementTypeBar.swift
//  scripty
//
//  The element bar that rides above the keyboard while writing. A hardware
//  keyboard has Tab and ⌘1–7 for this; on glass this bar is how you retype the
//  block you're in, so the two ways of writing stay level.
//

import SwiftUI

struct ElementTypeBar: View {
    let model: ScriptModel
    let block: Block

    private static let secondary: [BlockType] = [
        .text, .dualDialogue, .lyrics, .centered, .section, .synopsis, .note, .pageBreak,
    ]

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(FountainRules.tabCycle) { type in
                        button(for: type)
                    }
                    Menu {
                        ForEach(Self.secondary) { type in
                            Button(type.label) { set(type) }
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                            .font(.callout)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                }
                .padding(.horizontal, 12)
            }

            Divider().frame(height: 24)

            Button("Done") { model.focusedBlockID = nil }
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 14)
        }
        .frame(height: 44)
        .background(.bar)
    }

    private func button(for type: BlockType) -> some View {
        let isCurrent = type == block.blockType
        return Button {
            set(type)
        } label: {
            Text(type.label)
                .font(.callout.weight(isCurrent ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isCurrent ? Color.accentColor.opacity(0.18) : .clear,
                            in: Capsule())
                .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func set(_ type: BlockType) {
        Task { await model.setType(block, to: type, content: model.draft) }
    }
}
