//
//  WordCountMemo.swift
//  scripty
//
//  Counting the same words over and over.
//
//  Every document surface shows a live word count, and each of them read it
//  straight out of `body` — so a note of two thousand words was split into
//  words again on every keystroke, and the two workspaces did it once per open
//  document, from inside a section header that redraws whenever anything in
//  that document moves.
//
//  The screenplay has memoized its own count for a while (`ScriptView`); this
//  is the same trick, small enough to hand to a document.
//

import Foundation

/// A word count that is only recomputed when the words change.
///
/// A reference type on purpose, in two roles: held in `@State` by a view, where
/// mutating a property of a class instance is not a write to the `@State` value
/// and so is allowed from `body`; or held by an `@Observable` document, where
/// it must be marked `@ObservationIgnored` — writing observed state during a
/// render is what makes SwiftUI complain, and this is written during one.
@MainActor
final class WordCountMemo {
    private var counted: [String]?
    private var total = 0

    /// The number of words across these pieces of text.
    ///
    /// Comparing the strings is the cost of a miss; splitting them into words
    /// is the cost this avoids, and it is much the larger of the two. The
    /// comparison also short-circuits on the first character that differs,
    /// which a keystroke at the end of a long note does not reach.
    func words(in pieces: [String]) -> Int {
        if let counted, counted == pieces { return total }
        let words = pieces.reduce(0) { $0 + ScriptStats.countWords($1) }
        counted = pieces
        total = words
        return words
    }

    /// One piece of text — a note, or a song kept as one lump rather than as
    /// lines.
    func words(in text: String) -> Int { words(in: [text]) }
}
