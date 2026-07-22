//
//  Note formatting checks
//
//  These rules are all caret arithmetic, which is exactly the kind of thing
//  that looks right on screen until the one case nobody tried. Return in the
//  middle of an item, Tab on a nested one, a numbered list that has had
//  something dropped into the middle of it — each is a place the caret can end
//  up a character out, or the numbering can go 1. 2. 2. 3.
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

/// Writes an edit as text with the caret drawn in, so a failure reads as the
/// document the writer would be looking at rather than as two numbers.
func rendered(_ edit: NoteEdit?) -> String {
    guard let edit else { return "<unchanged>" }
    let index = edit.text.index(edit.text.startIndex, offsetBy: edit.caret)
    return (edit.text[..<index] + "|" + edit.text[index...])
        .replacingOccurrences(of: "\n", with: "⏎")
}

/// The caret goes where the ⌶ is; everything else is the document.
func at(_ marked: String) -> (String, Int) {
    let caret = marked.distance(from: marked.startIndex,
                                to: marked.firstIndex(of: "⌶") ?? marked.startIndex)
    return (marked.replacingOccurrences(of: "⌶", with: ""), caret)
}

print("Return inside a list")
do {
    var (text, caret) = at("- milk⌶")
    check("carries the bullet down",
          rendered(NoteFormatting.newline(in: text, caret: caret)), "- milk⏎- |")

    (text, caret) = at("1. milk⌶")
    check("and counts the next number",
          rendered(NoteFormatting.newline(in: text, caret: caret)), "1. milk⏎2. |")

    // The only way out of a list without reaching for the mouse.
    (text, caret) = at("- milk\n- ⌶")
    check("an empty item leaves the list",
          rendered(NoteFormatting.newline(in: text, caret: caret)), "- milk⏎|")

    // Splitting an item mid-word behaves like splitting a paragraph.
    (text, caret) = at("- mi⌶lk")
    check("Return mid-item splits it",
          rendered(NoteFormatting.newline(in: text, caret: caret)), "- mi⏎- |lk")

    (text, caret) = at("just a line⌶")
    check("a plain line is left to the text view",
          rendered(NoteFormatting.newline(in: text, caret: caret)), "<unchanged>")
}

print("")
print("Tab")
do {
    // Inside a list Tab nests the whole item, wherever the caret sits in it.
    var (text, caret) = at("- mi⌶lk")
    check("nests a list item",
          rendered(NoteFormatting.indent(in: text, caret: caret, outdent: false)),
          "    - mi|lk")

    (text, caret) = at("plain⌶ line")
    check("and is otherwise just an indent",
          rendered(NoteFormatting.indent(in: text, caret: caret, outdent: false)),
          "plain    | line")

    (text, caret) = at("    - mil⌶k")
    check("Shift-Tab un-nests",
          rendered(NoteFormatting.indent(in: text, caret: caret, outdent: true)),
          "- mil|k")

    (text, caret) = at("- milk⌶")
    check("and does nothing at the left margin",
          rendered(NoteFormatting.indent(in: text, caret: caret, outdent: true)),
          "<unchanged>")
}

print("")
print("Toolbar prefixes")
do {
    var (text, caret) = at("mi⌶lk")
    check("a bullet goes on",
          rendered(NoteFormatting.toggleList(in: text, caret: caret, ordered: false)),
          "- milk|")

    (text, caret) = at("- mi⌶lk")
    check("and the same control takes it off",
          rendered(NoteFormatting.toggleList(in: text, caret: caret, ordered: false)),
          "milk|")

    // A line holds one prefix, so a new one replaces the old.
    (text, caret) = at("# Shop⌶ping")
    check("a bullet replaces a heading",
          rendered(NoteFormatting.toggleList(in: text, caret: caret, ordered: false)),
          "- Shopping|")

    (text, caret) = at("Shop⌶ping")
    check("headings go on",
          rendered(NoteFormatting.toggleHeading(in: text, caret: caret, level: 2)),
          "## Shopping|")

    (text, caret) = at("## Shop⌶ping")
    check("and come off",
          rendered(NoteFormatting.toggleHeading(in: text, caret: caret, level: 2)),
          "Shopping|")

    (text, caret) = at("## Shop⌶ping")
    check("a different level replaces rather than stacks",
          rendered(NoteFormatting.toggleHeading(in: text, caret: caret, level: 1)),
          "# Shopping|")
}

print("")
print("Renumbering")
do {
    // Return in the middle of a numbered list is the case that leaves
    // 1. 2. 2. 3. behind if nothing renumbers.
    let (text, caret) = at("1. milk⌶\n2. bread\n3. jam")
    check("inserting in the middle renumbers what follows",
          rendered(NoteFormatting.newline(in: text, caret: caret)),
          "1. milk⏎2. |⏎3. bread⏎4. jam")

    // A run restarts after anything that is not a list item.
    let broken = NoteEdit(text: "1. a\n\n5. b\n7. c", caret: 0)
    check("a gap starts the count again",
          NoteFormatting.renumbering(broken).text, "1. a\n\n1. b\n2. c")

    // Nesting counts separately, or a sub-list would carry on from its parent.
    let nested = NoteEdit(text: "1. a\n    3. x\n    9. y\n1. b", caret: 0)
    check("each level counts on its own",
          NoteFormatting.renumbering(nested).text, "1. a\n    1. x\n    2. y\n2. b")

    // Bullets are left exactly as they are.
    let mixed = NoteEdit(text: "- a\n- b", caret: 0)
    check("bullets are not numbered", NoteFormatting.renumbering(mixed).text, "- a\n- b")
}

print("")
if failures == 0 {
    print("Note formatting checks passed.")
    exit(0)
} else {
    print("\(failures) note formatting check(s) FAILED.")
    exit(1)
}
