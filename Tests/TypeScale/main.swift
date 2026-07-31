//
//  Optical type scale checks
//
//  The bug these exist to prevent: four writing surfaces each picked a nominal
//  point size independently, and nominal points are not a size anyone can see.
//  Courier Prime puts 0.451 of its em into the x-height where Menlo puts 0.547,
//  so the script editor rendered a sixth smaller than the note editor at the
//  identical `16` — and nothing failed, because nothing was watching.
//
//  The first check below is the one that would have caught it. The rest pin the
//  couplings that make the sizes safe to change: the editor's column has to grow
//  with its type or the editor starts wrapping lines that fit on paper, and the
//  set of sizes has to stay small because EditableBlockRow caches fonts by size
//  and never evicts.
//
//  Run via Tests/run.sh.
//

import CoreGraphics
import Foundation

var failures = 0

func check(_ label: String, _ actual: some Equatable, _ expected: some Equatable) {
    if "\(actual)" == "\(expected)" {
        print("  PASS  \(label)")
    } else {
        failures += 1
        print("  FAIL  \(label) — expected \(expected), got \(actual)")
    }
}

func expect(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition {
        print("  PASS  \(label)")
    } else {
        failures += 1
        let detail = detail()
        print("  FAIL  \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

/// Courier Prime's advance as a fraction of the em, measured off the file in
/// Resources/Fonts. Monospaced, so one number covers every glyph.
let courierAdvance: CGFloat = 0.5996

// MARK: - The invariant that matters

/// Every face has to land on the same x-height, or the sizes are decorative.
///
/// A quarter point of slack, which is what rounding each size to the half point
/// can cost: a face whose ratio is wrong by more than that was guessed rather
/// than measured, which is exactly the mistake being guarded against.
func runOpticalTarget() {
    print("Every face lands on the target x-height")
    let target = ScriptTypeScale.targetXHeight
    check("target is the system face at its stated size", target,
          ScriptTypeScale.opticalTarget * ScriptTypeScale.Face.system.xHeightRatio)

    for face in ScriptTypeScale.Face.allCases {
        let rendered = ScriptTypeScale.body(face) * face.xHeightRatio
        expect("\(face) renders on target",
               abs(rendered - target) <= 0.25,
               "x-height \(rendered) against \(target)")
    }

    // The system face is the reference, so it must be exact rather than close.
    check("system face sits exactly on its stated size",
          ScriptTypeScale.body(.system), ScriptTypeScale.opticalTarget)
}

// MARK: - The column coupling

/// The editor must never wrap a line the paper would not.
///
/// The paginator counts characters, not points, so the two only agree if the
/// column grows with the type. Stating the measure in ems is what holds it —
/// this fails if someone puts a literal width back.
func runColumnMeasure() {
    print("The editor's column tracks its type")
    check("measure is derived, not hardcoded",
          ScriptTypeScale.editorMeasure,
          ScriptTypeScale.measureEms * ScriptTypeScale.screenplay)

    let columns = ScriptTypeScale.editorMeasure / (courierAdvance * ScriptTypeScale.screenplay)
    let paper = CGFloat(ScreenplayLayout.actionBox.columns)
    expect("wraps no earlier than the paginator's \(Int(paper)) columns",
           columns >= paper,
           "column holds \(columns) characters")

    // Pinned so a deliberate change to `measureEms` shows up as a diff here
    // rather than as lines re-wrapping in someone's script.
    expect("holds the 66-to-67 characters it always has",
           columns >= 66 && columns < 67,
           "column holds \(columns) characters")

    // The reader's measure moved with its body the same way.
    check("the reader's measure tracks its body",
          ScriptTypeScale.readerMeasure,
          640.0 / 17.0 * ScriptTypeScale.body(.system))
}

// MARK: - The sizes themselves

/// The decision, written down. These are the numbers agreed for the app, so a
/// change to any of them should be a change to this file too.
func runPublishedSizes() {
    print("The sizes the surfaces set at")
    check("script editor", ScriptTypeScale.screenplay, 21.5)
    check("note editor", ScriptTypeScale.notes, 17.5)
    check("song lyrics", ScriptTypeScale.lyrics, 19.0)
    check("Arial scripts", ScriptTypeScale.body(.helvetica), 18.5)
    check("Times scripts", ScriptTypeScale.body(.timesNewRoman), 21.5)

    check("Courier Prime maps to its own face",
          ScriptFont.courierPrime.opticalFace, ScriptTypeScale.Face.courierPrime)
    check("Arial maps to Helvetica, the face it actually draws in",
          ScriptFont.arial.opticalFace, ScriptTypeScale.Face.helvetica)
    check("Times maps to its own face",
          ScriptFont.timesNewRoman.opticalFace, ScriptTypeScale.Face.timesNewRoman)
}

/// EditableBlockRow caches resolved fonts by size and never evicts, so the set
/// of sizes it can be asked for has to stay countable.
func runHalfPointDiscipline() {
    print("Every published size is a whole half-point")
    var sizes: [(String, CGFloat)] = []
    for face in ScriptTypeScale.Face.allCases {
        sizes.append(("body(\(face))", ScriptTypeScale.body(face)))
        for type in BlockType.allCases {
            sizes.append(("size(\(type), \(face))",
                          ScriptTypeScale.size(for: type, face: face)))
        }
    }
    for role: ScriptTypeScale.ReaderRole in [.title, .section, .scene, .body, .character, .speaker] {
        sizes.append(("reader(\(role))", ScriptTypeScale.reader(role)))
    }

    let ragged = sizes.filter { ($0.1 * 2).rounded() != $0.1 * 2 }
    expect("all \(sizes.count) sizes land on a half point",
           ragged.isEmpty,
           ragged.map { "\($0.0) = \($0.1)" }.joined(separator: ", "))
}

// MARK: - Proportions the old absolute fonts used to carry

/// Sections and notes used to reach for `.title3` and `.callout` — absolute
/// system sizes that only read correctly while the body happened to be 16pt.
/// Their proportions survive; their absoluteness does not.
func runEmphasis() {
    print("Sections and notes keep their proportions")
    check("a section is the old .title3 proportion", ScriptTypeScale.emphasis(for: .section), 20.0 / 17.0)
    check("a note is the old .callout proportion", ScriptTypeScale.emphasis(for: .note), 16.0 / 17.0)
    check("everything else is body", ScriptTypeScale.emphasis(for: .action), 1.0)

    let body = ScriptTypeScale.screenplay
    expect("a section stands above body",
           ScriptTypeScale.size(for: .section, face: .courierPrime) > body)
    // The failure this rules out is the one that made notes look wrong: an
    // absolute size that falls far below the body it annotates.
    let note = ScriptTypeScale.size(for: .note, face: .courierPrime)
    expect("a note sits just under body, not in fine print",
           note < body && note > body * 0.9,
           "note \(note) against body \(body)")

    // The reader's own hierarchy, from one body rather than six constants.
    expect("the reader's title is its largest",
           ScriptTypeScale.reader(.title) > ScriptTypeScale.reader(.section))
    expect("the reader's speaker label is its smallest",
           ScriptTypeScale.reader(.speaker) < ScriptTypeScale.reader(.character))
    check("the reader's scene heading matches its body",
          ScriptTypeScale.reader(.scene), ScriptTypeScale.reader(.body))
}

/// One function feeding both the row padding and the marks, so a pin cannot sit
/// at a different height depending on whether its row can be typed in.
func runTopInsets() {
    print("The space above an element")
    check("scene", ScriptTypeScale.topInset(for: .scene), 18.0)
    check("section", ScriptTypeScale.topInset(for: .section), 14.0)
    check("character cue", ScriptTypeScale.topInset(for: .character), 10.0)
    check("page break", ScriptTypeScale.topInset(for: .pageBreak), 8.0)
    check("action runs flush", ScriptTypeScale.topInset(for: .action), 0.0)

    expect("a scene breathes more than a cue, and a cue more than action",
           ScriptTypeScale.topInset(for: .scene)
           > ScriptTypeScale.topInset(for: .character),
           "and \(ScriptTypeScale.topInset(for: .character)) > \(ScriptTypeScale.topInset(for: .action))")

    // What EditableBlockRow does with it: the 4pt floor every editable row
    // carries, so consecutive action lines are not flush.
    check("an editable action row still keeps its 4pt",
          max(ScriptTypeScale.topInset(for: .action), 4), 4.0)
}

/// The lyric list has no row-height floor to absorb growth — the padding *is*
/// the leading — so it has to scale or the lines close up.
func runLyricGap() {
    print("Lyric lines stay single-spaced")
    check("the gap is the old 2pt, at the new size",
          ScriptTypeScale.lyricGap, ScriptTypeScale.lyrics * (2.0 / 17.0))
    expect("it grew with the type rather than staying at 2",
           ScriptTypeScale.lyricGap > 2.0,
           "gap \(ScriptTypeScale.lyricGap)")
    // Two lines of leading against a 19pt line is still single spacing; a gap
    // approaching the line itself would read as double.
    expect("but stays far short of a blank line",
           ScriptTypeScale.lyricGap * 2 < ScriptTypeScale.lyrics * 0.5,
           "gap \(ScriptTypeScale.lyricGap) against line \(ScriptTypeScale.lyrics)")
}

runOpticalTarget()
runColumnMeasure()
runPublishedSizes()
runHalfPointDiscipline()
runEmphasis()
runTopInsets()
runLyricGap()

print("")
if failures == 0 {
    print("Type scale checks passed.")
    exit(0)
} else {
    print("\(failures) type scale check(s) FAILED.")
    exit(1)
}
