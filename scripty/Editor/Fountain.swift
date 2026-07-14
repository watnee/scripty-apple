//
//  Fountain.swift
//  scripty
//
//  The screenplay typing rules, ported from the web editor so both clients
//  behave identically. The three rules that define the writing loop:
//
//    * `nextType(after:)` — what Enter creates (fountain-power.js nextTypeAfter)
//    * `cycle(_:backward:)` — what Tab does (fountain-power.js cycleType)
//    * `detect(_:)` — what typing "INT. HOUSE - DAY" turns into (detectFountain)
//
//  Keep these in step with static/js/fountain-power.js; they are the second
//  deliberate coupling point with the server after Rel.
//

import Foundation

enum Fountain {

    // MARK: - Tab cycling

    /// Classic screenplay Tab order (Final Draft-style "next logical element").
    static let tabCycle: [BlockType] = [
        .scene, .action, .character, .parenthetical, .dialogue, .transition, .shot,
    ]

    /// Less-common types map onto the logical cycle before advancing, so Tab
    /// from a Note lands somewhere sensible instead of dead-ending.
    private static let tabCycleEntry: [BlockType: BlockType] = [
        .text: .action,
        .centered: .action,
        .note: .action,
        .lyrics: .dialogue,
        .dualDialogue: .character,
        .section: .scene,
        .synopsis: .scene,
        .pageBreak: .scene,
    ]

    static func cycle(_ current: BlockType, backward: Bool = false) -> BlockType {
        let entry = tabCycle.contains(current) ? current : (tabCycleEntry[current] ?? .action)
        let index = tabCycle.firstIndex(of: entry) ?? 1   // .action
        let count = tabCycle.count
        let next = backward ? (index - 1 + count) % count : (index + 1) % count
        return tabCycle[next]
    }

    // MARK: - Enter

    /// After a character cue the writer is always about to type dialogue;
    /// everything else falls back to action.
    static func nextType(after type: BlockType) -> BlockType {
        (type == .character || type == .dualDialogue) ? .dialogue : .action
    }

    // MARK: - Fountain detection

    struct Detection {
        let type: BlockType
        let content: String
        /// True when explicit Fountain syntax (`.`, `@`, `>`, `~`, `#`, `=`)
        /// drove the result rather than a heuristic. Forced detections always
        /// win; heuristics only retype a neutral block. See `shouldApply`.
        let isForced: Bool
    }

    /// Mirrors `detectFountain` in fountain-power.js. Returns nil when the text
    /// carries no signal and the block should keep the type it already has.
    static func detect(_ raw: String) -> Detection? {
        let text = raw.replacingOccurrences(of: "\u{00a0}", with: "")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Force markers apply to the first line only, so a multi-line action
        // block is never truncated.
        let firstLine = trimmed.components(separatedBy: "\n")[0]
            .trimmingCharacters(in: .whitespaces)
        let isSingleLine = trimmed == firstLine

        if matches(trimmed, Patterns.pageBreak) {
            return Detection(type: .pageBreak, content: "===", isForced: true)
        }
        if trimmed.hasPrefix("[["), trimmed.hasSuffix("]]") {
            let inner = String(trimmed.dropFirst(2).dropLast(2))
            return Detection(type: .note,
                             content: inner.trimmingCharacters(in: .whitespaces),
                             isForced: true)
        }
        if firstLine.hasPrefix("#") {
            return Detection(type: .section,
                             content: stripFirstLine(trimmed, Patterns.sectionPrefix),
                             isForced: true)
        }
        if firstLine.hasPrefix("="), !firstLine.hasPrefix("==") {
            return Detection(type: .synopsis,
                             content: stripFirstLine(trimmed, Patterns.synopsisPrefix),
                             isForced: true)
        }
        if firstLine.hasPrefix("~") {
            return Detection(type: .lyrics,
                             content: stripFirstLine(trimmed, Patterns.lyricsPrefix),
                             isForced: true)
        }
        if firstLine.hasPrefix("."), !firstLine.hasPrefix("..") {
            return Detection(type: .scene,
                             content: stripFirstLine(trimmed, Patterns.scenePrefix),
                             isForced: true)
        }
        if firstLine.hasPrefix("@") {
            let isDual = firstLine.hasSuffix("^")
            let cue = firstLine.dropFirst()
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "^", with: "")
                .trimmingCharacters(in: .whitespaces)
                .uppercased()
            // A cue is one line; keep any body lines so Enter does not wipe
            // dialogue typed under the cue in the same block.
            var content = cue
            if !isSingleLine, let newline = trimmed.firstIndex(of: "\n") {
                content = cue + trimmed[newline...]
            }
            return Detection(type: isDual ? .dualDialogue : .character,
                             content: content, isForced: true)
        }
        if isSingleLine, firstLine.hasPrefix(">"), firstLine.hasSuffix("<"), firstLine.count > 2 {
            let inner = firstLine.dropFirst().dropLast()
            return Detection(type: .centered,
                             content: inner.trimmingCharacters(in: .whitespaces),
                             isForced: true)
        }
        if isSingleLine, firstLine.hasPrefix(">") {
            let inner = firstLine.dropFirst()
            return Detection(type: .transition,
                             content: inner.trimmingCharacters(in: .whitespaces),
                             isForced: true)
        }

