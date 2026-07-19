//
//  ScreenplayPageView.swift
//  scripty
//
//  The script as paper: discrete sheets at the chosen paper size, with the
//  elements sitting at their real screenplay indents and a page number in the
//  corner. This is the read-only counterpart of the continuous editor — the
//  web app works the same way, since you cannot type into a paginated page and
//  have the pagination stay still underneath you.
//
//  Everything scales off one number: how many points of screen an inch of
//  paper is worth. That keeps the 12pt type, the 1.5in gutter and the 6in
//  column in the same proportion at any zoom.
//

import SwiftUI

struct ScreenplayPageView: View {
    let pages: [ScriptPage]
    let setup: PageSetup
    let zoomScale: Double
    /// Reported back so the navigator can show "Page 3 of 12" while scrolling.
    var onVisiblePageChanged: (Int) -> Void = { _ in }

    var body: some View {
        GeometryReader { outer in
            ScrollView {
                LazyVStack(spacing: 28) {
                    ForEach(pages) { page in
                        sheet(page, containerWidth: outer.size.width)
                            .id(page.number)
                            .background(visibilityProbe(for: page))
                    }
                }
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity)
            }
            .coordinateSpace(name: "pages")
            // Every sheet reports its offset, and the winner is picked once
            // from the whole set — the last page to have crossed the reading
            // line. Deciding per-sheet would let whichever probe fired last
            // win, which reads as a jittering page number while scrolling.
            .onPreferenceChange(PageOffsetKey.self) { offsets in
                let line = outer.size.height * 0.28
                let current = offsets
                    .filter { $0.top <= line }
                    .max(by: { $0.number < $1.number })?.number
                    ?? offsets.min(by: { $0.top < $1.top })?.number
                if let current { onVisiblePageChanged(current) }
            }
            .background(deskColor)
        }
    }

    /// Sheets cap out at a comfortable reading width and then zoom from there,
    /// mirroring the web app's `min(10.5in, 100%) * zoom`.
    private func sheetWidth(containerWidth: CGFloat) -> CGFloat {
        let available = max(240, containerWidth - 48)
        return min(available, 760) * zoomScale
    }

    @ViewBuilder
    private func sheet(_ page: ScriptPage, containerWidth: CGFloat) -> some View {
        let width = sheetWidth(containerWidth: containerWidth)
        // One inch of paper, in screen points. Every other measurement derives
        // from this so the sheet stays proportional at any zoom.
        let unit = width / setup.paper.widthIn
        let height = width / setup.paper.aspectRatio

        VStack(alignment: .leading, spacing: 0) {
            ForEach(page.rows) { row in
                ScreenplaySheetRow(row: row, unit: unit, setup: setup)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, setup.margins.topIn * unit)
        .padding(.bottom, setup.margins.bottomIn * unit)
        .padding(.leading, setup.margins.leftIn * unit)
        .padding(.trailing, setup.margins.rightIn * unit)
        // `minHeight` rather than `height`: a page that overflows its sheet
        // grows instead of clipping the text, the same concession the web app
        // makes for an over-full page.
        .frame(minWidth: width, maxWidth: width,
               minHeight: height, alignment: .topLeading)
        .background(paperColor)
        .overlay(alignment: .topLeading) { pageNumber(page, unit: unit) }
        .overlay {
            Rectangle()
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Page \(page.number) of \(pages.count)")
    }

    /// Page one is unnumbered by screenplay convention, as in the web app.
    @ViewBuilder
    private func pageNumber(_ page: ScriptPage, unit: CGFloat) -> some View {
        if setup.pageNumbers != .none && page.number > 1 {
            Text("\(page.number).")
                .font(.custom("Courier New",
                              size: ScreenplayLayout.lineHeightPt * unit
                                  / ScreenplayLayout.pointsPerInch / 1.15))
                .foregroundStyle(inkColor.opacity(0.85))
                .padding(.top, setup.margins.topIn * unit * 0.5)
                .padding(.horizontal, setup.margins.rightIn * unit)
                .frame(maxWidth: .infinity,
                       maxHeight: .infinity,
                       alignment: numberAlignment)
                .allowsHitTesting(false)
        }
    }

    private var numberAlignment: Alignment {
        switch setup.pageNumbers {
        case .topRight: return .topTrailing
        case .topLeft: return .topLeading
        case .bottomCenter: return .bottom
        case .none: return .topTrailing
        }
    }

    /// Publishes where this sheet currently sits, for the scroll spy above.
    private func visibilityProbe(for page: ScriptPage) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: PageOffsetKey.self,
                value: [PageOffset(number: page.number,
                                   top: proxy.frame(in: .named("pages")).minY)])
        }
    }

    // Paper stays white in both appearances — a screenplay page is a screenplay
    // page — while the desk behind it follows the system theme.
    private var paperColor: Color { Color(white: 1.0) }
    private var inkColor: Color { Color(white: 0.1) }

    @Environment(\.colorScheme) private var colorScheme
    private var deskColor: Color {
        colorScheme == .dark
            ? Color(red: 0.10, green: 0.12, blue: 0.15)
            : Color(white: 0.91)
    }
}

