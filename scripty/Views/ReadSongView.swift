//
//  ReadSongView.swift
//  scripty
//
//  Read mode for a song: the lyric with the keyboard taken out of it.
//
//  The sibling of `ReadScriptView`, and built to the same rule — the words are
//  set exactly as the writing surface sets them, and the editing chrome is what
//  goes. Same face, same size, same left edge, same line for line: the only
//  difference between the two surfaces is that one takes a caret and the other
//  does not.
//
//  It was a re-typesetting before. The reader gathered the lines into stanzas,
//  gave each verse break twenty-four points of air instead of the blank line
//  the writer had typed, held the column to a measure of its own and centred
//  it. All of that reads well on its own and none of it is what the writer had
//  just been looking at, so entering the mode moved every line of the song
//  sideways and most of them up. The numbers both surfaces lay out with are in
//  `ProseColumn` now, and the type is the editor's own font.
//
//  Not a screen of its own. Like the script reader, this is one of the song
//  editor's surfaces: the mode swaps the editable lines for this column in
//  place, and the toolbar, the banners and the saving all stay exactly where
//  they were.
//
//  Takes plain strings rather than lyric blocks, because a song reaches this
//  view two ways — as the lines the server stores, and as the text of a song
//  that has none. Highlights are deliberately not drawn: a tint is a working
//  mark on a line to come back to, the same class of thing the script reader
//  leaves out along with notes and synopses.
//

import SwiftUI

/// The type a song's name is set in wherever the song itself is on screen.
///
/// Shared because both editors head their own surface with it now, and a title
/// that changed face or size on the way into reading would be the one part of
/// the page that moved when the mode did. The lines underneath do not change at
/// all any more, and neither does this.
///
/// In the lyric's own face, which is the script's: the reader gave up its serif
/// prose so a writer moving between a scene and the song in it would not meet a
/// second typeface, and a heading left behind in the old one would be the whole
/// of what that change was meant to stop.
@MainActor
enum DocumentTitleType {
    /// A step up from the lyric rather than the display size the serif face
    /// carried: Courier sets wide, and a title big enough to eat the measure
    /// would wrap before the verses did.
    static let baseSize: CGFloat = ProseFont.baseSize * 1.5

    /// Bold in the font itself rather than through `.fontWeight`, because one of
    /// the four places this is used is a `TextField`: a weight modifier on the
    /// view around a field does not reach the text inside it, so the name came
    /// out light while it was being typed and bold the moment it was read.
    static func font(scale: CGFloat) -> Font {
        Font(PresentationSettings.shared.defaultFont
            .uiFont(size: baseSize * scale, traits: .traitBold))
    }
}

struct ReadSongView: View {
    let title: String
    /// The lyric, one string per line, in order — including the blank ones,
    /// which are drawn as the blank lines they are. A verse break is something
    /// the writer typed and can see themselves typing; turning it into air on
    /// the way into reading was this surface deciding it knew better, and it
    /// cost the writer every line's position to say so.
    let lines: [String]
    let textScale: Double
    /// Start writing the lyric — the double tap's counterpart of the Edit
    /// button in the toolbar. Nil where there is nothing to write in: a song
    /// the server sent to be read only.
    ///
    /// Handed how far into the lyric *as a whole* the finger landed, in UTF-16
    /// and counting the line breaks between the lines. One number rather than a
    /// line and an offset into it, because the two editors behind this surface
    /// disagree about what a line is: the plain one holds the lyric as a single
    /// string, and only the lyric editor keeps a row apiece. Counted the way the
    /// plain editor stores it, so that one spends it as it stands and the other
    /// walks it back to a row — see `caretOffset(inLine:at:)`.
    var onEdit: ((Int) -> Void)?
    /// Whether the writing surface behind this one keeps each line as a row of
    /// its own — the lyric editor does, the plain one does not.
    ///
    /// It decides nothing about how the words *look*; it decides how the height
    /// of the column is added up, and the two editors add it up differently. A
    /// row is a view, and a view's height is rounded up to a whole point: a
    /// lyric of forty lines drawn as forty rows is a few points taller than the
    /// same forty lines drawn as one text view, and reading the one as the other
    /// walked every line slowly out of place down the page. So the reader
    /// rounds the way whichever editor it stands in for rounds.
    var linesAreRows = false
    /// Which line the voice is on, while the song is being read aloud — an
    /// index into `lines`, since that is all this surface is given to point
    /// at. Nil when nothing is being read, which is the ordinary state.
    ///
    /// Only marked where the lines are rows. Drawn as one text view they are a
    /// single view with no line to put a wash behind, and the alternative —
    /// splitting the text to highlight it — would re-typeset the very column
    /// this surface exists to leave alone.
    var highlighted: Int?

