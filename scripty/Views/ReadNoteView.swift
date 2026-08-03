//
//  ReadNoteView.swift
//  scripty
//
//  Read mode for a note: the note as prose, for reading rather than writing.
//
//  The third of the readers, and built to the same rules as `ReadScriptView`
//  and `ReadSongView` — a held measure, the editing chrome left out, the type
//  scaled by the same device-wide preference — because they are the same
//  posture. What differs is what a note is. A screenplay has element types and
//  a lyric has verse lines; a note has paragraphs, and the handful of prefixes
//  the writing surface maintains: `# Act One`, `- a bullet`, `1. an item`.
//  Those are set as what they are here rather than shown as the characters they
//  are stored as — see `NoteReading`, which does the recognising, and which
//  changes nothing about the note itself.
//
//  Not a screen of its own. Like the other two, this is one of the editor's
//  surfaces: the mode swaps the title field and the text view for this column
//  in place, and the toolbar, the badge and the saving all stay where they were.
//
//  Takes the text on screen rather than the last saved copy, so a paragraph
//  typed a moment ago is there to be read whether or not its save has landed.
//

import SwiftUI

struct ReadNoteView: View {
    let title: String
    let text: String
    let textScale: Double
    /// Start writing the note — the double tap's counterpart of the Edit button
    /// in the toolbar. Nil where there is nothing to write in: a note the
    /// server sent to be read only.
    ///
    /// No line is named, as none is in the lyric reader: this surface is handed
    /// one string, so there is no element to put a caret in, and the editor
    /// comes back where it was left rather than where the finger landed.
    var onEdit: (() -> Void)?

    /// The face the note is set in, which is the one it is written in — the
    /// writer's chosen default, and so the script's. Serif prose here would put
    /// the whole note in a different typeface the moment the mode changed,
    /// which is the fault the lyric reader gave up its own serif to fix.
    private var face: String { PresentationSettings.shared.defaultFont.postScriptName }

    /// The reader's measure — wider than the lyric's 520 and a little wider
    /// than the screenplay's column, because prose is measured in characters
    /// to the line and a paragraph wants more of them than a verse does.
    private var measure: CGFloat { 620 * scale }

    /// One level of nesting, as a margin. The stored line indents with spaces;
    /// a reader sets it, for the reason `NoteFormatting.LineKind.plain` gives.
    private var indentUnit: CGFloat { 22 * scale }

    /// The OS text-size setting as a multiplier, so the reader honours Dynamic
    /// Type while keeping its own proportions — exactly as the other two
    /// readers fold the two together.
    @ScaledMetric(relativeTo: .body) private var dynamicTypeScale: CGFloat = 1

    private var scale: CGFloat { CGFloat(textScale) * dynamicTypeScale }

    private var paragraphs: [[NoteFormatting.LineKind]] {
        NoteReading.paragraphs(in: text)
    }

    var body: some View {
        // Once per redraw, not twice: the empty-state overlay below used to
        // ask `paragraphs` for its own copy, which re-read the whole note just
        // to find out whether there was anything in it.
        let groups = paragraphs
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 18 * scale) {
                Text(title.isEmpty ? "Untitled Notes" : title)
                    .font(DocumentTitleType.font(scale: scale))
                    .fontWeight(.bold)
                    .accessibilityAddTraits(.isHeader)

                ForEach(Array(groups.enumerated()), id: \.offset) { _, paragraph in
                    VStack(alignment: .leading, spacing: 6 * scale) {
                        ForEach(Array(paragraph.enumerated()), id: \.offset) { _, line in
                            self.line(line)
                        }
                    }
                    // One paragraph is one thing to hear: VoiceOver reads it
                    // through rather than making the reader swipe line by line.
                    .accessibilityElement(children: .combine)
                }
            }
            // Take the whole measure rather than settling on the longest line,
            // for the reason the other readers do: a lazy stack is only as wide
            // as the rows it has built, so the column — and, being centred, its
            // left edge — would otherwise shift as scrolling went on.
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxWidth: measure, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .textSelection(.enabled)
            // Two taps in the prose are the same instruction as Edit in the
            // corner, the way they are in Pages and Word. On the column rather
            // than on each paragraph: this surface holds one string, so the
            // gesture means "write this note" rather than "write this line".
            .doubleTapToEdit(onEdit)
        }
        .overlay { emptyState(groups) }
    }

    // MARK: - Lines

    @ViewBuilder
    private func line(_ kind: NoteFormatting.LineKind) -> some View {
        switch kind {
        case .heading(let level, let text):
            Text(text)
                .font(.custom(face, fixedSize: headingSize(level)))
                .fontWeight(headingWeight(level))
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Air above a heading, the way the script reader gives a scene
                // heading its two blank lines — except at the head of a
                // paragraph, where the paragraph's own spacing already has it.
                .padding(.top, 2 * scale)

        case .bullet(let depth, let text):
            item(marker: "•", text: text, depth: depth)

        case .numbered(let depth, let number, let text):
            item(marker: "\(number).", text: text, depth: depth)

        case .plain(let depth, let text):
            prose(text)
                .padding(.leading, CGFloat(depth) * indentUnit)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .blank:
            // Never reached: `NoteReading` turns blank lines into the gaps
            // between paragraphs rather than passing them on as rows.
            EmptyView()
        }
    }

    /// A list item: the marker in a column of its own, and the words hanging
    /// beside it — so a bullet that wraps lines up under its own text rather
    /// than under the dot.
    private func item(marker: String, text: String, depth: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8 * scale) {
            prose(marker)
                .frame(minWidth: 16 * scale, alignment: .trailing)
                .accessibilityHidden(true)
            prose(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(depth + 1) * indentUnit)
    }

    /// One line of prose, in the reader's face and size — the size the note is
    /// written at, so reading it re-sets the words rather than enlarging them.
    private func prose(_ text: String) -> Text {
        Text(text.isEmpty ? " " : text)
            .font(.custom(face, fixedSize: ProseFont.baseSize * scale))
    }

    /// Headings step down towards the body size and stop there: a note is a
    /// page of prose, not a document with six levels of outline in it, so an
    /// `###### ` line is still a heading but no smaller than what it heads.
    ///
    /// As multiples of the body size rather than as point sizes of their own,
    /// so the ladder survives the body size moving: written out as 24/21/19 for
    /// a 16pt note, a heading was nearly the size of what it headed the moment
    /// the prose grew.
    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return ProseFont.baseSize * 1.5 * scale
        case 2: return ProseFont.baseSize * 1.3 * scale
        case 3: return ProseFont.baseSize * 1.2 * scale
        default: return ProseFont.baseSize * scale
        }
    }

    private func headingWeight(_ level: Int) -> Font.Weight {
        level <= 2 ? .bold : .semibold
    }

    /// Takes the paragraphs rather than re-reading the note for its own copy.
    @ViewBuilder
    private func emptyState(_ groups: [[NoteFormatting.LineKind]]) -> some View {
        if groups.isEmpty {
            ContentUnavailableView(
                "Nothing to Read",
                systemImage: "note.text",
                description: Text("This note has nothing in it yet."))
        }
    }
}
