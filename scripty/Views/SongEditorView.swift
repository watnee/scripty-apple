//
//  SongEditorView.swift
//  scripty
//
//  Title + content editor for a song or note. List rows carry only a preview,
//  so an existing document's full content is fetched when the sheet opens.
//  Read-only when the server didn't advertise an `update` link.
//

import SwiftUI

struct SongEditorView: View {
    let model: ScriptModel
    let document: TextDocument?   // nil = create
    let type: DocumentType

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var content: String
    @State private var isSaving = false
    @State private var isLoading = false
    @State private var didLoad = false
    @State private var errorMessage: String?
    /// The formatting bar's handle on the text view.
    @State private var formatting = NoteEditorController()

    private let settings = PresentationSettings.shared

    init(model: ScriptModel, document: TextDocument?, type: DocumentType) {
        self.model = model
        self.document = document
        self.type = type
        _title = State(initialValue: document?.title ?? "")
        _content = State(initialValue: document?.content ?? "")
    }

    private var isNew: Bool { document == nil }
    private var canEdit: Bool { document?.hasLink(.update) ?? true }
    private var canSave: Bool {
        canEdit && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    private var navTitle: String {
        if isNew { return type == .song ? "New Song" : "New Note" }
        return canEdit ? "Edit \(type.label)" : type.label
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                        .font(.headline)
                        .disabled(!canEdit)
                }
                Section(type == .song ? "Lyrics" : "Notes") {
                    // Notes get the list and heading controls; lyrics take the
                    // same keyboard rules but not the bar, which is the split
                    // the browser makes too.
                    if type != .song && canEdit {
                        NoteFormatBar(controller: formatting)
                            .listRowSeparator(.hidden)
                    }
                    NoteTextView(text: $content,
                                 controller: formatting,
                                 isEditable: canEdit,
                                 spellChecks: settings.isSpellcheckEnabled)
                        .frame(minHeight: 260)
                        .overlay(alignment: .topLeading) {
                            if content.isEmpty {
                                Text(type == .song
                                     ? "Write the lyrics here…"
                                     : "Write your notes here…")
                                    .foregroundStyle(.tertiary)
                                    .allowsHitTesting(false)
                            }
                        }
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .overlay {
                if isLoading { ProgressView() }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(canEdit ? "Cancel" : "Done") { dismiss() }
                }
                if canEdit {
                    ToolbarItem(placement: .confirmationAction) {
                        if isSaving {
                            ProgressView()
                        } else {
                            Button("Save") { save() }
                                .disabled(!canSave)
                        }
                    }
                }
            }
            .task { await loadFullContentIfNeeded() }
        }
    }

    /// The list only has a preview, so pull the full document once on open.
    private func loadFullContentIfNeeded() async {
        guard let document, !didLoad else { return }
        didLoad = true
        isLoading = true
        defer { isLoading = false }
        if let full = await model.fetchDocument(document) {
            title = full.title ?? title
            content = full.content ?? ""
        }
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        errorMessage = nil
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let succeeded: Bool
            if let document {
                succeeded = await model.updateDocument(document, title: trimmedTitle, content: content)
            } else {
                succeeded = await model.createDocument(title: trimmedTitle, content: content, type: type) != nil
            }
            isSaving = false
            if succeeded {
                dismiss()
            } else {
                errorMessage = model.errorMessage ?? "Could not save. Please try again."
            }
        }
    }
}
