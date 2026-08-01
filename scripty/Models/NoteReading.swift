//
//  NoteReading.swift
//  scripty
//
//  A note as it is read rather than typed: its plain text grouped into
//  paragraphs, each line classified by the prefix it carries.
//
//  The screenplay reader sets each element by its type and the song reader sets
//  a lyric as stanzas; a note is prose, and what a note has instead of element
//  types is the handful of prefixes `NoteFormatting` maintains while it is being
//  written — `#` for a heading, `-` and `1.` for a list. Reading them back is
//  what lets the reader set a heading as a heading instead of showing the hash.
//
//  Display only, and worth being plain about: nothing here rewrites a note.
//  The line the server holds still says "# Act One", it still says that in the
//  editor, and it still says that when the note is inserted into the script.
//  This is the same posture the script reader takes when it draws a scene
//  heading in bold — the document is unchanged, the setting of it is not.
//
//  Text in, values out, so the grouping can be checked without a view: the
//  reader only has to decide how each kind is set.
//

import Foundation

enum NoteReading {
    /// The note's lines, grouped into paragraphs.
    ///
    /// A blank line is a paragraph break rather than a line with no words in
    /// it — the rule the song reader applies to a verse — so a run of several
    /// blanks is one break, and the reader spaces paragraphs instead of drawing
    /// empty rows. Line breaks *inside* a paragraph are kept exactly as typed:
    /// a note is plain text, and a writer who broke a line meant to.
    ///
    /// A line that is nothing but a marker — the empty bullet Return leaves
    /// waiting for the next item — is left out rather than drawn as a dot with
    /// no words beside it. It is not a paragraph break either: the writer was
    /// in the middle of a list, not between two of them, so the item that
    /// follows stays in the same run as the one before.
    ///
    /// An empty note is no paragraphs at all, which is what the reader's
    /// "Nothing to Read" is asked about.
    static func paragraphs(in text: String) -> [[NoteFormatting.LineKind]] {
        var built: [[NoteFormatting.LineKind]] = []
        var current: [NoteFormatting.LineKind] = []
        for line in text.components(separatedBy: .newlines) {
            let kind = NoteFormatting.kind(of: line)
            if kind == .blank {
                if !current.isEmpty {
                    built.append(current)
                    current = []
                }
            } else if !kind.words.trimmingCharacters(in: .whitespaces).isEmpty {
                current.append(kind)
            }
        }
        if !current.isEmpty { built.append(current) }
        return built
    }
}
