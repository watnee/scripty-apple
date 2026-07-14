//
//  BlockTextView.swift
//  scripty
//
//  One screenplay element as an editable line of the page.
//
//  SwiftUI's TextField cannot express the screenplay writing loop: Return has
//  to split the element instead of inserting a newline, Tab has to retype it,
//  and Backspace in an empty element has to delete it and move the caret up.
//  All three are UIKit-level, so the editor is a UITextView underneath.
//

import SwiftUI
import UIKit

struct BlockTextView: UIViewRepresentable {
    let block: Block
    let text: String
    /// The caret, owned by the model — Enter and Backspace move it between blocks.
    let focus: BlockFocus?

    var onEdit: (String) -> Void
    /// Return: the text either side of the caret. `before` stays in this block,
    /// `after` moves into a new one below.
    var onReturn: (_ before: String, _ after: String) -> Void
    var onTab: (_ backward: Bool) -> Void
    /// Backspace with the caret at position 0.
    var onBackspaceAtStart: () -> Void
    var onFocus: () -> Void

    private var isFocused: Bool { focus?.blockId == block.id }

    func makeUIView(context: Context) -> ScreenplayTextView {
        let view = ScreenplayTextView()
        view.delegate = context.coordinator
        view.isScrollEnabled = false          // so intrinsic height drives layout
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.onTab = onTab
        return view
    }

    func updateUIView(_ view: ScreenplayTextView, context: Context) {
        context.coordinator.parent = self
        view.onTab = onTab

        apply(ScreenplayLayout.of(block.blockType), to: view)

        if view.text != text {
            let selection = view.selectedRange
            view.text = text
            // Reassigning text drops the selection; put the caret back where it was.
            view.selectedRange = NSRange(
                location: min(selection.location, (text as NSString).length),
                length: 0)
        }

        if isFocused {
            if !view.isFirstResponder {
                view.becomeFirstResponder()
            }
            // Only when the model moved the caret, not on every redraw — otherwise
            // typing would fight the caret back to where the last split left it.
            if let focus, context.coordinator.appliedGeneration != focus.generation {
                context.coordinator.appliedGeneration = focus.generation
                view.selectedRange = range(for: focus.caret, in: text)
            }
        } else if view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    /// SwiftUI asks for the height; a non-scrolling text view can compute it.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ScreenplayTextView,
                      context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let fitted = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width,
                      height: max(fitted.height, uiView.font?.lineHeight ?? 20))
    }

    private func range(for caret: BlockFocus.Caret, in text: String) -> NSRange {
        let length = (text as NSString).length
        switch caret {
        case .start:
            return NSRange(location: 0, length: 0)
        case .end:
            return NSRange(location: length, length: 0)
        case .offset(let offset):
            return NSRange(location: min(max(offset, 0), length), length: 0)
        }
    }

    private func apply(_ layout: ScreenplayLayout, to view: ScreenplayTextView) {
        var font = ScreenplayLayout.font(for: block)
        var traits: UIFontDescriptor.SymbolicTraits = []
        if layout.isBold || (block.textBold ?? false) { traits.insert(.traitBold) }
        if layout.isItalic || (block.textItalic ?? false) { traits.insert(.traitItalic) }
        if !traits.isEmpty,
           let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
            font = UIFont(descriptor: descriptor, size: font.pointSize)
        }
        view.font = font
        view.textColor = .label
        view.textAlignment = textAlignment(for: layout)

        // Scene headings, cues and transitions are written in caps. Let the
        // keyboard do it, so the stored text matches what is on the page —
        // UITextView has no equivalent of CSS text-transform.
        view.autocapitalizationType = layout.isUppercase ? .allCharacters : .sentences
    }

    private func textAlignment(for layout: ScreenplayLayout) -> NSTextAlignment {
        // A per-block override set in the web app wins over the element default.
        switch block.textAlign {
        case "CENTER": return .center
        case "RIGHT": return .right
        case "LEFT": return .left
        default: break
        }
        switch layout.alignment {
        case .trailing: return .right
        case .center: return .center
        default: return .left
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: BlockTextView
        /// The last caret move already applied, so a redraw does not re-apply it.
        var appliedGeneration: Int?

        init(parent: BlockTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            // Scene headings, cues and transitions are written in caps. The web
            // gets this from CSS text-transform; a UITextView has no equivalent,
            // and `autocapitalizationType` is ignored the moment a hardware
            // keyboard is attached — which is how anyone writes on an iPad. So
            // fold the case here, where every keystroke passes.
            if ScreenplayLayout.of(parent.block.blockType).isUppercase {
                let folded = textView.text.uppercased()
                if textView.text != folded {
                    let selection = textView.selectedRange
                    textView.text = folded
                    textView.selectedRange = selection
                }
            }
            parent.onEdit(textView.text)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onFocus()
        }

        func textView(_ textView: UITextView,
                      shouldChangeTextIn range: NSRange,
                      replacementText text: String) -> Bool {
            let current = textView.text as NSString

            if text == "\n" {
                let before = current.substring(to: range.location)
                let after = current.substring(from: range.location + range.length)
                parent.onReturn(before, after)
                return false
            }

            // Backspace with the caret at the very start and nothing selected.
            if text.isEmpty, range.location == 0, range.length == 0 {
                parent.onBackspaceAtStart()
                return false
            }

            return true
        }
    }
}

/// A UITextView that reports Tab. `keyCommands` is the only hook that sees Tab
/// before the system spends it moving focus between fields.
final class ScreenplayTextView: UITextView {
    var onTab: ((_ backward: Bool) -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(handleTab(_:))),
            UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(handleTab(_:))),
        ]
    }

    @objc private func handleTab(_ command: UIKeyCommand) {
        onTab?(command.modifierFlags.contains(.shift))
    }
}
