//
//  FountainRules.swift
//  scripty
//
//  The typing rules that make the script page behave like a screenplay
//  editor rather than a form: which element follows which on Return, what
//  Tab cycles through, and how Fountain shorthand retypes a block as you
//  write it.
//
//  Ported from the web client's fountain-power.js so both clients agree —
//  a script typed on iPad and one typed in the browser come out the same.
//

import Foundation

enum FountainRules {

    // MARK: - Return

    /// The element a new block takes when Return is pressed in `type`.
    /// A cue is always followed by what the character says; everything else
    /// falls back to action.
    static func nextType(after type: BlockType) -> BlockType {
        type.isCharacterCue ? .dialogue : .action
    }

    // MARK: - Tab

    /// Classic screenplay Tab order (Final Draft's "next logical element").
    static let tabCycle: [BlockType] = [
        .scene, .action, .character, .parenthetical, .dialogue, .transition, .shot,
    ]

    /// Types outside the cycle join it at their nearest logical equivalent,
    /// so Tab from a Note continues as though it were Action.
    private static let cycleEntry: [BlockType: BlockType] = [
        .text: .action,
        .centered: .action,
        .note: .action,
        .lyrics: .dialogue,
        .dualDialogue: .character,
        .section: .scene,
        .synopsis: .scene,
        .pageBreak: .scene,
    ]

    static func cycle(from current: BlockType, backward: Bool = false) -> BlockType {
        let entry = tabCycle.contains(current) ? current : (cycleEntry[current] ?? .action)
        let index = tabCycle.firstIndex(of: entry) ?? 1   // 1 == .action
        let step = backward ? -1 : 1
        let next = (index + step + tabCycle.count) % tabCycle.count
        return tabCycle[next]
    }

    /// Final Draft–style number keys (⌘1…⌘7), matching the Tab order.
    static func type(forDigit digit: Character) -> BlockType? {
        switch digit {
        case "1": return .scene
        case "2": return .action
        case "3": return .character
        case "4": return .parenthetical
        case "5": return .dialogue
        case "6": return .transition
        case "7": return .shot
        default: return nil
        }
    }

    // MARK: - Fountain detection

    /// A retype suggested by what the writer typed.
    struct Detection: Equatable {
        let type: BlockType
        let content: String
    }

