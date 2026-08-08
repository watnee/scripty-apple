//
//  TextCaseTransform.swift
//  scripty
//
//  Changing the case of what a writer selected, in the four ways they mean.
//
//  A screenplay is full of text that has to be shouted — a slugline, a cue, a
//  transition — and until this the only way to change one that had been typed in
//  lower case was to type it again. The same is true of a chorus a songwriter
//  decided should be capitals after all.
//
//  The judgement is why this is a type rather than four calls to Foundation:
//  `String.capitalized` turns "don't" into "Don'T" and "a tale of two cities"
//  into "A Tale Of Two Cities", neither of which is what Title Case means to
//  anybody writing English. So the rules live here, where they can be checked
//  without a simulator.
//
//  Kept free of UIKit deliberately, and not only for tidiness: the test runner
//  compiles all of Models/ into several suites at once, so an import of UIKit
//  here would break every one of them.
//

import Foundation

/// One of the four case changes offered on a selection.
enum TextCaseTransform: String, CaseIterable, Identifiable, Sendable {
    case uppercase
    case lowercase
    case titleCase
    case sentenceCase

    var id: String { rawValue }

    /// Written the way the result reads, so the menu shows what it will do.
    var title: String {
        switch self {
        case .uppercase: return "UPPERCASE"
        case .lowercase: return "lowercase"
        case .titleCase: return "Title Case"
        case .sentenceCase: return "Sentence case"
        }
    }

    var systemImage: String {
        switch self {
        case .uppercase: return "textformat.size.larger"
        case .lowercase: return "textformat.size.smaller"
        case .titleCase: return "textformat"
        case .sentenceCase: return "text.alignleft"
        }
    }

    /// Words that stay lower case inside a title, but not at either end of one.
    ///
    /// Short, and deliberately so. A longer list starts making decisions a
    /// writer did not ask for, and the ones people notice missing are these.
    private static let titleStopWords: Set<String> = [
        "a", "an", "the",
        "and", "but", "or", "nor", "for", "yet", "so",
        "as", "at", "by", "in", "of", "off", "on", "per", "to", "up", "via",
        "from", "into", "onto", "over", "with",
    ]

    func apply(to text: String) -> String {
        switch self {
        case .uppercase:
            return text.uppercased()
        case .lowercase:
            return text.lowercased()
        case .titleCase:
            return Self.titleCased(text)
        case .sentenceCase:
            return Self.sentenceCased(text)
        }
    }

    // MARK: - Title Case

    /// Capitalises each word, leaving the small words in the middle alone.
    ///
    /// Splitting on whitespace rather than on word boundaries is what keeps
    /// "don't" and "rock-'n'-roll" intact: only the first letter of a run is
    /// touched, and the rest of the run is lower-cased as a unit. Runs of
    /// whitespace are preserved exactly, so a writer's spacing survives.
    private static func titleCased(_ text: String) -> String {
        let pieces = splitKeepingWhitespace(text)
        // Which pieces are words decides what "first" and "last" mean — a
        // trailing space must not make the last word an interior one.
        let wordPositions = pieces.indices.filter { !pieces[$0].isWhitespaceRun }
        guard let first = wordPositions.first, let last = wordPositions.last else { return text }

        var result = ""
        for (index, piece) in pieces.enumerated() {
            if piece.isWhitespaceRun {
                result += piece.text
                continue
            }
            let lowered = piece.text.lowercased()
            let isEdge = index == first || index == last
            if !isEdge && titleStopWords.contains(strippedForStopWordMatch(lowered)) {
                result += lowered
            } else {
                result += capitalizingFirstLetter(lowered)
            }
        }
        return result
    }

    /// A stop word wearing punctuation is still a stop word: `(of` matches `of`.
    private static func strippedForStopWordMatch(_ word: String) -> String {
        String(word.unicodeScalars
            .drop(while: { !CharacterSet.letters.contains($0) })
            .reversed()
            .drop(while: { !CharacterSet.letters.contains($0) })
            .reversed()
            .map(Character.init))
    }

    /// Upper-cases the first *letter*, not the first character.
    ///
    /// So an opening quote or bracket does not absorb the capital and leave the
    /// word itself lower case — `"hello` becomes `"Hello`.
    private static func capitalizingFirstLetter(_ word: String) -> String {
        guard let index = word.firstIndex(where: { $0.isLetter }) else { return word }
        return String(word[word.startIndex..<index])
            + String(word[index]).uppercased()
            + String(word[word.index(after: index)...])
    }

    // MARK: - Sentence case

    /// Lower-cases everything, then capitalises the start of each sentence.
    ///
    /// A sentence starts at the beginning of the text, after `.`, `?` or `!`,
    /// and after a line break — a lyric or an outline line is its own sentence
    /// whether or not it was punctuated. A standalone "I" is put back, since
    /// lower-casing it is the one change that reads as a mistake rather than a
    /// choice.
    private static func sentenceCased(_ text: String) -> String {
        // Quotes and brackets sit between a full stop and the first letter often
        // enough that they must not end the pause.
        let transparent: Set<Character> = ["\"", "'", "(", "[", "“", "‘", "«"]
        var result = ""
        var startOfSentence = true

        for character in text.lowercased() {
            if startOfSentence, character.isLetter {
                result += String(character).uppercased()
                startOfSentence = false
                continue
            }
            if character == "." || character == "?" || character == "!" || character.isNewline {
                startOfSentence = true
            } else if !character.isWhitespace && !transparent.contains(character) {
                startOfSentence = false
            }
            result.append(character)
        }
        return restoringStandaloneI(in: result)
    }

    private static func restoringStandaloneI(in text: String) -> String {
        var result = ""
        var current = ""
        for character in text {
            if character.isLetter || character == "'" || character == "’" {
                current.append(character)
            } else {
                result += Self.fixedPronoun(current)
                current = ""
                result.append(character)
            }
        }
        result += Self.fixedPronoun(current)
        return result
    }

    /// `i`, `i'm`, `i'll`, `i've`, `i'd` — the contractions people actually type.
    private static func fixedPronoun(_ word: String) -> String {
        guard word.first == "i" else { return word }
        let rest = word.dropFirst()
        guard rest.isEmpty || rest.first == "'" || rest.first == "’" else { return word }
        return "I" + rest
    }

    // MARK: - Splitting

    private struct Piece {
        var text: String
        var isWhitespaceRun: Bool
    }

    /// Runs of whitespace and runs of non-whitespace, in order, losing nothing.
    private static func splitKeepingWhitespace(_ text: String) -> [Piece] {
        var pieces: [Piece] = []
        var current = ""
        var currentIsWhitespace: Bool?

        for character in text {
            let isWhitespace = character.isWhitespace
            if currentIsWhitespace == nil {
                currentIsWhitespace = isWhitespace
            } else if currentIsWhitespace != isWhitespace {
                pieces.append(Piece(text: current, isWhitespaceRun: currentIsWhitespace == true))
                current = ""
                currentIsWhitespace = isWhitespace
            }
            current.append(character)
        }
        if let currentIsWhitespace, !current.isEmpty {
            pieces.append(Piece(text: current, isWhitespaceRun: currentIsWhitespace))
        }
        return pieces
    }
}
