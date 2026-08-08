//
//  HelpSearch.swift
//  scripty
//
//  What the help centre's search box does with what you typed.
//
//  It used to be one line: lowercase the query, split it on spaces, and ask
//  whether every word appeared anywhere in the topic. That is three problems
//  in a row. `act` found Characters, Elements and half of Writing, because a
//  substring does not care where a word begins. `Find & Replace` found
//  nothing, because the ampersand was welded to the words on either side of
//  it. And whatever did match came back in the order it happened to be
//  written in, so the one topic that was actually about the query could be
//  the last row on the screen.
//
//  So: cut both the query and the prose into words, match a word against the
//  *start* of a word, and keep a score while doing it. A hit in a heading is
//  worth more than the same word buried in the ninth paragraph of Songs and
//  Notes, because the reader who typed it meant the heading.
//
//  Foundation only, deliberately: the whole of it can be checked without a
//  running view, which is the point of the content being data in the first
//  place.
//

import Foundation

/// Text cut down to the words a search can compare.
enum HelpText {
    /// The words of `text` with where each one sits, case- and accent-folded.
    ///
    /// The ranges are into the string as given, so the caller can show the
    /// reader where their word landed. Only the comparison is folded — folding
    /// the whole string first would move the indices out from under it, since
    /// a ligature or a composed accent need not fold to its own length.
    static func wordRanges(in text: String) -> [(range: Range<String.Index>, word: String)] {
        var found: [(Range<String.Index>, String)] = []
        var start: String.Index?

        // An apostrophe holds a word together — `doesn't` is one word, not two
        // — but the same character closes a quotation, so one on either end is
        // punctuation and gets trimmed back off.
        func flush(_ end: String.Index) {
            guard var lower = start else { return }
            start = nil
            var upper = end
            while lower < upper, isApostrophe(text[lower]) { lower = text.index(after: lower) }
            while lower < upper, isApostrophe(text[text.index(before: upper)]) {
                upper = text.index(before: upper)
            }
            guard lower < upper else { return }
            found.append((lower..<upper, fold(String(text[lower..<upper]))))
        }

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isLetter || character.isNumber || isApostrophe(character) {
                if start == nil { start = index }
            } else {
                flush(index)
            }
            index = text.index(after: index)
        }
        flush(text.endIndex)
        return found
    }

    /// Just the words, for anything that has no use for where they were.
    static func words(_ text: String) -> [String] {
        wordRanges(in: text).map(\.word)
    }

    /// One word, folded: case, accents and full-width forms all gone, and the
    /// two apostrophes made one.
    ///
    /// The prose here is typeset — it uses `\u{2019}` throughout — and a
    /// software keyboard hands over the same character, but a hardware one
    /// hands over `'`. Left alone that is a word the reader can see on the
    /// screen and cannot type.
    ///
    /// No locale, on purpose. The help centre is written in English, and a
    /// device set to Turkish would otherwise fold `I` to `ı` and stop the word
    /// `Import` from ever matching itself.
    static func fold(_ word: String) -> String {
        word.replacingOccurrences(of: "\u{2019}", with: "'")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: nil)
    }

    /// `word` with a plural `s` taken off.
    ///
    /// Matching is by prefix, so `note` already finds `notes`; this is the
    /// other direction, where the reader typed the plural and the prose says
    /// it once, in the singular. Nothing cleverer than that: a stemmer that
    /// knew `indices` from `index` would be a library, and this is a help
    /// sheet. Both sides go through it, so `press` losing its `s` costs
    /// nothing — the prose loses the same one.
    static func stem(_ word: String) -> String {
        guard word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") else { return word }
        return String(word.dropLast())
    }

    private static func isApostrophe(_ character: Character) -> Bool {
        character == "'" || character == "\u{2019}"
    }
}

/// A query typed into the help search box, reduced to the words it is made of.
struct HelpQuery: Equatable {
    /// Folded and stemmed, in the order they were typed.
    let words: [String]

    init(_ raw: String) {
        words = HelpText.words(raw).map(HelpText.stem)
    }

    var isEmpty: Bool { words.isEmpty }

    /// Whether a word of the prose answers a word of the query.
    ///
    /// A prefix, not a substring: `act` reaches `action` and stops there,
    /// instead of also reaching `character`, `exactly` and `practice`, which
    /// is what put six unrelated topics on the screen for a three-letter word.
    static func word(_ word: String, answers queryWord: String) -> Bool {
        HelpText.stem(word).hasPrefix(queryWord)
    }

