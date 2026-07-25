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

struct BlockTextView: UIViewRepresentable, Equatable {
    let model: ScriptModel
    let block: Block
    /// The suggestion list, which this view both feeds (every keystroke
    /// recomputes it) and obeys (Return accepts rather than splits while it is
    /// open).
    let autocomplete: ScriptAutocomplete
    /// This block's slice of the model's editing state, passed in as values
    /// rather than read off the model here. @Observable tracks whole
    /// properties, so an `updateUIView` that read `model.liveText[block.id]`
    /// would be invalidated by *any* block's keystroke — every visible row
    /// re-running its UIKit styling per character typed. The row reads the
    /// dictionaries instead (a cheap SwiftUI body), and the Equatable
    /// conformance below lets the untouched rows skip the UIKit work.
    let liveText: String?
    let caretRequest: Int?
    let isFocused: Bool
    let font: UIFont
    let alignment: NSTextAlignment
    let autocapitalize: UITextAutocapitalizationType
    /// Whether misspellings are underlined as the writer types.
    let spellChecks: Bool
    /// Names the screenplay element type for VoiceOver; the spoken value stays
    /// the block's own text.
    let accessibilityLabel: String

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, block: block, autocomplete: autocomplete)
    }

    func makeUIView(context: Context) -> BlockUITextView {
        let view = BlockUITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.smartDashesType = .no
        view.smartQuotesType = .no
        view.text = liveText ?? block.content ?? ""
        view.onDeleteBackwardAtStart = { [weak coordinator = context.coordinator] in
            coordinator?.backspaceAtStart()
        }
        view.onShiftTab = { [weak coordinator = context.coordinator] in
            coordinator?.tab(backward: true)
        }
        // The arrow keys and Escape only belong to the suggestion list while it
        // is open; the rest of the time they are the caret's, so the view asks
        // before claiming them.
        view.isSuggesting = { [weak coordinator = context.coordinator] in
            coordinator?.isSuggesting ?? false
        }
        view.onMoveSuggestion = { [weak coordinator = context.coordinator] delta in
            coordinator?.autocomplete.moveSelection(by: delta)
        }
        view.onDismissSuggestions = { [weak coordinator = context.coordinator] in
            coordinator?.dismissSuggestions()
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
        let desired = liveText ?? block.content ?? ""
        if liveText == nil, view.text != desired {
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

        if isFocused, !view.isFirstResponder {
            // A row just inserted into the LazyVStack isn't in the window during
            // its first update, so becomeFirstResponder() would silently no-op.
            // Defer until the view has joined the hierarchy.
            DispatchQueue.main.async { view.becomeFirstResponder() }
        }

        if let offset = caretRequest {
            let blockId = block.id
            DispatchQueue.main.async {
                context.coordinator.applyCaret(offset)
                model.caretRequests[blockId] = nil
            }
        }
    }

    /// Deterministic update-skipping for the rows a keystroke did not touch.
    /// Wrapped in `.equatable()` at the call site: when nothing this view
    /// draws from has changed, `updateUIView` is not called at all, so the
    /// per-row styling and measurement stay O(1) per keystroke rather than
    /// O(visible rows). The classes are compared by identity — the model and
    /// autocomplete are per-script singletons, and fonts come from a cache
    /// that hands back the same instance for the same key.
    static func == (lhs: BlockTextView, rhs: BlockTextView) -> Bool {
        lhs.block == rhs.block
            && lhs.liveText == rhs.liveText
            && lhs.caretRequest == rhs.caretRequest
            && lhs.isFocused == rhs.isFocused
            && lhs.font === rhs.font
            && lhs.alignment == rhs.alignment
            && lhs.autocapitalize == rhs.autocapitalize
            && lhs.spellChecks == rhs.spellChecks
            && lhs.accessibilityLabel == rhs.accessibilityLabel
            && lhs.model === rhs.model
            && lhs.autocomplete === rhs.autocomplete
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
        let autocomplete: ScriptAutocomplete
        var block: Block
        weak var textView: BlockUITextView?

        init(model: ScriptModel, block: Block, autocomplete: ScriptAutocomplete) {
            self.model = model
            self.block = block
            self.autocomplete = autocomplete
        }

        /// Whether the list is open *for this element*. The object is shared by
        /// every row, so a row that no longer has focus must not answer yes.
        var isSuggesting: Bool {
            autocomplete.isOpen && autocomplete.blockId == block.id
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            model.focusedBlockId = block.id
            model.hasActiveEdit = true
            refreshSuggestions(textView.text)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            let block = block
            if autocomplete.blockId == block.id { autocomplete.clear() }
            Task { await model.blur(block) }
        }

        func textViewDidChange(_ textView: UITextView) {
            let retypeTo = applyLiveForceDetection(textView)
            model.liveEdit(block, text: textView.text)
            if let retypeTo {
                let block = block
                Task { await model.retypeLive(block, to: retypeTo) }
            }
            refreshSuggestions(textView.text)
        }

        /// Live Fountain force-marker detection — the reflow the web editor's
        /// `input` handler runs on every keystroke. When the text opens with a
        /// force marker (`.@>~#=`, `[[`, `===`) strip it in place, keeping the
        /// caret where the browser does, and return the element to retype to
        /// (nil when the element is unchanged). The INT./`TO:`/cue heuristics
        /// stay on Return via `liveDetect`, so a half-typed word never reflows.
        private func applyLiveForceDetection(_ textView: UITextView) -> BlockType? {
            let text = textView.text ?? ""
            guard let detected = FountainDetector.liveDetect(text) else { return nil }
            let typeChanged = detected.type != block.blockType
            let contentChanged = detected.content != text
            guard typeChanged || contentChanged else { return nil }

            if contentChanged, !Coordinator.dropsLines(from: text, to: detected.content) {
                let caret = textView.selectedRange.location
                let newLength = (detected.content as NSString).length
                textView.text = detected.content
                textView.selectedRange = NSRange(location: min(caret, newLength), length: 0)
            }
            return typeChanged ? detected.type : nil
        }

        /// Whether rewriting `original` to `detected` would silently drop a line
        /// from multi-line content — the web's safety net against a rewrite
        /// collapsing a block to its first line.
        private static func dropsLines(from original: String, to detected: String) -> Bool {
            guard original.contains("\n") else { return false }
            return lineCount(detected) < lineCount(original)
        }

        private static func lineCount(_ string: String) -> Int {
            var trimmed = Substring(string)
            while let last = trimmed.last, last.isWhitespace { trimmed = trimmed.dropLast() }
            return trimmed.split(separator: "\n", omittingEmptySubsequences: false).count
        }

        func textView(_ textView: UITextView,
                      shouldChangeTextIn range: NSRange,
                      replacementText text: String) -> Bool {
            switch text {
            case "\n":
                // While the list is open Return means "yes, that one" — the
                // same bargain the web editor strikes, and the reason the list
                // closes as soon as the writer types past every match.
                if acceptSuggestion() { return false }
                let caret = characterOffset(in: textView, utf16Location: textView.selectedRange.location)
                let block = block
                Task { await model.splitBlock(block, caret: caret) }
                return false
            case "\t":
                if acceptSuggestion() { return false }
                tab(backward: false)
                return false
            default:
                return true
            }
        }

        // MARK: - Suggestions

        private func refreshSuggestions(_ text: String) {
            guard model.focusedBlockId == block.id else { return }
            autocomplete.update(blockId: block.id,
                                text: text,
                                type: block.blockType,
                                blocks: model.blocks,
                                characters: model.characters)
        }

        @discardableResult
        func acceptSuggestion() -> Bool {
            guard isSuggesting, let suggestion = autocomplete.selected else { return false }
            let block = block
            autocomplete.clear()
            Task { await model.accept(suggestion, on: block) }
            return true
        }

        func dismissSuggestions() {
            guard isSuggesting else { return }
            autocomplete.dismiss(showing: textView?.text ?? "")
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
    /// Whether a suggestion list is open for this element. The arrow keys and
    /// Escape are only borrowed while it is.
    var isSuggesting: (() -> Bool)?
    var onMoveSuggestion: ((Int) -> Void)?
    var onDismissSuggestions: (() -> Void)?

    override func deleteBackward() {
        if selectedRange.location == 0, selectedRange.length == 0 {
            onDeleteBackwardAtStart?()
            return
        }
        super.deleteBackward()
    }

    override var keyCommands: [UIKeyCommand]? {
        var commands = [
            UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(handleShiftTab))
        ]
        // Asked fresh each time UIKit builds the responder's commands, so the
        // arrows go back to moving the caret the moment the list closes.
        if isSuggesting?() == true {
            commands += [
                UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [],
                             action: #selector(handleSuggestionUp)),
                UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [],
                             action: #selector(handleSuggestionDown)),
                UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [],
                             action: #selector(handleSuggestionEscape))
            ]
        }
        return commands
    }

    @objc private func handleShiftTab() {
        onShiftTab?()
    }

    @objc private func handleSuggestionUp() {
        onMoveSuggestion?(-1)
    }

    @objc private func handleSuggestionDown() {
        onMoveSuggestion?(1)
    }

    @objc private func handleSuggestionEscape() {
        onDismissSuggestions?()
    }
}
