//
//  Offline print PDF checks
//
//  The offline fallback prints whatever ScreenplayPDF draws, with no server
//  copy to compare against — so the drawing arithmetic is pinned here instead.
//  Three things carry the feature: the wrap now yields the very lines the
//  paginator counted (one wrap, shared), the display-text rules match the
//  sheet view's, and the renderer puts the right number of right-sized pages
//  into the file. The last is read back through CGPDFDocument, which is as
//  close to the printer's view of the file as a headless check can get.
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

func makeBlock(_ id: Int, _ type: String, _ content: String,
               extra: String = "") -> Block {
    let encoded = String(
        data: try! JSONSerialization.data(withJSONObject: [content], options: .fragmentsAllowed),
        encoding: .utf8)!.dropFirst().dropLast()
    let json = #"{"id":\#(id),"order":\#(id),"type":"\#(type)","content":\#(encoded)\#(extra)}"#
    return try! JSONDecoder().decode(Block.self, from: Data(json.utf8))
}

func makeProject(_ fields: String) -> Project {
    try! JSONDecoder().decode(Project.self, from: Data("{\"id\":1,\(fields)}".utf8))
}

func pdfDocument(_ data: Data) -> CGPDFDocument? {
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    return CGPDFDocument(provider)
}

// MARK: - The wrap yields the lines the count charges

print("Wrapped lines")
check("simple wrap",
      ScriptPagination.wrappedLines("one two three", columns: 9),
      ["one two", "three"])
check("exact fit keeps the line whole",
      ScriptPagination.wrappedLines("abcd efgh", columns: 9),
      ["abcd efgh"])
check("empty text still occupies its line",
      ScriptPagination.wrappedLines("", columns: 10), [""])
check("hard newlines start their own lines",
      ScriptPagination.wrappedLines("a\n\nb", columns: 10),
      ["a", "", "b"])
check("oversized word breaks at the column",
      ScriptPagination.wrappedLines("abcdefghijkl", columns: 5),
      ["abcde", "fghij", "kl"])
check("oversized word flushes what came before",
      ScriptPagination.wrappedLines("hi abcdefg", columns: 5),
      ["hi", "abcde", "fg"])
check("zero columns hands the text back",
      ScriptPagination.wrappedLines("anything", columns: 0), ["anything"])

// The count is the lines' count, by construction — pin a few anyway so a
// future divergence between the two names cannot pass unnoticed.
for (text, columns) in [("one two three", 9), ("", 10), ("a\n\nb", 10),
                        ("abcdefghijkl", 5), ("hi abcdefg", 5),
                        ("the quick brown fox jumps over the lazy dog", 12)] {
    check("count matches lines for \(String(reflecting: text)) @\(columns)",
          ScriptPagination.wrappedLineCount(text, columns: columns),
          ScriptPagination.wrappedLines(text, columns: columns).count)
}

// MARK: - What a row prints as

print("\nDisplay text")
let upper: (String, BlockType) -> String = { text, _ in text.uppercased() }
check("cased types pass through the hook",
      ScreenplayPDF.displayText(for: makeBlock(1, "SCENE", "int. barn - day"), cased: upper),
      "INT. BARN - DAY")
check("action skips the hook",
      ScreenplayPDF.displayText(for: makeBlock(2, "ACTION", "He waits."), cased: upper),
      "He waits.")
check("parenthetical grows its parentheses",
      ScreenplayPDF.displayText(for: makeBlock(3, "PARENTHETICAL", "beat"), cased: upper),
      "(beat)")
check("parenthetical keeps existing parentheses",
      ScreenplayPDF.displayText(for: makeBlock(4, "PARENTHETICAL", "(beat)"), cased: upper),
      "(beat)")
check("empty cue falls back to the linked character",
      ScreenplayPDF.displayText(
          for: makeBlock(5, "CHARACTER", "", extra: #","personName":"Ada""#),
          cased: { text, _ in text }),
      "Ada")

// MARK: - Pages in the file

print("\nRendered PDF")
let blocks: [Block] = [
    makeBlock(1, "SCENE", "INT. BARN - DAY"),
    makeBlock(2, "ACTION", String(repeating: "A horse walks past the window. ", count: 40)),
    makeBlock(3, "CHARACTER", "ADA"),
    makeBlock(4, "DIALOGUE", String(repeating: "We should talk about the horse. ", count: 30)),
    makeBlock(5, "ACTION", String(repeating: "More barn business. ", count: 60)),
]
let setup = PageSetup.default
let pages = ScriptPagination.paginate(blocks: blocks, setup: setup)
check("fixture spans several pages", pages.count > 1, true)

let bare = ScreenplayPDF.render(pages: pages, cover: nil, setup: setup)
if let document = pdfDocument(bare) {
    check("one PDF page per script page", document.numberOfPages, pages.count)
    if let first = document.page(at: 1) {
        let box = first.getBoxRect(.mediaBox)
        check("letter sheet is 612pt wide", Int(box.width.rounded()), 612)
        check("letter sheet is 792pt tall", Int(box.height.rounded()), 792)
    } else {
        failures += 1; print("  FAIL  letter first page unreadable")
    }
} else {
    failures += 1; print("  FAIL  rendered data is not a PDF")
}

let covered = makeProject(#""title":"Barn Play","writers":"A. Lovelace","contactInfo":"ada@example.com""#)
if let cover = ScreenplayCover(project: covered) {
    check("cover title is capitalised", cover.title, "BARN PLAY")
    let withCover = ScreenplayPDF.render(pages: pages, cover: cover, setup: setup,
                                         title: "Barn Play")
    check("cover adds one unnumbered sheet",
          pdfDocument(withCover)?.numberOfPages ?? -1, pages.count + 1)
} else {
    failures += 1; print("  FAIL  titled project produced no cover")
}

check("untitled project has no cover sheet",
      ScreenplayCover(project: makeProject(#""title":null"#)) == nil, true)

var a4 = PageSetup.default
a4.paper = .a4
let a4Pages = ScriptPagination.paginate(blocks: blocks, setup: a4)
if let document = pdfDocument(ScreenplayPDF.render(pages: a4Pages, cover: nil, setup: a4)),
   let first = document.page(at: 1) {
    let box = first.getBoxRect(.mediaBox)
    check("a4 sheet is 595pt wide", Int(box.width.rounded()), 595)
    check("a4 sheet is 842pt tall", Int(box.height.rounded()), 842)
} else {
    failures += 1; print("  FAIL  a4 render unreadable")
}

let coverOnly = ScreenplayPDF.render(pages: [], cover: ScreenplayCover(project: covered),
                                     setup: setup)
check("a cover alone still makes a one-page file",
      pdfDocument(coverOnly)?.numberOfPages ?? -1, 1)

print()
if failures == 0 {
    print("All offline print checks passed.")
    exit(0)
} else {
    print("\(failures) offline print check(s) FAILED.")
    exit(1)
}
