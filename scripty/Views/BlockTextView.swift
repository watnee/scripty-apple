//
//  BlockTextView.swift
//  scripty
//
//  A UITextView bridged into SwiftUI so a screenplay block can be typed
//  into continuously — no modal sheet. Return, Backspace-at-start and Tab
//  are intercepted and handed to the ScriptModel so they split, merge and
//  retype elements exactly the way the web editor does.
//

import SwiftUI
import UIKit

struct BlockTextView: UIViewRepresentable {
    let model: ScriptModel
    let block: Block
    let font: UIFont
    let alignment: NSTextAlignment
    let autocapitalize: UITextAutocapitalizationType
    /// Whether misspellings are underlined as the writer types.
    let spellChecks: Bool
    /// Names the screenplay element type for VoiceOver; the spoken value stays
    /// the block's own text.
    let accessibilityLabel: String

    func makeCoordinator() -> Coordinator { Coordinator(model: model, block: block) }

    func makeUIView(context: Context) -> BlockUITextView {
        let view = BlockUITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.smartDashesType = .no
        view.smartQuotesType = .no
        view.text = model.currentText(block)
        view.onDeleteBackwardAtStart = { [weak coordinator = context.coordinator] in
            coordinator?.backspaceAtStart()
        }
        view.onShiftTab = { [weak coordinator = context.coordinator] in
            coordinator?.tab(backward: true)
        }
        context.coordinator.textView = view
        apply(font: font, alignment: alignment, capitalize: autocapitalize,
              spellChecks: spellChecks, to: view)
        if view.accessibilityLabel != accessibilityLabel {
            view.accessibilityLabel = accessibilityLabel
        }
        return view
    }

