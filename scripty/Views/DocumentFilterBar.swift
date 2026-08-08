//
//  DocumentFilterBar.swift
//  scripty
//
//  The find field the song editor and both workspaces raise from a toolbar
//  button, rather than the standing bar `.searchable` draws.
//
//  `.searchable` is right on a list a writer arrives at to look something up —
//  the projects sidebar, the songs list, the help centre. It is wrong on a
//  surface opened to write on: inside a `fullScreenCover` it draws a full-width
//  bar across the foot of every opening, `.searchToolbarBehavior(.minimize)`
//  collapses a toolbar field only outside one, and the band it takes is a line
//  of the lyric on a screen whose whole point is how many lines fit. Searching
//  there is the rare errand, not the ordinary state.
//
//  So the surfaces that write keep the errand in the toolbar and this bar
//  underneath, raised by the button and by ⌘F, and taken down again by Done —
//  which empties the query on the way out, because a filter left standing behind
//  a hidden bar is a page with rows missing and nothing on screen to say why.
//

import SwiftUI

/// Find-as-filter, presented as a bar above the keyboard the way the
/// screenplay's search is — but narrowing what is listed rather than stepping a
/// cursor through hits, which is how the web narrows the same surfaces.
struct DocumentFilterBar: View {
    @Binding var text: String
    /// What the empty field says it will narrow: lyrics, songs, notes.
    let prompt: String
    /// Called when the writer taps Done; the host hides the bar.
    let onDismiss: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(prompt, text: $text)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($isFocused)
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear Search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            Button("Done") {
                text = ""
                isFocused = false
                onDismiss()
            }
            .font(.body.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // No background of its own: the host mounts it with `.safeAreaBar`,
        // which supplies the Liquid Glass and the separation from the page.
        .onAppear { isFocused = true }
    }
}
