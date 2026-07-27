//
//  SongEditorView.swift
//  scripty
//
//  Title + content editor for a note, and for a song the server has no lyric
//  lines for. List rows carry only a preview, so an existing document's full
//  content is fetched when the sheet opens. Read-only when the server didn't
//  advertise an `update` link.
//
//  The writing surface is the whole sheet below the title rather than a row in
//  a Form. A note is prose — often pages of it — and the form put it in a fixed
//  260-point box that scrolled inside the form's own scroll view: two nested
//  scrollers fighting over one drag, and a text view too short to hold a
//  paragraph. What sits around it now is only chrome that earns its place: the
//  formatting bar while the caret is in the note, and the same word-count
//  readout the screenplay and lyric editors show under the same preference.
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
    /// Whether the caret is in the note itself, so the formatting bar shows
    /// only when there is a line under the caret for it to act on — pressing
    /// "H1" while the title field has focus would silently head a line the
    /// writer cannot see.
    @State private var isWritingBody = false
    @State private var confirmingDiscard = false
    /// The formatting bar's handle on the text view.
    @State private var formatting = NoteEditorController()
    @FocusState private var titleFocused: Bool

    /// What was on screen when the document finished loading. Anything typed
    /// after that is the work a discard would throw away.
    @State private var savedTitle: String
    @State private var savedContent: String

    private let settings = PresentationSettings.shared

    init(model: ScriptModel, document: TextDocument?, type: DocumentType) {
        self.model = model
        self.document = document
        self.type = type
        let title = document?.title ?? ""
        let content = document?.content ?? ""
        _title = State(initialValue: title)
        _content = State(initialValue: content)
        _savedTitle = State(initialValue: title)
        _savedContent = State(initialValue: content)
    }

    private var isNew: Bool { document == nil }
    private var canEdit: Bool { document?.hasLink(.update) ?? true }
    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var canSave: Bool { canEdit && !trimmedTitle.isEmpty && !isSaving }

    /// Whether leaving now would lose something. A brand-new document counts as
    /// changed the moment anything is typed into it — there is nothing on the
    /// server yet for it to match.
    private var hasUnsavedChanges: Bool {
        canEdit && !isLoading && (title != savedTitle || content != savedContent)
    }

    /// Notes get the list and heading controls; lyrics take the same keyboard
    /// rules but not the bar, which is the split the browser makes too.
    private var showsFormatBar: Bool { type != .song && canEdit }

    private var navTitle: String {
        if isNew { return type == .song ? "New Song" : "New Note" }
        return canEdit ? "Edit \(type.label)" : type.label
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                titleField
                Divider()
                editor
            }
            .overlay {
                if isLoading { ProgressView() }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .task { await loadFullContentIfNeeded() }
            // A sheet dragged away takes the note with it, and unlike Cancel it
            // gives no chance to say so — so while there is something to lose,
            // the drag is turned off and Cancel is the only way out.
            .interactiveDismissDisabled(hasUnsavedChanges)
            .confirmationDialog("Discard changes?",
                                isPresented: $confirmingDiscard,
                                titleVisibility: .visible) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text(isNew
                     ? "This \(type == .song ? "song" : "note") has not been saved yet."
                     : "Your edits since opening will be lost.")
            }
        }
    }

    // MARK: - Surfaces

    private var titleField: some View {
        TextField(type == .song ? "Song title" : "Note title", text: $title)
            .font(.title3.weight(.semibold))
            .textInputAutocapitalization(.words)
            .submitLabel(.next)
            .focused($titleFocused)
            // Return in the title means "on with it", not a line break — there
            // is nowhere else for the caret to go.
            .onSubmit { formatting.focus() }
            .disabled(!canEdit)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .accessibilityLabel("Title")
    }

    private var editor: some View {
        NoteTextView(text: $content,
                     controller: formatting,
                     isEditable: canEdit,
                     spellChecks: settings.isSpellcheckEnabled,
                     textScale: settings.textScale,
                     placeholder: placeholder,
                     onFocusChange: { isWritingBody = $0 })
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(type == .song ? "Lyrics" : "Notes")
    }

    private var placeholder: String {
        if !canEdit { return "" }   // nothing to invite; this note is read-only
        return type == .song ? "Write the lyrics here…" : "Write your notes here…"
    }

    /// Under the note: what went wrong, how long it is, and the formatting bar
    /// riding above the keyboard. Stacked in that order so the bar sits closest
    /// to the writer's thumbs and the readout stays put above it.
    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 0) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
            if settings.showsWordCount {
                WordCountBar(words: ScriptStats.countWords(content))
            }
            if showsFormatBar && isWritingBody {
                NoteFormatBar(controller: formatting)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(canEdit ? "Cancel" : "Done") {
                if hasUnsavedChanges {
                    confirmingDiscard = true
                } else {
                    dismiss()
                }
            }
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
        ToolbarItem(placement: .secondaryAction) {
            Toggle(isOn: wordCountBinding) {
                Label("Word Count", systemImage: "number")
            }
        }
        // The same device-wide type size the lyric and screenplay editors set.
        // Notes already read it; until now nothing on this screen could change
        // it, so a writer who had sized the script up found their notes still
        // at 100%.
        ToolbarItem(placement: .secondaryAction) {
            Menu {
                Button {
                    settings.increaseTextSize()
                } label: {
                    Label("Bigger", systemImage: "textformat.size.larger")
                }
                .disabled(!settings.canIncreaseTextSize)

                Button {
                    settings.decreaseTextSize()
                } label: {
                    Label("Smaller", systemImage: "textformat.size.smaller")
                }
                .disabled(!settings.canDecreaseTextSize)

                Button {
                    settings.resetTextSize()
                } label: {
                    Label("Actual Size (\(settings.textSize)%)", systemImage: "textformat")
                }
                .disabled(settings.textSize == PresentationSettings.defaultTextSize)
            } label: {
                Label("Text Size", systemImage: "textformat.size")
            }
        }
    }

    private var wordCountBinding: Binding<Bool> {
        Binding(get: { settings.showsWordCount }, set: { settings.showsWordCount = $0 })
    }

    // MARK: - Actions

    /// The list only has a preview, so pull the full document once on open.
    private func loadFullContentIfNeeded() async {
        guard let document else {
            // A new one opens with the caret in the title, which is the only
            // field that has to be filled in for it to be saveable.
            titleFocused = canEdit
            return
        }
        guard !didLoad else { return }
        didLoad = true
        isLoading = true
        defer { isLoading = false }
        if let full = await model.fetchDocument(document) {
            title = full.title ?? title
            content = full.content ?? ""
        }
        // Whatever landed is the baseline — including a load that failed and
        // left what the list row already had, since that is still what the
        // server holds.
        savedTitle = title
        savedContent = content
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        errorMessage = nil
        let title = trimmedTitle
        Task {
            let succeeded: Bool
            if let document {
                succeeded = await model.updateDocument(document, title: title, content: content)
            } else {
                succeeded = await model.createDocument(title: title, content: content, type: type) != nil
            }
            isSaving = false
            if succeeded {
                // Cleared before dismissing so the discard prompt cannot fire
                // on the way out over work that has just been saved.
                savedTitle = self.title
                savedContent = content
                dismiss()
            } else {
                errorMessage = model.errorMessage ?? "Could not save. Please try again."
            }
        }
    }
}
