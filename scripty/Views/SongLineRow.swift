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
//  `TextField`, for one reason SwiftUI's field cannot give: a `TextField` has
//  no spell-check control, so a writer who turns spellcheck off in the view
//  options still saw red squiggles under every lyric — the one surface that
//  ignored the preference the screenplay and notes editors already honour. A
//  UITextView can be told, exactly as `BlockTextView` tells its own.
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
            Menu {
                lineMenu
            } label: {
                Text("\(block.order ?? 0)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Line \(block.order ?? 0) actions")

            SongLineField(text: text,
                          isFocused: focusedLine == block.id,
                          isEditable: block.isEditable,
                          fontSize: Self.baseLineSize * textScale,
                          spellChecks: spellChecks,
                          spellcheckRevision: spellcheckRevision,
                          accessibilityLabel: "Lyric line \(block.order ?? 0)",
                          onBeginEditing: { focusedLine = block.id },
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
                          })
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
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
            Menu {
                ForEach(BlockHighlight.allCases) { colour in
                    Button(colour.label) {
                        Task { await model.setHighlight(block, to: colour) }
                    }
                }
                Button("None") {
                    Task { await model.setHighlight(block, to: nil) }
                }
            } label: {
                Label("Highlight", systemImage: "highlighter")
            }
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
    let onBeginEditing: () -> Void
    let onEndEditing: () -> Void
    /// Return: the model makes and focuses the next line. A lyric line is one
    /// block, so a newline is never inserted into the text itself.
    let onReturn: () -> Void

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

/// A UITextView the size of one lyric line. Carries the type and the revision
/// of the ignored list it was last checked against; the line's behaviour lives
/// in the coordinator above.
final class SongLineUITextView: UITextView, SpellcheckingTextView {
    var checkedSpellingRevision = 0
}
