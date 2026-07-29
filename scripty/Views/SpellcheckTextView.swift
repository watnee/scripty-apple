//
//  SpellcheckTextView.swift
//  scripty
//
//  The spell-checking half of the three writing surfaces — screenplay
//  elements, lyric lines and notes.
//
//  Two things all three need and none of them should own:
//
//  * **Ignore Spelling in the editing menu.** The browser's route onto the
//    ignored list is its own popup on an underlined word. The system menu here
//    offers corrections but no way to say "that is a character's name, leave it
//    alone", so until this the only route was to leave the page, find a
//    settings screen and type the word out a second time. Now the word is
//    where the writer is already looking.
//  * **Repainting when the list changes.** A word the checker has already
//    judged keeps its underline until something makes it look again, so
//    ignoring a word appeared to do nothing until the line was retyped.
//

import UIKit

/// A UITextView that follows the ignored-words list.
///
/// The stored revision lives on the view rather than on the screen around it
/// because these views come and go as a list scrolls: a row recycled into place
/// must be able to say for itself which version of the list it last checked
/// against.
@MainActor
protocol SpellcheckingTextView: UITextView {
    var checkedSpellingRevision: Int { get set }
}

extension SpellcheckingTextView {
    /// Turn checking on or off, and re-check when the ignored list has moved on.
    ///
    /// Callers that style their text themselves should call this *before* the
    /// styling: a re-check reassigns the string, which drops any attributes on
    /// it.
    func applySpellchecking(_ enabled: Bool, revision: Int) {
        // Explicit rather than `.default`, which would mean "on" and leave the
        // preference with nothing to say — and a live text view only adopts the
        // change once its input configuration is asked for again.
        let checking: UITextSpellCheckingType = enabled ? .yes : .no
        if spellCheckingType != checking {
            spellCheckingType = checking
            if isFirstResponder { reloadInputViews() }
        }

        guard checkedSpellingRevision != revision else { return }
        checkedSpellingRevision = revision
        if checking == .yes { recheckSpelling() }
    }

    /// Ask the checker to look again at text it has already been over.
    ///
    /// Reassigning the string is what does it — rebuilding the text storage is
    /// the only thing that makes the input system reconsider a word it has
    /// already judged. The selection is put back afterwards; a composing
    /// keyboard (`markedTextRange`) is left strictly alone, since replacing the
    /// string underneath one loses whatever is half-typed.
    func recheckSpelling() {
        let current = text ?? ""
        guard !current.isEmpty, markedTextRange == nil else { return }
        let selection = selectedRange
        text = ""
        text = current
        if selectedRange != selection { selectedRange = selection }
    }
}

/// "Ignore Spelling", added to whatever the system already offers for the word
/// under the selection.
@MainActor
enum SpellcheckEditMenu {
    /// The menu to show for `range`, or nil to leave the system's own alone.
    ///
    /// Offered for any single word not already on the list, rather than only
    /// for words a checker calls wrong. That is deliberate, and it is the one
    /// place this feature does not follow `UITextChecker`: the underline a
    /// writer is looking at is drawn by the keyboard, and asking the checker
    /// about the same word frequently comes back "nothing wrong here" — so
    /// gating on its verdict left the entry missing at exactly the moment it
    /// was wanted, which reads as a broken button. An entry that is always
    /// there when a word is selected is worth more than a tidier menu.
    ///
    /// The system's own suggestions are handed back alongside it: what this
    /// returns *replaces* the menu rather than adding to it, so dropping them
    /// would take the spelling corrections with it.
    static func menu(for textView: UITextView,
                     in range: NSRange,
                     appending suggested: [UIMenuElement]) -> UIMenu? {
        guard textView.spellCheckingType != .no,
              let word = ignorableWord(in: textView, at: range)
        else { return nil }

        let ignore = UIAction(title: "Ignore Spelling",
                              image: UIImage(systemName: "character.book.closed")) { _ in
            MainActor.assumeIsolated {
                SpellcheckDictionary.shared.add(word)
                // This view is the one the writer is looking at, and a change to
                // the list may not re-lay it out; the rest of the screen picks
                // the new revision up through SwiftUI.
                (textView as? any SpellcheckingTextView)?.recheckSpelling()
            }
        }
        // First, so it is on the menu's first page: the corrections are what a
        // writer takes when the word was a typo, and this is what they reach
        // for when it was a name all along.
        return UIMenu(children: [ignore] + suggested)
    }

    /// The word under the selection, unless the list already covers it.
    private static func ignorableWord(in textView: UITextView, at range: NSRange) -> String? {
        guard let word = SpellcheckWord.word(in: textView.text ?? "", around: range),
              !SpellcheckDictionary.shared.contains(word)
        else { return nil }
        return word
    }
}
