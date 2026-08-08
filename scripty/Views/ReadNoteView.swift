//
//  ReadNoteView.swift
//  scripty
//
//  Read mode for a note: the note with the keyboard taken out of it.
//
//  The third of the readers, and built to the same rule as `ReadScriptView` and
//  `ReadSongView`: the words are set exactly as the writing surface sets them —
//  same face, same size, same left edge, same line breaks — and what goes is the
//  editing chrome. One surface takes a caret and the other does not, and that is
//  the whole of the difference.
//
//  It re-typeset the note before. `# Act One` came out as a twenty-four point
//  heading with the hashes hidden, `- a bullet` grew a dot and a hanging indent,
//  a nested line was indented by a margin instead of by the spaces it is stored
//  with, blank lines became paragraph air, and the column narrowed and centred
//  itself. Every one of those is a difference between what the writer had been
//  looking at a moment earlier and what reading gave them back, and together
//  they moved every line in the note. The note is plain text — hashes and dashes
//  and all — so reading it shows plain text. The numbers both surfaces lay out
//  with are in `ProseColumn`, and the type is the editor's own font.
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
    /// Whether the note is still on its way.
    ///
    /// Only ever true now that a note can *open* into reading rather than only
    /// be switched into it: the editor seeds the mode from the remembered
    /// setting in `init` and only corrects it after the fetch has been awaited,
    /// so on a cold launch this surface is on screen before there is a word to
    /// put on it. Without this, a writer who left a page of notes in reading
    /// mode reopened it to "Nothing to Read — This note has nothing in it yet"
    /// for the length of the request, and then the notes appeared. The spinner
    /// the editor already has is attached to the writing surface, which is not
    /// the one on screen at that moment. `ReadSongView` takes the same input for
    /// the same cold-launch path, and `ReadScriptView` before it.
    var isLoading = false
    /// Start writing the note — the double tap's counterpart of the Edit button
    /// in the toolbar. Nil where there is nothing to write in: a note the
    /// server sent to be read only.
    ///
    /// Handed how far into the note the finger landed, in UTF-16. A note is one
    /// string on both surfaces, so the offset the reader measures is already the
    /// offset the editor wants — nothing has to be converted on the way across.
    var onEdit: ((Int) -> Void)?
    /// Reports finger-driven scrolling, so the editor around this surface can
    /// fold its bars away while the note is being read through — the same fold
    /// the writing surface takes, since reading is the posture it exists for.
    var onUserScroll: (_ delta: CGFloat, _ fromTop: CGFloat) -> Void = { _, _ in }

    /// The OS text-size setting as a multiplier, for the title — which is a
    /// SwiftUI font sized in points, unlike the note itself, whose font carries
    /// Dynamic Type inside it. Exactly as the editor scales the same heading.
    @ScaledMetric(relativeTo: .body) private var dynamicTypeScale: CGFloat = 1

    private var titleScale: CGFloat { CGFloat(textScale) * dynamicTypeScale }

    /// How wide this surface is, so the words can be given the same definite
    /// width the editor's text view is given — see `ProseColumn.columnWidth(in:)`.
    @State private var availableWidth: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(title.isEmpty ? "Untitled Notes" : title)
                    .font(DocumentTitleType.font(scale: titleScale))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, ProseColumn.titleTopPadding)
                    .padding(.bottom, ProseColumn.titleBottomPadding)

                // The note in one piece, in the same text view the writing
                // surface is: same engine, same width, same font, so the words
                // break where they broke a moment ago. Blank lines come through
                // as the blank lines they are, which is what the writer typed
                // and what they will see again the moment they tap Edit.
                ProseText(text: text,
                          textScale: textScale,
                          // Two taps in the prose are the same instruction as
                          // Edit in the corner, the way they are in Pages and
                          // Word.
                          startWriting: onEdit)
                    .frame(width: ProseColumn.columnWidth(in: availableWidth),
                           alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ProseColumn.horizontalPadding)
            .padding(.bottom, ProseColumn.bottomSlack)
        }
        .onUserScroll(onUserScroll)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
            availableWidth = $0
        }
        .overlay { emptyState }
    }

    @ViewBuilder
    private var emptyState: some View {
        if isLoading {
            ProgressView()
        } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView(
                "Nothing to Read",
                systemImage: "note.text",
                description: Text("This note has nothing in it yet."))
        }
    }
}
