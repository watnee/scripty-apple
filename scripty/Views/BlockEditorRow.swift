//
//  BlockEditorRow.swift
//  scripty
//
//  A block being typed into, in place in the script. It renders with the
//  same `BlockLayout` as the read-only row, so tapping into a block does
//  not move its text — the writer just starts typing where they looked.
//

import SwiftUI

struct BlockEditorRow: View {
    let block: Block
    @Binding var text: String
    @FocusState.Binding var focusedBlockID: Int?

    private var layout: BlockLayout { .of(block) }

    var body: some View {
        TextField("", text: $text, axis: .vertical)
            .focused($focusedBlockID, equals: block.id)
            .font(layout.font)
            .fontWeight(layout.weight)
            .italic(layout.italic)
            .multilineTextAlignment(layout.textAlignment)
            // Scene headings, cues and transitions are written in caps.
            .textInputAutocapitalization(layout.uppercase ? .characters : .sentences)
            .autocorrectionDisabled(false)
            .textFieldStyle(.plain)
            .frame(maxWidth: layout.columnWidth, alignment: layout.frameAlignment)
            .frame(maxWidth: .infinity, alignment: layout.columnAlignment)
            .padding(.top, layout.topPadding)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 4))
            .frame(maxWidth: BlockLayout.pageWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
    }
}

/// The element-type bar: retypes the block being edited, the way the web
/// editor's element menu does. Shown above the keyboard while editing.
struct BlockTypeBar: View {
    let current: BlockType
    let onSelect: (BlockType) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(BlockType.editorBar) { type in
                        Button {
                            onSelect(type)
                        } label: {
                            Text(type.label)
                                .font(.footnote.weight(type == current ? .semibold : .regular))
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(type == current ? Color.accentColor : Color.clear,
                                            in: Capsule())
                                .foregroundStyle(type == current ? Color.white : Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .id(type)
                    }
                }
                .padding(.horizontal, 4)
            }
            .onAppear { proxy.scrollTo(current, anchor: .center) }
            .onChange(of: current) { _, type in
                withAnimation { proxy.scrollTo(type, anchor: .center) }
            }
        }
    }
}
