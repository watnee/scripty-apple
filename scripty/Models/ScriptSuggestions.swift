//
//  ScriptSuggestions.swift
//  scripty
//
//  What to offer the writer as they type, ported from the web editor's
//  autocomplete in fountain-power.js.
//
//  A screenplay repeats itself on purpose: the same characters speak, the same
//  locations come back, and a heading is nearly always one of a handful of
//  shapes. So there are two things worth completing — a character cue against
//  the cast, and a scene heading against the headings already written — and the
//  heading splits into three stages as it is typed, since "INT." wants a
//  location next and a location followed by " - " wants a time of day.
//
//  Everything here is computed from the blocks already loaded. Nothing is
//  fetched: the cast and the scene list are both already on screen.
//

import Foundation

/// One thing the writer could accept.
struct ScriptSuggestion: Identifiable, Equatable {
    /// The text the element becomes — the *whole* line, not the remainder, so
    /// accepting is an assignment rather than an insertion.
    let text: String
    /// The character this cue names, when the cast knows them. Accepting links
    /// the element to the person rather than just spelling their name.
    var personId: Int?
    /// The element the line should become once accepted, when accepting also
    /// implies a retype (typing "INT." into an action line).
    var becomesType: BlockType?

    var id: String { text }
}

enum ScriptSuggestions {
    /// How many fit above the keyboard without burying the line being typed.
    static let limit = 8

    private static let standardTimes = [
        "DAY", "NIGHT", "DAWN", "DUSK", "MORNING", "AFTERNOON", "EVENING",
        "CONTINUOUS", "LATER", "MOMENTS LATER", "SAME TIME", "THE NEXT DAY"
    ]

    private static let scenePrefixes = ["INT. ", "EXT. ", "EST. ", "INT./EXT. ", "I/E. "]

    /// The stub of a heading prefix, matched while the writer is still partway
    /// through typing it and the element is therefore still action.
    private static let prefixStub = try! NSRegularExpression(
        pattern: #"^(?:I|IN|INT|INT\.|E|EX|EXT|EXT\.|ES|EST|EST\.|I/|I/E|I/E\.|INT\.?/|INT\.?/E|INT\.?/EX|INT\.?/EXT|INT\.?/EXT\.?)$"#,
        options: .caseInsensitive)

    private static let scenePrefix = try! NSRegularExpression(
        pattern: #"^(?:INT\.?|EXT\.?|EST\.?|INT\.?/EXT\.?|I/E\.?)\b"#,
        options: .caseInsensitive)

    /// A heading's prefix and whatever follows it.
    private static let prefixSplit = try! NSRegularExpression(
        pattern: #"^(INT\.?/EXT\.?|I/E\.?|INT\.?|EXT\.?|EST\.?)\s+"#,
        options: .caseInsensitive)

    // MARK: - Entry point

    /// The suggestions for a line being typed, best first.
    ///
    /// `type` is the element as it stands *now*, which is not always what the
    /// writer is heading for: live Fountain detection only retypes an action
    /// line once it looks like a heading, so an action line holding "INT" is
    /// still offered locations.
    static func suggestions(forText text: String,
                            type: BlockType,
                            blocks: [Block],
                            characters: [Person]) -> [ScriptSuggestion] {
        // Only ever completes a single line: once a line has been broken, the
        // writer is composing rather than naming something.
        guard !text.contains("\n") else { return [] }

        let forcedCue = text.trimmingCharacters(in: .whitespaces).hasPrefix("@")
        if type == .scene || (!forcedCue && looksLikeSceneTyping(text, type: type)) {
            let scene = sceneSuggestions(forText: text, type: type, blocks: blocks)
            if !scene.isEmpty { return scene }
            // A scene element with nothing to offer stops here rather than
            // falling through: an empty heading is not a character cue.
            if type == .scene { return [] }
        }
        if type.isCharacterCue || type == .action {
            return cueSuggestions(forText: text, type: type,
                                  blocks: blocks, characters: characters)
        }
        return []
    }

