//
//  AutocompleteBar.swift
//  scripty
//
//  Completions for the focused element, as a row of chips above the format bar.
//
//  The web app draws a dropdown under the caret and drives it with ↑/↓/Enter/
//  Tab. That does not transplant: on iPad a caret-anchored popover fights the
//  software keyboard for the same strip of screen, and all four of those keys
//  already mean something here — Return splits the element, Tab cycles its
//  type. Rebinding them only while the list happens to be open would make the
//  two most load-bearing keys in the editor conditional, which is a bad trade
//  for a shortcut. So the chips are tapped, and they live in the bar stack the
//  writer is already looking at.
//
//  Nothing here is gated on a link: completion reads the script already in
//  memory and writes through the element's own `update`, which the format bar
//  above it has already established.
//

import SwiftUI

struct AutocompleteBar: View {
    let suggestions: [ScriptAutocomplete.Suggestion]
    let accept: (ScriptAutocomplete.Suggestion) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions) { suggestion in
                    Button {
                        accept(suggestion)
                    } label: {
                        Text(suggestion.label)
                            .font(.footnote.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    .accessibilityLabel("Complete as \(suggestion.label)")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}