    /// Whether every word of the query lands somewhere in `text`.
    ///
    /// For the short strings that have no index behind them — a row of the
    /// keyboard reference, say — so that they are matched by the rule the
    /// topics are matched by rather than by one of their own.
    func matches(_ text: String) -> Bool {
        guard !isEmpty else { return true }
        let candidates = HelpText.words(text)
        return words.allSatisfy { queryWord in
            candidates.contains { HelpQuery.word($0, answers: queryWord) }
        }
    }

    /// The ranges of `text` this query matched.
    ///
    /// The reason a result can point at itself. Some of these topics run to
    /// fourteen paragraphs, and one that opens to a wall of prose with no mark
    /// on it has answered the question by handing it back.
    func matchRanges(in text: String) -> [Range<String.Index>] {
        guard !isEmpty else { return [] }
        return HelpText.wordRanges(in: text).compactMap { found in
            words.contains { HelpQuery.word(found.word, answers: $0) } ? found.range : nil
        }
    }
}

/// How well one topic answers a query: how much of it landed, and how well.
///
/// Words first, points second. A topic that answers both words of `title page`
/// comes before one that answers `page` twice over, however loudly.
struct HelpRelevance: Equatable, Comparable {
    let matchedWords: Int
    let points: Int

    static let none = HelpRelevance(matchedWords: 0, points: 0)

    static func < (lhs: HelpRelevance, rhs: HelpRelevance) -> Bool {
        lhs.matchedWords == rhs.matchedWords
            ? lhs.points < rhs.points
            : lhs.matchedWords < rhs.matchedWords
    }
}

/// One topic's words, folded once and kept.
///
/// Sixty kilobytes of prose gets folded on the first keystroke and never
/// again — the sort of cost that is invisible on the machine it was written
/// on and obvious on a phone with a slower one.
struct HelpTopicIndex {
    let title: [String]
    let keywords: [String]
    let section: [String]
    let body: [String]

    /// Where a word can land, and what landing there is worth.
    ///
    /// The gaps are wide on purpose: no amount of repetition in a paragraph
    /// should push a topic past one whose heading is the thing being asked
    /// about.
    private enum Weight {
        static let title = 60
        static let keyword = 25
        static let section = 12
        static let body = 5
        /// All of the query in the heading, in the order it was typed —
        /// `find replace` at Find and Replace, which no per-word score can
        /// tell apart from a heading that merely contains both words.
        static let titleOrder = 80
    }

    init(title: String, keywords: [String], section: String, paragraphs: [String]) {
        self.title = HelpText.words(title)
        self.keywords = HelpText.words(keywords.joined(separator: " "))
        self.section = HelpText.words(section)
        self.body = HelpText.words(paragraphs.joined(separator: " "))
    }

    func relevance(for query: HelpQuery) -> HelpRelevance {
        guard !query.isEmpty else { return .none }
        var matched = 0
        var points = 0
        for queryWord in query.words {
            var best = 0
            if Self.hits(title, queryWord) { best = Weight.title }
            if best < Weight.keyword, Self.hits(keywords, queryWord) { best = Weight.keyword }
            if best < Weight.section, Self.hits(section, queryWord) { best = Weight.section }
            if best < Weight.body, Self.hits(body, queryWord) { best = Weight.body }
            if best > 0 {
                matched += 1
                points += best
            }
        }
        if matched == query.words.count, titleReadsAsTheQuery(query) {
            points += Weight.titleOrder
        }
        return HelpRelevance(matchedWords: matched, points: points)
    }

    /// Whether the query's words all appear in the heading, in the order they
    /// were typed. Words may stand between them — a reader typing
    /// `find replace` is asking for Find and Replace, not for a phrase.
    private func titleReadsAsTheQuery(_ query: HelpQuery) -> Bool {
        var remaining = query.words[...]
        for word in title {
            guard let next = remaining.first else { break }
            if HelpQuery.word(word, answers: next) { remaining = remaining.dropFirst() }
        }
        return remaining.isEmpty
    }

    private static func hits(_ words: [String], _ queryWord: String) -> Bool {
        words.contains { HelpQuery.word($0, answers: queryWord) }
    }
}
