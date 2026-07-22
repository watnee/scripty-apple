//
//  ScriptStats.swift
//  scripty
//
//  Screenplay statistics computed from the blocks we already hold — a direct
//  port of the web app's ScriptStatsServiceImpl so the two clients report the
//  same numbers. Pure value type: no networking, no UI, no ScriptModel.
//

import Foundation

/// One character's share of the dialogue.
struct CharacterStat: Identifiable, Hashable {
    let name: String
    let speechCount: Int
    let wordCount: Int
    /// How many distinct scenes the character speaks in.
    let sceneCount: Int
    let dialogueSharePercent: Int

    var id: String { name }
}

/// One location and how many scenes play there.
struct LocationStat: Identifiable, Hashable {
    let name: String
    let sceneCount: Int

    var id: String { name }
}

/// Aggregated stats for one screenplay: size, dialogue/action balance, and the
/// character and location breakdowns.
struct ScriptStats: Equatable {
    var blockCount = 0
    var sceneCount = 0
    var pageEstimate = 0
    var totalWords = 0
    var dialogueWords = 0
    var actionWords = 0
    var dialoguePercent = 0
    var actionPercent = 0
    var speakingCharacterCount = 0
    var locationCount = 0

    var interiorSceneCount = 0
    var exteriorSceneCount = 0
    var daySceneCount = 0
    var nightSceneCount = 0

    var characters: [CharacterStat] = []
    var locations: [LocationStat] = []

    /// The web app shows "nothing to measure yet" on exactly this condition.
    var hasNothingToMeasure: Bool { sceneCount == 0 && totalWords == 0 }

    // MARK: - Courier-12 page geometry (mirrors the server's constants)

    private static let linesPerPage = 55
    private static let actionLineWidth = 60
    private static let dialogueLineWidth = 34
    private static let parentheticalLineWidth = 30

    init() {}

