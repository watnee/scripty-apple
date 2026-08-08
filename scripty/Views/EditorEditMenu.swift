//
//  EditorEditMenu.swift
//  scripty
//
//  The editing menu for all three writing surfaces — screenplay elements, lyric
//  lines and notes — built in one place.
//
//  There is one rule here worth stating loudly, because getting it wrong fails
//  silently: what this returns *replaces* the system's menu. `suggestedActions`
//  has to be handed back, unwrapped, at the top level. Re-parenting it into a
//  submenu takes Cut, Copy, Paste and the spelling corrections with it, and the
//  menu simply comes up short with no error anywhere. Our own items may nest —
//  the case transforms do, to keep the first page readable — but the system's may
//  not. When there is nothing to add, nil is returned and the system menu is left
//  entirely alone.
//

import UIKit

@MainActor
enum EditorEditMenu {

    /// The menu for `range`, or nil to leave the system's own alone.
    ///
    /// `willEdit` is called immediately before a transform writes, for surfaces
    /// that need to know an edit was a deliberate gesture rather than typing —
    /// the note editor uses it to keep the change out of its typing-coalescing
    /// window, so one Undo takes back the transform and nothing else.
    static func menu(for textView: UITextView,
                     in range: NSRange,
                     appending suggested: [UIMenuElement],
                     willEdit: (() -> Void)? = nil) -> UIMenu? {
        var ours: [UIMenuElement] = []
        if let ignore = SpellcheckEditMenu.ignoreAction(for: textView, in: range) {
            ours.append(ignore)
        }
        if let cases = caseMenu(for: textView, in: range, willEdit: willEdit) {
            ours.append(cases)
        }
        guard !ours.isEmpty else { return nil }
        return UIMenu(children: ours + suggested)
    }

    /// "Text Case", holding the four transforms.
    ///
    /// Offered only on a real selection in an editable view. On a bare caret it
    /// is absent rather than guessing at "the word you are in" — the same refusal
    /// `SpellcheckWord` already makes for Ignore Spelling, and for the same
    /// reason: a transform applied to something the writer did not select is a
    /// worse outcome than a missing menu item.
    private static func caseMenu(for textView: UITextView,
                                 in range: NSRange,
                                 willEdit: (() -> Void)?) -> UIMenu? {
        guard textView.isEditable, range.length > 0 else { return nil }
        let actions = TextCaseTransform.allCases.map { transform in
            UIAction(title: transform.title,
                     image: UIImage(systemName: transform.systemImage)) { _ in
                MainActor.assumeIsolated {
                    willEdit?()
                    apply(transform, to: textView, in: range)
                }
            }
        }
        return UIMenu(title: "Text Case",
                      image: UIImage(systemName: "textformat.alt"),
                      children: actions)
    }

    /// Rewrites `range` in place.
    ///
    /// `replace(_:withText:)` rather than assigning `.text`, which matters twice
    /// over: it registers the change with UIKit's own undo manager, so the shake
    /// gesture and ⌘Z stay coherent, and it fires `textViewDidChange`, so each
    /// surface's existing save path picks the edit up with no new plumbing —
    /// the screenplay's debounced write, the lyric's per-line commit, the note's
    /// history capture. Assigning the string would do neither.
    ///
    /// The selection is put back around the result so a writer can chain
    /// transforms, and its length is measured off the *new* string rather than
    /// assumed equal: some scalars change length when their case does, and "ß"
    /// upper-cased to "SS" would otherwise leave the selection short.
    static func apply(_ transform: TextCaseTransform, to textView: UITextView, in range: NSRange) {
        let current = textView.text ?? ""
        let string = current as NSString
        guard range.location >= 0, range.length > 0,
              range.location + range.length <= string.length,
              let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
              let end = textView.position(from: start, offset: range.length),
              let textRange = textView.textRange(from: start, to: end)
        else { return }

        let replacement = transform.apply(to: string.substring(with: range))
        guard replacement != string.substring(with: range) else { return }

        textView.replace(textRange, withText: replacement)
        textView.selectedRange = NSRange(location: range.location,
                                         length: (replacement as NSString).length)
    }

    // MARK: - Hardware keyboard

    /// The ⌘⌥ chords for the four transforms.
    ///
    /// Bound on the text views rather than in the menu bar. Two responders
    /// claiming one chord is settled by responder order with the loser silently
    /// dead, and these only mean anything with a caret in a line — so the line is
    /// where they belong. The transform travels in `propertyList` so one selector
    /// serves all four.
    static func caseKeyCommands(action: Selector) -> [UIKeyCommand] {
        let keys: [(TextCaseTransform, String)] = [
            (.uppercase, "u"),
            (.lowercase, "l"),
            (.titleCase, "t"),
            (.sentenceCase, "s"),
        ]
        return keys.map { transform, key in
            let command = UIKeyCommand(title: transform.title,
                                       action: action,
                                       input: key,
                                       modifierFlags: [.command, .alternate],
                                       propertyList: transform.rawValue)
            // Nothing is selected most of the time; a chord that would do
            // nothing should read as unavailable rather than inert.
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    /// The transform a `caseKeyCommands` command carries, if it is one of ours.
    static func transform(from command: UIKeyCommand) -> TextCaseTransform? {
        guard let raw = command.propertyList as? String else { return nil }
        return TextCaseTransform(rawValue: raw)
    }
}
