//
//  ElementTypeBar.swift
//  scripty
//
//  The element-type bar from the web editor: while a block is focused, a
//  row of type chips retypes it in place (rel `setType`). The current type
//  is highlighted; Tab / Shift-Tab on a hardware keyboard walk the same set.
//
//  The chips are packed tight on purpose: this bar and FormatBar both sit
//  above the keyboard, and every point they spend on padding is a point of
//  script the writer cannot see. Padding rather than fixed heights, so the
//  chips still grow with the text size a writer chose.
//

import SwiftUI

struct ElementTypeBar: View {
    let model: ScriptModel
    let block: Block

    /// Narrowed while the script is collapsed to its outline, the way the web
    /// editor narrows the same bar: every other type would take the element
    /// straight off the screen the moment it was applied.
    private let settings = PresentationSettings.shared

    /// The types offered on the bar — the logical Tab cycle plus the handful
    /// of extras a writer reaches for often.
    private static let types: [BlockType] =
        [.scene, .action, .character, .dialogue, .parenthetical,
         .transition, .shot, .centered, .lyrics, .section, .synopsis, .note]

    private var types: [BlockType] {
        settings.isOutlineMode ? BlockType.outlineTypes : Self.types
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(types) { type in
                    Button {
                        Task { await model.changeType(block, to: type) }
                    } label: {
                        Text(type.label)
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(type == block.blockType ? Color.white : Color.primary)
                    .background(
                        Capsule().fill(type == block.blockType
                                       ? Color.accentColor
                                       : Color.secondary.opacity(0.15)))
                    // The highlight is colour-only; VoiceOver needs the state
                    // said out loud, as FormatBar's chips already do.
                    .accessibilityAddTraits(type == block.blockType ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        // No background: `ScriptView` mounts the editing bars with
        // `.safeAreaBar`, so the strip is already floating on Liquid Glass.
        .scrollEdgeEffectHidden()
    }
}
