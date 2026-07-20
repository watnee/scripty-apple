//
//  ScriptAutocomplete.swift
//  scripty
//
//  Character-cue and scene-heading completion, ported from the web editor's
//  `fountain-power.js`.
//
//  Entirely local. The server offers a `contactSuggestions` resource, but the
//  answers here are derivable from the script already in memory, and a network
//  round trip per keystroke is the wrong shape for something that has to keep
//  up with typing. Cast names come from the project's people *and* from cues
//  already written, so a character typed straight into the script completes
//  before anyone has formally added them to the cast.
//
//  A suggestion carries the whole replacement line rather than the fragment it
//  would append. Accepting one is then a straight assignment instead of caret
//  arithmetic against text the writer may have kept editing, and the result is
//  what the tests assert on.
//

import Foundation

enum ScriptAutocomplete {

    enum Kind: Hashable {
        case character
        case scenePrefix
        case location
        case timeOfDay
    }

    struct Suggestion: Identifiable, Hashable {
        /// What is shown on the chip — the part being offered.
        let label: String
        /// What the element's whole text becomes if this is accepted.
        let replacement: String
        let kind: Kind

        var id: String { "\(kind)-\(replacement)" }
    }

    /// Nothing is offered past this many; the bar is a shortcut, not a browser.
    static let limit = 8

    /// The openers a scene heading can take, in the web app's order.
    static let scenePrefixes = ["INT. ", "EXT. ", "EST. ", "INT./EXT. ", "I/E. "]

    /// The times of day offered after the location.
    static let timesOfDay = [
        "DAY", "NIGHT", "DAWN", "DUSK", "MORNING", "AFTERNOON", "EVENING",
        "CONTINUOUS", "LATER", "MOMENTS LATER", "SAME TIME", "THE NEXT DAY",
    ]

    /// Matches a heading that already opens with a scene prefix.
    private static let scenePrefixPattern = try? NSRegularExpression(
        pattern: #"^(INT\./EXT\.?|I/E\.?|INT\.?|EXT\.?|EST\.?)[ ]"#,
        options: [.caseInsensitive])

    // MARK: - Entry point

    /// What to offer for `text` in an element of `type`.
    ///
    /// Returns nothing for element types that have no vocabulary to draw on —
    /// action and dialogue are prose, and guessing at them would fight the
    /// writer rather than help.
    static func suggestions(for text: String,
                            type: BlockType,
                            blocks: [Block],
                            characters: [Person]) -> [Suggestion] {
        switch type {
        case .character, .dualDialogue:
            return characterSuggestions(for: text, blocks: blocks, characters: characters)
        case .scene:
            return sceneSuggestions(for: text, blocks: blocks)
        default:
            return []
        }
    }

    // MARK: - Character cues

    private static func characterSuggestions(for text: String,
                                             blocks: [Block],
                                             characters: [Person]) -> [Suggestion] {
        let typed = text.trimmingCharacters(in: .whitespaces).uppercased()

        // A cue carries extensions — "MAYA (V.O.)" — and completing against the
        // extension would offer names nobody typed. Match on the bare name.
        let names = knownCharacterNames(blocks: blocks, characters: characters)
        let matches = names.filter { name in
            guard name != typed else { return false }   // already complete
            return typed.isEmpty || name.hasPrefix(typed)
        }
        return matches.prefix(limit).map {
            Suggestion(label: $0, replacement: $0, kind: .character)
        }
    }

    /// Every name that could be a cue: the cast, plus anyone already speaking.
    static func knownCharacterNames(blocks: [Block], characters: [Person]) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        func add(_ raw: String) {
            let name = bareName(raw)
            guard !name.isEmpty, seen.insert(name).inserted else { return }
            names.append(name)
        }
        for person in characters { add(person.displayName) }
        for block in blocks where block.blockType.isCharacterCue {
            add(block.content ?? "")
        }
        return names.sorted()
    }

    /// "MAYA (V.O.)" -> "MAYA". Also drops the dual-dialogue caret.
    private static func bareName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespaces).uppercased()
        if let paren = name.firstIndex(of: "(") {
            name = String(name[..<paren])
        }
        if name.hasSuffix("^") { name.removeLast() }
        return name.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Scene headings

    /// Scene headings complete in three stages — the opener, then the location,
    /// then the time of day — because that is the order they are written in and
    /// each stage has a different vocabulary.
    private static func sceneSuggestions(for text: String, blocks: [Block]) -> [Suggestion] {
        let upper = text.uppercased()

        // Stage three: past a " - ", what follows is the time of day.
        if let dash = upper.range(of: " - ", options: .backwards) {
            let head = String(upper[..<dash.upperBound])
            let typed = String(upper[dash.upperBound...])
            return timesOfDay
                .filter { typed.isEmpty || ($0.hasPrefix(typed) && $0 != typed) }
                .prefix(limit)
                .map { Suggestion(label: $0, replacement: head + $0, kind: .timeOfDay) }
        }

        // Stage one: no opener yet.
        guard let prefixRange = matchedPrefixRange(in: upper) else {
            return scenePrefixes
                .filter { upper.isEmpty || $0.hasPrefix(upper) }
                .prefix(limit)
                .map { Suggestion(label: $0.trimmingCharacters(in: .whitespaces),
                                  replacement: $0,
                                  kind: .scenePrefix) }
        }

        // Stage two: opener written, so offer places already used.
        let opener = String(upper[..<prefixRange.upperBound])
        let typed = String(upper[prefixRange.upperBound...])
        return knownLocations(blocks: blocks)
            .filter { typed.isEmpty || ($0.hasPrefix(typed) && $0 != typed) }
            .prefix(limit)
            .map { Suggestion(label: $0, replacement: opener + $0, kind: .location) }
    }

    private static func matchedPrefixRange(in upper: String) -> Range<String.Index>? {
        guard let pattern = scenePrefixPattern else { return nil }
        let range = NSRange(upper.startIndex..., in: upper)
        guard let match = pattern.firstMatch(in: upper, range: range) else { return nil }
        return Range(match.range, in: upper)
    }

    /// Places named in scene headings already written, most recent first — a
    /// writer returning to a location usually just left it.
    static func knownLocations(blocks: [Block]) -> [String] {
        var seen = Set<String>()
        var locations: [String] = []
        for block in blocks.reversed() where block.blockType == .scene {
            let heading = (block.content ?? "").uppercased()
            guard let prefix = matchedPrefixRange(in: heading) else { continue }
            var place = String(heading[prefix.upperBound...])
            if let dash = place.range(of: " - ", options: .backwards) {
                place = String(place[..<dash.lowerBound])
            }
            place = place.trimmingCharacters(in: .whitespaces)
            guard !place.isEmpty, seen.insert(place).inserted else { continue }
            locations.append(place)
        }
        return locations
    }
}
