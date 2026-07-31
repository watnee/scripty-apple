//
//  ScriptTypeScale.swift
//  scripty
//
//  How big the writing surfaces set their type.
//
//  Deliberately separate from `ScriptTypeface.swift`, which is about *page*
//  fidelity — `naturalLeading` and `ScreenplayFont.sheet` exist so a rendered
//  line fills exactly one line of paper. Nothing here touches paper. Page view,
//  the paginator and PDF export are measured in inches and must not read from
//  this file.
//
//  The bug this replaces: four surfaces each picked a nominal point size on
//  their own — 16 for the script editor, 16 for the note editor, 17 for lyric
//  lines, 17 for the reader — and nominal points are not a size anyone can see.
//  Courier Prime puts 0.451 of its em into the x-height where SF puts 0.508 and
//  Menlo 0.547, so the script editor rendered a sixth smaller than the note
//  editor at the identical `16`. Screenplays are heavy on capitals, where the
//  gap is wider still (0.580 em against SF's 0.705).
//
//  So the size is stated once, optically, and each face is asked for whatever
//  point size lands on it.
//

import CoreGraphics

enum ScriptTypeScale {
    /// The size everything is meant to read at, given as the system face's
    /// point size because that is the one people have a feel for.
    ///
    /// This is the number to change to make the app's writing surfaces bigger
    /// or smaller as a whole. The type-size preference
    /// (`PresentationSettings.textSize`, 80–200%) multiplies whatever this
    /// resolves to, and 100% still means 100%.
    ///
    /// Worth writing down, because the two are easily confused: the *screenplay*
    /// opts out of Dynamic Type (`fixedSize:` in `BlockRowView.baseFont`)
    /// because its type is tied to a column measured in characters, and letting
    /// the system grow one without the other changes where lines wrap. Prose
    /// surfaces — the note editor, the reader — have no such tie and do compose
    /// Dynamic Type on top. That split is intentional. What was not intentional
    /// was the four surfaces disagreeing about what `16` meant.
    static let opticalTarget: CGFloat = 19

    /// The x-height every face is sized to hit, in points.
    static var targetXHeight: CGFloat { opticalTarget * Face.system.xHeightRatio }

    /// The faces the app sets text in. More than `ScriptFont` has, because the
    /// note editor draws in the system monospace and lyric lines in the system
    /// proportional face — neither is a screenplay font, but both need sizing
    /// against the same target.
    enum Face: CaseIterable {
        case courierPrime
        case helvetica
        case timesNewRoman
        case system
        case systemMono

        /// x-height as a fraction of the em, measured off the shipping fonts
        /// with `CTFontGetXHeight(font) / CTFontGetSize(font)`.
        ///
        /// Measured rather than looked up: the point of the table is that these
        /// are facts about the files in `Resources/Fonts` and on the device, and
        /// a face added without measuring it is the original bug returning. The
        /// test suite asserts every case lands on `targetXHeight`, so a guessed
        /// number fails there rather than in someone's eyes six months later.
        var xHeightRatio: CGFloat {
            switch self {
            case .courierPrime: return 0.451
            case .helvetica: return 0.523
            case .timesNewRoman: return 0.447
            case .system: return 0.508
            case .systemMono: return 0.547
            }
        }
    }

    /// Body type for a face, in points.
    ///
    /// Rounded to the half point. `EditableBlockRow` caches resolved `UIFont`s
    /// by `(family, size, traits)` and never evicts, so the set of sizes it can
    /// be asked for has to stay small: five faces times three emphases times the
    /// preference's thirteen steps, and no more.
    static func body(_ face: Face) -> CGFloat {
        halfPoint(targetXHeight / face.xHeightRatio)
    }

    /// The screenplay editor's face at its default, 21.5pt Courier Prime.
    static var screenplay: CGFloat { body(.courierPrime) }
    /// The note and lyric-prose editor, 17.5pt in the system monospace.
    static var notes: CGFloat { body(.systemMono) }
    /// One lyric line in the song editor, 19pt in the system face.
    static var lyrics: CGFloat { body(.system) }

