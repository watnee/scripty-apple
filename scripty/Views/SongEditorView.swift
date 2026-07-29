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
//  A note that already exists saves itself as it is written, as it does in the
//  browser. Every other writing surface in this app has worked that way for as
//  long as it has existed — the screenplay debounces each block, a lyric line
//  saves on the way out of it — and this was the one place where an hour of
//  prose lived only in a text view until somebody remembered to press a button.
//  A new note is still saved by hand: it has no title until the writer gives it
//  one, and creating a document behind their back on the first keystroke is a
//  worse surprise than the prompt on the way out.
//

import SwiftUI

struct SongEditorView: View {
    let model: ScriptModel
    let document: TextDocument?   // nil = create
    let type: DocumentType

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var title: String
    @State private var content: String
    @State private var isSaving = false
    @State private var isLoading = false
    @State private var didLoad = false
    @State private var errorMessage: String?
    /// What the writer is told about the saving of an existing note. Nil until
    /// something has been typed, so a note opened and not touched says nothing.
    @State private var saveStatus: SaveStatus?
    /// The armed debounce. Cancelled and replaced on every keystroke, which is
    /// what makes this a save a second after typing stops rather than one per
    /// character — the same shape `SongBlockModel` gives a lyric line.
    @State private var autosave: Task<Void, Never>?
    /// Whether the caret is in the note itself, so the formatting bar shows
    /// only when there is a line under the caret for it to act on — pressing
    /// "H1" while the title field has focus would silently head a line the
    /// writer cannot see.
    @State private var isWritingBody = false
    @State private var confirmingDiscard = false
    /// Set by Discard on the way out, so the parting save knows the words on
    /// screen are not wanted.
    @State private var discarding = false
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

    /// Whether this editor saves as it is written. A document the server will
    /// take an edit for, and that therefore already exists to be edited.
    private var autosaves: Bool { document != nil && canEdit }

    /// How long typing has to stop before the note is sent. The browser waits
    /// 900ms; this waits a little longer because a phone's save is a request
    /// over whatever network it has, not a same-host POST.
    private static let autosaveDelay: Duration = .milliseconds(1200)

