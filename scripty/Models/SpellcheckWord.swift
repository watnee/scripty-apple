//
//  SpellcheckWord.swift
//  scripty
//
//  Which word the writer meant when they asked to ignore one.
//
//  The editing menu hands over a selection, not a word. A tap on an underlined
//  word arrives as that word's range, but a caret parked mid-word arrives with
//  no length at all, and a drag can arrive with a comma or half a second word
//  attached. This turns any of those into the one word to add to the ignored
//  list — or into nothing, when the answer would be a guess.
//
//  Kept free of UIKit so it can be checked without a simulator: the caller
//  passes the UTF-16 range a UITextView deals in and gets one back.
//

import Foundation

enum SpellcheckWord {
    /// The word under `selection`, in the same UTF-16 offsets the caller used.
    ///
    /// Nil when the selection holds no word, or holds more than one: "Ignore
    /// Spelling" on a phrase or on a run of punctuation means nothing, and
    /// offering it would only mislead.
    static func range(in text: String, around selection: NSRange) -> NSRange? {
        let string = text as NSString
        guard string.length > 0 else { return nil }

        let start = min(max(selection.location, 0), string.length)
        let end = min(max(start + max(selection.length, 0), start), string.length)

        if end > start {
            // A selection: exactly what was selected, and nothing either side
            // of it — a writer who dragged over two words did not mean one.
            var lower = start, upper = end
            trim(string, &lower, &upper)
            guard upper > lower else { return nil }
            for index in lower..<upper where !isWordCharacter(string.character(at: index)) {
                return nil
            }
            return NSRange(location: lower, length: upper - lower)
        }

        // A caret: grow outwards over the word it sits in, or beside.
        var lower = start, upper = start
        while lower > 0, isWordCharacter(string.character(at: lower - 1)) { lower -= 1 }
        while upper < string.length, isWordCharacter(string.character(at: upper)) { upper += 1 }
        trim(string, &lower, &upper)
        guard upper > lower else { return nil }
        return NSRange(location: lower, length: upper - lower)
    }

    /// The word itself, for callers that only want the string.
    static func word(in text: String, around selection: NSRange) -> String? {
        guard let range = range(in: text, around: selection) else { return nil }
        return (text as NSString).substring(with: range)
    }

    /// Pull both edges in to the nearest letter. That drops the quotes around
    /// 'quiet' and the apostrophe after Maya' while leaving the one inside
    /// don't alone, and it is what guarantees the answer holds a letter rather
    /// than being punctuation the checker would never have flagged.
    private static func trim(_ string: NSString, _ lower: inout Int, _ upper: inout Int) {
        while lower < upper, !isLetter(string.character(at: lower)) { lower += 1 }
        while upper > lower, !isLetter(string.character(at: upper - 1)) { upper -= 1 }
    }

    /// Letters and apostrophes: what a checker treats as one word. Digits are
    /// deliberately out, so a caret in "3D" answers "D" rather than a token no
    /// dictionary was ever going to recognise.
    private static func isWordCharacter(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.letters.contains(scalar) || scalar == "'" || scalar == "\u{2019}"
    }

    private static func isLetter(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.letters.contains(scalar)
    }
}