    /// How much larger or smaller an element sets than the body around it.
    ///
    /// Sections and notes used to reach for `.title3` and `.callout`, which are
    /// absolute system sizes: at a 16pt body they happened to read as a heading
    /// and as body, and at anything else they did not. Kept as the proportions
    /// those two used to work out to, against the 17pt system body they were
    /// measured against.
    static func emphasis(for type: BlockType) -> CGFloat {
        switch type {
        case .section: return 20.0 / 17.0
        case .note: return 16.0 / 17.0
        default: return 1
        }
    }

    /// What one element of a script sets at, in points, before the writer's
    /// type-size preference is applied.
    static func size(for type: BlockType, face: Face) -> CGFloat {
        halfPoint(body(face) * emphasis(for: type))
    }

    /// The space an element leaves above its first line.
    ///
    /// One function because two copies of these numbers drifted: the editable
    /// row scaled them with the type and the read-only row did not, and the
    /// marks hung off a third copy again, so a pin sat at a different height
    /// depending on whether the row could be typed in.
    static func topInset(for type: BlockType) -> CGFloat {
        switch type {
        case .scene: return 18
        case .section: return 14
        case .character, .dualDialogue, .transition, .shot: return 10
        case .pageBreak: return 8
        default: return 0
        }
    }

    // MARK: - The editor's column

    /// The text column, in ems of the script face.
    ///
    /// Stated in ems because the column and the type have to move together: at
    /// Courier Prime's 0.5996 advance this is a little under 67 characters,
    /// comfortably past the 60 columns `ScreenplayLayout.actionBox` wraps action
    /// at. That direction is the one that matters — the editor must never wrap a
    /// line the paper would not. Fixing it *to* 60 would narrow the column from
    /// what it is today, which is a separate decision.
    static let measureEms: CGFloat = 40

    /// The text column at its full size, in points.
    static var editorMeasure: CGFloat { measureEms * screenplay }

    // MARK: - Read Script mode

    /// Read Script mode's own scale. Its proportions are the point of it — a
    /// scene heading sits a shade above the prose, a speaker label below — so
    /// they are ratios of one body size rather than six independent constants,
    /// which is how they drifted apart the first time.
    ///
    /// The reader draws in `design: .serif` (New York) rather than SF, so it is
    /// not strictly on the target; New York is drawn close enough to SF's
    /// x-height that riding SF's ratio is right for now, and a measured
    /// `.readerSerif` face can be added later without moving anything else.
    enum ReaderRole {
        case title, section, scene, body, character, speaker

        /// Against the 17pt body the reader was built at.
        var ratio: CGFloat {
            switch self {
            case .title: return 28.0 / 17.0
            case .section: return 20.0 / 17.0
            case .scene, .body: return 1
            case .character: return 16.0 / 17.0
            case .speaker: return 15.0 / 17.0
            }
        }
    }

    static func reader(_ role: ReaderRole) -> CGFloat {
        halfPoint(body(.system) * role.ratio)
    }

    /// The reader's measure, which was 640pt against that same 17pt body.
    static var readerMeasure: CGFloat { 640.0 / 17.0 * body(.system) }

    // MARK: - Song lyrics

    /// The gap above and below a lyric line.
    ///
    /// Two points at a 17pt line is what made the list read as single-spaced,
    /// and the hosts drop `defaultMinListRowHeight` so there is no row floor to
    /// absorb growth — the padding *is* the leading. Scaled with the type, or
    /// the lines close up as it grows.
    static var lyricGap: CGFloat { lyrics * (2.0 / 17.0) }

    // MARK: -

    private static func halfPoint(_ value: CGFloat) -> CGFloat {
        (value * 2).rounded() / 2
    }
}

extension ScriptFont {
    /// The measured face this screenplay font draws in.
    var opticalFace: ScriptTypeScale.Face {
        switch self {
        case .courierPrime: return .courierPrime
        case .arial: return .helvetica
        case .timesNewRoman: return .timesNewRoman
        }
    }
}
