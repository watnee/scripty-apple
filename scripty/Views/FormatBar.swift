//
//  FormatBar.swift
//  scripty
//
//  Character formatting for the focused element — bold / italic / underline,
//  alignment and typeface — sitting directly above ElementTypeBar. Every
//  control reflects the block's current server state, so the bar doubles as
//  an indicator.
//
//  The three styles and the three alignments are each packed into one
//  segmented capsule, and the typeface shows its short name, so the whole bar
//  fits a phone without scrolling — two rows of chips above the keyboard is
//  already as much of the screen as formatting deserves. Segment height
//  matches ElementTypeBar's chips, so the two rows still read as one language.
//
//  Shown only when the block advertises an `update` link.
//

import SwiftUI

struct FormatBar: View {
    let model: ScriptModel
    let block: Block

    private var align: TextAlign { TextAlign(serverValue: block.textAlign) ?? .left }
    /// nil is a real state here — the element carries no font override and so
    /// prints in the default typeface. The menu shows "Default" for it.
    private var font: ScriptFont? { ScriptFont(serverValue: block.font) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                segmented { styleSegments }
                segmented { alignSegments }
                fontMenu
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        // No background: `ScriptView` mounts the editing bars with
        // `.safeAreaBar`, so the strip is already floating on Liquid Glass.
        .scrollEdgeEffectHidden()
    }

    // MARK: - Bold / italic / underline

    @ViewBuilder
    private var styleSegments: some View {
        segment("bold", isOn: block.textBold ?? false, label: "Bold") {
            Task { await model.toggleBold(block) }
        }
        segment("italic", isOn: block.textItalic ?? false, label: "Italic") {
            Task { await model.toggleItalic(block) }
        }
        segment("underline", isOn: block.textUnderline ?? false, label: "Underline") {
            Task { await model.toggleUnderline(block) }
        }
    }

    // MARK: - Alignment

    @ViewBuilder
    private var alignSegments: some View {
        ForEach(TextAlign.allCases) { option in
            segment(option.systemImage, isOn: option == align, label: option.label) {
                Task { await model.setAlign(block, to: option) }
            }
        }
    }

    // MARK: - Typeface

    private var fontMenu: some View {
        Menu {
            // "Default" resets the override, matching the web Format menu's
            // "Font: Default". It clears through the bulk endpoint's `clearFont`
            // flag, since the per-block PUT can only set a named font — a blank
            // one there is treated as "leave alone", not "reset".
            fontOption(nil, label: "Default")
            ForEach(ScriptFont.allCases) { option in
                fontOption(option, label: option.label)
            }
        } label: {
            HStack(spacing: 4) {
                Text(font?.shortLabel ?? "Default")
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .background(Capsule().fill(Color.secondary.opacity(0.15)))
        .accessibilityLabel("Font")
        // The chip shows the name shortened; VoiceOver reads it whole.
        .accessibilityValue(font?.label ?? "Default")
    }

    @ViewBuilder
    private func fontOption(_ option: ScriptFont?, label: String) -> some View {
        Button {
            Task {
                if let option {
                    await model.setFont(block, to: option)
                } else {
                    await model.bulkClearFont([block.id])
                }
            }
        } label: {
            if option == font {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    // MARK: - Segmented group

    /// One control's segments inside a shared capsule. Grouping does the job
    /// the dividers used to, in less room: the eye reads three alignments as
    /// one control without a rule drawn beside them.
    private func segmented<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        HStack(spacing: 2) {
            content()
        }
        .padding(2)
        .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }

    /// Padding rather than a fixed frame, so the segments still grow with the
    /// text size a writer chose.
    private func segment(_ systemImage: String, isOn: Bool, label: String,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.medium))
                .frame(minWidth: 22)
                .padding(.horizontal, 4)
                .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? Color.white : Color.primary)
        .background(Capsule().fill(isOn ? Color.accentColor : Color.clear))
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}