    /// Where an autosaving note has got to. Absent while nothing has been
    /// typed, so an untouched note carries no chrome at all.
    private enum SaveStatus: Equatable {
        case saving
        case saved
        /// The save was refused. Sticky: this is the one state the writer has
        /// to see, because it is the one where leaving loses something.
        case failed(String)
    }

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
            .safeAreaBar(edge: .bottom, spacing: 0) { footer }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .task { await loadFullContentIfNeeded() }
            .onChange(of: title) { _, _ in scheduleAutosave() }
            .onChange(of: content) { _, _ in scheduleAutosave() }
            // A phone put down mid-sentence is backgrounded, and a backgrounded
            // app is one the system may end without asking. Don't wait out the
            // debounce for that. The sheet is still here, so this is the
            // ordinary save rather than the parting one below.
            .onChange(of: scenePhase) { _, phase in
                guard phase != .active else { return }
                autosave?.cancel()
                Task { await saveNow() }
            }
            // Covers every other way this sheet goes away: Done, the drag, and
            // the parent view deciding it is finished with it.
            .onDisappear {
                autosave?.cancel()
                flush()
            }
            // A sheet dragged away takes the note with it, and unlike a button
            // it gives no chance to say so. An autosaving note has nothing to
            // lose to the drag — it is already saved, or saving — so the drag
            // is only refused where the words really would go: a note that was
            // never created, and one whose last save the server turned down.
            .interactiveDismissDisabled(isNew ? hasUnsavedChanges : saveFailed)
            .confirmationDialog(saveFailed ? "Discard unsaved changes?" : "Discard changes?",
                                isPresented: $confirmingDiscard,
                                titleVisibility: .visible) {
                Button("Discard", role: .destructive) {
                    // Before dismissing, or the parting save below would send
                    // the very words the writer just chose to throw away.
                    discarding = true
                    dismiss()
                }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text(discardMessage)
            }
        }
    }

    /// Whether the last save was refused and the words are still only here.
    private var saveFailed: Bool {
        if case .failed = saveStatus { return true }
        return false
    }

    private var discardMessage: String {
        if saveFailed {
            return "The last save did not reach the server, so your most recent edits are only on this device."
        }
        return isNew
            ? "This \(type == .song ? "song" : "note") has not been saved yet."
            : "Your edits since opening will be lost."
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

    /// Under the note: what went wrong, whether it is saved, how long it is,
    /// and the formatting bar riding above the keyboard. Stacked in that order
    /// so the bar sits closest to the writer's thumbs and the readouts stay put
    /// above it.
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
            }
            saveStatusBar
            if settings.showsWordCount {
                WordCountBar(words: ScriptStats.countWords(content))
            }
            if showsFormatBar && isWritingBody {
                NoteFormatBar(controller: formatting)
            }
        }
    }

    /// Says where the note stands with the server, and — when that is nowhere —
    /// offers the one thing worth offering, which is to try again.
    @ViewBuilder
    private var saveStatusBar: some View {
        if let saveStatus {
            HStack(spacing: 6) {
                switch saveStatus {
                case .saving:
                    ProgressView().controlSize(.mini)
                    Text("Saving…").foregroundStyle(.secondary)
                case .saved:
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                    Text("Saved").foregroundStyle(.secondary)
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message).foregroundStyle(.primary)
                    Button("Retry") { Task { await saveNow() } }
                        .font(.footnote.weight(.medium))
                }
                Spacer(minLength: 0)
            }
            .font(.footnote)
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // An autosaving note is only ever left, never cancelled: there is
        // nothing to cancel back to. The one exception is a save the server
        // refused, where leaving does lose something and so has to be asked
        // about.
        ToolbarItem(placement: .cancellationAction) {
            Button(autosaves || !canEdit ? "Done" : "Cancel") {
                if autosaves ? saveFailed : hasUnsavedChanges {
                    confirmingDiscard = true
                } else {
                    dismiss()
                }
            }
        }
        if canEdit && !autosaves {
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

    // MARK: - Autosave

    /// Arms the debounce. The load above writes into the same two fields, so
    /// this checks that the note has really diverged rather than trusting that
    /// a change came from the keyboard.
    private func scheduleAutosave() {
        guard autosaves, !isLoading, hasUnsavedChanges else { return }
        // Said from the first keystroke rather than when the request leaves:
        // what the writer needs to know is that the words are on their way, and
        // a readout that still says "Saved" over unsent text is the one thing
        // this bar must never do.
        saveStatus = .saving
        autosave?.cancel()
        autosave = Task {
            try? await Task.sleep(for: Self.autosaveDelay)
            guard !Task.isCancelled else { return }
            await saveNow()
        }
    }

    /// Sends what is on screen and says so.
    ///
    /// A save landing while more is being typed is the ordinary case, so what
    /// went is remembered and compared against what is there afterwards — if
    /// the note moved on in the meantime, another save is armed rather than the
    /// newer words being marked as saved.
    private func saveNow() async {
        guard autosaves, let document, !isSaving else { return }
        // Typed back to what the server already holds — there is nothing to
        // send, but the bar has been saying "Saving…" since the keystroke that
        // got it there.
        guard hasUnsavedChanges else {
            if saveStatus == .saving { saveStatus = .saved }
            return
        }
        // An untitled note cannot be saved: the server requires the title, and
        // the list would have nothing to draw. Say so rather than retrying into
        // a refusal every second.
        guard !trimmedTitle.isEmpty else {
            saveStatus = .failed("Add a title to save this \(type == .song ? "song" : "note").")
            return
        }
        let sentTitle = title
        let sentContent = content
        isSaving = true
        saveStatus = .saving
        let succeeded = await model.saveDocument(document, title: trimmedTitle, content: sentContent)
        isSaving = false
        guard succeeded else {
            saveStatus = .failed(model.errorMessage ?? "Not saved.")
            return
        }
        savedTitle = sentTitle
        savedContent = sentContent
        saveStatus = .saved
        errorMessage = nil
        // Typed into while that was in flight: those words have not been sent.
        if hasUnsavedChanges { scheduleAutosave() }
    }

    /// Sends whatever is unsent without waiting out the debounce, on a task
    /// that belongs to the model rather than to this view — a sheet on its way
    /// out takes its own tasks with it, and this is exactly the moment the
    /// last paragraph would be lost.
    ///
    /// Also where the lists left alone during the session are brought back into
    /// step, since every save until now deliberately skipped them.
    private func flush() {
        guard autosaves, let document else { return }
        let dirty = hasUnsavedChanges && !trimmedTitle.isEmpty && !discarding
        guard dirty || saveStatus != nil else { return }
        let sentTitle = trimmedTitle
        let sentContent = content
        let model = model
        Task { @MainActor in
            if dirty {
                await model.saveDocument(document, title: sentTitle, content: sentContent)
            }
            await model.refreshAfterDocumentEdit()
        }
    }

    /// The Save button, which now only ever creates: a document that exists is
    /// saving itself, and one that does not has no update link for anything
    /// else to use.
    private func save() {
        guard canSave, document == nil else { return }
        isSaving = true
        errorMessage = nil
        let title = trimmedTitle
        Task {
            let succeeded = await model.createDocument(
                title: title, content: content, type: type) != nil
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
