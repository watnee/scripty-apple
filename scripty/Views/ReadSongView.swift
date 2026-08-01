//
//  ReadSongView.swift
//  scripty
//
//  Read mode for a song: the lyric as verse, for reading rather than writing.
//
//  The sibling of `ReadScriptView`, and built to the same rules — the app's
//  own face, a held measure, the editing chrome left out — because they are the
//  same posture. What differs is what a lyric is: short lines that must break
//  where the writer broke them, and blank lines that mean a verse ended rather
//  than a line with no words in it.
//
//  Both readers were serif prose once. The screenplay reader gave that up for
//  Courier so the script would read as a script, and this one kept it — so a
//  writer switching from a scene to the song in it met a different typeface
//  for the length of one tap. It is set in the default face now — the writer's
//  own choice, Courier Prime until they say otherwise — at the size the lyric
//  is written at, the way the script reader re-typesets rather than resizes.
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
///
/// In the lyric's own face, which is the script's: the reader gave up its serif
/// prose so a writer moving between a scene and the song in it would not meet a
/// second typeface, and a heading left behind in the old one would be the whole
/// of what that change was meant to stop.
@MainActor
enum SongTitleType {
    /// A step up from the lyric rather than the display size the serif face
    /// carried: Courier sets wide, and a title big enough to eat the measure
    /// would wrap before the verses did.
    static let baseSize: CGFloat = ProseFont.baseSize * 1.5

    static func font(scale: CGFloat) -> Font {
        .custom(PresentationSettings.shared.defaultFont.postScriptName,
                fixedSize: baseSize * scale)
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
    ///
    /// Left where it was when the reader gave up its serif face: Courier is the
    /// wider of the two, so the same width now holds about fifty characters
    /// rather than sixty — still more than a lyric line asks for, and still
    /// visibly narrower than the script.
    private var measure: CGFloat { 520 * scale }

    /// The OS text-size setting as a multiplier, so the reader honours Dynamic
    /// Type while keeping its own proportions — exactly as `ReadScriptView`
    /// folds the two together.
    @ScaledMetric(relativeTo: .body) private var dynamicTypeScale: CGFloat = 1

    private var scale: CGFloat { CGFloat(textScale) * dynamicTypeScale }

    /// The lyric's type size: what it is written at, scaled. Reading a song is
    /// meant to re-set the words, not enlarge them.
    private var fontSize: CGFloat { ProseFont.baseSize * scale }

    /// The song's own face, which is the screenplay's — see `ProseFont`.
    ///
    /// The chosen default rather than the shipped one: a lyric has no font of
    /// its own to override it with, so the Default Font setting simply is the
    /// face a song is written and read in, and a script reset to Times brings
    /// its songs with it. Read here, in a property the body reaches, rather
    /// than stored — that is what registers the observation.
    private var face: String { PresentationSettings.shared.defaultFont.postScriptName }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24 * scale) {
                Text(title.isEmpty ? "Untitled Song" : title)
                    .font(SongTitleType.font(scale: scale))
                    .fontWeight(.bold)
                    .accessibilityAddTraits(.isHeader)

                ForEach(Array(stanzas.enumerated()), id: \.offset) { _, stanza in
                    VStack(alignment: .leading, spacing: 3 * scale) {
                        ForEach(Array(stanza.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.custom(face, fixedSize: fontSize))
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
