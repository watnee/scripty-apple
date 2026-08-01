//
//  ScriptPagination / PageSetup checks
//
//  Pagination is the one piece of the presentation work with real arithmetic
//  behind it, and the numbers are load-bearing: a page is 54 lines because
//  Courier at 12pt is ten characters to the inch over a nine-inch column. These
//  fixtures pin that down, along with the atom-binding and (MORE)/(CONT'D)
//  rules ported from the web app's page-view-mode.js.
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

func makeBlock(_ id: Int, _ type: String, _ content: String) -> Block {
    let encoded = String(
        data: try! JSONSerialization.data(withJSONObject: [content], options: .fragmentsAllowed),
        encoding: .utf8)!.dropFirst().dropLast()
    let json = #"{"id":\#(id),"order":\#(id),"type":"\#(type)","content":\#(encoded)}"#
    return try! JSONDecoder().decode(Block.self, from: Data(json.utf8))
}

// MARK: - Geometry

print("ScreenplayLayout")
check("action column", ScreenplayLayout.actionBox.textWidthIn, 6.0)
check("action columns of text", ScreenplayLayout.actionBox.columns, 60)
check("dialogue columns", ScreenplayLayout.dialogueBox.columns, 35)
check("parenthetical columns", ScreenplayLayout.parentheticalBox.columns, 20)
// 2.2in indent leaves 3.8in to the right margin.
check("character columns", ScreenplayLayout.characterBox.columns, 38)
// The CSS percentages are these inches over the six-inch column.
check("character indent fraction",
      (ScreenplayLayout.characterBox.indentFraction * 1000).rounded(), 367.0)
check("dialogue width fraction",
      (ScreenplayLayout.dialogueBox.widthFraction * 1000).rounded(), 583.0)

// The rule the writing column and the reading surface both space their
// elements by. They used to space themselves — the column by a hand-picked
// number of points per element type, the reader by these line units — so the
// script changed shape on the way between them. One rule now, in points, at
// whatever size the surface happens to be set at.
check("a scene heading gets two blank lines",
      ScreenplayLayout.spacing(for: .scene, lineHeight: 16), 32.0)
check("an action line gets one",
      ScreenplayLayout.spacing(for: .action, lineHeight: 16), 16.0)
check("dialogue hugs the cue above it",
      ScreenplayLayout.spacing(for: .dialogue, lineHeight: 16), 0.0)
check("and so does a parenthetical",
      ScreenplayLayout.spacing(for: .parenthetical, lineHeight: 16), 0.0)
// A bigger type size is a taller line, and the air scales with it.
check("the air scales with the type",
      ScreenplayLayout.spacing(for: .scene, lineHeight: 24), 48.0)

print("\nPageSetup")
check("letter/standard lines per page", PageSetup.default.linesPerPage, 54)
check("letter/standard text column", PageSetup.default.textWidthIn, 6.0)
var narrow = PageSetup.default
narrow.margins = .narrow
check("narrow text column", narrow.textWidthIn, 7.0)
check("narrow lines per page", narrow.linesPerPage, 60)

// MARK: - Wrapping

print("\nLine wrapping")
check("empty element still occupies a line",
      ScriptPagination.wrappedLineCount("", columns: 60), 1)
check("short line", ScriptPagination.wrappedLineCount("A quiet room.", columns: 60), 1)
// Words of five characters, so the arithmetic is checkable by hand: n words
// occupy 6n−1 columns.
func words(_ count: Int) -> String {
    Array(repeating: "aaaaa", count: count).joined(separator: " ")
}
// 12 words = 71 columns: ten fit on the first line of a 60-column action
// element, the rest fall to a second.
check("wraps at the column", ScriptPagination.wrappedLineCount(words(12), columns: 60), 2)
check("the last word that fits is kept",
      ScriptPagination.wrappedLineCount(words(10), columns: 60), 1)
check("hard newlines start a line",
      ScriptPagination.wrappedLineCount("one\ntwo\nthree", columns: 60), 3)
check("an over-long word is broken",
      ScriptPagination.wrappedLineCount(String(repeating: "x", count: 125), columns: 60), 3)
// The same 24 words take three lines in the action column but four in the
// narrower dialogue column — which is why speech paginates differently.
check("action column", ScriptPagination.wrappedLineCount(words(24), columns: 60), 3)
check("dialogue column wraps sooner",
      ScriptPagination.wrappedLineCount(words(24), columns: 35), 4)

