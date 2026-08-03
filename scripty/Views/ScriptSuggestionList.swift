//
//  ScriptSuggestionList.swift
//  scripty
//
//  The completions offered under the line being typed: the cast for a cue, and
//  the script's own headings, locations and times of day for a scene.
//
//  Deliberately not the keyboard's own suggestion bar. These are answers about
//  *this screenplay* — who is in it and where it has been — so they belong next
//  to the words they would replace, where the writer can see what they are
//  choosing between, rather than in a strip that also holds the dictionary's
//  guesses.
//

import SwiftUI

struct ScriptSuggestionList: View {
    let autocomplete: ScriptAutocomplete
    let onAccept: (ScriptSuggestion) -> Void

    /// The would-become-a tag's size, following the OS text setting.
    @ScaledMetric(relativeTo: .caption2) private var tagSize: CGFloat = 9

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(autocomplete.suggestions.enumerated()), id: \.element.id) { index, item in
                row(item, at: index)
                if index < autocomplete.suggestions.count - 1 {
                    Divider().padding(.leading, 10)
                }
            }
        }
        .frame(maxWidth: 320, alignment: .leading)
        // Clipped before the material goes on, so the highlight behind the
        // selected row follows the rounded corner instead of squaring it off.
        .clipShape(.rect(cornerRadius: 12))
        // Liquid Glass: the list hangs over the line being typed, so the words
        // underneath stay readable through it rather than being covered by an
        // opaque panel. The material draws its own edge and shadow.
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .padding(.top, 2)
        // One list, read as one thing: VoiceOver users reach the same names
        // from the cast list, so this is a shortcut rather than the only route.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggestions")
    }

    private func row(_ item: ScriptSuggestion, at index: Int) -> some View {
        Button {
            onAccept(item)
        } label: {
            HStack(spacing: 6) {
                Text(item.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                // Says that accepting this also changes what kind of line it
                // is — otherwise the retype looks like the app second-guessing.
                if let becomes = item.becomesType {
                    // Scaled, not an absolute 9pt: a fixed point size ignores
                    // the OS text setting entirely, so this tag stayed 9pt at
                    // every accessibility size while the suggestion beside it
                    // grew. Nothing is laid out against its width, so unlike
                    // the script's element labels it can simply scale.
                    Text(becomes.label.uppercased())
                        .font(.system(size: tagSize, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(index == autocomplete.selectedIndex
                        ? AnyShapeStyle(.tint.opacity(0.15))
                        : AnyShapeStyle(.clear))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(index == autocomplete.selectedIndex ? [.isSelected] : [])
    }
}
