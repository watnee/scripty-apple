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
//  barely a result.
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

    private var sections: [HelpSection] { HelpTopic.sections(matching: query) }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        content
            .navigationTitle("Scripty Help")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search help")
    }

    @ViewBuilder
    private var content: some View {
        if sections.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List {
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.topics) { topic in
                            HelpTopicRow(topic: topic, isExpanded: binding(for: topic))
                        }
                    }
                }

                Section {
                    NavigationLink {
                        KeyboardShortcutsView()
                    } label: {
                        Label("Keyboard Shortcuts", systemImage: "keyboard")
                    }
                } footer: {
                    Text("Every key this app answers to, on the Mac and on an iPad "
                         + "with a keyboard attached.")
                }
            }
        }
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

private struct HelpTopicRow: View {
    let topic: HelpTopic
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(topic.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
        } label: {
            Label(topic.title, systemImage: topic.systemImage)
                .font(.headline)
        }
    }
}
