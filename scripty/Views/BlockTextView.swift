//
//  BlockTextView.swift
//  scripty
//
//  A text view for one screenplay element. SwiftUI's TextEditor can't tell us
//  that Return was pressed — it just inserts a newline — but Return is the most
//  important key in a screenplay editor, so the field is a UITextView whose
//  keys we intercept, mirroring the web editor's keydown handler.
//
//  Return       commit this element, open the next one
//  Backspace    at the top of an empty element, take it back
//  Tab / ⇧Tab   cycle this element's type
//  ⌘1…⌘7        set the type outright
//

import SwiftUI
import UIKit

struct BlockTextView: UIViewRepresentable {
    @Binding var text: String
    let type: BlockType
    let isFocused: Bool

    var onFocus: () -> Void = {}
    var onReturn: (String) -> Void = { _ in }
    var onBackspaceIntoPrevious: () -> Void = {}
    var onCycleType: (_ backward: Bool) -> Void = { _ in }
    var onSetType: (BlockType) -> Void = { _ in }
    /// Blur, i.e. the caret left this element — save what's in it.
    var onCommit: (String) -> Void = { _ in }

    func makeUIView(context: Context) -> ScriptTextView {
        let view = ScriptTextView()
        view.delegate = context.coordinator
        view.actions = context.coordinator
        // The row owns the height; a scrolling text view inside a scrolling
        // list would trap the writer's scroll gesture.
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.spellCheckingType = .yes
        // Autocorrect has to be off: it "fixes" screenplay grammar into prose —
        // INT. becomes Isn't. and the scene heading never gets recognised.
        // Spelling is still flagged, which is what the web editor does too.
        view.autocorrectionType = .no
        view.smartQuotesType = .no          // a screenplay is a plain-text format
        view.smartDashesType = .no
        return view
    }

    func updateUIView(_ view: ScriptTextView, context: Context) {
        context.coordinator.parent = self

        if view.text != text {
            view.text = text
        }
        view.font = Self.font(for: type)
        view.textAlignment = Self.alignment(for: type)
        view.textColor = BlockStyle.of(type).isSecondary ? .secondaryLabel : .label

        // Cues and headings are upper case on the page, so the keyboard types
        // them that way rather than making the writer hold shift.
        let capitalization: UITextAutocapitalizationType =
            type.isUppercased ? .allCharacters : .sentences
        if view.autocapitalizationType != capitalization {
            view.autocapitalizationType = capitalization
            // The keyboard only picks up a new trait on reload.
            if view.isFirstResponder { view.reloadInputViews() }
        }

        // Focus is state the model owns: whichever block it names holds the caret.
        if isFocused, !view.isFirstResponder {
            DispatchQueue.main.async { view.becomeFirstResponder() }
        } else if !isFocused, view.isFirstResponder {
            DispatchQueue.main.async { view.resignFirstResponder() }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // MARK: - Typography

    static func font(for type: BlockType) -> UIFont {
        let style = BlockStyle.of(type)
        // Screenplay convention: Courier-style monospace at a fixed size.
        var font = UIFont.monospacedSystemFont(ofSize: 16,
                                               weight: style.isBold ? .bold : .regular)
        if style.isItalic,
           let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) {
            font = UIFont(descriptor: descriptor, size: font.pointSize)
        }
        return font
    }

    static func alignment(for type: BlockType) -> NSTextAlignment {
        switch BlockStyle.of(type).alignment {
        case .center: return .center
        case .trailing: return .right
        default: return .left
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, ScriptTextViewActions {
        var parent: BlockTextView

        init(parent: BlockTextView) {
            self.parent = parent
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onFocus()
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            // The row grows with the text as it wraps.
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onCommit(textView.text)
        }

        func textView(_ textView: UITextView,
                      shouldChangeTextIn range: NSRange,
                      replacementText text: String) -> Bool {
            switch text {
            case "\n":
                parent.onReturn(textView.text)
                return false
            case "\t":
                // A hardware Tab reaches us as text when no key command claims it.
                parent.onCycleType(false)
                return false
            default:
                return true
            }
        }

        // MARK: ScriptTextViewActions

        /// Backspace only leaves the block when there's nothing left in it and the
        /// caret is at the very top — otherwise it deletes a character as usual.
        func shouldLeaveOnBackspace(_ textView: ScriptTextView) -> Bool {
            guard textView.text.isEmpty else { return false }
            parent.onBackspaceIntoPrevious()
            return true
        }

        func cycleType(backward: Bool) {
            parent.onCycleType(backward)
        }

        func setType(_ type: BlockType) {
            parent.onSetType(type)
        }
    }
}

// MARK: - UITextView subclass

@MainActor
protocol ScriptTextViewActions: AnyObject {
    /// Returns true when the delete was handled as "leave this block".
    func shouldLeaveOnBackspace(_ textView: ScriptTextView) -> Bool
    func cycleType(backward: Bool)
    func setType(_ type: BlockType)
}

/// Carries the key handling a screenplay editor needs and UITextView doesn't offer.
final class ScriptTextView: UITextView {
    weak var actions: ScriptTextViewActions?

    override var intrinsicContentSize: CGSize {
        // With scrolling off the text view is as tall as its text, which is what
        // lets each block sit in the list at its natural height.
        let width = bounds.width > 0 ? bounds.width : UIView.noIntrinsicMetric
        guard width != UIView.noIntrinsicMetric else { return super.intrinsicContentSize }
        let fitted = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: UIView.noIntrinsicMetric,
                      height: max(fitted.height, font?.lineHeight ?? 20))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Width changes (rotation, split view) change how the text wraps.
        invalidateIntrinsicContentSize()
    }

    override func deleteBackward() {
        if actions?.shouldLeaveOnBackspace(self) == true { return }
        super.deleteBackward()
    }

    override var keyCommands: [UIKeyCommand]? {
        var commands = [
            UIKeyCommand(input: "\t", modifierFlags: [],
                         action: #selector(handleTab(_:))),
            UIKeyCommand(input: "\t", modifierFlags: .shift,
                         action: #selector(handleBackTab(_:))),
        ]
        for digit in 1...7 {
            commands.append(
                UIKeyCommand(input: "\(digit)", modifierFlags: .command,
                             action: #selector(handleTypeDigit(_:))))
        }
        for command in commands {
            // Otherwise the key beeps through to the system before we see it.
            command.wantsPriorityOverSystemBehavior = true
        }
        return commands
    }

    @objc private func handleTab(_ sender: UIKeyCommand) {
        actions?.cycleType(backward: false)
    }

    @objc private func handleBackTab(_ sender: UIKeyCommand) {
        actions?.cycleType(backward: true)
    }

    @objc private func handleTypeDigit(_ sender: UIKeyCommand) {
        guard let digit = sender.input?.first,
              let type = FountainRules.type(forDigit: digit) else { return }
        actions?.setType(type)
    }
}
