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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .shadow(radius: 8, y: 2)
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
                    Text(becomes.label.uppercased())
                        .font(.system(size: 9, weight: .semibold))
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