    // MARK: - Character cues

    /// The cast, as cues: the project's character records plus any cue already
    /// written that no record covers, since a writer often types a name long
    /// before anyone creates them.
    static func cueNames(blocks: [Block], characters: [Person]) -> [(name: String, personId: Int?)] {
        var entries: [(name: String, personId: Int?)] = []

        func upsert(_ name: String, _ personId: Int?) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if let index = entries.firstIndex(where: {
                $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
            }) {
                // A name harvested from the script first learns its id later.
                if entries[index].personId == nil { entries[index].personId = personId }
                return
            }
            entries.append((trimmed, personId))
        }

        for person in characters {
            upsert(person.name ?? person.fullName ?? "", person.id)
        }
        for block in blocks where block.blockType.isCharacterCue {
            upsert(strippingDualMarker(block.content ?? ""), block.personId)
        }
        return entries.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func cueSuggestions(forText text: String,
                                       type: BlockType,
                                       blocks: [Block],
                                       characters: [Person]) -> [ScriptSuggestion] {
        let forced = text.trimmingCharacters(in: .whitespaces).hasPrefix("@")
        var query = text
        if forced { query = String(query.drop(while: { $0 == " " }).dropFirst()) }
        query = strippingDualMarker(query)

        // An action line is not usually a cue, so it takes either the force
        // marker or enough letters to be a deliberate name.
        if type == .action && !forced && query.count < 2 { return [] }

        let entries = cueNames(blocks: blocks, characters: characters)
        let matches = rank(query, in: entries.map(\.name))
        // The one thing already typed in full is not a suggestion.
        if matches.count == 1,
           matches[0].caseInsensitiveCompare(query.trimmingCharacters(in: .whitespaces)) == .orderedSame {
            return []
        }
        return matches.map { name in
            ScriptSuggestion(
                text: name,
                personId: entries.first { $0.name == name }?.personId,
                becomesType: type == .action ? .character : nil)
        }
    }

    // MARK: - Scene headings

