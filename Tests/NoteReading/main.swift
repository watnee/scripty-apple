//
//  A note as the reader sees it
//
//  Read mode for a note sets its prefixes as what they mean — a heading as a
//  heading, a bullet as a bullet — while the note itself stays the plain text
//  it has always been. Two things are easy to get wrong there and both are
//  checked here: what each line *is* (the recogniser has to agree with the
//  typing rules next to it, or the reader would set as a paragraph the very
//  line Return had just carried a bullet onto), and how the lines group (a
//  blank line is a paragraph break, and a run of them is still one break —
//  the rule the song reader applies to a verse).
//
//  Run via Tests/run.sh.
//

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

func runLineKinds() {
    print("What a line is")

    check("a hash is a heading, without the hash",
          NoteFormatting.kind(of: "# Act One"),
          NoteFormatting.LineKind.heading(level: 1, text: "Act One"))
    check("and the level is how many there are",
          NoteFormatting.kind(of: "### Scene 4"),
          NoteFormatting.LineKind.heading(level: 3, text: "Scene 4"))
    // The typing rules require a space after the marker, so this is prose that
    // happens to start with a hash — a note about a hashtag, not a heading.
    check("a hash with no space after it is not a heading",
          NoteFormatting.kind(of: "#hashtag"),
          NoteFormatting.LineKind.plain(depth: 0, text: "#hashtag"))

    check("a dash is a bullet", NoteFormatting.kind(of: "- buy flowers"),
          NoteFormatting.LineKind.bullet(depth: 0, text: "buy flowers"))
    check("and so is a star", NoteFormatting.kind(of: "* buy flowers"),
          NoteFormatting.LineKind.bullet(depth: 0, text: "buy flowers"))
    check("a number is a numbered item",
          NoteFormatting.kind(of: "2. then the letter"),
          NoteFormatting.LineKind.numbered(depth: 0, number: 2, text: "then the letter"))

    // The indent unit is four spaces, which is what Tab inserts.
    check("four spaces nest an item one level",
          NoteFormatting.kind(of: "    - under it"),
          NoteFormatting.LineKind.bullet(depth: 1, text: "under it"))
    check("eight nest it two", NoteFormatting.kind(of: "        - deeper"),
          NoteFormatting.LineKind.bullet(depth: 2, text: "deeper"))
    check("a tab is one level too", NoteFormatting.kind(of: "\t- under it"),
          NoteFormatting.LineKind.bullet(depth: 1, text: "under it"))
    // Stray spaces short of a level must not promote the line: a reader that
    // rounded up would indent a paragraph the writer never indented.
    check("a part of a level rounds down",
          NoteFormatting.kind(of: "  - barely"),
          NoteFormatting.LineKind.bullet(depth: 0, text: "barely"))

    check("an ordinary line is plain", NoteFormatting.kind(of: "She never calls."),
          NoteFormatting.LineKind.plain(depth: 0, text: "She never calls."))
    check("an indented one keeps its depth, not its spaces",
          NoteFormatting.kind(of: "    an aside"),
          NoteFormatting.LineKind.plain(depth: 1, text: "an aside"))
    check("nothing but whitespace is blank", NoteFormatting.kind(of: "   "),
          NoteFormatting.LineKind.blank)
}

func runParagraphs() {
    print("")
    print("How the lines group")

    let note = """
    # Act One

    She never calls.
    He waits by the phone anyway.


    - flowers
        - the yellow ones
    2. the letter
    """
    let paragraphs = NoteReading.paragraphs(in: note)

    check("a blank line breaks the paragraph", paragraphs.count, 3)
    check("the heading stands on its own", paragraphs[0].count, 1)
    // The writer broke that line themselves; a reader that reflowed it would be
    // rewriting the note, which is the one thing this surface must never do.
    check("lines inside a paragraph are kept as typed", paragraphs[1].count, 2)
    check("and in order", paragraphs[1][1],
          NoteFormatting.LineKind.plain(depth: 0, text: "He waits by the phone anyway."))
    // Two blank lines are one break, the way they read on paper.
    check("a run of blanks is still one break", paragraphs[2].count, 3)
    check("a nested bullet keeps its level", paragraphs[2][1],
          NoteFormatting.LineKind.bullet(depth: 1, text: "the yellow ones"))

    // Return at the end of a list leaves "- " behind, waiting for the next
    // item. In the editor that is where the caret goes; in the reader it is a
    // dot with nothing beside it, so it is left out — without breaking the
    // list it sits in the middle of.
    let interrupted = "- flowers\n- \n- the letter"
    check("an empty item is left out", NoteReading.paragraphs(in: interrupted)[0].count, 2)
    check("and does not break the list", NoteReading.paragraphs(in: interrupted).count, 1)
    check("a paragraph of nothing but one is no paragraph",
          NoteReading.paragraphs(in: "- ").count, 0)

    check("an empty note has nothing to read", NoteReading.paragraphs(in: "").count, 0)
    check("and neither has one of blank lines",
          NoteReading.paragraphs(in: "\n \n\n").count, 0)

    // Windows line endings arrive from imported files and pasted text; the
    // reader must not turn a note into one very long paragraph over them.
    check("carriage returns break paragraphs too",
          NoteReading.paragraphs(in: "one\r\n\r\ntwo").count, 2)
}

runLineKinds()
runParagraphs()

print("")
if failures == 0 {
    print("All note reading checks passed.")
} else {
    print("\(failures) note reading check(s) FAILED.")
    exit(1)
}