    /// The OS text-size setting as a multiplier, for the title — which is a
    /// SwiftUI font sized in points, unlike the lines below it, whose own font
    /// carries Dynamic Type inside it. Exactly as both song editors scale it.
    @ScaledMetric(relativeTo: .body) private var dynamicTypeScale: CGFloat = 1

    private var titleScale: CGFloat { CGFloat(textScale) * dynamicTypeScale }

    /// How wide this surface is, so the words can be given the same definite
    /// width the editable rows are given — see `ProseColumn.columnWidth(in:)`.
    @State private var availableWidth: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Spacing zero: a lyric is single-spaced, and the lines it is
                // being compared against are text views drawn flush in a list
                // whose minimum row height has been taken away.
                VStack(alignment: .leading, spacing: 0) {
                    Text(title.isEmpty ? "Untitled Song" : title)
                        .font(DocumentTitleType.font(scale: titleScale))
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, ProseColumn.titleTopPadding)
                        .padding(.bottom, ProseColumn.titleBottomPadding)

                    if linesAreRows {
                        // One text view per line, as the editor keeps one row
                        // per line — same engine, same width, same rounding.
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            // A blank line is drawn as a space, so it takes the
                            // line's height the empty row it stands in for takes.
                            lyric(line.isEmpty ? " " : line,
                                  startingAt: lineStart(index),
                                  within: line)
                                // The wash is inset outwards, so switching it on
                                // cannot move the line it marks — the same trick
                                // the script reader's spotlight uses.
                                .background {
                                    if index == highlighted {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(Color.accentColor.opacity(0.16))
                                            .padding(.horizontal, -10)
                                    }
                                }
                                .id(index)
                        }
                    } else {
                        // The lyric in one text view, as the plain editor holds
                        // it in one. A line break is a line break to TextKit, so
                        // every line still breaks where the writer left it — and
                        // an offset into this view is already an offset into the
                        // lyric, so it starts at nothing.
                        lyric(lines.joined(separator: "\n"), startingAt: 0,
                              within: lines.joined(separator: "\n"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ProseColumn.horizontalPadding)
                .padding(.bottom, ProseColumn.bottomSlack)
            }
            // Follow the voice, where there are rows to follow it by.
            .onChange(of: highlighted) { _, index in
                guard let index else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
            availableWidth = $0
        }
        .overlay { emptyState }
    }

    /// One stretch of lyric, set the way the editor sets it. Two taps in it are
    /// the same instruction as Edit in the toolbar, the way they are in Pages
    /// and Word.
    ///
    /// `start` is where this stretch begins in the lyric as a whole — nothing
    /// where the lyric is drawn in one piece, and the sum of the lines above it
    /// where each line is a view of its own. It is what turns the offset the
    /// text view reports into the offset the host was promised.
    ///
    /// `stored` is the same words as the writer has them, which is not always
    /// what is drawn: a blank line is set as a space so that it keeps a line's
    /// height. The caret is held inside *those* words, so a tap past the end of
    /// a blank line's placeholder lands at the blank line rather than a
    /// character into the line below it.
    private func lyric(_ text: String, startingAt start: Int,
                       within stored: String) -> some View {
        ProseText(text: text,
                  textScale: textScale,
                  startWriting: onEdit.map { edit in
                      { offset in edit(start + min(offset, textLength(stored))) }
                  })
            .frame(width: ProseColumn.columnWidth(in: availableWidth),
                   alignment: .leading)
    }

    /// Where `index` begins in the lyric as a whole: every line above it, plus
    /// the line break after each. Only meaningful where the lines are rows —
    /// drawn in one piece there is nothing above any of them.
    ///
    /// Counted from `lines` rather than from what was drawn, because a blank
    /// line is *drawn* as a space and stored as nothing: adding up the drawn
    /// text would push every line below the first blank one one place along.
    private func lineStart(_ index: Int) -> Int {
        lines.prefix(index).reduce(0) { $0 + textLength($1) + 1 }
    }

    /// A string's length in UTF-16 — the count a text view's own selection is
    /// in, and so the only count that can be added to one.
    private func textLength(_ text: String) -> Int {
        (text as NSString).length
    }

    /// Whether there is a word here to read. Blank lines do not count: a lyric
    /// of nothing but empty lines is an empty lyric, however many Returns went
    /// into it.
    private var isEmpty: Bool {
        lines.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    @ViewBuilder
    private var emptyState: some View {
        if isEmpty {
            ContentUnavailableView(
                "Nothing to Read",
                systemImage: "music.note",
                description: Text("This song has no lyrics yet."))
        }
    }
}
