//
//  SpellcheckWordsView.swift
//  scripty
//
//  Everything about spelling in one screen, and the menu that reaches it from
//  the surfaces with no View menu of their own.
//
//  The route in that matters is the editing menu on an underlined word —
//  `SpellcheckEditMenu`, next door. This screen is what that list looks like
//  afterwards: the switch that turns checking off altogether, a way to add a
//  word you already know will be flagged, and the way back for one added by
//  mistake. It says plainly that the list reaches the whole device, because
//  that is not what a writer would assume from a screen inside one app.
//

import SwiftUI

struct SpellcheckWordsView: View {
    @Environment(\.dismiss) private var dismiss
    private let dictionary = SpellcheckDictionary.shared
    private let settings = PresentationSettings.shared

    @State private var newWord = ""
    @State private var notice: Notice?
    @State private var filter = ""
    /// Whether the list came in long enough to need a search field.
    ///
    /// Decided once, when the screen is first made, rather than watched: adding
    /// the ninth word would otherwise rebuild the form around the field being
    /// typed into and drop the keyboard mid-word.
    @State private var isSearchable: Bool

    init() {
        _isSearchable = State(initialValue: SpellcheckDictionary.shared.words.count > 8)
    }

    /// What became of the last word typed in. Worth saying either way: the list
    /// is sorted and long enough that a writer would not spot the entry already
    /// sitting there, and an "Add" that visibly does nothing reads as broken.
    private enum Notice {
        case added(String), alreadyThere(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                if isSearchable {
                    form.searchable(text: $filter, prompt: "Find a word")
                } else {
                    form
                }
            }
            .navigationTitle("Spelling")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var form: some View {
        Form {
            Section {
                Toggle(isOn: spellcheckBinding) {
                    Label("Check Spelling", systemImage: "textformat.abc.dottedunderline")
                }
            } footer: {
                Text("Underlines what this device does not recognise as you write — "
                     + "in screenplays, in lyrics and in notes.")
            }

            Section {
                HStack {
                    TextField("Word", text: $newWord)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(trimmed.isEmpty)
                }
            } header: {
                Text("Add a Word")
            } footer: {
                switch notice {
                case .added(let word):
                    Text("Added \(word).")
                case .alreadyThere(let word):
                    Text("\(word) is already on the list.")
                case nil:
                    Text("Words on this list are added to the dictionary this device "
                         + "checks against, so they stop being flagged in other apps "
                         + "too. Removing one takes it back out.")
                }
            }

            if dictionary.words.isEmpty {
                Section {
                    Text("No ignored words yet. Touch and hold an underlined word while "
                         + "you write and choose Ignore Spelling, or add one above.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(shown, id: \.self) { word in
                        Text(word)
                    }
                    // By word rather than by offset: with a search running, row
                    // three of what is on screen is not word three of the list.
                    .onDelete { offsets in
                        for word in offsets.map({ shown[$0] }) { dictionary.remove(word) }
                    }
                } header: {
                    Text("Ignored (\(dictionary.words.count))")
                } footer: {
                    if shown.isEmpty {
                        Text("No ignored word matches “\(filter)”.")
                    } else {
                        Text("Swipe a word to stop ignoring it.")
                    }
                }
            }
        }
    }

    /// The list, narrowed by the search field.
    private var shown: [String] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return dictionary.words }
        return dictionary.words.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var trimmed: String {
        newWord.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var spellcheckBinding: Binding<Bool> {
        Binding(get: { settings.isSpellcheckEnabled },
                set: { settings.isSpellcheckEnabled = $0 })
    }

    private func add() {
        let word = trimmed
        guard !word.isEmpty else { return }
        notice = dictionary.add(word) ? .added(word.uppercased()) : .alreadyThere(word.uppercased())
        newWord = ""
        // A word just added has to be visible, and a search left running from
        // last time would be the one thing hiding it.
        filter = ""
    }
}

/// The spelling controls as a toolbar menu, for the surfaces with no View menu
/// to put them in: the song editor, the all-songs workspace and the note sheet.
///
/// Until this, every one of them honoured the preference and none of them could
/// change it — a writer whose lyrics were a field of red squiggles had to leave
/// the song, open a screenplay and turn checking off from there.
///
/// The sheet is presented by the host, not from in here: a `.sheet` attached
/// inside a toolbar item is not reliably in the hierarchy that would present it.
struct SpellingMenu: View {
    @Binding var showingIgnoredWords: Bool

    private let settings = PresentationSettings.shared

    var body: some View {
        Menu {
            Toggle(isOn: spellcheckBinding) {
                Label("Check Spelling", systemImage: "textformat.abc.dottedunderline")
            }
            Button {
                showingIgnoredWords = true
            } label: {
                Label("Ignored Words…", systemImage: "character.book.closed")
            }
        } label: {
            Label("Spelling", systemImage: "textformat.abc.dottedunderline")
        }
    }

    private var spellcheckBinding: Binding<Bool> {
        Binding(get: { settings.isSpellcheckEnabled },
                set: { settings.isSpellcheckEnabled = $0 })
    }
}