    init(blocks: [Block]) {
        var characterOrder: [String] = []
        var characterStats: [String: CharacterAccumulator] = [:]
        var locationOrder: [String] = []
        var locationCounts: [String: Int] = [:]

        var estimatedLines = 0
        var activeCharacter: String?
        var currentSceneIndex = -1

        blockCount = blocks.count

        for block in blocks {
            let content = block.content ?? ""
            let words = Self.countWords(content)

            switch block.blockType {
            case .scene:
                activeCharacter = nil
                sceneCount += 1
                currentSceneIndex = sceneCount
                totalWords += words
                // A scene heading is preceded by a blank line on the page.
                estimatedLines += 1 + Self.wrappedLines(content, width: Self.actionLineWidth)

                if let heading = SceneHeading(content.trimmingCharacters(in: .whitespaces)) {
                    if heading.isInterior { interiorSceneCount += 1 }
                    if heading.isExterior { exteriorSceneCount += 1 }

                    let timeOfDay = heading.timeOfDay
                    if timeOfDay.contains("NIGHT") || timeOfDay.contains("EVENING") {
                        nightSceneCount += 1
                    } else if timeOfDay.contains("DAY") || timeOfDay.contains("MORNING")
                                || timeOfDay.contains("AFTERNOON") {
                        daySceneCount += 1
                    }

                    // The server keys locations by their upper-cased name.
                    let key = heading.locationName.uppercased()
                    if !key.isEmpty {
                        if locationCounts[key] == nil { locationOrder.append(key) }
                        locationCounts[key, default: 0] += 1
                    }
                }

            case .character, .dualDialogue:
                let name = block.personName ?? content
                activeCharacter = Self.normalizeCharacterName(name)
                // Cue plus its blank line above.
                estimatedLines += 2

            case .dialogue:
                // A linked character wins over the cue we were tracking.
                let name = block.personName.flatMap(Self.normalizeCharacterName) ?? activeCharacter
                totalWords += words
                dialogueWords += words
                estimatedLines += Self.wrappedLines(content, width: Self.dialogueLineWidth)
                if let name, !name.isEmpty {
                    if characterStats[name] == nil {
                        characterOrder.append(name)
                        characterStats[name] = CharacterAccumulator(name: name)
                    }
                    characterStats[name]?.speechCount += 1
                    characterStats[name]?.wordCount += words
                    if currentSceneIndex > 0 {
                        characterStats[name]?.scenes.insert(currentSceneIndex)
                    }
                }

            case .parenthetical:
                totalWords += words
                estimatedLines += Self.wrappedLines(content, width: Self.parentheticalLineWidth)

            case .lyrics:
                // Sung lines count as dialogue.
                totalWords += words
                dialogueWords += words
                estimatedLines += Self.wrappedLines(content, width: Self.dialogueLineWidth)

            case .action, .text, .centered, .shot:
                activeCharacter = nil
                totalWords += words
                actionWords += words
                estimatedLines += 1 + Self.wrappedLines(content, width: Self.actionLineWidth)

            case .transition:
                activeCharacter = nil
                totalWords += words
                estimatedLines += 2

            case .pageBreak:
                activeCharacter = nil
                // Round the running line count up to the next page boundary.
                let remainder = estimatedLines % Self.linesPerPage
                if remainder > 0 { estimatedLines += Self.linesPerPage - remainder }

            case .section, .synopsis, .note:
                // Structural notes are not script content.
                activeCharacter = nil
            }
        }

        let spokenPlusAction = dialogueWords + actionWords
        if spokenPlusAction > 0 {
            dialoguePercent = Int((Float(dialogueWords) * 100 / Float(spokenPlusAction)).rounded())
            actionPercent = 100 - dialoguePercent
        }
        pageEstimate = estimatedLines > 0
            ? (estimatedLines + Self.linesPerPage - 1) / Self.linesPerPage
            : 0

        characters = characterOrder
            .compactMap { characterStats[$0] }
            .map { accumulator in
                CharacterStat(
                    name: accumulator.name,
                    speechCount: accumulator.speechCount,
                    wordCount: accumulator.wordCount,
                    sceneCount: accumulator.scenes.count,
                    dialogueSharePercent: dialogueWords > 0
                        ? Int((Float(accumulator.wordCount) * 100 / Float(dialogueWords)).rounded())
                        : 0)
            }
            // Loudest first, ties broken alphabetically.
            .sorted { $0.wordCount != $1.wordCount ? $0.wordCount > $1.wordCount : $0.name < $1.name }
        speakingCharacterCount = characters.count

        locations = locationOrder
            .map { LocationStat(name: $0, sceneCount: locationCounts[$0] ?? 0) }
            .sorted { $0.sceneCount != $1.sceneCount ? $0.sceneCount > $1.sceneCount : $0.name < $1.name }
        locationCount = locations.count
    }

    // MARK: - Counting rules (ported verbatim)

    /// Whitespace-separated tokens; empty content counts as no words.
    static func countWords(_ content: String) -> Int {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        return trimmed.split(whereSeparator: \.isWhitespace).count
    }

    /// Lines the content occupies when wrapped at the given width (min 1 per
    /// hard line, and at least one line overall).
    static func wrappedLines(_ content: String, width: Int) -> Int {
        var lines = 0
        for line in content.components(separatedBy: "\n") {
            let length = line.trimmingCharacters(in: .whitespaces).count
            lines += length == 0 ? 1 : (length + width - 1) / width
        }
        return max(lines, 1)
    }

    /// Drops a trailing cue extension — (V.O.), (O.S.), (CONT'D) — and
    /// upper-cases, so the same speaker never splits into two rows.
    ///
    /// `nonisolated` because it is pure and is called from the nonisolated
    /// stats/outline initialisers, which would otherwise inherit the module's
    /// main-actor default and warn.
    nonisolated static func normalizeCharacterName(_ name: String?) -> String? {
        guard let name else { return nil }
        var cleaned = name.trimmingCharacters(in: .whitespaces)
        if let open = cleaned.lastIndex(of: "("),
           let close = cleaned.lastIndex(of: ")"),
           open < close,
           cleaned[cleaned.index(after: close)...].allSatisfy(\.isWhitespace),
           !cleaned[open..<close].contains(")") {
            cleaned = String(cleaned[..<open])
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces).uppercased()
        return cleaned.isEmpty ? nil : cleaned
    }

    private struct CharacterAccumulator {
        let name: String
        var speechCount = 0
        var wordCount = 0
        var scenes: Set<Int> = []
    }
}

