//
//  HelpView.swift
//  scripty
//
//  The help centre — the web app's searchable card grid, as a list.
//
//  The web page puts its four categories behind tabs and reveals a separate
//  results pane while you search. That is two ways of showing the same cards,
//  and the second exists only because the first hides most of them. A sectioned
//  list has no such problem: the categories are all on screen at once, and
//  searching narrows what is already there rather than replacing it.
//
//  Topics are collapsed to their headings so the whole map fits on a screen,
//  and a search opens every match — a result you still have to tap open is
//  barely a result. What a search finds is ordered by how well it answers
//  (see `HelpSearch.swift`) and has the reader's own words picked out of it,
//  because the longest topics here run to fourteen paragraphs and opening one
//  unmarked is a wall of prose, not an answer.
//
//  The keyboard reference is searched alongside the topics. "How do I bold
//  this" is a help question whose answer is a chord, and leaving it in a
//  separate room the reader has to think to walk into is how it went unfound.
//

import SwiftUI

/// Whichever help screen was asked for, with the sheet chrome both share.
///
/// The two are one presentation rather than two so that the shortcut reference
/// can be reached from inside help by pushing it, instead of by closing one
/// sheet and opening another on top of the space it left.
struct HelpSheet: View {
    let screen: HelpPresentation.Screen

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch screen {
                case .help: HelpView()
                case .shortcuts: KeyboardShortcutsView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct HelpView: View {
    @State private var query = ""
    /// Which topics the reader has opened by hand. A search opens its matches
    /// without touching this, so leaving the search puts the list back the way
    /// they arranged it.
    @State private var expanded: Set<String> = []

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        content
            .navigationTitle("Scripty Help")
            .navigationBarTitleDisplayMode(.inline)
            // Pinned rather than hidden above the first row. A help centre is
            // a screen people arrive at with a question already in mind, and a
            // search field you have to know to drag down for is one most of
            // them never find — they scroll thirty-seven headings instead.
            .searchable(text: $query,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search help")
    }

    @ViewBuilder
    private var content: some View {
        // Once per body. Each of these walks the whole help centre, and a
        // computed property read four times down a view builder walks it four
        // times — per keystroke.
        let results = HelpTopic.results(for: query)
        let typed = HelpQuery(query)
        let shortcuts = matchingShortcuts(typed)

        if results.isEmpty && shortcuts.isEmpty {
            noResults
        } else {
            List {
                if results.isPartial {
                    // Its own section, or it is one anyway — a bare row in an
                    // inset list becomes one — with the full gap after it,
                    // which reads as a section whose contents failed to load.
                    Section { partialNote }
                        .listSectionSpacing(.compact)
                }

                ForEach(results.sections) { section in
                    Section(section.title) {
                        ForEach(section.topics) { topic in
                            HelpTopicRow(topic: topic,
                                         query: typed,
                                         isExpanded: binding(for: topic))
                        }
                    }
                }

                shortcutSection(shortcuts, query: typed)
            }
        }
    }

    /// A dead end is still a dead end if the reference is behind it. Both ways
    /// on stay reachable: back to the whole map, or over to the keys.
    private var noResults: some View {
        ContentUnavailableView {
            Label("No Results", systemImage: "magnifyingglass")
        } description: {
            Text("Nothing in help matches \u{201C}\(query)\u{201D}.")
        } actions: {
            Button("Clear Search") { query = "" }
            NavigationLink("Keyboard Shortcuts") { KeyboardShortcutsView() }
        }
    }

    /// Said before the results rather than after, because a reader who takes
    /// the first row as an answer to what they asked will never reach a footer.
    private var partialNote: some View {
        Text("Nothing matches all of those words. These match some of them.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private func shortcutSection(_ hits: [ShortcutHit], query: HelpQuery) -> some View {
        Section {
            ForEach(hits) { hit in
                ShortcutHitRow(hit: hit, query: query)
            }
            NavigationLink {
                KeyboardShortcutsView()
            } label: {
                Label(hits.isEmpty ? "Keyboard Shortcuts" : "All Keyboard Shortcuts",
                      systemImage: "keyboard")
            }
        } header: {
            if !hits.isEmpty { Text("Keyboard Shortcuts") }
        } footer: {
            Text("Every key this app answers to, on the Mac and on an iPad "
                 + "with a keyboard attached.")
        }
    }

    /// The chords worth putting in front of a help query.
    ///
    /// Matched row by row, and by the rule the topics are matched by — not
    /// through `ShortcutGroup.groups(matching:)`. That one hands back a whole
    /// group when the group's *title* matches, which is right when the
    /// reference itself is the screen and wrong here: `song` would answer a
    /// help question with the first six rows of the Songs group, whatever they
    /// happened to be about.
    ///
    /// Two characters at least, since a single letter begins a great many
    /// actions. Capped, too — the point is to answer in passing, and past a
    /// handful of rows the reference is the better screen.
    private func matchingShortcuts(_ query: HelpQuery) -> [ShortcutHit] {
        guard query.words.contains(where: { $0.count >= 2 }) else { return [] }
        let hits = ShortcutGroup.groups.flatMap { group in
            group.entries
                .filter { query.matches($0.action) }
                .map { ShortcutHit(group: group, entry: $0) }
        }
        return Array(hits.prefix(6))
    }

    /// Open while it matches a search, and otherwise however the reader left it.
    private func binding(for topic: HelpTopic) -> Binding<Bool> {
        Binding(
            get: { isSearching || expanded.contains(topic.id) },
            set: { isOpen in
                if isOpen {
                    expanded.insert(topic.id)
                } else {
                    expanded.remove(topic.id)
                }
            })
    }
}

/// One row of the reference, kept with the group it came from.
///
/// The group has to travel with it for two reasons: Move Up is a row in three
/// different groups and they would otherwise collide on `ShortcutEntry`'s id,
/// and a chord with no situation named beside it is the kind of promise the
/// reference exists not to make.
private struct ShortcutHit: Identifiable {
    let group: ShortcutGroup
    let entry: ShortcutEntry

    var id: String { "\(group.id)/\(entry.action)" }
}

private struct ShortcutHitRow: View {
    let hit: ShortcutHit
    let query: HelpQuery

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(query.highlighting(hit.entry.action))
                Text(hit.group.context)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            ForEach(Array(hit.entry.keys.enumerated()), id: \.offset) { index, key in
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

private struct HelpTopicRow: View {
    let topic: HelpTopic
    let query: HelpQuery
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(topic.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(query.highlighting(paragraph))
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
        } label: {
            Label {
                Text(query.highlighting(topic.title))
            } icon: {
                Image(systemName: topic.systemImage)
            }
            .font(.headline)
        }
    }
}

extension HelpQuery {
    /// `text` with the words this query matched picked out of it.
    ///
    /// Weight and full-strength colour rather than a wash: the paragraphs are
    /// secondary text, so a matched word coming forward to primary is legible
    /// in both themes and survives Increase Contrast, which a tinted
    /// background behind grey text does not.
    func highlighting(_ text: String) -> AttributedString {
        let ranges = matchRanges(in: text)
        guard !ranges.isEmpty else { return AttributedString(text) }

        // Built by running along the string rather than by indexing into a
        // finished AttributedString: the two index spaces are not the same
        // one, and converting between them is the sort of thing that works
        // until a paragraph contains an emoji or a composed accent.
        var result = AttributedString()
        var cursor = text.startIndex
        for range in ranges {
            if cursor < range.lowerBound {
                result += AttributedString(String(text[cursor..<range.lowerBound]))
            }
            var hit = AttributedString(String(text[range]))
            hit.foregroundColor = .primary
            hit.inlinePresentationIntent = .stronglyEmphasized
            result += hit
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            result += AttributedString(String(text[cursor...]))
        }
        return result
    }
}
