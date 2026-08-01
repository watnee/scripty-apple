//
//  NoteFormatting.swift
//  scripty
//
//  Lists, indents and headings while typing a note, ported from the web
//  editor's text-document-edit.js.
//
//  Notes stay plain text end to end: nothing here is ever rewritten into markup
//  on the way to the server, and the prefixes survive verbatim into the script
//  when a note is inserted into it. All this does is save the writer typing them
//  by hand — Return carries the bullet down to the next line, Tab nests it, and
//  a numbered list renumbers itself when something is added in the middle.
//
//  The one place the prefixes are *read* rather than written is the reading
//  surface — see `kind(of:)` at the foot of this file and `NoteReading` next
//  door. That is display only: a heading is set as a heading on screen and the
//  stored line still says "# Act One".
//
//  Kept as pure text-in, text-out so the rules can be checked without a running
//  text view; the view layer only has to decide *when* to call them.
//

import Foundation

/// A rewritten document and where the caret should land in it. Offsets are in
/// Characters, converted at the text view's edge like every other caret in the
/// app.
struct NoteEdit: Equatable {
    var text: String
    var caret: Int
}

/// The one span of a note that a rule rewrote: where it starts, where it ended
/// in the old text, and what replaces it. Offsets are in Characters, like every
/// other offset here.
struct NoteChange: Equatable {
    var start: Int
    var end: Int
    var replacement: String
}

enum NoteFormatting {
    /// One level, as spaces. Notes have no tab stops, so nesting has to be
    /// something a plain-text reader will also see.
    static let indentUnit = "    "