// MARK: - Atom binding

print("\nAtom binding")

var id = 0
func push(_ list: inout [Block], _ type: String, _ content: String) {
    id += 1
    list.append(makeBlock(id, type, content))
}

/// Guards a fixture that is expected to span pages, so a mis-sized fixture
/// reports a failure instead of trapping on a missing index.
func requirePages(_ label: String, _ pages: [ScriptPage], _ expected: Int) -> Bool {
    check("\(label) paginates to \(expected) pages", pages.count, expected)
    return pages.count == expected
}

// A scene heading that would land at the foot of a page drags a line of action
// with it rather than being orphaned.
//
// Budget: N single-line ACTION elements cost 2N−1 lines, since only the first
// sheds its leading blank. 26 of them fill 51 of the 54, leaving too little for
// the 5-line SCENE+ACTION atom.
var orphan: [Block] = []
for _ in 0..<26 { push(&orphan, "ACTION", "Filler.") }
push(&orphan, "SCENE", "INT. LATE ARRIVAL - NIGHT")
push(&orphan, "ACTION", "Someone closes the door.")

let orphanPages = ScriptPagination.paginate(blocks: orphan)
if requirePages("orphan fixture", orphanPages, 2) {
    // The heading must not be the last row of page one.
    check("scene heading is not orphaned at the page foot",
          orphanPages[0].rows.last?.block?.blockType == .scene, false)
    // Heading and its action landed together.
    let pageTwoTypes = orphanPages[1].rows.compactMap { $0.block?.blockType }
    check("heading and body moved together",
          pageTwoTypes.prefix(2).map(\.rawValue).joined(separator: ","),
          "SCENE,ACTION")
}

// MARK: - MORE / CONT'D

print("\nSpeech continuation")

/// A speech long enough to straddle a page: 25 filler actions take 49 lines,
/// the cue plus its first two-line dialogue takes 4 more, and the second
/// dialogue then no longer fits under the (MORE) reserve.
func speechFixture(cue: String) -> [Block] {
    var blocks: [Block] = []
    for _ in 0..<25 { push(&blocks, "ACTION", "Filler.") }
    push(&blocks, "CHARACTER", cue)
    push(&blocks, "DIALOGUE", "The first thing you learn is that nobody is coming to help.")
    push(&blocks, "DIALOGUE", "The second thing you learn is that this is fine.")
    push(&blocks, "DIALOGUE", "The third thing takes longer.")
    return blocks
}

id = 0
let speechPages = ScriptPagination.paginate(blocks: speechFixture(cue: "MAYA"))
if requirePages("speech fixture", speechPages, 2) {
    check("page one closes with (MORE)",
          speechPages[0].rows.last?.kind == .more, true)
    check("page two opens with the speaker continued",
          speechPages[1].rows.first?.kind == .continued(speaker: "MAYA"), true)
}

// A speaker who already carries (CONT'D) does not gain a second one.
id = 0
let contdPages = ScriptPagination.paginate(blocks: speechFixture(cue: "DEV (CONT'D)"))
if requirePages("continued-cue fixture", contdPages, 2) {
    check("an existing (CONT'D) is not doubled",
          contdPages[1].rows.first?.kind == .continued(speaker: "DEV"), true)
}

// MARK: - Forced breaks

print("\nForced page breaks")

var forced: [Block] = []
id = 0
push(&forced, "ACTION", "Before the break.")
push(&forced, "PAGE_BREAK", "")
push(&forced, "ACTION", "After the break.")

let forcedPages = ScriptPagination.paginate(blocks: forced)
check("a page break splits the script", forcedPages.count, 2)
check("the break marker draws nothing itself",
      forcedPages[0].rows.count, 1)
check("page numbers are sequential",
      forcedPages.map(\.number), [1, 2])

// An empty script paginates to nothing rather than one blank sheet.
check("an empty script has no pages", ScriptPagination.paginate(blocks: []).count, 0)

// MARK: - Non-printing elements

print("\nNon-printing elements")

