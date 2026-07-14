//
//  BlockDetailsSheet.swift
//  scripty
//
//  The parts of a block that are not its text. Content is typed straight into
//  the page (see ScriptView), and the element type is Tab or the element bar —
//  what is left is who is speaking and how the block is tagged.
//

import SwiftUI

struct BlockDetailsSheet: View {
    let model: ScriptModel
    let block: Block

    @Environment(\.dismiss) private var dismiss
    @State private var personId: Int?
    @State private var tags: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(model: ScriptModel, block: Block) {
        self.model = model
        self.block = block
        _personId = State(initialValue: block.personId)
        _tags = State(initialValue: block.tags ?? "")
    }

    /// Only dialogue and cues have a speaker.
    private var showsSpeaker: Bool {
        (block.blockType == .dialogue
            || block.blockType == .parenthetical
            || block.blockType.isCharacterCue)
            && !model.characters.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Element", value: block.blockType.label)

                if showsSpeaker {
                    Picker("Speaker", selection: $personId) {
                        Text("None").tag(Int?.none)
                        ForEach(model.characters) { person in
                            Text(person.displayName).tag(Int?.some(person.id))
                        }
                    }
                }

                Section("Tags") {
                    TextField("Comma-separated tags", text: $tags)
                        .textInputAutocapitalization(.never)
                }

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("Block Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        let trimmed = tags.trimmingCharacters(in: .whitespaces)
        Task {
            var succeeded = true
            if showsSpeaker, personId != block.personId {
                succeeded = await model.setSpeaker(block, personId: personId)
            }
            if succeeded, trimmed != (block.tags ?? "") {
                succeeded = await model.setTags(block, tags: trimmed.isEmpty ? nil : trimmed)
            }
            isSaving = false
            if succeeded {
                dismiss()
            } else {
                errorMessage = model.errorMessage
            }
        }
    }
}
