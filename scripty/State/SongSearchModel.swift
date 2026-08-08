//
//  SongSearchModel.swift
//  scripty
//
//  Find-in-song over the lyric lines already on screen — `ScriptSearchModel` for
//  a song, and a step-through rather than the filter this editor used to have.
//
//  Filtering was the source of a whole class of bug the walk simply does not
//  have. A lyric line made by Return is empty, matches nothing, and used to
//  vanish from under the caret the instant it appeared; the old editor carried
//  two long comments and a special case to stop it. Nothing is ever hidden now,
//  so none of that is needed.
//
//  Simpler than the screenplay's in two ways, both because a lyric line is not a
//  screenplay element: there is no field to distinguish (a line has no character
//  cue and no tags, so every hit is the words), and no snippet machinery (a line
//  is short enough to show whole).
//
//  Input is `(id, text)` pairs, not `SongBlock`s. That keeps this pure and
//  testable with no networking, and it forces every caller through
//  `SongBlockModel.currentText` — the words on screen. Searching the server's
//  copy is what used to answer "No results" for a word the writer was looking
//  at after an hour offline.
//

import Foundation
import Observation

@Observable @MainActor
final class SongSearchModel {

    /// One matching line. The whole line is the snippet.
    struct Match: Identifiable, Hashable {
        let lineId: Int
        let text: String

        var id: Int { lineId }

        static func == (lhs: Match, rhs: Match) -> Bool { lhs.lineId == rhs.lineId }
        func hash(into hasher: inout Hasher) { hasher.combine(lineId) }
    }

    /// One lyric line as this model wants it: the id to scroll to, and the words
    /// as they stand on screen.
    struct Line {
        let id: Int
        let text: String

        init(id: Int, text: String) {
            self.id = id
            self.text = text
        }
    }

    /// What the writer typed. Call `refresh(in:)` after changing it.
    var query = ""

    // MARK: - Replace

    /// The replace row is hidden until asked for — finding is the common case.
    var isReplacing = false
    var replacement = ""
    var matchCase = false
    var wholeWord = false

    private(set) var matches: [Match] = []
    /// Index into `matches`; meaningless while `matches` is empty.
    private(set) var currentIndex = 0

    var current: Match? {
        matches.indices.contains(currentIndex) ? matches[currentIndex] : nil
    }

    var hasQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasMatches: Bool { !matches.isEmpty }

    /// The "3 of 12" readout next to the field.
    var statusText: String {
        guard hasQuery else { return "" }
        guard hasMatches else { return "No results" }
        return "\(currentIndex + 1) of \(matches.count)"
    }

    // MARK: - Searching

    /// Recompute the hit list, keeping the cursor on the same line while that
    /// line still matches — so typing another letter does not jump the writer
    /// back to the top of the song.
    func refresh(in lines: [Line]) {
        refreshReplaceTargets(in: lines)
        let needle = trimmedQuery
        guard !needle.isEmpty else {
            matches = []
            currentIndex = 0
            return
        }

        let previous = current?.lineId
        matches = Self.matches(in: lines, needle: needle, matchCase: matchCase, wholeWord: wholeWord)
        if let previous, let index = matches.firstIndex(where: { $0.lineId == previous }) {
            currentIndex = index
        } else {
            currentIndex = 0
        }
    }

    func clear() {
        query = ""
        replacement = ""
        isReplacing = false
        matches = []
        currentIndex = 0
        replaceTargets = []
    }

    // MARK: - Navigation

    /// Advance to the next hit, wrapping at the end.
    @discardableResult
    func next() -> Match? {
        guard !matches.isEmpty else { return nil }
        currentIndex = (currentIndex + 1) % matches.count
        return current
    }

    /// Step back to the previous hit, wrapping at the start.
    @discardableResult
    func previous() -> Match? {
        guard !matches.isEmpty else { return nil }
        currentIndex = (currentIndex - 1 + matches.count) % matches.count
        return current
    }

    @discardableResult
    func select(_ match: Match) -> Match? {
        guard let index = matches.firstIndex(where: { $0.lineId == match.lineId }) else { return nil }
        currentIndex = index
        return current
    }

    // MARK: - Replace targets

    /// The lines a Replace All would actually rewrite, kept rather than asked
    /// for.
    ///
    /// The replace row wants this three times over — to enable the button, to
    /// say "4 lines", and to word the confirmation — and it wants it from
    /// `body`, so typing in the replacement field would walk the whole song two
    /// or three times per character while the query beside it was carefully
    /// debounced. The screenplay's bar hit exactly this and solved it the same
    /// way.
    private(set) var replaceTargets: [Int] = []

    /// Every switch below changes the answer and none of them is debounced, so
    /// each has to say so: a tally that goes stale the moment someone flips
    /// Match Case is worse than no tally at all.
    func refreshReplaceTargets(in lines: [Line]) {
        replaceTargets = replaceTargetIds(in: lines)
    }

    func replaceTargetIds(in lines: [Line]) -> [Int] {
        let needle = trimmedQuery
        guard !needle.isEmpty else { return [] }
        return lines.compactMap { line in
            ScriptSearchModel.containsMatch(line.text, needle: needle,
                                            matchCase: matchCase, wholeWord: wholeWord)
                ? line.id : nil
        }
    }

    /// The line a single "Replace" would act on: the current hit, but only while
    /// it still holds something the present switches would change.
    func currentReplaceTarget(in lines: [Line]) -> Int? {
        guard let current, let line = lines.first(where: { $0.id == current.lineId }) else { return nil }
        return ScriptSearchModel.containsMatch(line.text, needle: trimmedQuery,
                                               matchCase: matchCase, wholeWord: wholeWord)
            ? line.id : nil
    }

    /// Re-scan after a single replace, leaving the cursor on the *next* hit to
    /// visit rather than snapping back to the top: the same line while it still
    /// holds an occurrence, otherwise whatever slid into its place. That is what
    /// makes pressing Replace repeatedly walk down the song.
    func refreshAfterReplace(in lines: [Line]) {
        refreshReplaceTargets(in: lines)
        let anchorIndex = currentIndex
        let anchorLine = current?.lineId
        let needle = trimmedQuery
        guard !needle.isEmpty else {
            matches = []
            currentIndex = 0
            return
        }
        matches = Self.matches(in: lines, needle: needle, matchCase: matchCase, wholeWord: wholeWord)
        if let anchorLine, let index = matches.firstIndex(where: { $0.lineId == anchorLine }) {
            currentIndex = index
        } else if matches.isEmpty {
            currentIndex = 0
        } else {
            currentIndex = min(anchorIndex, matches.count - 1)
        }
    }

    // MARK: - Matching

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Straight through `ScriptSearchModel.containsMatch`, deliberately.
    ///
    /// That is the client's copy of the server's rule — a literal term, an
    /// optional word boundary either side, case-insensitive unless asked — and
    /// re-deriving it here would let this editor's "4 lines" tally drift from
    /// what the server actually rewrites, which is the kind of disagreement
    /// nobody notices until a replace does too little.
    private static func matches(in lines: [Line], needle: String,
                                matchCase: Bool, wholeWord: Bool) -> [Match] {
        lines.compactMap { line in
            ScriptSearchModel.containsMatch(line.text, needle: needle,
                                            matchCase: matchCase, wholeWord: wholeWord)
                ? Match(lineId: line.id, text: line.text)
                : nil
        }
    }
}
