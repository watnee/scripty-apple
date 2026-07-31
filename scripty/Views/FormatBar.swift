//
//  FormatBar.swift
//  scripty
//
//  Character formatting for the focused element — bold / italic / underline,
//  alignment, typeface and type size — folded out directly above
//  ElementTypeBar by the toggle button at that bar's leading edge. Every
//  control except the size reflects the block's current server state, so the
//  bar doubles as an indicator.
//
//  The three styles, the three alignments and the three size controls are
//  each packed into one segmented capsule, and the typeface shows its short
//  name, so a phone shows all of the formatting and reaches the size with a
//  short scroll — the order puts what belongs to the block first. It still
//  hides behind the toggle: a second permanent row of chips above the
//  keyboard is more of the screen than formatting deserves. Segment height
//  matches ElementTypeBar's chips, so the two rows still read as one
//  language: the group's own 2pt inset plus a segment's 3pt comes to the 5pt
//  a chip pads by, and both rows inset by the same 12/5.
//
//  Shown only when the block advertises an `update` link.
//

import SwiftUI

struct FormatBar: View {
    let model: ScriptModel
    let block: Block

    private let settings = PresentationSettings.shared

    private var align: TextAlign { TextAlign(serverValue: block.textAlign) ?? .left }
    /// nil is a real state here — the element carries no font override and so
    /// prints in the default typeface. The menu shows "Default" for it.
    private var font: ScriptFont? { ScriptFont(serverValue: block.font) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                segmented { styleSegments }
                segmented { alignSegments }
                fontMenu
                segmented { sizeSegments }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
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
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
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

    // MARK: - Type size

    /// The device-wide type size — the same setting the View menu's Text Size
    /// section moves, not a property of this block. It rides along here because
    /// this bar is what a writer has open while typing: the toolbar menu is a
    /// couple of taps and a dismissed keyboard away, and wanting the script
    /// bigger is something the eyes ask for mid-sentence.
    ///
    /// The bar itself is still gated on an `update` link, so a reader reaches
    /// these through the View menu as before — nothing they could reach was
    /// taken away.
    @ViewBuilder
    private var sizeSegments: some View {
        segment(isOn: false, label: "Smaller", isEnabled: settings.canDecreaseTextSize) {
            settings.decreaseTextSize()
        } content: {
            Image(systemName: "textformat.size.smaller").frame(minWidth: 22)
        }

        // The readout doubles as the reset, the way "Actual Size (120%)" does
        // in the menus — one segment rather than two, and the number is the
        // only way to tell 110% from 120% at a glance.
        segment(isOn: false, label: "Actual Size",
                isEnabled: settings.textSize != PresentationSettings.defaultTextSize) {
            settings.resetTextSize()
        } content: {
            Text("\(settings.textSize)%").monospacedDigit()
        }
        .accessibilityValue("\(settings.textSize)%")

        segment(isOn: false, label: "Bigger", isEnabled: settings.canIncreaseTextSize) {
            settings.increaseTextSize()
        } content: {
            Image(systemName: "textformat.size.larger").frame(minWidth: 22)
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
        segment(isOn: isOn, label: label, action: action) {
            Image(systemName: systemImage).frame(minWidth: 22)
        }
    }

    /// The same segment with its own content, for the one control that reads
    /// as a number rather than a glyph. `isEnabled` is what the size controls
    /// need and the format ones do not: bold is always available on a block
    /// this bar is showing for, where 200% is the end of the road.
    private func segment<Content: View>(
        isOn: Bool, label: String, isEnabled: Bool = true,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .foregroundStyle(segmentForeground(isOn: isOn, isEnabled: isEnabled))
        .background(Capsule().fill(isOn ? Color.accentColor : Color.clear))
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private func segmentForeground(isOn: Bool, isEnabled: Bool) -> AnyShapeStyle {
        if isOn { return AnyShapeStyle(Color.white) }
        return isEnabled ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.tertiary)
    }
}
