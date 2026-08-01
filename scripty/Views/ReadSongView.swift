//
//  ReadSongView.swift
//  scripty
//
//  Read mode for a song: the lyric as verse, for reading rather than writing.
//
//  The sibling of `ReadScriptView`, and built to the same rules — a serif face,
//  a held measure, the editing chrome left out — because they are the same
//  posture. What differs is what a lyric is: short lines that must break where
//  the writer broke them, and blank lines that mean a verse ended rather than a
//  line with no words in it.
//
//  Not a screen of its own. Like the script reader, this is one of the song
//  editor's surfaces: the mode swaps the editable lines for this column in
//  place, and the toolbar, the banners and the saving all stay exactly where
//  they were.
//
//  Takes plain strings rather than lyric blocks, because a song reaches this
//  view two ways — as the lines the server stores, and as the text of a song
//  that has none — and neither shape survives into the reading. Highlights are
//  deliberately not drawn: a tint is a working mark on a line to come back to,
//  the same class of thing the script reader leaves out along with notes and
//  synopses.
//

import SwiftUI

/// The type a song's name is set in wherever the song itself is on screen.
///
/// Shared because both editors head their own surface with it now, and a title
/// that changed face or size on the way into reading would be the one part of
/// the page that moved when the mode did. The lines underneath change — set as
/// verse here, as editable lines there — and the title deliberately does not.
enum SongTitleType {
    /// The size at 100%, against the reader's 17pt lyric line.
    static let baseSize: CGFloat = 28

    static func font(scale: CGFloat) -> Font {
        .system(size: baseSize * scale, weight: .bold, design: .serif)
    }
}

struct ReadSongView: View {
    let title: String
    /// The lyric, one string per line, in order. Blank entries are the writer's
    /// own verse breaks; see `stanzas`.
    let lines: [String]
    let textScale: Double

    /// The reader's measure, narrower than the screenplay reader's 640.
    ///
    /// A measure is a count of characters, and a lyric line is a fraction of a
    /// prose paragraph — set to the script's width, a verse becomes a narrow
    /// ribbon of text stranded down the left of a very wide column. Scaled with
    /// the type for the reason the script reader scales its own.
    private var measure: CGFloat { 520 * scale }

    /// The OS text-size setting as a multiplier, so the reader honours Dynamic
    /// Type while keeping its own proportions — exactly as `ReadScriptView`
    /// folds the two together.
    @ScaledMetric(relativeTo: .body) private var dynamicTypeScale: CGFloat = 1

    private var scale: CGFloat { CGFloat(textScale) * dynamicTypeScale }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24 * scale) {
                Text(title.isEmpty ? "Untitled Song" : title)
                    .font(SongTitleType.font(scale: scale))
                    .accessibilityAddTraits(.isHeader)

                ForEach(Array(stanzas.enumerated()), id: \.offset) { _, stanza in
                    VStack(alignment: .leading, spacing: 3 * scale) {
                        ForEach(Array(stanza.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 17 * scale, design: .serif))
                        }
                    }
                    // One stanza is one thing to hear, not a list of lines:
                    // VoiceOver reads the verse through rather than making the
                    // reader swipe between every line of it.
                    .accessibilityElement(children: .combine)
                }
            }
            // Take the whole measure rather than settling on the longest line.
            // A lazy stack is only as wide as the rows it has built, so without
            // this the column — and, being centred, its left edge — would shift
            // as scrolling brought a longer line into the window.
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxWidth: measure, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .textSelection(.enabled)
        }
        .overlay { emptyState }
    }

    /// The lyric split into stanzas: runs of lines, broken wherever the writer
    /// left a blank one.
    ///
    /// A blank line in a lyric is a verse break rather than a line with no
    /// words in it, so it becomes air between stanzas instead of an empty row —
    /// and a run of several blanks is one break, the way it reads on paper.
    /// Whitespace-only lines count as blank: a line holding a stray space was
    /// still typed as a gap.
    private var stanzas: [[String]] {
        var built: [[String]] = []
        var current: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty {
                    built.append(current)
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { built.append(current) }
        return built
    }

    @ViewBuilder
    private var emptyState: some View {
        if stanzas.isEmpty {
            ContentUnavailableView(
                "Nothing to Read",
                systemImage: "music.note",
                description: Text("This song has no lyrics yet."))
        }
    }
}
