//
//  SongLineRow.swift
//  scripty
//
//  One line of a lyric, as a row in a list.
//
//  Split out from the song editor because the workspace — every song in the
//  project on one screen — has to render the same line, with the same actions
//  and the same saving behaviour, inside a list it does not own. Two
//  implementations of "a lyric line" would drift apart on the first change to
//  either.
//

import SwiftUI

struct SongLineRow: View {
    let model: SongBlockModel
    let block: SongBlock
    /// Owned by whatever list this row is in, so Return can move the caret to
    /// the line it just created.
    @FocusState.Binding var focusedLine: Int?

    @Environment(\.colorScheme) private var colorScheme
    /// The writer's chosen type size, shared with the screenplay through the
    /// same environment key so one preference scales lyrics wherever they show
    /// — the song editor and the all-songs workspace both set it. Defaults to
    /// 1.0, so a host that never sets it leaves the line at its natural size.
    @Environment(\.scriptTextScale) private var textScale

    /// The lyric's base point size at 100%. Matches the default body text this
    /// row used before it scaled, so nothing moves at the default setting.
    private static let baseLineSize: CGFloat = 17

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Menu {
                lineMenu
            } label: {
                Text("\(block.order ?? 0)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Line \(block.order ?? 0) actions")

            TextField("", text: text, axis: .vertical)
                .font(.system(size: Self.baseLineSize * textScale))
                .focused($focusedLine, equals: block.id)
                .disabled(!block.isEditable)
                .submitLabel(.return)
                .onSubmit {
                    Task {
                        if let created = await model.addLine(below: block) {
                            focusedLine = created
                        }
                    }
                }
                .onChange(of: focusedLine) { previous, _ in
                    // Save on the way out rather than waiting for the debounce.
                    if previous == block.id {
                        Task { await model.commit(block) }
                    }
                }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .listRowBackground(rowBackground)
        .swipeActions(edge: .trailing) {
            if block.hasLink(.delete) {
                Button(role: .destructive) {
                    Task { await model.delete(block) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private var text: Binding<String> {
        Binding(get: { model.currentText(block) },
                set: { model.edit(block, text: $0) })
    }

    @ViewBuilder
    private var rowBackground: some View {
        if let tint = block.tint {
            tint.color(for: colorScheme)
        } else {
            Color.clear
        }
    }

    /// The per-line actions hang off the number in the margin rather than off a
    /// context menu on the row. The text field fills the row and swallows a
    /// long press, so a row-level menu is simply unreachable — which is how the
    /// first version of this shipped, with Move, Highlight and Delete visible
    /// in the code and unusable in the app. The number is also worth having:
    /// lyrics get discussed by line.
    @ViewBuilder
    private var lineMenu: some View {
        if model.canMoveUp(block) {
            Button {
                Task { await model.move(block, by: -1) }
            } label: {
                Label("Move Up", systemImage: "arrow.up")
            }
        }
        if model.canMoveDown(block) {
            Button {
                Task { await model.move(block, by: 1) }
            } label: {
                Label("Move Down", systemImage: "arrow.down")
            }
        }
        if block.hasLink(.setHighlight) {
            Menu {
                ForEach(BlockHighlight.allCases) { colour in
                    Button(colour.label) {
                        Task { await model.setHighlight(block, to: colour) }
                    }
                }
                Button("None") {
                    Task { await model.setHighlight(block, to: nil) }
                }
            } label: {
                Label("Highlight", systemImage: "highlighter")
            }
        }
        if block.hasLink(.delete) {
            Button(role: .destructive) {
                Task { await model.delete(block) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
