//
//  FountainDetect.swift
//  scripty
//
//  Fountain shorthand detection, ported from the web editor's
//  fountain-power.js `detectFountain`. As the writer types, a leading
//  force marker (`.` scene, `@` character, `>` transition, `~` lyrics,
//  `#` section, `=` synopsis, `[[ ]]` note, `===` page break) or a
//  recognizable heading / transition / cue retypes the element — exactly
//  as it does in the browser.
//

import Foundation

/// The element a chunk of text should become, plus the content with its
/// force marker stripped.
struct FountainDetection: Equatable {
    let type: BlockType
    let content: String
}

enum FountainDetector {
    private static let sceneHeading = regex(#"^(?:INT\.?|EXT\.?|EST\.?|INT\.?/EXT\.?|I/E\.?)\s+.+"#,
                                            caseInsensitive: true)
    private static let transition = regex(#"^[A-Z][A-Z0-9 ]+ TO:$"#, caseInsensitive: false)
    private static let shot = regex(
        #"^(?:ANGLE ON|ANOTHER ANGLE|CLOSE ON|CLOSE UP|CLOSEUP|C\.U\.?|CU|POV|INSERT|BACK TO SCENE|BACK TO|TIGHT ON|WIDER(?: SHOT)?|TRACKING|CRANE|AERIAL|ESTABLISHING|FAVOR ON|REVERSE ANGLE)\b.*"#,
        caseInsensitive: true)
    private static let parenOnly = regex(#"^\([^)]*\)$"#, caseInsensitive: false)
    private static let cueBase = regex(#"^[A-Z0-9][A-Z0-9 \-'.]*$"#, caseInsensitive: false)

    /// Returns the element the text should become, or nil to leave it as-is.
    static func detect(_ raw: String) -> FountainDetection? {
        let text = raw.replacingOccurrences(of: "\u{00a0}", with: "")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let firstLine = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
            .first.map { $0.trimmingCharacters(in: .whitespaces) } ?? trimmed
        let singleLine = trimmed == firstLine

        if matches(#"^={3,}$"#, trimmed) {
            return FountainDetection(type: .pageBreak, content: "===")
        }
        if trimmed.hasPrefix("[[") && trimmed.hasSuffix("]]") {
            let inner = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
            return FountainDetection(type: .note, content: inner)
        }
        if firstLine.hasPrefix("#") {
            return FountainDetection(type: .section,
                                     content: stripFirstLine(trimmed) { $0.replacing(regex(#"^#+\s*"#), with: "") })
        }
        if firstLine.hasPrefix("=") && !firstLine.hasPrefix("==") {
            return FountainDetection(type: .synopsis,
                                     content: stripFirstLine(trimmed) { $0.replacing(regex(#"^=+\s*"#), with: "") })
        }
        if firstLine.hasPrefix("~") {
            return FountainDetection(type: .lyrics,
                                     content: stripFirstLine(trimmed) { $0.replacing(regex(#"^~\s*"#), with: "") })
        }
        if firstLine.hasPrefix(".") && !firstLine.hasPrefix("..") {
            return FountainDetection(type: .scene,
                                     content: stripFirstLine(trimmed) { $0.replacing(regex(#"^\.\s*"#), with: "") })
        }
        if firstLine.hasPrefix("@") {
            let stripped = String(firstLine.dropFirst()).trimmingCharacters(in: .whitespaces)
            let cue = stripped.replacing(regex(#"\s*\^\s*$"#), with: "")
            let dual = matches(#"\^\s*$"#, firstLine)
            let content: String
            if singleLine {
                content = cue.uppercased()
            } else if let nl = trimmed.firstIndex(of: "\n") {
                content = cue.uppercased() + trimmed[nl...]
            } else {
                content = cue.uppercased()
            }
            return FountainDetection(type: dual ? .dualDialogue : .character, content: content)
        }
        if firstLine.hasPrefix(">") && firstLine.hasSuffix("<") && firstLine.count > 2 {
            guard singleLine else { return nil }
            let inner = String(firstLine.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            return FountainDetection(type: .centered, content: inner)
        }
        if firstLine.hasPrefix(">") {
            guard singleLine else { return nil }
            let inner = String(firstLine.dropFirst()).trimmingCharacters(in: .whitespaces)
            return FountainDetection(type: .transition, content: inner)
        }

        // Heuristics: require a single line so multi-line action is never
        // truncated when Return runs detection.
        if singleLine && fullMatch(sceneHeading, firstLine) {
            return FountainDetection(type: .scene, content: firstLine)
        }
        if singleLine && fullMatch(transition, firstLine) {
            return FountainDetection(type: .transition, content: firstLine)
        }
        if singleLine && fullMatch(shot, firstLine) {
            return FountainDetection(type: .shot, content: firstLine)
        }
        if singleLine && (fullMatch(parenOnly, firstLine) || firstLine.hasPrefix("(")) {
            let paren: String
            if firstLine.hasPrefix("(") {
                paren = firstLine.hasSuffix(")")
                    ? String(firstLine.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                    : String(firstLine.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else {
                paren = firstLine
            }
            return FountainDetection(type: .parenthetical, content: paren)
        }
        if singleLine && isCharacterCueLine(firstLine) {
            let dual = matches(#"\^\s*$"#, firstLine)
            let name = firstLine.replacing(regex(#"^@"#), with: "")
                .replacing(regex(#"\s*\^\s*$"#), with: "")
                .trimmingCharacters(in: .whitespaces)
            return FountainDetection(type: dual ? .dualDialogue : .character, content: name)
        }
        return nil
    }

    /// A short ALL-CAPS line that reads as an intentional speaker cue.
    ///
    /// Internal rather than private so the paste parser can ask the same
    /// question. It had its own looser test — uppercase, has a letter, short —
    /// which accepted "MEANWHILE, ACROSS TOWN" and "BANG!" as speakers and
    /// turned the line beneath them into dialogue.
    static func isCharacterCueLine(_ line: String) -> Bool {
        guard !line.isEmpty, line.count <= 60 else { return false }
        if matches(#"[.?!]$"#, line) { return false }
        if fullMatch(sceneHeading, line) || fullMatch(transition, line) || fullMatch(shot, line) {
            return false
        }
        let core = line.replacing(regex(#"^@"#), with: "")
            .replacing(regex(#"\s*\^\s*$"#), with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty else { return false }
        let base = core.replacing(regex(#"\s*\([^)]*\)\s*$"#), with: "")
            .trimmingCharacters(in: .whitespaces)
        guard fullMatch(cueBase, base) else { return false }
        guard base.split(whereSeparator: { $0 == " " }).count <= 5 else { return false }
        guard base.rangeOfCharacter(from: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")) != nil
        else { return false }
        return base == base.uppercased()
    }

    // MARK: - Regex helpers

    private static func stripFirstLine(_ trimmed: String, _ replacer: (String) -> String) -> String {
        guard let nl = trimmed.firstIndex(of: "\n") else { return replacer(trimmed) }
        return replacer(String(trimmed[..<nl])) + trimmed[nl...]
    }

    private static func regex(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        // Patterns are all compile-time constants; a failure is a programmer error.
        return try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static func matches(_ pattern: String, _ string: String) -> Bool {
        let re = regex(pattern)
        return re.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }

    private static func fullMatch(_ re: NSRegularExpression, _ string: String) -> Bool {
        let range = NSRange(string.startIndex..., in: string)
        guard let match = re.firstMatch(in: string, range: range) else { return false }
        return match.range == range
    }
}

private extension String {
    /// Replace the first match of `re` with `replacement` (anchored patterns
    /// used here match at most once at the start).
    func replacing(_ re: NSRegularExpression, with replacement: String) -> String {
        let range = NSRange(startIndex..., in: self)
        return re.stringByReplacingMatches(in: self, range: range, withTemplate: replacement)
    }
}