/// The running readout under the script: how many words, and roughly how many
/// pages that is.
///
/// Separate from `ScriptStats` because it is recomputed as the writer types
/// and so must stay cheap — no character tables, no location tables, no line
/// wrapping. The rules are the web's `collectScriptWordCount` and
/// `formatPageEstimate` in fountain-power.js, including its rougher
/// 250-words-to-the-page guess: the honest per-line pagination is what the page
/// view shows, and a number that jumped between the two while typing would read
/// as a bug rather than as a refinement.
enum ScriptWordCount {
    static let wordsPerPage = 250

    /// Structure rather than script. The web leaves out notes, synopses,
    /// sections and page breaks; this leaves out the character cue as well, and
    /// deliberately, because `ScriptStats` does — the readout and the stats
    /// sheet are a tap apart in this client, and two different word counts for
    /// the same script reads as one of them being broken. The web can afford
    /// the inconsistency, having put them on different screens.
    static func counts(_ type: BlockType) -> Bool {
        switch type {
        case .note, .synopsis, .section, .pageBreak, .character, .dualDialogue: return false
        default: return true
        }
    }

    static func total(in blocks: [Block]) -> Int {
        blocks.reduce(0) { running, block in
            guard counts(block.blockType) else { return running }
            return running + ScriptStats.countWords(block.content ?? "")
        }
    }

    /// One decimal below ten pages, whole pages above — a half-page difference
    /// matters when there are three of them and not when there are ninety.
    static func pageEstimate(words: Int) -> String {
        guard words > 0 else { return "0" }
        let pages = Double(words) / Double(wordsPerPage)
        if pages < 10 {
            let rounded = (pages * 10).rounded() / 10
            return rounded == rounded.rounded()
                ? String(Int(rounded))
                : String(format: "%.1f", rounded)
        }
        return String(Int(pages.rounded()))
    }

    /// Grouped for reading, as `toLocaleString` does in the browser.
    static func formatted(_ words: Int) -> String {
        words.formatted(.number.grouping(.automatic))
    }
}

/// A parsed Fountain scene heading: `INT. KITCHEN - NIGHT`.
///
/// Mirrors the server's SCENE_HEADING pattern — the prefix alternatives are
/// tried longest-first so `INT./EXT.` wins over a bare `INT.`.
struct SceneHeading {
    let prefix: String
    /// Everything after the prefix, trimmed.
    let remainder: String
    let locationName: String
    /// Upper-cased time of day, empty when the heading carries none.
    let timeOfDay: String

    private static let prefixes = [
        "INT./EXT.", "INT./EXT", "INT/EXT.", "INT/EXT",
        "I/E.", "I/E",
        "INT.", "INT",
        "EXT.", "EXT",
        "EST.", "EST",
    ]

    /// Returns nil when `content` is not a scene heading at all.
    init?(_ content: String, splittingTimeFromEnd: Bool = true) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = trimmed.uppercased()
        guard let match = Self.prefixes.first(where: { candidate in
            guard upper.hasPrefix(candidate) else { return false }
            let rest = trimmed.dropFirst(candidate.count)
            // The server's `\s+` — a prefix must be followed by whitespace.
            return rest.first?.isWhitespace == true
        }) else { return nil }

        prefix = match
        remainder = trimmed.dropFirst(match.count).trimmingCharacters(in: .whitespaces)

        // The stats page splits on the *last* " - " so hyphenated location
        // names survive; the outline sidebar splits on the first one.
        let separator = " - "
        let range = splittingTimeFromEnd
            ? remainder.range(of: separator, options: .backwards)
            : remainder.range(of: separator)
        if let range {
            locationName = String(remainder[..<range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            timeOfDay = String(remainder[range.upperBound...])
                .trimmingCharacters(in: .whitespaces).uppercased()
        } else {
            locationName = remainder
            timeOfDay = ""
        }
    }

    var isInterior: Bool {
        prefix.hasPrefix("INT") || prefix.hasPrefix("I/E")
    }

    var isExterior: Bool {
        prefix.hasPrefix("EXT") || prefix.hasPrefix("EST") || prefix.contains("/E")
    }
}
