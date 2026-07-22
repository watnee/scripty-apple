//
//  KeyboardShortcutsView.swift
//  scripty
//
//  The keyboard reference the web app keeps at /shortcuts.
//
//  Worth having on a touch device because this one is not only a touch device:
//  an iPad with a keyboard attached, or a Mac, answers to nearly all of it, and
//  a writer who has just moved over from the browser will otherwise go on
//  pressing the browser's keys and finding nothing happens.
//
//  Each group leads with when it applies. A key that only works while the caret
//  is inside an element is a different promise from one that works anywhere,
//  and a table of keys with no such column is how a reference starts lying.
//

import SwiftUI

struct KeyboardShortcutsView: View {
    @State private var query = ""

    private var groups: [ShortcutGroup] { ShortcutGroup.groups(matching: query) }

    var body: some View {
        content
            .navigationTitle("Keyboard Shortcuts")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search shortcuts")
    }

    @ViewBuilder
    private var content: some View {
        if groups.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            ShortcutRow(entry: entry)
                        }
                    } header: {
                        Label(group.title, systemImage: group.systemImage)
                    } footer: {
                        // The context always shows; the note is the extra
                        // sentence only some groups have earned.
                        Text([group.context, group.note].compactMap { $0 }.joined(separator: " "))
                    }
                }
            }
        }
    }
}

private struct ShortcutRow: View {
    let entry: ShortcutEntry

    var body: some View {
        // Keys to the trailing edge and wrapping under the description, because
        // the descriptions vary in length and a key column that shifted with
        // them would be no column at all.
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(entry.action)
                Spacer(minLength: 12)
                keys
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.action)
                keys
            }
        }
    }

    private var keys: some View {
        HStack(spacing: 6) {
            ForEach(Array(entry.keys.enumerated()), id: \.offset) { index, key in
                if index > 0 {
                    Text("or")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(key)
                    .font(.callout.monospaced())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }
}
