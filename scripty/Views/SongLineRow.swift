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
    /// Owned by whatever list this row is in, so Return can move the caret to
    /// the line it just created. Bridged to the UITextView below rather than
    /// attached with `.focused`: the field grants itself first responder when
    /// this points at it and reports back when the writer taps it directly, so
    /// the shared value stays the single source of truth across both hosts.
    @FocusState.Binding var focusedLine: Int?
    /// True while the list this row is in is being rearranged. The line stops
    /// taking text for as long as that lasts: a tap meant for a drag handle
    /// that opens the keyboard instead is the whole mode undone.
    var isRearranging = false
    /// Whether the row has a number in the margin. The all-songs workspace
    /// turns it off — a page of every song is read as lyrics, not discussed
    /// by line — and with it goes the per-line menu the number anchors:
    /// there, the lyric fills the row and Delete survives as a swipe.
    var showsLineNumber = true

    @Environment(\.colorScheme) private var colorScheme
    /// The writer's chosen type size, shared with the screenplay through the
    /// same environment key so one preference scales lyrics wherever they show
    /// — the song editor and the all-songs workspace both set it. Defaults to
    /// 1.0, so a host that never sets it leaves the line at its natural size.
    @Environment(\.scriptTextScale) private var textScale

    /// The lyric's base point size at 100%. Matches the default body text this
    /// row used before it scaled, so nothing moves at the default setting.
    private static let baseLineSize: CGFloat = 17

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
        HStack(alignment: .top, spacing: 8) {
            if showsLineNumber {
                if isRearranging {
                    // No menu while rearranging: Move Up and Move Down are what
                    // the drag handle is now for, and the rest would be a menu
                    // opened by a tap aimed at a row about to be dragged.
                    lineNumber
                } else {
                    Menu {
                        lineMenu
                    } label: {
                        lineNumber
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Line \(block.order ?? 0) actions")
                }
            }

            SongLineField(text: text,
                          isFocused: isFocused,
                          isEditable: block.isEditable && !isRearranging,
                          fontSize: Self.baseLineSize * textScale,
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
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        // The list's own row insets would put a blank line's worth of air
        // between one lyric line and the next, which reads as double spacing.
        // A verse is single-spaced: the 2pt row padding above is the only
        // vertical gap, matching the near-flush lines of the web's song
        // editor. Horizontal stays at the plain list's usual 16pt.
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowBackground(rowBackground)
        .swipeActions(edge: .trailing) {
            if block.hasLink(.delete) {
                Button(role: .destructive) {
                    Task { await model.delete(block) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
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
    private var isFocused: Bool {
        guard !isRearranging else { return false }
        return focusedLine == block.id || model.focusRequest == block.id
    }

    private var text: Binding<String> {
        Binding(get: { model.currentText(block) },
                set: { model.edit(block, text: $0) })
    }

    /// The line's tint, as something a Picker can drive. Reads the block, and
    /// writes through the server — there is no local copy to keep in step.
    private var highlight: Binding<BlockHighlight?> {
        Binding(get: { block.tint },
                set: { colour in
                    guard colour != block.tint else { return }
                    Task { await model.setHighlight(block, to: colour) }
                })
    }

    /// The number in the margin. Worth having on its own account — lyrics get
    /// discussed by line — and it doubles as the target for the row's menu.
    private var lineNumber: some View {
        Text("\(block.order ?? 0)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .frame(width: 22, alignment: .trailing)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var rowBackground: some View {
        if let tint = block.tint {
            tint.color(for: colorScheme)
        } else {
            Color.clear
        }
    }

    /// The per-line actions hang off the number in the margin rather than off a
    /// context menu on the row. The text field fills the row and swallows a
    /// long press, so a row-level menu is simply unreachable — which is how the
    /// first version of this shipped, with Move, Highlight and Delete visible
    /// in the code and unusable in the app. The number is also worth having:
    /// lyrics get discussed by line.
    @ViewBuilder
    private var lineMenu: some View {
        if model.canMoveUp(block) {
            Button {
                Task { await model.move(block, by: -1) }
            } label: {
                Label("Move Up", systemImage: "arrow.up")
            }
        }
        if model.canMoveDown(block) {
            Button {
                Task { await model.move(block, by: 1) }
            } label: {
                Label("Move Down", systemImage: "arrow.down")
            }
        }
        if block.hasLink(.setHighlight) {
            // A Picker rather than a list of buttons, so the colour already on
            // the line is ticked. The tint is behind the row, which says the
            // line is highlighted but not which of two neighbouring yellows it
            // is wearing — and the writer who set it is the one most likely to
            // want it changed.
            Picker(selection: highlight) {
                Text("None").tag(BlockHighlight?.none)
                ForEach(BlockHighlight.allCases) { colour in
                    Text(colour.label).tag(BlockHighlight?.some(colour))
                }
            } label: {
                Label("Highlight", systemImage: "highlighter")
            }
            // Explicit, or the picker flattens into the row's menu and the six
            // colour names sit there unlabelled among Move and Delete.
            .pickerStyle(.menu)
        }
        if block.hasLink(.delete) {
            Button(role: .destructive) {
                Task { await model.delete(block) }
            } label: {
                Label("Delete", systemImage: "trash")
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
private struct SongLineField: UIViewRepresentable {
    @Binding var text: String
    let isFocused: Bool
    let isEditable: Bool
    let fontSize: CGFloat
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

    private func apply(to view: SongLineUITextView) {
        let font = UIFont.systemFont(ofSize: fontSize)
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