    private static let sceneHeading = regex(#"^(?:INT\.?|EXT\.?|EST\.?|INT\.?/EXT\.?|I/E\.?)\s+.+"#)
    private static let transition = regex(#"^[A-Z][A-Z0-9 ]+ TO:$"#, caseSensitive: true)
    private static let shot = regex(
        #"^(?:ANGLE ON|ANOTHER ANGLE|CLOSE ON|CLOSE UP|CLOSEUP|C\.U\.?|CU|POV|INSERT|BACK TO SCENE|BACK TO|TIGHT ON|WIDER(?: SHOT)?|TRACKING|CRANE|AERIAL|ESTABLISHING|FAVOR ON|REVERSE ANGLE)\b.*"#)

    /// Detects the element the writer is implying, or nil to leave the block
    /// as it is. Returns the content with any Fountain marker stripped.
    ///
    /// Rewrites never drop lines after the first: a multi-line block keeps its
    /// body so pressing Return can't silently eat typed text.
    static func detect(_ raw: String) -> Detection? {
        let text = raw.replacingOccurrences(of: "\u{00a0}", with: "")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let firstLine = trimmed.components(separatedBy: "\n")[0]
            .trimmingCharacters(in: .whitespaces)
        let singleLine = trimmed == firstLine

        // Force markers — these win over any heuristic.
        if matches(trimmed, #"^={3,}$"#) {
            return Detection(type: .pageBreak, content: "===")
        }
        if trimmed.hasPrefix("[["), trimmed.hasSuffix("]]") {
            let inner = String(trimmed.dropFirst(2).dropLast(2))
            return Detection(type: .note, content: inner.trimmingCharacters(in: .whitespaces))
        }
        if firstLine.hasPrefix("#") {
            return Detection(type: .section,
                             content: stripFirstLine(trimmed, pattern: #"^#+\s*"#))
        }
        if firstLine.hasPrefix("=") && !firstLine.hasPrefix("==") {
            return Detection(type: .synopsis,
                             content: stripFirstLine(trimmed, pattern: #"^=+\s*"#))
        }
        if firstLine.hasPrefix("~") {
            return Detection(type: .lyrics,
                             content: stripFirstLine(trimmed, pattern: #"^~\s*"#))
        }
        if firstLine.hasPrefix(".") && !firstLine.hasPrefix("..") {
            return Detection(type: .scene,
                             content: stripFirstLine(trimmed, pattern: #"^\.\s*"#))
        }
        if firstLine.hasPrefix("@") {
            let isDual = matches(firstLine, #"\^\s*$"#)
            let cue = String(firstLine.dropFirst())
                .replacingOccurrences(of: #"\s*\^\s*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
                .uppercased()
            // A cue is one line; keep anything typed beneath it intact.
            let content: String
            if singleLine {
                content = cue
            } else if let newline = trimmed.firstIndex(of: "\n") {
                content = cue + trimmed[newline...]
            } else {
                content = cue
            }
            return Detection(type: isDual ? .dualDialogue : .character, content: content)
        }
        if firstLine.hasPrefix(">"), firstLine.hasSuffix("<"), firstLine.count > 2 {
            guard singleLine else { return nil }
            let inner = String(firstLine.dropFirst().dropLast())
            return Detection(type: .centered, content: inner.trimmingCharacters(in: .whitespaces))
        }
        if firstLine.hasPrefix(">") {
            guard singleLine else { return nil }
            let inner = String(firstLine.dropFirst())
            return Detection(type: .transition, content: inner.trimmingCharacters(in: .whitespaces))
        }

        // Heuristics. All require a single line, so multi-line action is never
        // truncated when a rewrite fires.
        guard singleLine else { return nil }

        if matches(firstLine, sceneHeading) {
            return Detection(type: .scene, content: firstLine)
        }
        if matches(firstLine, transition) {
            return Detection(type: .transition, content: firstLine)
        }
        if matches(firstLine, shot) {
            return Detection(type: .shot, content: firstLine)
        }
        if firstLine.hasPrefix("(") {
            var paren = String(firstLine.dropFirst())
            if paren.hasSuffix(")") { paren = String(paren.dropLast()) }
            return Detection(type: .parenthetical,
                             content: paren.trimmingCharacters(in: .whitespaces))
        }
        if isCharacterCueLine(firstLine) {
            let isDual = matches(firstLine, #"\^\s*$"#)
            let name = firstLine
                .replacingOccurrences(of: #"^@"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s*\^\s*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            return Detection(type: isDual ? .dualDialogue : .character, content: name)
        }
        return nil
    }

    /// A short, all-caps line that isn't a heading — i.e. someone about to speak.
    /// Tolerates a trailing extension: `JOE (V.O.)`.
    static func isCharacterCueLine(_ line: String) -> Bool {
        guard !line.isEmpty, line.count <= 60 else { return false }
        if matches(line, #"[.?!]$"#) { return false }
        if matches(line, sceneHeading) || matches(line, transition) || matches(line, shot) {
            return false
        }
        let core = line
            .replacingOccurrences(of: #"^@"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\^\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty else { return false }

        let base = core
            .replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard matches(base, #"^[A-Z0-9][A-Z0-9 \-'.]*$"#, caseSensitive: true) else { return false }
        guard base.split(separator: " ").count <= 5 else { return false }
        guard matches(base, #"[A-Z]"#, caseSensitive: true) else { return false }
        return base == base.uppercased()
    }

    // MARK: - Regex helpers

    private static func regex(_ pattern: String, caseSensitive: Bool = false) -> NSRegularExpression {
        // Patterns are literals in this file; a bad one is a programmer error.
        try! NSRegularExpression(
            pattern: pattern,
            options: caseSensitive ? [] : [.caseInsensitive])
    }

    private static func matches(_ string: String, _ expression: NSRegularExpression) -> Bool {
        let range = NSRange(string.startIndex..., in: string)
        return expression.firstMatch(in: string, range: range) != nil
    }

    private static func matches(_ string: String, _ pattern: String,
                                caseSensitive: Bool = false) -> Bool {
        matches(string, regex(pattern, caseSensitive: caseSensitive))
    }

    /// Applies `pattern` to the first line only, leaving the body untouched.
    private static func stripFirstLine(_ trimmed: String, pattern: String) -> String {
        guard let newline = trimmed.firstIndex(of: "\n") else {
            return trimmed.replacingOccurrences(of: pattern, with: "",
                                                options: .regularExpression)
        }
        let head = String(trimmed[..<newline])
            .replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        return head + trimmed[newline...]
    }
}
