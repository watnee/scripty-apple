//
//  ScreenplayPDF.swift
//  scripty
//
//  Draws paginated pages into a PDF on the device, for printing when the
//  server's renderer cannot be reached. Online, printing still downloads the
//  server's PDF; this exists so a writer with no route to the network can put
//  paper in their hands from the cached copy they are already looking at.
//
//  It mirrors ScreenplaySheetRow deliberately: the same boxes, faces, casing
//  and budgets, at 72 points to the inch instead of screen points. Each row
//  draws the very lines the paginator counted — wrappedLines is the single
//  wrap they share — so what comes out of the printer fills each page to the
//  line the page view showed.
//
//  Core Text rather than UIKit, so the arithmetic stays checkable by the
//  swiftc suites in Tests/run.sh, which build without an app around them.
//

import CoreGraphics
import CoreText
import Foundation

enum ScreenplayPDF {
    private static let pointsPerInch = ScreenplayLayout.pointsPerInch
    private static let lineHeight = ScreenplayLayout.lineHeightPt

    /// Render pages (and the cover, when the script has one) to PDF data.
    ///
    /// `cased` is the presentation casing hook — the caller passes the shared
    /// CapitalizationSettings transform. A parameter rather than a direct call
    /// so this file stays free of app state and deterministic under test.
    static func render(pages: [ScriptPage],
                       cover: ScreenplayCover?,
                       setup: PageSetup,
                       title: String? = nil,
                       cased: (String, BlockType) -> String = { text, _ in text }) -> Data {
        var mediaBox = CGRect(x: 0, y: 0,
                              width: setup.paper.widthIn * pointsPerInch,
                              height: setup.paper.heightIn * pointsPerInch)
        let data = NSMutableData()
        var info: [CFString: Any] = [kCGPDFContextCreator: "Scripty"]
        if let title, !title.isEmpty { info[kCGPDFContextTitle] = title }
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox,
                                      info as CFDictionary) else {
            return Data()
        }

