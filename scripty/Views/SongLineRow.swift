//
//  SongLineRow.swift
//  scripty
//
//  One line of a lyric, as a row in a list.
//
//  Split out from the song editor because the workspace — every song in the
//  project on one screen — has to render the same line, with the same actions
//  and the same saving behaviour, inside a list it does not own. Two
//  implementations of "a lyric line" would drift apart on the first change to
//  either.
//
//  The line itself is a UITextView bridged into SwiftUI rather than a plain
//  `TextField`, for two reasons SwiftUI's field cannot give. A `TextField` has
//  no spell-check control, so a writer who turns spellcheck off in the view
//  options still saw red squiggles under every lyric — the one surface that
//  ignored the preference the screenplay and notes editors already honour. And
//  it cannot see a Backspace pressed at offset 0, which is what folds a line
//  into the one above it. A UITextView can be told and can be asked, exactly as
//  `BlockTextView` tells and asks its own.
//

import SwiftUI
import UIKit

struct SongLineRow: View {
    let model: SongBlockModel
    let block: SongBlock
    /// Whether this song is locked for reading. Not a property of the line —
    /// the whole lyric locks at once — but it is applied here, because every
    /// way into a line is on this row: the text itself, and the swipes that
    /// delete and tint it. A lock the server never heard of, so it narrows
    /// what an editor may do and can never widen it.
    let isLocked: Bool
    /// Owned by whatever list this row is in, so Return can move the caret to
    /// the line it just created. Bridged to the UITextView below rather than
    /// attached with `.focused`: the field grants itself first responder when
    /// this points at it and reports back when the writer taps it directly, so
    /// the shared value stays the single source of truth across both hosts.
    @FocusState.Binding var focusedLine: Int?
    /// What a double tap on a line nobody can type into should do: leave the
    /// reading view, take the lock off, or whatever else the host has put in the
    /// way. Nil where the host has nothing to undo, and never offered on a line
    /// the server itself made read-only — see `DoubleTapToEdit`.
    ///
    /// Handed how far into *this line* the finger landed. The lock, which is
    /// what every host but the song editor puts in the way, needs nothing with
    /// it: the line stays the same view and places its own caret.
    var startWriting: ((Int) -> Void)?
    /// Whether the voice reading the song aloud is on this line. Off by
    /// default, for the workspace and anywhere else that has no reading of its
    /// own to follow.
    var isBeingRead = false

    /// Whether the highlight swipe is showing its colours.
    @State private var pickingHighlight = false

    /// Everything the text view calls back into, behind one stable reference —
    /// see `SongLineCallbacks`. Refreshed from `body` below, which runs on
    /// every redraw whether or not the field itself needs updating.
    @State private var callbacks = SongLineCallbacks()

    @Environment(\.colorScheme) private var colorScheme
    /// The writer's chosen type size, shared with the screenplay through the
    /// same environment key so one preference scales lyrics wherever they show
    /// — the song editor and the all-songs workspace both set it. Defaults to
    /// 1.0, so a host that never sets it leaves the line at its natural size.
    @Environment(\.scriptTextScale) private var textScale

    /// Whether the keyboard underlines what it does not recognise. Read here so
    /// switching the device-wide preference re-draws every visible lyric line,
    /// the same way `EditableBlockRow` reads it for the screenplay.
    private var spellChecks: Bool {
        PresentationSettings.shared.isSpellcheckEnabled
    }

    /// Which version of the ignored-words list these lines have been checked
    /// against. Read here for the same reason: a name ignored from one line's
    /// menu has to stop being underlined in the chorus that repeats it.
    private var spellcheckRevision: Int {
        SpellcheckDictionary.shared.revision
    }

