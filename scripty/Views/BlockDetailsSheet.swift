//
//  BlockDetailsSheet.swift
//  scripty
//
//  The metadata behind one block: its element type, the character speaking
//  it, tags, and the bookmark/pin flags. Content is normally typed in place
//  in the script — it is offered here too for the long ones.
//
//  Retyping goes through `setType`, which carries content, speaker and tags
//  with it, so a type change plus an edit is a single request.
//

import SwiftUI

struct BlockDetailsSheet: View {
    let model: ScriptModel
    let block: Block

    @Environment(\.dismiss) private var dismiss
    @State private var content: String
    @State private var type: BlockType
    @State private var personId: Int?
    @State private var tags: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(model: ScriptModel, block: Block) {
        self.model = model
        self.block = block
        _content = State(initialValue: block.content ?? "")
        _type = State(initialValue: block.blockType)
        _personId = State(initialValue: block.personId)
        _tags = State(initialValue: block.tags ?? "")
    }

    private var canSetType: Bool { block.hasLink(.setType) }

    private var showsCharacterPicker: Bool {
        (type == .dialogue || type.isCharacterCue) && !model.characters.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if canSetType {
                    Picker("Type", selection: $type) {
                        ForEach(BlockType.allCases) { blockType in
                            Text(blockType.label).tag(blockType)
                        }
                    }
                } else {
                    LabeledContent("Type", value: type.label)
                }

                Section(type.isCharacterCue ? "Speaker Name" : "Content") {
                    TextEditor(text: $content)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120)
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

        // Empty (rather than nil) clears the tags: the server preserves any
        // field sent as null.
        let newTags = tags.trimmingCharacters(in: .whitespaces)
        let speaker = showsCharacterPicker ? personId : block.personId

        Task {
            let succeeded: Bool
            if type != block.blockType, canSetType {
                // setType carries the rest of the edit with it.
                succeeded = await model.setType(block, to: type, content: content,
                                                personId: speaker, tags: newTags)
            } else {
                succeeded = await model.updateBlock(block, content: content,
                                                    personId: speaker, tags: newTags)
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
