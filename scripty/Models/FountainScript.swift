//
//  FountainScript.swift
//  scripty
//
//  Reading a block of pasted text as a sequence of screenplay elements, and
//  writing elements back out as Fountain.
//
//  `FountainDetector` answers "what is this one chunk?" while the writer
//  types. This answers the paste question — "what are these many chunks, and
//  where does one element end and the next begin?" — which needs context the
//  single-chunk detector does not have: the line after a character cue is
//  dialogue precisely *because* a cue came before it.
//
//  The deliberate conservatism is `looksLikeScreenplay`. Pasting a paragraph
//  of prose into an action element should leave it in that element, not
//  shatter it into rows; only text that actually carries screenplay structure
//  is worth restructuring. The web app draws the same line.
//

import Foundation

/// One element recovered from pasted text.
struct FountainElement: Equatable {
    let type: BlockType
    let content: String
}

enum FountainScript {

    // MARK: - Writing

    /// Elements as Fountain text — what lands on the clipboard for anything
    /// that is not Scripty, and what a plain-text paste of our own copy would
    /// fall back to reading.
    static func fountain(from elements: [FountainElement]) -> String {
        elements.map { element in
            switch element.type {
            case .scene: return element.content.uppercased()
            case .character, .dualDialogue:
                let cue = element.content.uppercased()
                return element.type == .dualDialogue ? cue + " ^" : cue
            case .transition: return element.content.uppercased()
            case .parenthetical:
                let inner = element.content.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                return "(\(inner))"
            case .section: return "# " + element.content
            case .synopsis: return "= " + element.content
            case .note: return "[[\(element.content)]]"
            case .lyrics: return "~ " + element.content
            case .centered: return "> \(element.content) <"
            case .pageBreak: return "==="
            default: return element.content
            }
        }
        // Dialogue must stay glued to its cue, so the separator depends on
        // what follows: a blank line everywhere except between a cue and the
        // line it introduces, which Fountain reads as one speech.
        .enumerated()
        .map { index, text -> String in
            guard index + 1 < elements.count else { return text }
            let current = elements[index].type
            let next = elements[index + 1].type
            let glued = (current.isCharacterCue || current == .parenthetical)
                && (next == .dialogue || next == .parenthetical)
            return text + (glued ? "\n" : "\n\n")
        }
        .joined()
    }

    // MARK: - Reading

    /// Whether `text` carries enough screenplay structure to be worth
    /// splitting. One prose paragraph pasted mid-sentence is not.
    static func looksLikeScreenplay(_ text: String) -> Bool {
        let elements = parse(text)
        guard elements.count > 1 else { return false }
        // Something must be more than action; otherwise this is just prose
        // that happened to contain a blank line.
        return elements.contains { $0.type != .action && $0.type != .text }
    }

    /// Split pasted text into elements.
    ///
    /// Paragraphs are the unit, because a blank line is the one separator
    /// Fountain is unambiguous about. Within a paragraph, a character cue
    /// claims its first line and hands the rest to dialogue — the one place
    /// where a single paragraph is more than one element.
    static func parse(_ text: String) -> [FountainElement] {
        var elements: [FountainElement] = []
        for paragraph in paragraphs(in: text) {
            elements.append(contentsOf: parse(paragraph: paragraph))
        }
        return elements
    }

    private static func paragraphs(in text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func parse(paragraph: String) -> [FountainElement] {
        let lines = paragraph.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return [] }

        // A cue with lines under it is a speech: cue, then parentheticals and
        // dialogue. This is the case the single-chunk detector cannot see.
        if lines.count > 1, let cue = cueType(for: first) {
            var elements = [FountainElement(type: cue, content: bareCue(first))]
            for line in lines.dropFirst() {
                elements.append(FountainElement(
                    type: isParenthetical(line) ? .parenthetical : .dialogue,
                    content: line))
            }
            return elements
        }

        // A structural first line with text under it: a writer who omitted the
        // blank line after a scene heading still meant two elements. Emit it,
        // then read what is left as its own paragraph.
        if lines.count > 1,
           let detected = FountainDetector.detect(first),
           isStructural(detected.type) {
            return [FountainElement(type: detected.type, content: detected.content)]
                + parse(paragraph: lines.dropFirst().joined(separator: "\n"))
        }

        if lines.count == 1 {
            // Ahead of the detector, which strips the brackets — the rest of
            // the app stores a parenthetical with them, and a paste should
            // look like what is already in the script.
            if isParenthetical(first) {
                return [FountainElement(type: .parenthetical, content: first)]
            }
            if let detected = FountainDetector.detect(first) {
                return [FountainElement(type: detected.type, content: detected.content)]
            }
            return [FountainElement(type: .action, content: first)]
        }

        if let detected = FountainDetector.detect(paragraph) {
            return [FountainElement(type: detected.type, content: detected.content)]
        }
        // Wrapped prose is one thought, so the lines rejoin.
        return [FountainElement(type: .action, content: lines.joined(separator: " "))]
    }

    /// Element types that stand on their own — anything that is not the prose
    /// body of a scene or a speech.
    private static func isStructural(_ type: BlockType) -> Bool {
        switch type {
        case .action, .text, .dialogue: return false
        default: return true
        }
    }

    /// A cue line, or nil. Deliberately stricter than the detector's: this
    /// runs on a line that has text under it, where a false positive would
    /// turn a paragraph of action into a character speaking.
    private static func cueType(for line: String) -> BlockType? {
        let bare = line.hasSuffix("^") ? String(line.dropLast()) : line
        let name = bare.split(separator: "(").first.map(String.init) ?? bare
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 40 else { return nil }
        guard trimmed == trimmed.uppercased() else { return nil }
        guard trimmed.rangeOfCharacter(from: .letters) != nil else { return nil }
        // A heading or a transition is uppercase too, and is not a cue.
        if FountainDetector.detect(line)?.type != nil,
           let detected = FountainDetector.detect(line)?.type,
           detected != .character, detected != .dualDialogue {
            return nil
        }
        return line.hasSuffix("^") ? .dualDialogue : .character
    }

    private static func bareCue(_ line: String) -> String {
        let bare = line.hasSuffix("^") ? String(line.dropLast()) : line
        return bare.trimmingCharacters(in: .whitespaces)
    }

    private static func isParenthetical(_ line: String) -> Bool {
        line.hasPrefix("(") && line.hasSuffix(")")
    }
}
