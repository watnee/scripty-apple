//
//  DocumentStats.swift
//  scripty
//
//  How long a song or a note is, in the terms those two are actually measured
//  in — the counterpart of `ScriptStats` for the other two writing surfaces.
//
//  Until this a writer could learn one number about a song (its word count, in
//  the "…" menu) and nothing at all about its shape. The screenplay has had a
//  whole sheet since the port.
//
//  Two things it deliberately does not do:
//
//  * **No page estimate.** A song is measured in lines and a note in
//    paragraphs; dividing either by 250 words would be a number with nothing
//    behind it. The lyric readout already says so in as many words.
//  * **No verse or chorus labels.** A `SongBlock` is id, order, content and
//    highlight — there is no section marker on the server, and reading "[Chorus]"
//    out of the words would be guessing at a convention this app never asked
//    anybody to follow. "Sections" counts runs of lines between blank ones,
//    which is the one structural signal the data really carries, and the sheet
//    says that is what it means.
//
//  Every word count comes from `ScriptStats.countWords`, never from a local
//  `split`. The screenplay sheet, the running readout, the two workspaces and
//  both "…" rows already descend from that one function, and two different
//  counts for the same document read as one of them being broken.
//
//  Foundation only: Tests/run.sh compiles all of Models/ into several suites at
//  once, and a UIKit import here would break every one of them.
//

import Foundation

struct DocumentStats: Equatable {
    /// What was measured, for the rows that only make sense on one of them.
    ///
    /// `nonisolated` because the module defaults to MainActor and this is pure
    /// data: without it the derived `Equatable` is main-actor isolated, and
    /// comparing two kinds anywhere else — a test, a background summary — is a
    /// warning today and an error under Swift 6.
    nonisolated enum Kind: Equatable {
        case song
        case note
    }

    var kind: Kind

    var words = 0
    /// Lines with something on them. Blank ones are counted separately, since
    /// in a lyric a blank line is a deliberate gap rather than nothing.
    var lines = 0
    var blankLines = 0
    var characters = 0
    var charactersNoSpaces = 0
    var uniqueWords = 0

    /// The longest line (song) or paragraph (note), and how many words it holds.
    var longestLineWords = 0
    var longestLine = ""

    /// Runs of non-blank lines: verses, choruses and bridges in a song;
    /// paragraphs in a note.
    var sections = 0

    /// Notes only — zero on a song, which has neither.
    var headings = 0
    var listItems = 0

    var readingSeconds = 0

    /// Nothing written yet, so the sheet shows its empty state rather than a
    /// grid of zeroes.
    var hasNothingToMeasure: Bool { words == 0 && lines == 0 }

    /// A comfortable reading pace. The same figure the web uses for its own
    /// estimate, so the two never disagree about the same note.
    static let wordsPerMinute = 200

    // MARK: - Building

    /// A song, one entry per lyric line.
    ///
    /// The caller passes what is on screen — `SongBlockModel.currentText` — not
    /// what the server last confirmed, so the numbers describe the words the
    /// writer is looking at.
    init(lyricLines: [String]) {
        self.init(kind: .song, lines: lyricLines)
    }

    /// A note, as one block of prose.
    ///
    /// Headings and list items are counted through `NoteFormatting.kind(of:)`
    /// rather than by looking for "#" and "- " here: that rule already exists,
    /// the reading surface uses it, and a second copy would drift.
    init(noteText: String) {
        let rawLines = noteText.components(separatedBy: "\n")
        self.init(kind: .note, lines: rawLines)

        for line in rawLines {
            switch NoteFormatting.kind(of: line) {
            case .heading: headings += 1
            case .bullet, .numbered: listItems += 1
            case .blank, .plain: break
            }
        }
    }

    private init(kind: Kind, lines rawLines: [String]) {
        self.kind = kind

        var seen = Set<String>()
        var inSection = false

        for line in rawLines {
            let isBlank = line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isBlank {
                blankLines += 1
                inSection = false
                continue
            }
            lines += 1
            if !inSection {
                sections += 1
                inSection = true
            }

            let lineWords = ScriptStats.countWords(line)
            words += lineWords
            if lineWords > longestLineWords {
                longestLineWords = lineWords
                longestLine = line.trimmingCharacters(in: .whitespaces)
            }
            for word in Self.words(in: line) {
                seen.insert(word)
            }
        }

        // Characters count the document as written, blank lines and all — it is
        // a length, not a summary.
        let whole = rawLines.joined(separator: "\n")
        characters = whole.count
        charactersNoSpaces = whole.filter { !$0.isWhitespace }.count

        uniqueWords = seen.count
        readingSeconds = words == 0
            ? 0
            : max(1, Int((Double(words) / Double(Self.wordsPerMinute) * 60).rounded()))
    }

    // MARK: - Words

    /// The distinct words of a line, case-folded and stripped of the
    /// punctuation that hangs off either end.
    ///
    /// Folded so "Love" and "love" are one word, which is what a writer asking
    /// how many different words they used means. An apostrophe is kept, since
    /// "don't" is one word and "dont" is not a word at all.
    private static func words(in line: String) -> [String] {
        line.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map { token in
                String(token.drop(while: { !$0.isLetter && !$0.isNumber })
                    .reversed()
                    .drop(while: { !$0.isLetter && !$0.isNumber })
                    .reversed())
            }
            .filter { !$0.isEmpty }
    }

    // MARK: - Reading

    /// "1 min", "4 min", "less than a minute" — never a raw second count, which
    /// nobody reads a document in.
    var readingTimeText: String {
        guard readingSeconds > 0 else { return "—" }
        if readingSeconds < 60 { return "under a minute" }
        let minutes = Int((Double(readingSeconds) / 60).rounded())
        return "\(max(1, minutes)) min"
    }

    /// Grouped exactly as every other count in the app is.
    func formatted(_ value: Int) -> String {
        ScriptWordCount.formatted(value)
    }

    /// What the "Sections" row means, in the writer's own terms rather than the
    /// data's — and honest that it is counting gaps, not labels.
    var sectionsHint: String {
        switch kind {
        case .song: return "Verses, choruses and bridges — runs of lines with a gap between them."
        case .note: return "Paragraphs — runs of lines with a blank line between them."
        }
    }

    var longestLineLabel: String {
        kind == .song ? "Longest line" : "Longest paragraph"
    }

    var linesLabel: String {
        kind == .song ? "Lines" : "Lines of text"
    }
}
