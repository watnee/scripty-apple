//
//  BlockTextView.swift
//  scripty
//
//  A UITextView wrapper for editing one screenplay block inline. SwiftUI's
//  TextEditor can't be used here because it cannot report the keys that make a
//  screenplay editor feel like the web app: Return (which splits into a new
//  element rather than inserting a newline), Backspace at the start of a block
//  (which merges into the element above), and Tab (which cycles the element
//  type). This intercepts all three.
//

import SwiftUI
import UIKit

/// UITextView subclass that reports the structural keystrokes to closures the
/// coordinator installs.
final class BlockUITextView: UITextView {
    /// Backspace pressed with the caret at offset 0 and nothing selected.
    var onDeleteBackwardAtStart: (() -> Void)?
    /// Tab (or Shift-Tab) pressed on a hardware keyboard. `backward` is true
    /// for Shift-Tab.
    var onTabKey: ((_ backward: Bool) -> Void)?

    override func deleteBackward() {
        if selectedRange == NSRange(location: 0, length: 0) {
            onDeleteBackwardAtStart?()
            return
        }
        super.deleteBackward()
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(tabForward)),
            UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(tabBackward)),
        ]
    }

    @objc private func tabForward() { onTabKey?(false) }
    @objc private func tabBackward() { onTabKey?(true) }
}

struct BlockTextView: UIViewRepresentable {
    let block: Block
    let text: String
    let isFocused: Bool
    let caretRequest: ScriptModel.CaretRequest?

    var onText: (String) -> Void
    var onReturn: (_ caret: Int) -> Void
    var onBackspaceAtStart: () -> Void
    var onTab: (_ backward: Bool) -> Void
    var onFocus: () -> Void
    var onBlur: () -> Void
    var onCaretConsumed: (_ token: Int) -> Void

    func makeUIView(context: Context) -> BlockUITextView {
        let view = BlockUITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        // Screenwriting: autocorrect mangles slug lines and abbreviations, but
        // spell-check is still useful — the web editor makes the same choice.
        view.autocorrectionType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.spellCheckingType = .yes
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        let coordinator = context.coordinator
        view.onDeleteBackwardAtStart = { coordinator.parent.onBackspaceAtStart() }
        view.onTabKey = { backward in coordinator.parent.onTab(backward) }
        return view
    }

    func updateUIView(_ view: BlockUITextView, context: Context) {
        context.coordinator.parent = self

        style(view)

        if view.text != text {
            view.text = text
        }

        // Focus and caret placement must happen after the view has joined the
        // window: a freshly-inserted LazyVStack row is not yet in the hierarchy
        // during its first updateUIView, so becomeFirstResponder() there is a
        // silent no-op. Dispatching lets the view attach first.
        if let request = caretRequest, request.blockId == block.id {
            DispatchQueue.main.async {
                if !view.isFirstResponder { view.becomeFirstResponder() }
                let utf16Count = (view.text as NSString).length
                let offset = Self.utf16Offset(in: view.text, characters: request.offset)
                let clamped = min(offset, utf16Count)
                view.selectedRange = NSRange(location: clamped, length: 0)
                onCaretConsumed(request.token)
            }
        } else if isFocused, !view.isFirstResponder {
            DispatchQueue.main.async {
                if !view.isFirstResponder { view.becomeFirstResponder() }
            }
        } else if !isFocused, view.isFirstResponder {
            DispatchQueue.main.async {
                if view.isFirstResponder { view.resignFirstResponder() }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: BlockUITextView,
                      context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let fitted = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(fitted.height, uiView.font?.lineHeight ?? 20))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // MARK: - Styling

    private func style(_ view: BlockUITextView) {
        view.font = BlockStyle.font(for: block.blockType)
        view.textAlignment = BlockStyle.alignment(for: block.blockType)
        view.autocapitalizationType = BlockStyle.autocapitalization(for: block.blockType)
    }

    /// Converts a Character offset (what the model splits on) into the UTF-16
    /// offset a UITextView selection needs.
    private static func utf16Offset(in string: String, characters: Int) -> Int {
        let clamped = max(0, min(characters, string.count))
        let index = string.index(string.startIndex, offsetBy: clamped)
        return string.utf16.distance(from: string.utf16.startIndex, to: index)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: BlockTextView

        init(parent: BlockTextView) {
            self.parent = parent
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onFocus()
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onBlur()
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.onText(textView.text)
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange,
                      replacementText text: String) -> Bool {
            if text == "\n" {
                // Caret offset in Characters = length of the head substring.
                let head = (textView.text as NSString).substring(to: range.location)
                parent.onReturn(head.count)
                return false
            }
            return true
        }
    }
}
