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
        apply(font: font, alignment: alignment, capitalize: autocapitalize, to: view)
        return view
    }

    func updateUIView(_ view: BlockUITextView, context: Context) {
        context.coordinator.block = block
        apply(font: font, alignment: alignment, capitalize: autocapitalize, to: view)

        // While the writer is mid-keystroke the model mirrors the view via
        // `liveText`, so leave the view alone. Once liveText is cleared the
        // model's value is authoritative again (a split trimmed this block, a
        // merge grew it, a retype rewrote it) and must be pushed back in — even
        // if the block still holds the caret.
        let desired = model.currentText(block)
        if model.liveText[block.id] == nil, view.text != desired {
            view.text = desired
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
                       capitalize: UITextAutocapitalizationType, to view: BlockUITextView) {
        if view.font != font { view.font = font }
        if view.textAlignment != alignment { view.textAlignment = alignment }
        if view.autocapitalizationType != capitalize { view.autocapitalizationType = capitalize }
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