        // Heuristics below require a single line so multi-line action is never
        // truncated, matching the web.
        guard isSingleLine else { return nil }

        if matches(firstLine, Patterns.sceneHeading) {
            return Detection(type: .scene, content: firstLine, isForced: false)
        }
        if matches(firstLine, Patterns.transition) {
            return Detection(type: .transition, content: firstLine, isForced: false)
        }
        if matches(firstLine, Patterns.shot) {
            return Detection(type: .shot, content: firstLine, isForced: false)
        }
        if firstLine.hasPrefix("(") {
            var paren = String(firstLine.dropFirst())
            if paren.hasSuffix(")") { paren = String(paren.dropLast()) }
            return Detection(type: .parenthetical,
                             content: paren.trimmingCharacters(in: .whitespaces),
                             isForced: false)
        }
        if isCharacterCue(firstLine) {
            let isDual = firstLine.hasSuffix("^")
            let name = firstLine
                .replacingOccurrences(of: "^", with: "")
                .trimmingCharacters(in: .whitespaces)
            return Detection(type: isDual ? .dualDialogue : .character,
                             content: name, isForced: false)
        }
        return nil
    }

    /// Forced syntax always retypes the block. A heuristic only retypes a block
    /// the writer has not deliberately typed — otherwise an all-caps line of
    /// dialogue ("STOP!") would silently become a character cue.
    static func shouldApply(_ detection: Detection, to current: BlockType) -> Bool {
        guard detection.type != current else { return false }
        return detection.isForced || current == .action || current == .text
    }

    /// Single ALL-CAPS line, short, not a scene heading or transition.
    private static func isCharacterCue(_ line: String) -> Bool {
        guard !line.isEmpty, line.count <= 60 else { return false }
        if let last = line.last, ".?!".contains(last) { return false }
        if matches(line, Patterns.sceneHeading)
            || matches(line, Patterns.transition)
            || matches(line, Patterns.shot) { return false }

        let core = line
            .replacingOccurrences(of: "^", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty else { return false }

        // Allow parenthetical extensions: JOE (V.O.)
        let base = replacing(core, Patterns.cueExtension, with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty,
              matches(base, Patterns.cueBase),
              base.split(separator: " ").count <= 5,
              base.rangeOfCharacter(from: .uppercaseLetters) != nil,
              base == base.uppercased() else { return false }
        return true
    }

    // MARK: - Regex

    private enum Patterns {
        static let pageBreak = regex("^={3,}$")
        static let sceneHeading = regex(#"^(?:INT\.?|EXT\.?|EST\.?|INT\.?/EXT\.?|I/E\.?)\s+.+"#,
                                        caseInsensitive: true)
        // Deliberately case-sensitive, like the web: "CUT TO:" is a transition,
        // "cut to:" typed mid-sentence is not.
        static let transition = regex("^[A-Z][A-Z0-9 ]+ TO:$")
        static let shot = regex(
            #"^(?:ANGLE ON|ANOTHER ANGLE|CLOSE ON|CLOSE UP|CLOSEUP|C\.U\.?|CU|POV|INSERT|BACK TO SCENE|BACK TO|TIGHT ON|WIDER(?: SHOT)?|TRACKING|CRANE|AERIAL|ESTABLISHING|FAVOR ON|REVERSE ANGLE)\b.*"#,
            caseInsensitive: true)
        static let cueBase = regex(#"^[A-Z0-9][A-Z0-9 \-'.]*$"#)
        static let cueExtension = regex(#"\s*\([^)]*\)\s*$"#)

        static let sectionPrefix = regex(#"^#+\s*"#)
        static let synopsisPrefix = regex(#"^=+\s*"#)
        static let lyricsPrefix = regex(#"^~\s*"#)
        static let scenePrefix = regex(#"^\.\s*"#)

        private static func regex(_ pattern: String,
                                  caseInsensitive: Bool = false) -> NSRegularExpression {
            // Patterns are literals checked at build time; a throw here is a bug.
            try! NSRegularExpression(
                pattern: pattern,
                options: caseInsensitive ? [.caseInsensitive] : [])
        }
    }

    private static func matches(_ string: String, _ pattern: NSRegularExpression) -> Bool {
        let range = NSRange(string.startIndex..., in: string)
        return pattern.firstMatch(in: string, range: range) != nil
    }

    private static func replacing(_ string: String, _ pattern: NSRegularExpression,
                                  with template: String) -> String {
        let range = NSRange(string.startIndex..., in: string)
        return pattern.stringByReplacingMatches(in: string, range: range, withTemplate: template)
    }

    /// Strips a force marker from the first line, leaving later lines untouched.
    private static func stripFirstLine(_ text: String,
                                       _ pattern: NSRegularExpression) -> String {
        var lines = text.components(separatedBy: "\n")
        lines[0] = replacing(lines[0], pattern, with: "")
            .trimmingCharacters(in: .whitespaces)
        return lines.joined(separator: "\n")
    }
}
