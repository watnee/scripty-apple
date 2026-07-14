//
//  BlockEditorSheet.swift
//  scripty
//
//  Create or edit a screenplay block. The API only allows choosing the
//  element type at creation time; editing changes content, the linked
//  character, and tags.
//

import SwiftUI

struct BlockEditorSheet: View {
    let model: ScriptModel
    let block: Block?   // nil = create a new block

    @Environment(\.dismiss) private var dismiss
    @State private var content: String
    @State private var type: BlockType
    @State private var personId: Int?
    @State private var tags: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var contentFocused: Bool

    init(model: ScriptModel, block: Block?) {
        self.model = model
        self.block = block
        _content = State(initialValue: block?.content ?? "")
        _type = State(initialValue: block?.blockType ?? .action)
        _personId = State(initialValue: block?.personId)
        _tags = State(initialValue: block?.tags ?? "")
    }

    private var isCreating: Bool { block == nil }

    private var showsCharacterPicker: Bool {
        (type == .dialogue || type.isCharacterCue) && !model.characters.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if isCreating {
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
                        .frame(minHeight: 140)
                        .focused($contentFocused)
                }

                if showsCharacterPicker {
                    Picker("Character", selection: $personId) {
                        Text("None").tag(Int?.none)
                        ForEach(model.characters) { person in
                            Text(person.displayName).tag(Int?.some(person.id))
                        }
                    }
                }

                if !isCreating {
                    Section("Tags") {
                        TextField("Comma-separated tags", text: $tags)
                            .textInputAutocapitalization(.never)
                    }
                }

                if let block {
                    togglesSection(for: block)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(isCreating ? "New Block" : "Edit Block")
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
                            .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .onAppear {
                model.hasActiveEdit = true
                contentFocused = true
            }
            .onDisappear { model.hasActiveEdit = false }
        }
    }

    @ViewBuilder
    private func togglesSection(for block: Block) -> some View {
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
            let succeeded: Bool
            if let block {
                succeeded = await model.updateBlock(
                    block,
                    content: content,
                    personId: showsCharacterPicker ? personId : block.personId,
                    tags: trimmedTags.isEmpty ? nil : trimmedTags)
            } else {
                succeeded = await model.createBlock(
                    content: content,
                    type: type,
                    personId: showsCharacterPicker ? personId : nil)
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
