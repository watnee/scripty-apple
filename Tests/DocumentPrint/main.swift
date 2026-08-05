//
//  Offline song/note print PDF checks
//
//  The offline fallback prints whatever DocumentPDF draws, with no server copy
//  to compare against — so the layout arithmetic is pinned here instead, the
//  way Tests/Print pins the screenplay's.
//
//  Three things carry the feature: a document is split into lines the way the
//  server splits its own, a sheet holds the number of lines the server's
//  margins and leading leave room for, and a run too long for the column wraps
//  rather than running off the page. The page counts are read back through
//  CGPDFDocument as well as from `pageCount`, so the drawing and the count
//  cannot drift apart.
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

func pdfDocument(_ data: Data) -> CGPDFDocument? {
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    return CGPDFDocument(provider)
}

/// What both `render` and `pageCount` say about the same sections, which must
/// be the same thing.
func pages(_ sections: [DocumentPDF.Section]) -> (counted: Int, drawn: Int) {
    (DocumentPDF.pageCount(sections),
     pdfDocument(DocumentPDF.render(sections))?.numberOfPages ?? -1)
}

// MARK: - What a document is to the renderer

print("Lines")
check("text splits on newlines, keeping the blanks",
      DocumentPDF.Section(title: "Verse", text: "one\n\ntwo").lines,
      ["one", "", "two"])
check("a trailing newline is a trailing line",
      DocumentPDF.Section(title: "Verse", text: "one\n").lines,
      ["one", ""])
check("no newline at all is one line",
      DocumentPDF.Section(title: "Verse", text: "one").lines, ["one"])
check("a titled document with no words is still worth a sheet",
      DocumentPDF.Section(title: "Verse", text: "").isEmpty, false)
check("nothing but whitespace is not",
      DocumentPDF.Section(title: "  ", text: "\n \n").isEmpty, true)

// MARK: - Sheets

print("\nSheets")
// 792pt tall less two 1in margins is 648pt of column. The 16pt title takes a
// 24pt line and leaves a 12pt gap under it, so the first sheet has 612pt for
// 18pt body lines — 34 of them — and every sheet after it has the whole 648
// for 36.
let short = DocumentPDF.Section(title: "Short Song",
                                lines: (1...34).map { "Line \($0)" })
check("a document that just fits is one sheet", pages([short]).counted, 1)
check("and the file agrees", pages([short]).drawn, 1)

let spilling = DocumentPDF.Section(title: "Long Song",
                                   lines: (1...35).map { "Line \($0)" })
check("one line more spills onto a second", pages([spilling]).counted, 2)
check("and the file agrees", pages([spilling]).drawn, 2)

let twoSheets = DocumentPDF.Section(title: "Long Song",
                                    lines: (1...70).map { "Line \($0)" })
check("the second sheet holds 36, having no title on it",
      pages([twoSheets]).counted, 2)
check("and the 71st line starts a third",
      pages([DocumentPDF.Section(title: "Long Song",
                                 lines: (1...71).map { "Line \($0)" })]).counted, 3)

// MARK: - Several documents

print("\nSeveral documents")
let three = [
    DocumentPDF.Section(title: "One", lines: ["a"]),
    DocumentPDF.Section(title: "Two", lines: ["b"]),
    DocumentPDF.Section(title: "Three", lines: ["c"]),
]
check("each document starts its own sheet", pages(three).counted, 3)
check("and the file agrees", pages(three).drawn, 3)
check("a spilling document does not take the next one's sheet with it",
      pages([spilling] + three).counted, 5)

// MARK: - Wrapping

print("\nWrapping")
// One paragraph on one line is the ordinary shape of a note, so the wrap is
// what stands between a note and prose running off the bottom of the sheet.
let paragraph = String(repeating: "The horse walks past the window again. ", count: 200)
let wrapped = DocumentPDF.Section(title: "A Note", text: paragraph)
check("one very long line is still one line", wrapped.lines.count, 1)
check("but it wraps across sheets", pages([wrapped]).counted > 1, true)
check("and the file agrees", pages([wrapped]).drawn, pages([wrapped]).counted)

// MARK: - The file itself

print("\nRendered PDF")
if let document = pdfDocument(DocumentPDF.render(three, title: "Songs")),
   let first = document.page(at: 1) {
    let box = first.getBoxRect(.mediaBox)
    check("letter sheet is 612pt wide", Int(box.width.rounded()), 612)
    check("letter sheet is 792pt tall", Int(box.height.rounded()), 792)
} else {
    failures += 1; print("  FAIL  rendered data is not a readable PDF")
}
check("nothing to print is still a sheet that says so",
      pdfDocument(DocumentPDF.render([]))?.numberOfPages ?? -1, 1)

print()
if failures == 0 {
    print("All song/note print checks passed.")
    exit(0)
} else {
    print("\(failures) song/note print check(s) FAILED.")
    exit(1)
}