    /// `  - ` or `  1. ` — the indent, the marker, and the space after it.
    private static let listPrefix = try! NSRegularExpression(
        pattern: #"^([ \t]*)([-*]|\d+\.)([ \t]+)"#)
    private static let headingPrefix = try! NSRegularExpression(pattern: #"^(#{1,6})[ \t]+"#)

    // MARK: - Typing

    /// Return pressed with the caret in a list item: carry the list down.
    ///
    /// Returns nil when the line is not a list item, which the caller reads as
    /// "let the newline through untouched".
    static func newline(in text: String, caret: Int) -> NoteEdit? {
        var (lines, row, column) = split(text, caret: caret)
        guard let list = listParts(lines[row]) else { return nil }

        // An empty item means the writer is done with the list. Clearing the
        // line rather than nesting another empty one is how every editor that
        // does this behaves, and the only way out that doesn't need the mouse.
        if list.body.trimmingCharacters(in: .whitespaces).isEmpty {
            lines[row] = ""
            return join(lines, row: row, column: 0)
        }

        let marker = list.number.map { "\($0 + 1)." } ?? list.marker
        let carried = list.indent + marker + list.spacing
        // Split at the caret, so Return in the middle of an item works the way
        // it does in the middle of a paragraph.
        let line = Array(lines[row])
        let cut = min(column, line.count)
        lines[row] = String(line[..<cut])
        lines.insert(carried + String(line[cut...]), at: row + 1)

        let edit = join(lines, row: row + 1, column: carried.count)
        return list.number == nil ? edit : renumbering(edit)
    }

    /// Tab and Shift-Tab. Inside a list they nest and un-nest the item; outside
    /// one they are just an indent, since a note has no other use for the key.
    static func indent(in text: String, caret: Int, outdent: Bool) -> NoteEdit? {
        var (lines, row, column) = split(text, caret: caret)
        let line = lines[row]
        let isList = listParts(line) != nil

        if outdent {
            let stripped = removingOneIndent(line)
            guard stripped != line else { return nil }
            let removed = line.count - stripped.count
            lines[row] = stripped
            let edit = join(lines, row: row, column: max(0, column - removed))
            return isList ? renumbering(edit) : edit
        }

        if isList {
            // Nest the whole item, wherever the caret happens to be in it.
            lines[row] = indentUnit + line
            return renumbering(join(lines, row: row, column: column + indentUnit.count))
        }
        let characters = Array(line)
        let cut = min(column, characters.count)
        lines[row] = String(characters[..<cut]) + indentUnit + String(characters[cut...])
        return join(lines, row: row, column: column + indentUnit.count)
    }

    // MARK: - Toolbar

    /// Puts a heading marker on the caret's line, or takes the same one off.
    static func toggleHeading(in text: String, caret: Int, level: Int) -> NoteEdit {
        applying(.heading(level), marker: String(repeating: "#", count: level),
                 to: text, caret: caret)
    }

    /// Puts a bullet or a number on the caret's line, or takes it off again.
    static func toggleList(in text: String, caret: Int, ordered: Bool) -> NoteEdit {
        let edit = applying(ordered ? .ordered : .bullet,
                            marker: ordered ? "1." : "-",
                            to: text, caret: caret)
        return ordered ? renumbering(edit) : edit
    }

    /// Which prefix a line carries, if any. A line holds at most one, so
    /// applying a new one replaces whatever was there rather than stacking.
    private enum Prefix: Equatable {
        case bullet, ordered
        case heading(Int)
    }

    private static func applying(_ kind: Prefix,
                                 marker: String,
                                 to text: String,
                                 caret: Int) -> NoteEdit {
        var (lines, row, _) = split(text, caret: caret)
        let (indent, existing, body) = parts(of: lines[row])
        // Pressing the same control again clears the prefix.
        lines[row] = existing == kind ? indent + body : indent + marker + " " + body
        return join(lines, row: row, column: lines[row].count)
    }

    // MARK: - Renumbering

    /// Rewrites the numbers in every ordered list so that inserting or removing
    /// an item does not leave 1. 2. 2. 3. behind.
    ///
    /// A run restarts after any line that is not a list item, and each level of
    /// nesting counts separately — otherwise a sub-list would go on from where
    /// its parent left off.
    static func renumbering(_ edit: NoteEdit) -> NoteEdit {
        var (lines, row, column) = split(edit.text, caret: edit.caret)
        var counters: [Int: Int] = [:]

        for index in lines.indices {
            guard let list = listParts(lines[index]) else {
                counters = [:]
                continue
            }
            let depth = list.indent.count
            guard list.number != nil else {
                // A bullet at this depth ends the numbering that was running there.
                counters[depth] = nil
                continue
            }
            for level in counters.keys where level > depth { counters[level] = nil }
            let next = (counters[depth] ?? 0) + 1
            counters[depth] = next

            let expected = "\(next)."
            guard expected != list.marker else { continue }
            let rewritten = list.indent + expected + list.spacing + list.body
            // The caret is on this line and past the marker, so it moves with it.
            if index == row {
                column = max(0, column + rewritten.count - lines[index].count)
            }
            lines[index] = rewritten
        }
        return join(lines, row: row, column: column)
    }

    // MARK: - Applying a rewrite

    /// The span that differs between two versions of a note, or nil when they
    /// are the same text.
    ///
    /// The rules above are written as whole-document rewrites, which is what
    /// makes them checkable without a text view. A text view, though, must be
    /// told what actually changed: replacing the whole document is invisible to
    /// UIKit's undo manager and would leave ⌘Z stepping back to a note that no
    /// longer exists. So the rewrite is narrowed to its one changed span on the
    /// way in — the same reason the browser editor pushes its edits through
    /// `execCommand('insertText')` instead of assigning `.value`.
    ///
    /// One span is always enough: every rule here rewrites the caret's line,
    /// and renumbering extends that to a run of lines around it. Anything a
    /// common prefix and suffix cannot narrow — a renumber above the caret and
    /// another below it — simply widens the span to cover both, which is still
    /// one correct replacement.
    static func change(from old: String, to new: String) -> NoteChange? {
        guard old != new else { return nil }
        let before = Array(old)
        let after = Array(new)

        var start = 0
        while start < before.count, start < after.count, before[start] == after[start] {
            start += 1
        }
        var oldEnd = before.count
        var newEnd = after.count
        while oldEnd > start, newEnd > start, before[oldEnd - 1] == after[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }
        return NoteChange(start: start, end: oldEnd,
                          replacement: String(after[start..<newEnd]))
    }

    // MARK: - Line parsing

    private struct ListParts {
        let indent: String
        let marker: String
        let spacing: String
        let body: String
        /// The value of a numbered marker, or nil for a bullet.
        let number: Int?
    }

    private static func listParts(_ line: String) -> ListParts? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = listPrefix.firstMatch(in: line, range: range),
              let indent = Range(match.range(at: 1), in: line),
              let marker = Range(match.range(at: 2), in: line),
              let spacing = Range(match.range(at: 3), in: line),
              let whole = Range(match.range, in: line)
        else { return nil }

        let markerText = String(line[marker])
        return ListParts(indent: String(line[indent]),
                         marker: markerText,
                         spacing: String(line[spacing]),
                         body: String(line[whole.upperBound...]),
                         number: Int(markerText.dropLast()))
    }

    /// A line split into its indent, whatever prefix it carries, and the rest.
    private static func parts(of line: String) -> (indent: String, prefix: Prefix?, body: String) {
        if let list = listParts(line) {
            return (list.indent, list.number == nil ? .bullet : .ordered, list.body)
        }
        let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        let rest = String(line.dropFirst(indent.count))
        let range = NSRange(rest.startIndex..., in: rest)
        if let match = headingPrefix.firstMatch(in: rest, range: range),
           let hashes = Range(match.range(at: 1), in: rest),
           let whole = Range(match.range, in: rest) {
            return (indent, .heading(rest[hashes].count), String(rest[whole.upperBound...]))
        }
        return (indent, nil, rest)
    }

    /// Drops up to one level of leading space, or a single tab.
    private static func removingOneIndent(_ line: String) -> String {
        if line.hasPrefix("\t") { return String(line.dropFirst()) }
        var stripped = line
        for _ in 0..<indentUnit.count {
            guard stripped.hasPrefix(" ") else { break }
            stripped.removeFirst()
        }
        return stripped
    }

    // MARK: - Reading

    /// What one line of a note is, as a surface that only shows it sees it.
    ///
    /// The same prefixes the typing rules above maintain, recognised rather
    /// than written — which is why this reuses their parsers instead of
    /// carrying a second idea of what a bullet looks like. `text` is the line
    /// with its marker taken off, for setting; nothing here changes the note.
    enum LineKind: Equatable {
        /// Nothing but whitespace: the writer's own paragraph break.
        case blank
        case heading(level: Int, text: String)
        case bullet(depth: Int, text: String)
        case numbered(depth: Int, number: Int, text: String)
        /// An ordinary line, with whatever it was indented by. The indent is
        /// counted rather than kept as spaces because a reader sets it as a
        /// margin — leading spaces in a `Text` are not a reliable indent.
        case plain(depth: Int, text: String)

        /// What the line actually says, with its marker off. A marker and
        /// nothing else — the empty bullet Return leaves waiting for the next
        /// item, a heading whose words have not been typed yet — says nothing,
        /// which is what lets a reader leave it out.
        var words: String {
            switch self {
            case .blank: return ""
            case .heading(_, let text), .bullet(_, let text),
                 .numbered(_, _, let text), .plain(_, let text):
                return text
            }
        }
    }

    static func kind(of line: String) -> LineKind {
        if line.trimmingCharacters(in: .whitespaces).isEmpty { return .blank }
        if let list = listParts(line) {
            let depth = depth(of: list.indent)
            if let number = list.number {
                return .numbered(depth: depth, number: number, text: list.body)
            }
            return .bullet(depth: depth, text: list.body)
        }
        let (indent, prefix, body) = parts(of: line)
        if case .heading(let level) = prefix {
            return .heading(level: level, text: body)
        }
        return .plain(depth: depth(of: indent), text: body)
    }

    /// How deeply a line is nested, from the whitespace in front of it. A tab
    /// is one level, as it is to the outdent rule above; spaces go by the
    /// indent unit, and a part-level of stray spaces rounds down rather than
    /// promoting the line.
    private static func depth(of indent: String) -> Int {
        let tabs = indent.filter { $0 == "\t" }.count
        let spaces = indent.filter { $0 == " " }.count
        return tabs + spaces / indentUnit.count
    }

    // MARK: - Caret arithmetic

    /// The document as lines, plus where the caret sits in them.
    private static func split(_ text: String, caret: Int) -> (lines: [String], row: Int, column: Int) {
        let lines = text.components(separatedBy: "\n")
        var remaining = max(0, min(caret, text.count))
        for (index, line) in lines.enumerated() {
            if remaining <= line.count || index == lines.count - 1 {
                return (lines, index, min(remaining, line.count))
            }
            remaining -= line.count + 1   // the newline itself
        }
        return (lines, 0, 0)
    }

    private static func join(_ lines: [String], row: Int, column: Int) -> NoteEdit {
        let offset = lines[..<row].reduce(0) { $0 + $1.count + 1 }
        return NoteEdit(text: lines.joined(separator: "\n"),
                        caret: offset + min(column, lines[row].count))
    }
}
