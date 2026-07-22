//
//  SpellcheckWordsView.swift
//  scripty
//
//  The list of words Scripty should stop underlining, and the way to add to it.
//
//  The browser's route in is its own suggestion popup; the system checker has
//  no equivalent hook, so this screen is the route here. It says plainly that
//  the list reaches the whole device, because that is not what a writer would
//  assume from a screen inside one app.
//

import SwiftUI

struct SpellcheckWordsView: View {
    @Environment(\.dismiss) private var dismiss
    private let dictionary = SpellcheckDictionary.shared

    @State private var newWord = ""
    @State private var duplicate: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("Word", text: $newWord)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit(add)
                        Button("Add", action: add)
                            .disabled(trimmed.isEmpty)
                    }
                } footer: {
                    if let duplicate {
                        Text("\(duplicate) is already on the list.")
                    } else {
                        Text("Words on this list are added to the dictionary this "
                             + "device checks against, so they stop being flagged "
                             + "in other apps too. Removing one takes it back out.")
                    }
                }

                if dictionary.words.isEmpty {
                    Section {
                        Text("No words yet.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Ignored") {
                        ForEach(dictionary.words, id: \.self) { word in
                            Text(word)
                        }
                        .onDelete { dictionary.remove(atOffsets: $0) }
                    }
                }
            }
            .navigationTitle("Ignored Words")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var trimmed: String {
        newWord.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func add() {
        let word = trimmed
        guard !word.isEmpty else { return }
        // Saying so beats silently swallowing it — the list is sorted and long
        // enough that the writer would not spot the entry already there.
        duplicate = dictionary.add(word) ? nil : word.uppercased()
        newWord = ""
    }
}
