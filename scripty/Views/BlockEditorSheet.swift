//
//  BlockEditorSheet.swift
//  scripty
//
//  The details behind one block — the speaker it's attached to, its tags, its
//  bookmark and pin. Content and element type are handled on the page itself,
//  where the writing happens; this is for the things that have no place there.
//

import SwiftUI

struct BlockEditorSheet: View {
    let model: ScriptModel
    let block: Block

    @Environment(\.dismiss) private var dismiss
    @State private var content: String
    @State private var personId: Int?
    @State private var tags: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(model: ScriptModel, block: Block) {
        self.model = model
        self.block = block
        _content = State(initialValue: block.content ?? "")
        _personId = State(initialValue: block.personId)
        _tags = State(initialValue: block.tags ?? "")
    }

    private var type: BlockType { block.blockType }

    private var showsCharacterPicker: Bool {
        (type == .dialogue || type.isCharacterCue) && !model.characters.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Type", value: type.label)

                Section(type.isCharacterCue ? "Speaker Name" : "Content") {
                    TextEditor(text: $content)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 140)
                }

                if showsCharacterPicker {
                    Picker("Character", selection: $personId) {
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

                togglesSection

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
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
            // Hold sync refreshes off while the sheet is open, the way the caret
            // does while typing on the page.
            .onAppear { model.hasActiveEdit = true }
            .onDisappear { model.hasActiveEdit = false }
        }
    }

    @ViewBuilder
    private var togglesSection: some View {
        let canBookmark = block.hasLink(.toggleBookmark)
        let canPin = block.hasLink(.togglePinned)
        if canBookmark || canPin {
            Section {
                if canBookmark {
                    Button {
                        Task { await model.toggleBookmark(block) }
                        dismiss()
                    } label: {
                        Label(block.isBookmarked ? "Remove Bookmark" : "Bookmark",
                              systemImage: block.isBookmarked ? "bookmark.slash" : "bookmark")
                    }
                }
                if canPin {
                    Button {
                        Task { await model.togglePinned(block) }
                        dismiss()
                    } label: {
                        Label(block.isPinned ? "Unpin" : "Pin",
                              systemImage: block.isPinned ? "pin.slash" : "pin")
                    }
                }
            }
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        let trimmedTags = tags.trimmingCharacters(in: .whitespaces)
        Task {
            let succeeded = await model.updateBlock(
                block,
                content: content,
                personId: showsCharacterPicker ? personId : block.personId,
                tags: trimmedTags.isEmpty ? nil : trimmedTags)
            isSaving = false
            if succeeded {
                dismiss()
            } else {
                errorMessage = model.errorMessage
            }
        }
    }
}
