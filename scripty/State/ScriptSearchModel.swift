//
//  ScriptSearchModel.swift
//  scripty
//
//  Find-in-script over the blocks we already hold. Matches the web app's
//  project search: a case-insensitive substring test against the element's
//  content, the speaking character's name, and its tags. Where the web filters
//  rows out, we walk the hits one at a time — the phone equivalent.
//

import Foundation
import Observation

@Observable @MainActor
final class ScriptSearchModel {

    /// Which part of the block the query was found in.
    enum Field {
        case content, character, tags

        var label: String {
            switch self {
            case .content: return "Text"
            case .character: return "Character"
            case .tags: return "Tag"
            }
        }
    }

    struct Match: Identifiable, Hashable {
        let blockId: Int
        let type: BlockType
        /// The hit shown in context, elided at both ends where text was cut.
        let snippet: String
        let field: Field

        var id: Int { blockId }

        static func == (lhs: Match, rhs: Match) -> Bool { lhs.blockId == rhs.blockId }
        func hash(into hasher: inout Hasher) { hasher.combine(blockId) }
    }

    /// What the writer typed. Call `refresh(in:)` after changing it.
    var query = ""

    // MARK: - Replace

    /// The replace row is hidden until asked for — finding is the common case.
    var isReplacing = false
    var replacement = ""
    var matchCase = false
    var wholeWord = false
    /// Character cues mirror their person record, so rewriting one would
    /// desync the two. Off by default, exactly as on the web.
    var includeCharacterCues = false

    private(set) var matches: [Match] = []
    /// Index into `matches`; meaningless while `matches` is empty.
    private(set) var currentIndex = 0

    /// Characters of surrounding text kept on either side of a hit.
    private static let snippetContext = 28

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

    /// Recompute the hit list. Keeps the caret on the same block when that
    /// block still matches, so typing another letter doesn't jump the reader
    /// back to the top.
    func refresh(in blocks: [Block]) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else {
            matches = []
            currentIndex = 0
            return
        }

        let previous = current?.blockId
        matches = blocks.compactMap { Self.match($0, needle: needle) }
        if let previous, let index = matches.firstIndex(where: { $0.blockId == previous }) {
            currentIndex = index
        } else {
            currentIndex = 0
        }
    }

    func clear() {
        query = ""
        matches = []
        currentIndex = 0
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

    /// Jump straight to a known hit (tapping a row in a results list).
    @discardableResult
    func select(_ match: Match) -> Match? {
        guard let index = matches.firstIndex(where: { $0.blockId == match.blockId }) else { return nil }
        currentIndex = index
        return current
    }

    // MARK: - Replace targets

    /// The blocks a replace would actually touch.
    ///
    /// Deliberately narrower than `matches`: find also hits character names and
    /// tags, but replace only ever rewrites element *content*, and it honours
    /// the case and whole-word switches that find ignores. Sending the wider
    /// set would ask the server to edit blocks the writer never saw highlighted.
    func replaceTargetIds(in blocks: [Block]) -> [Int] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return blocks.compactMap { block in
            if !includeCharacterCues && block.blockType.isCharacterCue { return nil }
            let content = block.content ?? ""
            return Self.containsMatch(content, needle: needle,
                                      matchCase: matchCase, wholeWord: wholeWord)
                ? block.id : nil
        }
    }

    /// The block the single "Replace" would act on: the current hit, but only
    /// when its content holds a match a replace would actually change under the
    /// present case and whole-word switches. A hit that landed on a character
    /// name or a tag, or one the switches now exclude, has nothing in its text
    /// to swap, so there is no target and the button stays disabled.
    func currentReplaceTarget(in blocks: [Block]) -> Block? {
        guard let current, current.field == .content,
              let block = blocks.first(where: { $0.id == current.blockId }) else { return nil }
        if !includeCharacterCues && block.blockType.isCharacterCue { return nil }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.containsMatch(block.content ?? "", needle: needle,
                                  matchCase: matchCase, wholeWord: wholeWord)
            ? block : nil
    }

    /// Re-scan after a single replace, leaving the cursor on the next hit to
    /// visit rather than snapping back to the top: the same block when it still
    /// holds an occurrence, otherwise whatever slid into its place. That is what
    /// makes repeated Replace walk forward, as it does on the web.
    func refreshAfterReplace(in blocks: [Block]) {
        let anchorIndex = currentIndex
        let anchorBlock = current?.blockId
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else {
            matches = []
            currentIndex = 0
            return
        }
        matches = blocks.compactMap { Self.match($0, needle: needle) }
        if let anchorBlock, let index = matches.firstIndex(where: { $0.blockId == anchorBlock }) {
            currentIndex = index
        } else if matches.isEmpty {
            currentIndex = 0
        } else {
            currentIndex = min(anchorIndex, matches.count - 1)
        }
    }

    /// Literal containment under the same rules the server applies: `find` is
    /// never a pattern, and whole-word means a word boundary either side.
    static func containsMatch(_ text: String,
                              needle: String,
                              matchCase: Bool,
                              wholeWord: Bool) -> Bool {
        guard !needle.isEmpty else { return false }
        guard wholeWord else {
            return text.range(of: needle,
                              options: matchCase ? [.literal] : [.literal, .caseInsensitive]) != nil
        }
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: needle))\\b"
        let options: NSRegularExpression.Options = matchCase ? [] : [.caseInsensitive]
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return false
        }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: - Matching

    private static func match(_ block: Block, needle: String) -> Match? {
        let content = block.content ?? ""
        if let snippet = snippet(content, needle: needle) {
            return Match(blockId: block.id, type: block.blockType, snippet: snippet, field: .content)
        }
        if let name = block.personName, name.lowercased().contains(needle) {
            return Match(blockId: block.id, type: block.blockType, snippet: name, field: .character)
        }
        if let tags = block.tags, tags.lowercased().contains(needle) {
            return Match(blockId: block.id, type: block.blockType, snippet: tags, field: .tags)
        }
        return nil
    }

    /// The first hit inside `text` with a little context either side, or nil
    /// when the needle isn't there.
    private static func snippet(_ text: String, needle: String) -> String? {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        guard let hit = flattened.range(of: needle, options: .caseInsensitive) else { return nil }

        let start = flattened.index(hit.lowerBound, offsetBy: -snippetContext,
                                    limitedBy: flattened.startIndex) ?? flattened.startIndex
        let end = flattened.index(hit.upperBound, offsetBy: snippetContext,
                                  limitedBy: flattened.endIndex) ?? flattened.endIndex

        var snippet = String(flattened[start..<end]).trimmingCharacters(in: .whitespaces)
        if start != flattened.startIndex { snippet = "…" + snippet }
        if end != flattened.endIndex { snippet += "…" }
        return snippet
    }
}
