//
//  BlockTextView.swift
//  scripty
//
//  A UITextView wrapper that makes a single screenplay element editable in
//  place, the way the web editor does: Return creates the next element
//  (splitting text at the caret), Backspace at the very start merges into the
//  element above, and Tab cycles the element type. Focus and caret position
//  are driven from `ScriptModel` so structural edits can move the keyboard
//  from one block to the next without a modal ever appearing.
//

import SwiftUI
import UIKit

struct BlockTextView: UIViewRepresentable {
    let blockType: BlockType
    let text: String
    let isFocused: Bool
    /// A one-shot caret offset to apply after a programmatic text change.
    let caretRequest: Int?

    var onChange: (String) -> Void
    /// Return pressed: text before/after the caret. The caller keeps `before`
    /// on this block and carries `after` into a new element below.
    var onReturn: (_ before: String, _ after: String) -> Void
    var onBackspaceAtStart: () -> Void
    var onTab: (_ backward: Bool) -> Void
    var onFocusChange: (Bool) -> Void
    var onCaretApplied: () -> Void

    func makeUIView(context: Context) -> BlockUITextView {
        let view = BlockUITextView()
        view.delegate = context.coordinator
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.setContentHuggingPriority(.required, for: .vertical)
        view.onDeleteBackwardAtStart = { [weak view] in
            guard view != nil else { return }
            context.coordinator.parent.onBackspaceAtStart()
        }
        context.coordinator.apply(style: blockType, to: view)
        view.text = text
        return view
    }

    func updateUIView(_ view: BlockUITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(style: blockType, to: view)

        // A caret request means the model changed this block's text
        // programmatically (split / merge / retype); force it in even while
        // the field holds focus, then position the caret.
        if let offset = caretRequest {
            if view.text != text { view.text = text }
            context.coordinator.setCaret(offset, in: view)
            onCaretApplied()
        } else if !view.isFirstResponder, view.text != text {
            // Passive sync from a background reload while not being edited.
            view.text = text
        }

        // Drive first-responder state from the model. Dispatch async so a
        // row that was just inserted (and isn't in the window yet during this
        // update pass) still takes focus once it joins the hierarchy —
        // `becomeFirstResponder` is a silent no-op off-window.
        let wantsFocus = isFocused
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            if wantsFocus, !view.isFirstResponder {
                view.becomeFirstResponder()
            } else if !wantsFocus, view.isFirstResponder {
                view.resignFirstResponder()
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: BlockTextView

        init(_ parent: BlockTextView) { self.parent = parent }

        func apply(style type: BlockType, to view: UITextView) {
            view.font = Self.font(for: type)
            view.textAlignment = Self.alignment(for: type)
            view.autocapitalizationType = type.entersUppercase ? .allCharacters : .sentences
            view.autocorrectionType = .default
            view.textColor = .label
        }

        func setCaret(_ offset: Int, in view: UITextView) {
            let clamped = max(0, min(offset, (view.text as NSString).length))
            if let position = view.position(from: view.beginningOfDocument, offset: clamped) {
                view.selectedTextRange = view.textRange(from: position, to: position)
            }
        }

        // MARK: UITextViewDelegate

        func textView(_ textView: UITextView,
                      shouldChangeTextIn range: NSRange,
                      replacementText replacement: String) -> Bool {
            if replacement == "\n" {
                let full = textView.text as NSString
                let split = range.location + range.length
                let before = full.substring(to: min(split, full.length))
                let after = full.substring(from: min(split, full.length))
                parent.onReturn(before, after)
                return false
            }
            if replacement == "\t" {
                parent.onTab(false)
                return false
            }
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.onChange(textView.text)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onFocusChange(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onFocusChange(false)
        }

        // MARK: Styling

        static func font(for type: BlockType) -> UIFont {
            let size: CGFloat = 16
            switch type {
            case .section:
                return .systemFont(ofSize: 18, weight: .semibold)
            default:
                // Screenplay convention: Courier-style monospace.
                let base = UIFont.monospacedSystemFont(ofSize: size, weight: weight(for: type))
                if type == .parenthetical || type == .lyrics || type == .synopsis {
                    return base.withItalic() ?? base
                }
                return base
            }
        }

        static func weight(for type: BlockType) -> UIFont.Weight {
            switch type {
            case .scene: return .bold
            case .shot: return .semibold
            default: return .regular
            }
        }

        static func alignment(for type: BlockType) -> NSTextAlignment {
            switch type {
            case .character, .dualDialogue, .centered: return .center
            case .transition: return .right
            default: return .left
            }
        }
    }
}

/// A UITextView that reports a backspace pressed with the caret at the very
/// start (nothing to delete) so the editor can merge into the block above.
final class BlockUITextView: UITextView {
    var onDeleteBackwardAtStart: (() -> Void)?

    override func deleteBackward() {
        if selectedRange == NSRange(location: 0, length: 0) {
            onDeleteBackwardAtStart?()
            return
        }
        super.deleteBackward()
    }
}

private extension BlockType {
    /// Element types conventionally typed in all caps.
    var entersUppercase: Bool {
        self == .scene || self == .character || self == .dualDialogue
            || self == .transition || self == .shot
    }
}

private extension UIFont {
    func withItalic() -> UIFont? {
        guard let descriptor = fontDescriptor.withSymbolicTraits(
            fontDescriptor.symbolicTraits.union(.traitItalic)) else { return nil }
        return UIFont(descriptor: descriptor, size: 0)
    }
}