/// Where one sheet sits in the scroll view, reported up to the scroll spy.
private struct PageOffset: Equatable {
    let number: Int
    let top: CGFloat
}

private struct PageOffsetKey: PreferenceKey {
    static let defaultValue: [PageOffset] = []

    static func reduce(value: inout [PageOffset], nextValue: () -> [PageOffset]) {
        value.append(contentsOf: nextValue())
    }
}

/// One element of a sheet, placed at its screenplay indent and sized to the
/// line budget the paginator gave it.
struct ScreenplaySheetRow: View {
    let row: PageRow
    /// Screen points per inch of paper.
    let unit: CGFloat
    let setup: PageSetup

    var body: some View {
        content
            // The row occupies exactly the space the paginator charged it, so
            // a page fills to precisely the line it was computed to fill to.
            .frame(height: CGFloat(row.lines) * lineHeight, alignment: .topLeading)
            .padding(.top, CGFloat(row.spacing) * lineHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
    }

    @ViewBuilder
    private var content: some View {
        switch row.kind {
        case .block(let block):
            blockRow(block)
        case .more:
            marker("(MORE)", box: ScreenplayLayout.characterBox)
        case .continued(let speaker):
            marker("\(speaker) (CONT'D)", box: ScreenplayLayout.characterBox)
        }
    }

    @ViewBuilder
    private func blockRow(_ block: Block) -> some View {
        let type = block.blockType
        if type == .pageBreak || !ScriptPagination.isPrintable(type) {
            // Page breaks did their work during pagination, and the
            // non-printing types were dropped before the page was measured —
            // neither is charged any lines, so neither leaves a gap.
            EmptyView()
        } else {
            let box = ScreenplayLayout.box(for: type)
            Text(text(for: block, type: type))
                .font(font(for: block))
                .fontWeight(weight(for: type))
                .italic(isItalic(block, type: type))
                .underline(block.textUnderline ?? false)
                .foregroundStyle(Color(white: 0.1))
                .frame(width: box.textWidthIn * unit, alignment: alignment(for: block, type: type))
                .padding(.leading, box.indentIn * unit)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func marker(_ label: String, box: ScreenplayLayout.ElementBox) -> some View {
        Text(label)
            .font(baseFont)
            .foregroundStyle(Color(white: 0.1))
            .padding(.leading, box.indentIn * unit)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One 12pt line of the page, in screen points.
    private var lineHeight: CGFloat {
        ScreenplayLayout.lineHeightPt * unit / ScreenplayLayout.pointsPerInch
    }

    /// A screenplay line is set solid — leading equal to the type size — but a
    /// font renders at its own natural leading, which for Courier is about
    /// 1.15×. Sizing the type down by that ratio makes a rendered line occupy
    /// one page line, so the text lands where the paginator put it. The
    /// slightly narrower glyphs also mean text wraps no later than the
    /// paginator assumed, so nothing is clipped out of its budget.
    private var fontSize: CGFloat {
        lineHeight / 1.15
    }

    /// Courier proper, not the system monospace: its advance is exactly 0.6em,
    /// which is what makes ten characters to the inch true.
    private var baseFont: Font {
        .custom("Courier New", size: fontSize)
    }

    private func font(for block: Block) -> Font {
        switch ScriptFont(serverValue: block.font) {
        case .arial: return .custom("Helvetica", size: fontSize)
        case .timesNewRoman: return .custom("Times New Roman", size: fontSize)
        case .courierPrime, .none: return baseFont
        }
    }

    private func text(for block: Block, type: BlockType) -> String {
        var content = block.content ?? ""
        if content.isEmpty, type.isCharacterCue, let name = block.personName {
            content = name
        }
        switch type {
        case .scene, .character, .dualDialogue, .transition, .shot:
            return content.uppercased()
        case .parenthetical:
            return content.hasPrefix("(") ? content : "(\(content))"
        default:
            return content.isEmpty ? " " : content
        }
    }

    private func weight(for type: BlockType) -> Font.Weight {
        switch type {
        case .character, .dualDialogue, .section: return .bold
        case .scene, .shot: return .semibold
        default: return .regular
        }
    }

    private func isItalic(_ block: Block, type: BlockType) -> Bool {
        if block.textItalic ?? false { return true }
        return type == .parenthetical || type == .lyrics
    }

    /// Scene headings and cues sit left in page view — the centred house style
    /// is a continuous-mode affectation the printed page does not share.
    private func alignment(for block: Block, type: BlockType) -> Alignment {
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
}