    var body: some View {
        // Refreshed here rather than handed to the field as stored closures:
        // `body` runs on every redraw, `updateUIView` no longer does (the
        // field is `.equatable()` below), and the coordinator holds this
        // reference for the life of the row. Writing a class instance's
        // properties is not a write to `@State`, so it is allowed from here.
        callbacks.startWriting =
            // Only where the words are the writer's to change. A line the
            // server sent read-only stays read-only, and the gesture is not
            // offered at all rather than unlocking a song around a line that
            // would still refuse the caret.
            block.isEditable ? startWriting : nil
        callbacks.onTextChanged = { model.edit(block, text: $0) }
        callbacks.onCaretApplied = { model.caretRequests[block.id] = nil }
        callbacks.onBeginEditing = {
            focusedLine = block.id
            // And in the model, which is the copy that survives: SwiftUI keeps
            // no focus value no view has claimed, so this is what the hosts'
            // keyboard bar reads.
            model.focusedBlockId = block.id
            // Taken: the model has no further say over where the caret goes
            // until it asks again.
            if model.focusRequest == block.id { model.focusRequest = nil }
        }
        callbacks.onEndEditing = {
            // Save on the way out rather than waiting for the debounce, and
            // release the shared focus only if it still points here — a tap on
            // another line has already moved it on by the time this fires.
            if focusedLine == block.id { focusedLine = nil }
            if model.focusedBlockId == block.id { model.focusedBlockId = nil }
            Task { await model.commit(block) }
        }
        callbacks.onReturn = {
            Task {
                if let created = await model.addLine(below: block) {
                    focusedLine = created
                }
            }
        }
        callbacks.onBackspaceAtStart = {
            // Backspace with nothing behind the caret folds the line into the
            // one above, the way it does in the screenplay. The model puts the
            // caret at the seam; all this has to do is follow it there.
            Task {
                if let target = await model.mergeIntoPrevious(block) {
                    focusedLine = target
                }
            }
        }

        return SongLineField(text: model.currentText(block),
                             isFocused: isFocused,
                             isEditable: block.isEditable && !isLocked,
                             textScale: textScale,
                             spellChecks: spellChecks,
                             spellcheckRevision: spellcheckRevision,
                             accessibilityLabel: "Lyric line \(block.order ?? 0)",
                             offersStartWriting: block.isEditable && startWriting != nil,
                             caret: model.caretRequests[block.id],
                             callbacks: callbacks)
        .equatable()
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        // The list's own row insets would put a blank line's worth of air
        // between one lyric line and the next, which reads as double spacing.
        // A verse is single-spaced, and a line is exactly as tall as its own
        // text: the two points of padding this row used to carry were two
        // points the reading surface — a stack of flush lines — did not, and
        // they compounded down a verse into a visible shift on the way into
        // reading. Horizontal stays at the plain list's usual 16pt, which with
        // the 4 above is `ProseColumn.horizontalPadding`.
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowBackground(rowBackground)
        // Both swipes change the lyric, so both go while the song is locked. A
        // locked song that still deleted a verse under the thumb would be the
        // accident the lock exists to prevent, in its worst form. Reading needs
        // no test of its own: that mode takes these rows off screen entirely.
        .swipeActions(edge: .trailing) {
            // `isLocal` beside the link: a line written offline advertises no
            // links at all, and removing it is the one removal that needs no
            // server — its queue entry is dropped. Without this the writer
            // could make a line with no connection and not take it back.
            if block.hasLink(.delete) || block.isLocal, !isLocked {
                Button(role: .destructive) {
                    Task { await model.delete(block) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        // Highlight used to live in a menu behind the line number. The number
        // is gone — lyrics read as lyrics, in the editor as in the workspace —
        // and a long press cannot replace the menu because the text field
        // swallows it, so the tint rides the same gesture Delete already uses.
        .swipeActions(edge: .leading) {
            if block.hasLink(.setHighlight), !isLocked {
                Button {
                    pickingHighlight = true
                } label: {
                    Label("Highlight", systemImage: "highlighter")
                }
                .tint(.orange)
            }
        }
        // Deliberately still inline, unlike the screenplay's element menu. The
        // same trick would apply — this builder runs on every redraw of the row
        // — but `confirmationDialog` only promises to draw the buttons its
        // builder yields, and a custom view in there is exactly the shape that
        // comes out as a dialog with nothing on it but Cancel. Seven small
        // button values is a price worth paying not to risk that; the menu on
        // the screenplay side was worth it because what it was building was a
        // trip out of the process.
        .confirmationDialog("Highlight Line",
                            isPresented: $pickingHighlight,
                            titleVisibility: .visible) {
            ForEach(BlockHighlight.allCases) { colour in
                Button(colour.label) {
                    Task { await model.setHighlight(block, to: colour) }
                }
            }
            if block.tint != nil {
                Button("Remove Highlight", role: .destructive) {
                    Task { await model.setHighlight(block, to: nil) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Whether this line should be holding the caret.
    ///
    /// Two sources, because they answer different questions. The host's
    /// `@FocusState` says which line the writer is in — set from the field
    /// itself when they tap one. The model's `focusRequest` says which line the
    /// *model* has just made or changed and wants typed into next, which is a
    /// value SwiftUI would throw away if it were kept in the focus state: no
    /// view here claims it with `.focused()`, since the field grants itself
    /// first responder.
    /// A locked lyric claims nothing: a focus request outlives the lock — it
    /// is whichever line was last made or merged — and granting first
    /// responder to a line that cannot be typed into would put the caret in a
    /// song the writer has just closed to editing.
    private var isFocused: Bool {
        !isLocked && (focusedLine == block.id || model.focusRequest == block.id)
    }

    /// The line's own colour, with the reading's wash over the top of it.
    ///
    /// Over rather than instead: a highlight is something the writer put on the
    /// line and it should not blink out for the second the voice is on it. The
    /// wash is the screenplay's spotlight, in the one place a lyric row can
    /// carry it — a row background, since the words themselves are a UIKit text
    /// view and an overlay across it would sit over the caret.
    @ViewBuilder
    private var rowBackground: some View {
        ZStack {
            if let tint = block.tint {
                tint.color(for: colorScheme)
            } else {
                Color.clear
            }
            if isBeingRead {
                Color.accentColor.opacity(0.16)
            }
        }
    }
}

/// A single lyric line as a UITextView, so it can be told whether to spell-check
/// — the only reason this is not a `TextField`.
///
/// Focus is granted, never revoked: when `isFocused` points here the field asks
/// to become first responder, exactly as `BlockTextView` does from
/// `model.focusedBlockId`. Losing focus is left to UIKit (another line taking
/// over, or the sheet closing), and the shared `@FocusState` follows along
/// through `onBeginEditing`/`onEndEditing` rather than driving a resign — a
/// programmatic resign here would fight the natural one and drop the keyboard.
/// Everything a lyric line calls back into, behind one reference that lives as
/// long as the row does.
///
/// `BlockTextView`'s coordinator takes its model and block at
/// `makeCoordinator` time and never reads the representable again — which is
/// what makes skipping `updateUIView` safe there. A lyric line's callbacks are
/// the *host's*, not the model's, so they cannot be handed over once and left:
/// they close over the focus binding and the host's way back into writing.
/// This is the same guarantee by another route. The row refreshes these from
/// `body`, which always runs; the coordinator reads them through a reference
/// that never changes, so a skipped update can never leave it calling into a
/// row that has moved on.
@MainActor
final class SongLineCallbacks {
    var startWriting: ((Int) -> Void)?
    var onTextChanged: (String) -> Void = { _ in }
    var onCaretApplied: () -> Void = {}
    var onBeginEditing: () -> Void = {}
    var onEndEditing: () -> Void = {}
    /// Return: the model makes and focuses the next line. A lyric line is one
    /// block, so a newline is never inserted into the text itself.
    var onReturn: () -> Void = {}
    /// Backspace pressed with the caret at offset 0 and nothing selected. It
    /// has no plain-text form to catch in the delegate, so the text view
    /// reports it — the same route `BlockUITextView` takes for the screenplay.
    var onBackspaceAtStart: () -> Void = {}
}

private struct SongLineField: UIViewRepresentable, Equatable {
    /// A value, not a binding. `@Observable` tracks whole properties, so a
    /// binding reading `model.currentText(block)` from inside `updateUIView`
    /// would be invalidated by *any* line's keystroke — every visible row
    /// re-running its UIKit styling per character typed, and in the all-songs
    /// workspace that is forty rows for one letter. The row reads the model (a
    /// cheap SwiftUI body) and the `==` below lets the untouched rows skip the
    /// UIKit work, exactly as `BlockTextView` does.
    let text: String
    let isFocused: Bool
    let isEditable: Bool
    /// The writer's chosen type size, as a multiple. Passed rather than a
    /// point size so the line resolves its type exactly as the note editor
    /// does, through `ProseFont`.
    let textScale: Double
    let spellChecks: Bool
    let spellcheckRevision: Int
    let accessibilityLabel: String
    /// The face the writer chose for everything with no font of its own.
    /// Resolved here, where the initialiser runs as the row builds its body,
    /// rather than down in `apply(to:)` — an observation registered from
    /// inside `updateUIView` belongs to no body and would leave a lyric
    /// editor left open behind the settings sheet in the old face.
    private let defaultFont = PresentationSettings.shared.defaultFont
    /// Whether there is a way into a line that is being read rather than
    /// written in. A value rather than the closure itself, so `==` can see it:
    /// the gesture is offered only while the field is not editable, so it
    /// never competes with the caret, and whether it is offered at all has to
    /// survive a skipped update.
    let offersStartWriting: Bool
    /// Where the caret should go once this line has taken focus, in Characters.
    /// Only a merge asks; the rest of the time UIKit's own placement is right.
    let caret: Int?
    /// The row's own callbacks. Compared by identity below — it is the same
    /// object for the life of the row, and the row keeps its contents current.
    let callbacks: SongLineCallbacks

    /// What a skipped update is allowed to leave stale: nothing that reaches
    /// UIKit. Every value `updateUIView` and `apply(to:)` read is here, and
    /// `callbacks` is a reference the row refreshes from its own body — so
    /// unlike `BlockTextView` there is no `parent` for the coordinator to hold
    /// a stale copy of.
    ///
    /// `defaultFont` is in here too, and has to be: it is resolved when this
    /// struct is built, and without it changing the app's typeface would leave
    /// every open lyric in the old face.
    static func == (lhs: SongLineField, rhs: SongLineField) -> Bool {
        lhs.text == rhs.text
            && lhs.isFocused == rhs.isFocused
            && lhs.isEditable == rhs.isEditable
            && lhs.textScale == rhs.textScale
            && lhs.spellChecks == rhs.spellChecks
            && lhs.spellcheckRevision == rhs.spellcheckRevision
            && lhs.accessibilityLabel == rhs.accessibilityLabel
            && lhs.offersStartWriting == rhs.offersStartWriting
            && lhs.caret == rhs.caret
            && lhs.defaultFont == rhs.defaultFont
            && lhs.callbacks === rhs.callbacks
    }

    func makeCoordinator() -> Coordinator { Coordinator(callbacks: callbacks) }

    func makeUIView(context: Context) -> SongLineUITextView {
        let view = SongLineUITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.smartDashesType = .no
        view.smartQuotesType = .no
        view.autocapitalizationType = .sentences
        // Follow the OS text-size setting without waiting for this row to be
        // rebuilt. `ProseFont` folds Dynamic Type in when the parent's body
        // runs, which covers the writer's own A−/A+ — but nothing here reads
        // the size category, so a lyric left open while the system setting was
        // changed stayed at the old size. The note editor has always asked for
        // this; a lyric line is the same prose at the same size.
        view.adjustsFontForContentSizeCategory = true
        view.text = text
        view.onDeleteBackwardAtStart = { [weak coordinator = context.coordinator] in
            coordinator?.callbacks.onBackspaceAtStart()
        }
        context.coordinator.textView = view
        // Through the callbacks rather than this struct: the closure outlives
        // it, and the host's answer to "start writing" changes with the mode
        // it is in.
        context.coordinator.doubleTap.startWriting = { [weak coordinator = context.coordinator] offset in
            coordinator?.callbacks.startWriting?(offset)
        }
        context.coordinator.doubleTap.attach(to: view)
        apply(to: view)
        offerDoubleTap(in: context.coordinator, for: view)
        return view
    }

    /// Wrap and grow at the width SwiftUI offers, the way `BlockTextView` does:
    /// a non-scrolling UITextView otherwise reports its longest line's width and
    /// overflows the row.
    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView: SongLineUITextView,
                      context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        let fitted = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitted.height))
    }

    func updateUIView(_ view: SongLineUITextView, context: Context) {
        // Only when the value really diverged — while the writer is typing the
        // binding already reads back what the view holds, so this never fires
        // mid-keystroke and never moves the caret. It only pushes the model's
        // value in after a reload, move or undo rewrote the line.
        if view.text != text { view.text = text }
        apply(to: view)
        offerDoubleTap(in: context.coordinator, for: view)

        if isFocused, !view.isFirstResponder {
            // A row just inserted into the list is not in the window during its
            // first update, so becomeFirstResponder() would silently no-op.
            // Defer until it has joined the hierarchy — the same reason
            // BlockTextView defers.
            DispatchQueue.main.async {
                if !view.isFirstResponder { view.becomeFirstResponder() }
            }
        }

        if let caret {
            // After the focus request above, and deferred for the same reason:
            // a line that has not become first responder yet would take the
            // selection and then lose it again on the way in.
            DispatchQueue.main.async {
                view.setCaret(characterOffset: caret)
                callbacks.onCaretApplied()
            }
        }
    }

    /// Two taps mean "let me write here" only while writing is exactly what
    /// this line will not do. Applied after `apply(to:)`, which is what settles
    /// whether it is editable this time round.
    @MainActor
    private func offerDoubleTap(in coordinator: Coordinator,
                                for view: SongLineUITextView) {
        coordinator.doubleTap.setOffered(!view.isEditable && offersStartWriting)
    }

    @MainActor
    private func apply(to view: SongLineUITextView) {
        // The same face and size the note editor and the screenplay rows use —
        // a lyric line was the last surface still set in the proportional
        // system font.
        let font = ProseFont.editor(scale: textScale, face: defaultFont)
        if view.font != font { view.font = font }
        if view.isEditable != isEditable { view.isEditable = isEditable }

        view.applySpellchecking(spellChecks, revision: spellcheckRevision)
        if view.accessibilityLabel != accessibilityLabel {
            view.accessibilityLabel = accessibilityLabel
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        /// Taken once and held, the way `BlockTextView`'s coordinator holds its
        /// model: nothing here reads the representable, so a redraw that skips
        /// `updateUIView` cannot leave this calling into a row that has moved
        /// on. The row keeps the closures inside current.
        let callbacks: SongLineCallbacks
        weak var textView: SongLineUITextView?
        /// The double tap that asks for the keyboard on a line that has none.
        /// Kept here because the recogniser has to outlive the struct that
        /// describes the row, which SwiftUI rebuilds on every redraw.
        let doubleTap = DoubleTapToEditGesture()

        init(callbacks: SongLineCallbacks) {
            self.callbacks = callbacks
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            callbacks.onBeginEditing()
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            callbacks.onEndEditing()
        }

        func textViewDidChange(_ textView: UITextView) {
            callbacks.onTextChanged(textView.text)
        }

        func textView(_ textView: UITextView,
                      shouldChangeTextIn range: NSRange,
                      replacementText text: String) -> Bool {
            if text == "\n" {
                callbacks.onReturn()
                return false
            }
            return true
        }

        /// "Ignore Spelling" beside the system's corrections — a lyric is as
        /// full of invented words as a screenplay is of names.
        func textView(_ textView: UITextView,
                      editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            SpellcheckEditMenu.menu(for: textView, in: range, appending: suggestedActions)
        }
    }
}

/// A UITextView the size of one lyric line.
///
/// Carries the one key the delegate cannot see: Backspace pressed with the
/// caret at the very start has no text to change, so `shouldChangeTextIn` is
/// never asked about it. `BlockUITextView` reports the same key the same way
/// for the screenplay. It also carries the revision of the ignored-word list
/// it was last checked against, which is what lets an edit to that list
/// re-check a line already on screen.
final class SongLineUITextView: UITextView, SpellcheckingTextView {
    var checkedSpellingRevision = 0
    var onDeleteBackwardAtStart: (() -> Void)?

    override func deleteBackward() {
        if selectedRange.location == 0, selectedRange.length == 0 {
            onDeleteBackwardAtStart?()
            return
        }
        super.deleteBackward()
    }

    /// Puts the caret at a Character offset. The line counts in UTF-16 and
    /// everything above counts in Characters, so the boundary is crossed here.
    func setCaret(characterOffset: Int) {
        let string = text ?? ""
        let bounded = max(0, min(characterOffset, string.count))
        let index = string.index(string.startIndex, offsetBy: bounded)
        let location = string.utf16.distance(
            from: string.utf16.startIndex,
            to: index.samePosition(in: string.utf16) ?? string.utf16.endIndex)
        selectedRange = NSRange(location: location, length: 0)
    }
}