// Sections, synopses and notes are working marks. They must be dropped before
// measuring, or the page reserves lines for something it never draws.
var annotated: [Block] = []
id = 0
push(&annotated, "SECTION", "Act One")
push(&annotated, "SYNOPSIS", "Maya loses the light.")
push(&annotated, "NOTE", "Check this against the shot list.")
push(&annotated, "ACTION", "A quiet room.")

let annotatedPages = ScriptPagination.paginate(blocks: annotated)
check("annotations do not reach the page", annotatedPages.first?.rows.count ?? -1, 1)
check("only the action survives",
      annotatedPages.first?.rows.first?.block?.blockType.rawValue ?? "none", "ACTION")
check("and it opens the page with no leading blank",
      annotatedPages.first?.rows.first?.spacing ?? -1, 0)
check("a script of nothing but annotations has no pages",
      ScriptPagination.paginate(blocks: Array(annotated.prefix(3))).count, 0)

// MARK: - Finding a place on paper
//
// The remembered reading position is an element id in both surfaces, so moving
// it between the column and the paper is a lookup in each direction. Getting it
// wrong sends the writer back to page one, which is exactly what remembering a
// position is meant to stop.

print("\nFinding a place on paper")

// `forced` is ids 1 (action), 2 (page break), 3 (action) over two sheets.
check("an element is found on the sheet it prints on",
      ScriptPagination.page(containing: 1, in: forcedPages) ?? -1, 1)
check("and on the sheet after a forced break",
      ScriptPagination.page(containing: 3, in: forcedPages) ?? -1, 2)
check("an element the script never had is on no page",
      ScriptPagination.page(containing: 99, in: forcedPages) == nil, true)
// `annotated` is 1 (section), 2 (synopsis), 3 (note), 4 (action): the working
// marks are dropped before measuring, so a position remembered on one of them
// has no sheet to open and the pager is left alone.
check("an element that never prints is on no page",
      ScriptPagination.page(containing: 3, in: annotatedPages) == nil, true)

check("a sheet gives back the element it opens with",
      ScriptPagination.firstBlockId(onPage: 2, in: forcedPages) ?? -1, 3)
check("a sheet the script does not have gives back nothing",
      ScriptPagination.firstBlockId(onPage: 9, in: forcedPages) == nil, true)
// A sheet that opens on a (CONT'D) marker still names the first real element
// on it, since a marker is not somewhere a writer can be.
if speechPages.count == 2 {
    check("a continued sheet skips its marker",
          ScriptPagination.firstBlockId(onPage: 2, in: speechPages)
              == speechPages[1].rows.compactMap(\.block).first?.id, true)
    check("and that is an element, not the marker",
          speechPages[1].rows.first?.block == nil, true)
}

// MARK: - Export query
//
// A paged export has to carry the writer's own paper and margins, or the PDF
// comes back paginated to the server's defaults and stops matching the page
// view it was exported from. The client never builds the URL itself, so what
// is pinned here is that the setup survives being folded into the advertised
// link — including the case where the link already carries query parameters.

print("")
print("Export query")

var exported = PageSetup.default
exported.paper = .a4
exported.margins = .narrow

check("paper and margins are both carried", exported.exportQuery.count, 2)
check("paper is named as the server spells it", exported.exportQuery["paper"] ?? "", "a4")
check("margins likewise", exported.exportQuery["margins"] ?? "", "narrow")

let bare = HALLink(href: "https://example.test/api/project/7/export/pdf")
check("the setup is appended to a bare link",
      bare.addingQuery(exported.exportQuery).href,
      "https://example.test/api/project/7/export/pdf?margins=narrow&paper=a4")

// The server advertises the edition on the export link, so decorating it must
// add to that query rather than replace it — otherwise exporting from inside
// an edition would silently export the default one.
let editioned = HALLink(href: "https://example.test/api/project/7/export/pdf?editionId=3")
check("an existing parameter is kept",
      editioned.addingQuery(exported.exportQuery).href,
      "https://example.test/api/project/7/export/pdf?editionId=3&margins=narrow&paper=a4")

check("re-exporting replaces rather than repeats",
      editioned.addingQuery(exported.exportQuery).addingQuery(PageSetup.default.exportQuery).href,
      "https://example.test/api/project/7/export/pdf?editionId=3&margins=standard&paper=letter")

print("")
if failures == 0 {
    print("Pagination checks passed.")
    exit(0)
} else {
    print("\(failures) pagination check(s) FAILED.")
    exit(1)
}