    /// Whether the line reads as a heading in progress. An empty scene element
    /// counts — that is exactly when the prefixes are most useful.
    static func looksLikeSceneTyping(_ text: String, type: BlockType) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return type == .scene }
        if trimmed.hasPrefix(".") { return true }
        if type == .scene { return true }
        if matched(scenePrefix, trimmed) != nil { return true }
        return matched(prefixStub, trimmed) != nil
    }

    private static func sceneSuggestions(forText text: String,
                                         type: BlockType,
                                         blocks: [Block]) -> [ScriptSuggestion] {
        guard looksLikeSceneTyping(text, type: type) else { return [] }

        var query = text.replacingOccurrences(of: "\u{00a0}", with: " ")
        if query.hasPrefix(".") {
            query = String(query.dropFirst().drop(while: { $0 == " " }))
        }

        let headings = sceneHeadings(in: blocks)
        var names: [String] = []

        // Each stage owns the line once the writer reaches it: a query with
        // " - " in it wants times of day, not more headings.
        if let time = timeContext(query) {
            names += filterByPrefix(time.query, in: timesOfDay(in: headings))
                .map { time.base + " - " + $0 }
        } else if let location = locationContext(query) {
            names += rank(location.query, in: locations(in: headings))
                .map { location.prefix + $0 }
        }

        // The prefixes drop away once the line has grown past them.
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let pastPrefixes = timeContext(query) != nil
            || locationContext(query) != nil
            || (trimmed.count > 4 && trimmed.contains(" "))
        if !pastPrefixes {
            names += rank(query, in: scenePrefixes)
        }
        names += rank(query, in: headings)

        var seen = Set<String>()
        let unique = names.filter { seen.insert($0.uppercased()).inserted }
        if unique.count == 1,
           unique[0].caseInsensitiveCompare(trimmed) == .orderedSame {
            return []
        }
        return unique.prefix(limit).map {
            ScriptSuggestion(text: $0, becomesType: type == .scene ? nil : .scene)
        }
    }

    private static func sceneHeadings(in blocks: [Block]) -> [String] {
        var seen = Set<String>()
        return blocks
            .filter { $0.blockType == .scene }
            .map {
                ($0.content ?? "")
                    .replacingOccurrences(of: "\u{00a0}", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty && seen.insert($0.uppercased()).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The places the script has already been, with the prefix and the time of
    /// day stripped off.
    private static func locations(in headings: [String]) -> [String] {
        var seen = Set<String>()
        return headings.compactMap { heading -> String? in
            let withoutTime = heading.replacingOccurrences(
                of: #"\s+-\s+.+$"#, with: "", options: .regularExpression)
            guard let range = matched(prefixSplit, withoutTime) else { return nil }
            let location = String(withoutTime[range.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            guard !location.isEmpty, seen.insert(location.uppercased()).inserted else { return nil }
            return location
        }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The standard times of day, plus any the script has coined for itself.
    private static func timesOfDay(in headings: [String]) -> [String] {
        var result = standardTimes
        var seen = Set(result.map { $0.uppercased() })
        for heading in headings {
            guard let range = heading.range(of: #"\s+-\s+"#, options: .regularExpression) else {
                continue
            }
            let time = String(heading[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !time.isEmpty, seen.insert(time.uppercased()).inserted else { continue }
            result.append(time)
        }
        return result
    }

    /// "INT. BAR - NI" → base "INT. BAR", query "NI". Nil until there is a
    /// location for the time to belong to.
    private static func timeContext(_ query: String) -> (base: String, query: String)? {
        guard let range = query.range(of: #"\s+-\s*"#, options: [.regularExpression, .backwards]),
              range.upperBound == query.endIndex || !query[range.upperBound...].contains(" - ")
        else { return nil }

        let base = String(query[..<range.lowerBound])
        guard matched(scenePrefix, base) != nil,
              let split = matched(prefixSplit, base),
              !base[split.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return (base, String(query[range.upperBound...]))
    }

    /// "INT. BA" → prefix "INT. ", query "BA".
    private static func locationContext(_ query: String) -> (prefix: String, query: String)? {
        guard timeContext(query) == nil,
              let range = matched(prefixSplit, query) else { return nil }
        return (String(query[..<range.upperBound]), String(query[range.upperBound...]))
    }

    // MARK: - Matching

    /// Prefix matches first, then anything containing the query. An empty query
    /// offers the head of the list, which is how a fresh cue line gets the cast.
    private static func rank(_ query: String, in candidates: [String]) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespaces).uppercased()
        guard !needle.isEmpty else { return Array(candidates.prefix(limit)) }
        var prefixed: [String] = []
        var contained: [String] = []
        for candidate in candidates {
            let upper = candidate.uppercased()
            if upper.hasPrefix(needle) {
                prefixed.append(candidate)
            } else if upper.contains(needle) {
                contained.append(candidate)
            }
        }
        return Array((prefixed + contained).prefix(limit))
    }

    /// Times of day match on their prefix only: typing "NI" should reach NIGHT
    /// and not also MORNING and EVENING, which merely contain the letters.
    private static func filterByPrefix(_ query: String, in candidates: [String]) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespaces).uppercased()
        guard !needle.isEmpty else { return Array(candidates.prefix(limit)) }
        return Array(candidates.filter { $0.uppercased().hasPrefix(needle) }.prefix(limit))
    }

    private static func strippingDualMarker(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s*\^\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func matched(_ regex: NSRegularExpression, _ string: String) -> Range<String.Index>? {
        let range = NSRange(string.startIndex..., in: string)
        guard let match = regex.firstMatch(in: string, range: range) else { return nil }
        return Range(match.range, in: string)
    }
}