    /// Wrap at the width SwiftUI offers rather than at the text's own idea of
    /// how wide it wants to be.
    ///
    /// A non-scrolling UITextView reports an intrinsic width big enough for its
    /// longest unbroken line, and without this the view lays out at that width
    /// and simply overflows the `.frame(maxWidth:)` around it — which is why a
    /// long action line used to run off the right edge and why narrowing the
    /// column (focus mode) had no visible effect.
    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView: BlockUITextView,
                      context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        let fitted = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitted.height))
    }

    func updateUIView(_ view: BlockUITextView, context: Context) {
        context.coordinator.block = block

        // While the writer is mid-keystroke the model mirrors the view via
        // `liveText`, so leave the view alone. Once liveText is cleared the
        // model's value is authoritative again (a split trimmed this block, a
        // merge grew it, a retype rewrote it) and must be pushed back in — even
        // if the block still holds the caret.
        let desired = model.currentText(block)
        if model.liveText[block.id] == nil, view.text != desired {
            view.text = desired
        }

        // After the text sync, never before: assigning `.text` rebuilds the
        // storage from the view's plain font/colour, dropping the underline
        // attribute, so styling has to be re-stamped on top of the new string.
        apply(font: font, alignment: alignment, capitalize: autocapitalize,
              spellChecks: spellChecks, to: view)
        if view.accessibilityLabel != accessibilityLabel {
            view.accessibilityLabel = accessibilityLabel
        }

        if model.focusedBlockId == block.id, !view.isFirstResponder {
            // A row just inserted into the LazyVStack isn't in the window during
            // its first update, so becomeFirstResponder() would silently no-op.
            // Defer until the view has joined the hierarchy.
            DispatchQueue.main.async { view.becomeFirstResponder() }
        }

        if let offset = model.caretRequests[block.id] {
            let blockId = block.id
            DispatchQueue.main.async {
                context.coordinator.applyCaret(offset)
                model.caretRequests[blockId] = nil
            }
        }
    }

    private func apply(font: UIFont, alignment: NSTextAlignment,
                       capitalize: UITextAutocapitalizationType,
                       spellChecks: Bool, to view: BlockUITextView) {
        if view.font != font { view.font = font }
        if view.textAlignment != alignment { view.textAlignment = alignment }
        if view.autocapitalizationType != capitalize { view.autocapitalizationType = capitalize }

        // Explicit rather than `.default`, which would mean "on" and leave the
        // preference with nothing to say. A live text view has already told the
        // keyboard how it wants to be treated, so the change only takes hold
        // once its input configuration is asked for again.
        let checking: UITextSpellCheckingType = spellChecks ? .yes : .no
        if view.spellCheckingType != checking {
            view.spellCheckingType = checking
            if view.isFirstResponder { view.reloadInputViews() }
        }
        applyUnderline(block.textUnderline ?? false, font: font, to: view)
    }

    /// Underline is the one style `UIFont` cannot carry, so it is applied as a
    /// text attribute instead.
    ///
    /// Deliberately an *attribute-only* edit: the view's `text` is never
    /// reassigned and `attributedText` is never used, so the backing string —
    /// and therefore every UTF-16 offset the caret math and the Return /
    /// Backspace interception depend on — is bit-for-bit unchanged. Attribute
    /// edits don't route through `shouldChangeTextIn` or `textViewDidChange`
    /// either, so no phantom keystroke reaches the model.
    private func applyUnderline(_ underlined: Bool, font: UIFont, to view: BlockUITextView) {
        let style = underlined ? NSUnderlineStyle.single.rawValue : 0

        // Governs text typed from the caret onward.
        var typing = view.typingAttributes
        let typingStyle = typing[.underlineStyle] as? Int ?? 0
        if typingStyle != style || typing[.font] as? UIFont != font {
            typing[.font] = font
            if underlined {
                typing[.underlineStyle] = style
            } else {
                typing.removeValue(forKey: .underlineStyle)
            }
            view.typingAttributes = typing
        }

        // Governs text already on screen.
        let storage = view.textStorage
        guard storage.length > 0 else { return }
        let existing = storage.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int ?? 0
        guard existing != style else { return }

        let range = NSRange(location: 0, length: storage.length)
        let selection = view.selectedRange
        storage.beginEditing()
        if underlined {
            storage.addAttribute(.underlineStyle, value: style, range: range)
        } else {
            storage.removeAttribute(.underlineStyle, range: range)
        }
        storage.endEditing()
        if view.selectedRange != selection { view.selectedRange = selection }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        let model: ScriptModel
        var block: Block
        weak var textView: BlockUITextView?

        init(model: ScriptModel, block: Block) {
            self.model = model
            self.block = block
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            model.focusedBlockId = block.id
            model.hasActiveEdit = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            let block = block
            Task { await model.blur(block) }
        }

        func textViewDidChange(_ textView: UITextView) {
            model.liveEdit(block, text: textView.text)
        }

        func textView(_ textView: UITextView,
                      shouldChangeTextIn range: NSRange,
                      replacementText text: String) -> Bool {
            switch text {
            case "\n":
                let caret = characterOffset(in: textView, utf16Location: textView.selectedRange.location)
                let block = block
                Task { await model.splitBlock(block, caret: caret) }
                return false
            case "\t":
                tab(backward: false)
                return false
            default:
                return true
            }
        }

        func backspaceAtStart() {
            let block = block
            Task { await model.mergeIntoPrevious(block) }
        }

        func tab(backward: Bool) {
            let block = block
            Task { await model.cycleType(block, backward: backward) }
        }

        func applyCaret(_ characterOffset: Int) {
            guard let textView else { return }
            let string = textView.text ?? ""
            let bounded = max(0, min(characterOffset, string.count))
            let charIndex = string.index(string.startIndex, offsetBy: bounded)
            let location = string.utf16.distance(
                from: string.utf16.startIndex,
                to: charIndex.samePosition(in: string.utf16) ?? string.utf16.endIndex)
            if !textView.isFirstResponder { textView.becomeFirstResponder() }
            textView.selectedRange = NSRange(location: location, length: 0)
        }

        /// Convert a UTF-16 selection location into a Character offset, so the
        /// model can split the Swift String correctly.
        private func characterOffset(in textView: UITextView, utf16Location: Int) -> Int {
            let ns = textView.text as NSString? ?? ""
            let safe = max(0, min(utf16Location, ns.length))
            return ns.substring(to: safe).count
        }
    }
}

/// A UITextView that reports a Backspace pressed with the caret at the very
/// start (nothing to delete) and Shift-Tab, both of which have no plain-text
/// representation to catch in the delegate.
final class BlockUITextView: UITextView {
    var onDeleteBackwardAtStart: (() -> Void)?
    var onShiftTab: (() -> Void)?

    override func deleteBackward() {
        if selectedRange.location == 0, selectedRange.length == 0 {
            onDeleteBackwardAtStart?()
            return
        }
        super.deleteBackward()
    }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(handleShiftTab))]
    }

    @objc private func handleShiftTab() {
        onShiftTab?()
    }
}
