//
//  FormatBar.swift
//  scripty
//
//  Character formatting for the focused element — bold / italic / underline,
//  alignment and typeface — folded out directly above ElementTypeBar by the
//  toggle button at that bar's leading edge. Every control reflects the
//  block's current server state, so the bar doubles as an indicator.
//
//  The type size at the end is the exception, and is documented where it is
//  built: it belongs to the device rather than to the element, because the
//  server carries no per-element size.
//
//  The three styles and the three alignments are each packed into one
//  segmented capsule, and the typeface and size show short labels, so the bar
//  fits a phone with only the last chip scrolled to. It still hides behind
//  the toggle: a second
//  permanent row of chips above the keyboard is more of the screen than
//  formatting deserves. Segment height matches ElementTypeBar's chips, so the
//  two rows still read as one language: the group's own 2pt inset plus a
//  segment's 3pt comes to the 5pt a chip pads by, and both rows inset by the
//  same 12/5.
//
//  Shown only when the block advertises an `update` link.
//

import SwiftUI

struct FormatBar: View {
    let model: ScriptModel
    let block: Block

    private let settings = PresentationSettings.shared

    @State private var isEnteringSize = false
    @State private var sizeText = ""

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
                sizeMenu
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        // No background: `ScriptView` mounts the editing bars with
        // `.safeAreaBar`, so the strip is already floating on Liquid Glass.
        .scrollEdgeEffectHidden()
        .alert("Text Size", isPresented: $isEnteringSize) {
            TextField("Points", text: $sizeText)
                .keyboardType(.decimalPad)
            Button("Cancel", role: .cancel) { sizeText = "" }
            Button("Set") {
                // A number that isn't one leaves the size alone; one outside
                // the range is pulled to the nearest end by the setter. The
                // comma is tried as a decimal point because that is the key
                // the number pad offers wherever a comma is the separator, and
                // `Double(_:)` only ever reads a full stop.
                let entry = sizeText.trimmingCharacters(in: .whitespaces)
                if let points = Double(entry)
                    ?? Double(entry.replacingOccurrences(of: ",", with: ".")) {
                    settings.fontSizePt = points
                }
                sizeText = ""
            }
        } message: {
            Text("Show the script between "
                 + "\(PresentationSettings.fontSizeLabel(PresentationSettings.minFontSizePt)) "
                 + "and "
                 + "\(PresentationSettings.fontSizeLabel(PresentationSettings.maxFontSizePt)) "
                 + "points.")
        }
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
        // The chip shows the name shortened; VoiceOver reads it whole.
        chipMenu(title: font?.shortLabel ?? "Default",
                 accessibilityLabel: "Font",
                 accessibilityValue: font?.label ?? "Default") {
            // "Default" resets the override, matching the web Format menu's
            // "Font: Default". It clears through the bulk endpoint's `clearFont`
            // flag, since the per-block PUT can only set a named font — a blank
            // one there is treated as "leave alone", not "reset".
            fontOption(nil, label: "Default")
            ForEach(ScriptFont.allCases) { option in
                fontOption(option, label: option.label)
            }
        }
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

    /// The size the script is shown in, in points, beside the typeface it is
    /// shown in — which is where a writer looks for it.
    ///
    /// The odd one out in this bar: every control to its left changes the
    /// element under the cursor, and this one changes how the whole script is
    /// drawn, on this device. There is no per-element size to change — the
    /// server carries a typeface, the three styles, an alignment and a
    /// highlight, and no size — so the section header says whose size it is,
    /// and the menu is the same one the View menu's Text Size section steps.
    private var sizeMenu: some View {
        chipMenu(title: "\(settings.fontSizeLabel) pt",
                 accessibilityLabel: "Script text size",
                 accessibilityValue: "\(settings.fontSizeLabel) points") {
            Section("Script Text Size") {
                ForEach(PresentationSettings.fontSizePresets, id: \.self) { size in
                    sizeOption(size)
                }

                // Last, and named for what it opens rather than for what it
                // sets: the presets cover the sizes anyone asks for by name,
                // and this is for the writer who knows the number they want.
                Button("Custom Size…") {
                    sizeText = settings.fontSizeLabel
                    isEnteringSize = true
                }
            }
        }
    }

    @ViewBuilder
    private func sizeOption(_ points: Double) -> some View {
        Button {
            settings.fontSizePt = points
        } label: {
            let label = "\(PresentationSettings.fontSizeLabel(points)) pt"
            if settings.isSetIn(fontSizePt: points) {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    // MARK: - Chips

    /// A menu dressed as one of the bar's capsules. Shared by the typeface and
    /// the size so the two read as one pair of controls rather than as two
    /// separately-built ones.
    private func chipMenu<Content: View>(
        title: String,
        accessibilityLabel: String,
        accessibilityValue: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 4) {
                Text(title)
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
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
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
                .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? Color.white : Color.primary)
        .background(Capsule().fill(isOn ? Color.accentColor : Color.clear))
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}
