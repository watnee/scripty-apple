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
    /// Whether the host has the song up to be read rather than written in.
    ///
    /// Off by default, which is what the all-songs workspace wants: that
    /// screen is a writing surface by definition — every song in the project,
    /// open at once, to be worked through — and has no reading posture to be
    /// in. Only the song editor sets it, and only until Edit is tapped.
    var isReadingView = false

    /// Whether the highlight swipe is showing its colours.
    @State private var pickingHighlight = false

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
        SongLineField(text: text,
                      isFocused: isFocused,
                      isEditable: block.isEditable && !isReadingView && !isLocked,
                      textScale: textScale,
                      spellChecks: spellChecks,
                      spellcheckRevision: spellcheckRevision,
                      accessibilityLabel: "Lyric line \(block.order ?? 0)",
                      caret: model.caretRequests[block.id],
                      onCaretApplied: { model.caretRequests[block.id] = nil },
                      onBeginEditing: {
                          focusedLine = block.id
                          // Taken: the model has no further say over where
                          // the caret goes until it asks again.
                          if model.focusRequest == block.id { model.focusRequest = nil }
                      },
                      onEndEditing: {
                          // Save on the way out rather than waiting for the
                          // debounce, and release the shared focus only if it
                          // still points here — a tap on another line has
                          // already moved it on by the time this fires.
                          if focusedLine == block.id { focusedLine = nil }
                          Task { await model.commit(block) }
                      },
                      onReturn: {
                          Task {
                              if let created = await model.addLine(below: block) {
                                  focusedLine = created
                              }
                          }
                      },
                      onBackspaceAtStart: {
                          // Backspace with nothing behind the caret folds
                          // the line into the one above, the way it does in
                          // the screenplay. The model puts the caret at the
                          // seam; all this has to do is follow it there.
                          Task {
                              if let target = await model.mergeIntoPrevious(block) {
                                  focusedLine = target
                              }
                          }
                      })
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        // The list's own row insets would put a blank line's worth of air
        // between one lyric line and the next, which reads as double spacing.
        // A verse is single-spaced: the 2pt row padding above is the only
        // vertical gap, matching the near-flush lines of the web's song
        // editor. Horizontal stays at the plain list's usual 16pt.
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowBackground(rowBackground)
        // Both swipes change the lyric, so both go while the song is up to be
        // read. A reading view that still deleted a verse under the thumb
        // would be the accident the mode exists to prevent, in its worst form.
        .swipeActions(edge: .trailing) {
            if block.hasLink(.delete), !isReadingView, !isLocked {
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
            if block.hasLink(.setHighlight), !isReadingView, !isLocked {
                Button {
                    pickingHighlight = true
                } label: {
                    Label("Highlight", systemImage: "highlighter")
                }
                .tint(.orange)
            }
        }
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

    private var text: Binding<String> {
        Binding(get: { model.currentText(block) },
                set: { model.edit(block, text: $0) })
    }

    @ViewBuilder
    private var rowBackground: some View {
        if let tint = block.tint {
            tint.color(for: colorScheme)
        } else {
            Color.clear
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
private struct SongLineField: UIViewRepresentable {
    @Binding var text: String
    let isFocused: Bool
    let isEditable: Bool
    /// The writer's chosen type size, as a multiple. Passed rather than a
    /// point size so the line resolves its type exactly as the note editor
    /// does, through `ProseFont`.
    let textScale: Double
    let spellChecks: Bool
    let spellcheckRevision: Int
    let accessibilityLabel: String
    /// Where the caret should go once this line has taken focus, in Characters.
    /// Only a merge asks; the rest of the time UIKit's own placement is right.
    let caret: Int?
    let onCaretApplied: () -> Void
    let onBeginEditing: () -> Void
    let onEndEditing: () -> Void
    /// Return: the model makes and focuses the next line. A lyric line is one
    /// block, so a newline is never inserted into the text itself.
    let onReturn: () -> Void
    /// Backspace pressed with the caret at offset 0 and nothing selected. It
    /// has no plain-text form to catch in the delegate, so the text view
    /// reports it — the same route `BlockUITextView` takes for the screenplay.
    let onBackspaceAtStart: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

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
        view.text = text
        view.onDeleteBackwardAtStart = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onBackspaceAtStart()
        }
        context.coordinator.textView = view
        apply(to: view)
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
        context.coordinator.parent = self

        // Only when the value really diverged — while the writer is typing the
        // binding already reads back what the view holds, so this never fires
        // mid-keystroke and never moves the caret. It only pushes the model's
        // value in after a reload, move or undo rewrote the line.
        if view.text != text { view.text = text }
        apply(to: view)

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
                onCaretApplied()
            }
        }
    }

    @MainActor
    private func apply(to view: SongLineUITextView) {
        // The same face and size the note editor and the screenplay rows use —
        // a lyric line was the last surface still set in the proportional
        // system font.
        let font = ProseFont.editor(scale: textScale)
        if view.font != font { view.font = font }
        if view.isEditable != isEditable { view.isEditable = isEditable }

        view.applySpellchecking(spellChecks, revision: spellcheckRevision)
        if view.accessibilityLabel != accessibilityLabel {
            view.accessibilityLabel = accessibilityLabel
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SongLineField
        weak var textView: SongLineUITextView?

        init(_ parent: SongLineField) {
            self.parent = parent
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onBeginEditing()
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onEndEditing()
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func textView(_ textView: UITextView,
                      shouldChangeTextIn range: NSRange,
                      replacementText text: String) -> Bool {
            if text == "\n" {
                parent.onReturn()
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