        if let cover {
            context.beginPDFPage(nil)
            drawCover(cover, setup: setup, in: context, mediaBox: mediaBox)
            context.endPDFPage()
        }
        for page in pages {
            context.beginPDFPage(nil)
            drawPage(page, setup: setup, cased: cased, in: context, mediaBox: mediaBox)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    // MARK: - What a row says

    /// The text a block prints as — the same rules as ScreenplaySheetRow:
    /// cues fall back to the linked character, parentheticals grow their
    /// parentheses, and the cased types pass through the casing hook.
    static func displayText(for block: Block,
                            cased: (String, BlockType) -> String) -> String {
        let type = block.blockType
        var content = block.content ?? ""
        if content.isEmpty, type.isCharacterCue, let name = block.personName {
            content = name
        }
        switch type {
        case .scene, .character, .dualDialogue, .transition, .shot:
            return cased(content, type)
        case .parenthetical:
            return content.hasPrefix("(") ? content : "(\(content))"
        default:
            return content
        }
    }

    // MARK: - Pages

    private static func drawPage(_ page: ScriptPage, setup: PageSetup,
                                 cased: (String, BlockType) -> String,
                                 in context: CGContext, mediaBox: CGRect) {
        // Non-standard margins widen the column, so the wrap uses the same
        // scaled character counts the paginator measured with.
        let columnScale = setup.textWidthIn / ScreenplayLayout.textWidthIn
        var top = setup.margins.topIn * pointsPerInch

        for row in page.rows {
            top += Double(row.spacing) * lineHeight
            switch row.kind {
            case .more:
                drawMarker("(MORE)", setup: setup, top: top,
                           in: context, mediaBox: mediaBox)
            case .continued(let speaker):
                drawMarker("\(speaker) (CONT'D)", setup: setup, top: top,
                           in: context, mediaBox: mediaBox)
            case .block(let block):
                let type = block.blockType
                if type != .pageBreak, ScriptPagination.isPrintable(type) {
                    drawBlock(block, setup: setup, columnScale: columnScale,
                              budget: row.lines, cased: cased, top: top,
                              in: context, mediaBox: mediaBox)
                }
            }
            top += Double(row.lines) * lineHeight
        }

        drawPageNumber(page.number, setup: setup, in: context, mediaBox: mediaBox)
    }

    private static func drawBlock(_ block: Block, setup: PageSetup,
                                  columnScale: Double, budget: Int,
                                  cased: (String, BlockType) -> String, top: Double,
                                  in context: CGContext, mediaBox: CGRect) {
        let type = block.blockType
        let box = ScreenplayLayout.box(for: type)
        let columns = max(1, Int((Double(box.columns) * columnScale).rounded(.down)))
        let text = displayText(for: block, cased: cased)

        // The paginator measured the raw content; parentheses or a rare casing
        // quirk can wrap one line longer. The sheet view clips that overflow to
        // the row's budget, and paper does the same.
        let lines = ScriptPagination.wrappedLines(text, columns: columns).prefix(budget)

        let family = ScriptFont(serverValue: block.font) ?? .default
        let font = resolvedFont(
            family: family,
            bold: isBold(type),
            italic: (block.textItalic ?? false) || type == .parenthetical || type == .lyrics)
        let boxWidth = Double(columns) / ScreenplayLayout.charactersPerInch * pointsPerInch
        let left = (setup.margins.leftIn + box.indentIn) * pointsPerInch

        for (index, line) in lines.enumerated() {
            draw(line, font: font, underlined: block.textUnderline ?? false,
                 top: top + Double(index) * lineHeight,
                 left: left, boxWidth: boxWidth,
                 alignment: alignment(for: block, type: type),
                 in: context, mediaBox: mediaBox)
        }
    }

    private static func drawMarker(_ label: String, setup: PageSetup, top: Double,
                                   in context: CGContext, mediaBox: CGRect) {
        let box = ScreenplayLayout.characterBox
        draw(label, font: resolvedFont(family: .default, bold: false, italic: false),
             underlined: false, top: top,
             left: (setup.margins.leftIn + box.indentIn) * pointsPerInch,
             boxWidth: box.textWidthIn * pointsPerInch, alignment: .leading,
             in: context, mediaBox: mediaBox)
    }

    /// Page one is unnumbered by screenplay convention, as on the sheet view.
    private static func drawPageNumber(_ number: Int, setup: PageSetup,
                                       in context: CGContext, mediaBox: CGRect) {
        guard setup.pageNumbers != .none, number > 1 else { return }
        let font = resolvedFont(family: .default, bold: false, italic: false)
        let pad = setup.margins.rightIn * pointsPerInch
        let width = mediaBox.width - 2 * pad
        switch setup.pageNumbers {
        case .topRight, .topLeft:
            draw("\(number).", font: font, underlined: false,
                 top: setup.margins.topIn * pointsPerInch * 0.5,
                 left: pad, boxWidth: width,
                 alignment: setup.pageNumbers == .topLeft ? .leading : .trailing,
                 in: context, mediaBox: mediaBox)
        case .bottomCenter:
            draw("\(number).", font: font, underlined: false,
                 top: mediaBox.height - setup.margins.bottomIn * pointsPerInch * 0.5 - lineHeight,
                 left: pad, boxWidth: width, alignment: .center,
                 in: context, mediaBox: mediaBox)
        case .none:
            break
        }
    }

    // MARK: - The cover sheet

    /// The title block set in the vertical middle and the contact lines in the
    /// bottom-left corner, as on the page view's cover. The sheet's sub-line
    /// gaps are rounded up to whole lines here — a cover is not paginated, so
    /// nothing downstream counts on their exact height.
    private static func drawCover(_ cover: ScreenplayCover, setup: PageSetup,
                                  in context: CGContext, mediaBox: CGRect) {
        let wrap = { (text: String) in
            ScriptPagination.wrappedLines(
                text, columns: max(1, Int(setup.textWidthIn * ScreenplayLayout.charactersPerInch)))
        }
        let width = setup.textWidthIn * pointsPerInch
        let left = setup.margins.leftIn * pointsPerInch
        let regular = resolvedFont(family: .default, bold: false, italic: false)
        let bold = resolvedFont(family: .default, bold: true, italic: false)

        // nil is a blank line between parts of the block.
        var block: [(text: String, font: CTFont)?] = wrap(cover.title).map { ($0, bold) }
        if let writers = cover.writers {
            block.append(nil)
            block.append(("written by", regular))
            block += wrap(writers).map { ($0, regular) }
        }
        if let version = cover.version {
            block.append(nil)
            block += wrap(version).map { ($0, regular) }
        }

        var top = (mediaBox.height - Double(block.count) * lineHeight) / 2
        for entry in block {
            if let entry {
                draw(entry.text, font: entry.font, underlined: false, top: top,
                     left: left, boxWidth: width, alignment: .center,
                     in: context, mediaBox: mediaBox)
            }
            top += lineHeight
        }

        if let contact = cover.contact {
            let lines = wrap(contact)
            var top = mediaBox.height - setup.margins.bottomIn * pointsPerInch
                - Double(lines.count) * lineHeight
            for line in lines {
                draw(line, font: regular, underlined: false, top: top,
                     left: left, boxWidth: width, alignment: .leading,
                     in: context, mediaBox: mediaBox)
                top += lineHeight
            }
        }
    }

    // MARK: - Type and ink

    private enum LineAlignment { case leading, center, trailing }

    /// Scene headings and cues sit left on paper, exactly as on the sheet —
    /// the centred house style is a continuous-mode affectation.
    private static func alignment(for block: Block, type: BlockType) -> LineAlignment {
        switch type {
        case .transition: return .trailing
        case .centered: return .center
        default:
            switch TextAlign(serverValue: block.textAlign) {
            case .center: return .center
            case .right: return .trailing
            case .left, .none: return .leading
            }
        }
    }

    private static func isBold(_ type: BlockType) -> Bool {
        switch type {
        // The sheet asks for semibold on scene headings and shots; Courier
        // Prime carries no semibold, so paper gets the bold the font has.
        case .character, .dualDialogue, .section, .scene, .shot: return true
        default: return false
        }
    }

    /// The face at the size the sheet uses: type is shrunk by the family's
    /// natural leading so one rendered line occupies exactly one 12pt line of
    /// paper (see ScriptFont.naturalLeading).
    private static func resolvedFont(family: ScriptFont, bold: Bool, italic: Bool) -> CTFont {
        let size = lineHeight / Double(family.naturalLeading)
        let base = CTFontCreateWithName(family.postScriptName as CFString, size, nil)
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard !traits.isEmpty else { return base }
        // A family without the trait keeps its regular face rather than
        // failing the whole draw.
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base
    }

    private static let ink = CGColor(gray: 0.1, alpha: 1.0)

    /// Draw one line of text into its 12pt slot. `top` is measured from the
    /// page's top edge; Core Graphics runs bottom-up, so the flip lives here
    /// and nowhere else.
    private static func draw(_ text: String, font: CTFont, underlined: Bool,
                             top: Double, left: Double, boxWidth: Double,
                             alignment: LineAlignment,
                             in context: CGContext, mediaBox: CGRect) {
        guard !text.isEmpty else { return }
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink,
        ]
        if underlined {
            attributes[NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)] =
                NSNumber(value: CTUnderlineStyle.single.rawValue)
        }
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes))

        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        let x: Double
        switch alignment {
        case .leading: x = left
        case .center: x = left + (boxWidth - width) / 2
        case .trailing: x = left + boxWidth - width
        }

        // Centre the glyphs in the slot: the face is sized under 12pt, so the
        // spare leading is split above and below, as SwiftUI does on a sheet.
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let slack = max(0, lineHeight - Double(ascent + descent)) / 2
        let baseline = mediaBox.height - top - lineHeight + Double(descent) + slack

        context.textMatrix = .identity
        context.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, context)
    }
}
