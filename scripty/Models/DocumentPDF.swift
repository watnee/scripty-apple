//
//  DocumentPDF.swift
//  scripty
//
//  A song or a note drawn into a PDF on the device, for printing when the
//  server's renderer cannot be reached. ScreenplayPDF's counterpart, and it
//  exists for the same reason: online, printing downloads the server's file, so
//  the paper is the document the writer would have exported; offline, this is
//  what puts paper in the hands of a writer with no route to the network.
//
//  What it mirrors is `SongExportServiceImpl.renderPdf`, which is a plainer
//  layout than the screenplay's: US Letter, one-inch margins, the title in
//  16pt bold, the words in 12pt, and each document starting its own page. Body
//  text, not screenplay text — so there is no page setup to honour here, for
//  the same reason `downloadExport` sends none with a song: paper size and
//  margins are the screenplay's settings, and the server lays a lyric out its
//  own way whatever they say.
//
//  Lines are what a document is to this renderer, which is why the caller hands
//  them over already split. A song is lyric lines and a note is prose the
//  writer broke where they meant to, and the server prints both a line at a
//  time — including the blank ones, which is what keeps a verse break visible.
//  A line too long for the column wraps and may take the page break with it: a
//  note is often one paragraph on one line, and the alternative is prose that
//  runs off the bottom of the sheet.
//
//  Core Text rather than UIKit, so the arithmetic stays checkable by the
//  swiftc suites in Tests/run.sh, which build without an app around them.
//

import CoreGraphics
import CoreText
import Foundation

/// `nonisolated`. Core Text and a CoreGraphics PDF context, with no UIKit
/// anywhere in the file — and the demo backend, which is an `actor`, has always
/// called straight into it without hopping. This says so rather than changing
/// it: the isolation now matches where the work already runs.
nonisolated enum DocumentPDF {
    /// One song or note: its name, and the lines under it.
    struct Section {
        let title: String
        let lines: [String]

        init(title: String, lines: [String]) {
            self.title = title
            self.lines = lines
        }

        /// The same thing from a document's stored text, split the way the
        /// server splits it — `split("\n", -1)`, so a trailing blank line is a
        /// line and a run of them is a run of them.
        init(title: String, text: String) {
            self.init(title: title, lines: text.components(separatedBy: "\n"))
        }

        /// Whether there is anything here worth putting on paper. A document
        /// with a name and no words still is: that is what an empty song the
        /// writer wants a lyric sheet for looks like.
        var isEmpty: Bool {
            title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && lines.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }

    // US Letter with the server's generous one-inch margins.
    static let pageWidth = 612.0
    static let pageHeight = 792.0
    static let margin = 72.0

    private static let titleSize = 16.0
    private static let bodySize = 12.0
    /// iText's default leading: one and a half times the type size. Mirrored
    /// rather than chosen, so a page here holds the number of lines the
    /// server's copy of the same document holds.
    private static let titleLeading = titleSize * 1.5
    private static let bodyLeading = bodySize * 1.5
    /// The gap `renderPdf` leaves under a heading.
    private static let titleSpacingAfter = 12.0

    /// Render the sections to PDF data, each starting its own page.
    ///
    /// `placeholder` is what a file with nothing in it says — the server writes
    /// one rather than handing back an empty download, so a print of nothing is
    /// still a sheet that explains itself.
    static func render(_ sections: [Section],
                       placeholder: String = "Nothing here yet.",
                       title: String? = nil) -> Data {
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        let data = NSMutableData()
        var info: [CFString: Any] = [kCGPDFContextCreator: "Scripty"]
        if let title, !title.isEmpty { info[kCGPDFContextTitle] = title }
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox,
                                      info as CFDictionary) else {
            return Data()
        }

        for page in pages(of: sections, placeholder: placeholder) {
            context.beginPDFPage(nil)
            for slot in page { draw(slot, in: context) }
            context.endPDFPage()
        }

        context.closePDF()
        return data as Data
    }

    /// How many sheets `render` would produce. The same walk without the ink,
    /// so the arithmetic can be checked a page at a time.
    static func pageCount(_ sections: [Section],
                          placeholder: String = "Nothing here yet.") -> Int {
        pages(of: sections, placeholder: placeholder).count
    }

    // MARK: - Laying it out

    /// One line of type on a page, already wrapped and placed. Blank slots
    /// carry no line: an empty lyric line is a gap, and it takes its slot.
    private struct Slot {
        let line: CTLine?
        let font: CTFont
        let leading: Double
        /// Distance from the top edge of the sheet to the top of the slot.
        var top: Double
    }

    /// The sheets, each a list of placed slots.
    private static func pages(of sections: [Section], placeholder: String) -> [[Slot]] {
        var pages: [[Slot]] = []
        var page: [Slot] = []
        var top = margin

        /// Puts one slot on the page, starting a fresh sheet where it would
        /// fall below the bottom margin. The title does not follow it onto the
        /// new sheet: the server heads each document once, not each page.
        func add(_ slot: Slot) {
            if top + slot.leading > pageHeight - margin, !page.isEmpty {
                pages.append(page)
                page = []
                top = margin
            }
            var placed = slot
            placed.top = top
            page.append(placed)
            top += slot.leading
        }

        guard !sections.isEmpty else {
            run(placeholder, font: bodyFont, leading: bodyLeading).forEach(add)
            return [page]
        }

        for section in sections {
            // Each document starts its own sheet, as the server's does.
            page = []
            top = margin
            run(section.title, font: titleFont, leading: titleLeading).forEach(add)
            top += titleSpacingAfter
            for line in section.lines {
                run(line, font: bodyFont, leading: bodyLeading).forEach(add)
            }
            pages.append(page)
        }
        return pages
    }

    /// Everything one run of text occupies: its wrapped lines, or a single
    /// blank slot where it has no words.
    private static func run(_ text: String, font: CTFont, leading: Double) -> [Slot] {
        let lines = wrapped(text, font: font)
        guard !lines.isEmpty else {
            return [Slot(line: nil, font: font, leading: leading, top: 0)]
        }
        return lines.map { Slot(line: $0, font: font, leading: leading, top: 0) }
    }

    // MARK: - Type and ink

    private static let titleFont = CTFontCreateWithName("Helvetica-Bold" as CFString, titleSize, nil)
    private static let bodyFont = CTFontCreateWithName("Helvetica" as CFString, bodySize, nil)

    private static let ink = CGColor(gray: 0.1, alpha: 1.0)

    private static var textWidth: Double { pageWidth - 2 * margin }

    /// The lines a run of text breaks into at the column width, by the font's
    /// own metrics — Core Text measures what the printer will draw, where the
    /// screenplay can count characters because its face is monospaced.
    private static func wrapped(_ text: String, font: CTFont) -> [CTLine] {
        guard !text.isEmpty else { return [] }
        let string = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink,
        ])
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        var lines: [CTLine] = []
        var start = 0
        while start < string.length {
            // A glyph too wide for the column would otherwise take no
            // characters and spin here forever.
            let taken = max(1, CTTypesetterSuggestLineBreak(typesetter, start, textWidth))
            lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: taken)))
            start += taken
        }
        return lines
    }

    /// `top` is measured from the sheet's top edge; Core Graphics runs
    /// bottom-up, so the flip lives here and nowhere else. The glyphs sit
    /// centred in their slot, as they do on a script sheet: the spare leading
    /// is split above and below.
    private static func draw(_ slot: Slot, in context: CGContext) {
        guard let line = slot.line else { return }
        let descent = Double(CTFontGetDescent(slot.font))
        let slack = max(0, slot.leading - Double(CTFontGetAscent(slot.font)) - descent) / 2
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: margin,
                                       y: pageHeight - slot.top - slot.leading + descent + slack)
        CTLineDraw(line, context)
    }
}
