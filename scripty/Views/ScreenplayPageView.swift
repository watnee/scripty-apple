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
    /// The front matter as an unnumbered first sheet, when the script has a
    /// title — the web page-view mode's cover page. Nil means no sheet, exactly
    /// as the web omits it. It sits outside `pages`, so it never counts toward
    /// "Page N of M" and carries no page number, the same as in every export.
    var cover: ScreenplayCover? = nil
    let setup: PageSetup
    let zoomScale: Double
    /// Fit-to-width sizes the sheet to the space it has, so the scale comes
    /// from measuring this view rather than from the stored percentage.
    var isFitToWidth: Bool = false
    /// Reported back so the navigator can show "Page 3 of 12" while scrolling.
    var onVisiblePageChanged: (Int) -> Void = { _ in }
    /// Reported back so the navigator can show what fit worked out to.
    var onFitZoomChanged: (Int) -> Void = { _ in }

    var body: some View {
        GeometryReader { outer in
            ScrollView {
                LazyVStack(spacing: 28) {
                    if let cover {
                        // Page one is numbered from the script, so the cover
                        // takes id 0 — a number the navigator never jumps to —
                        // and reports no offset, keeping the page count honest.
                        coverSheet(cover, containerWidth: outer.size.width)
                            .id(0)
                    }
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
            // Hard rather than soft: these are discrete sheets on a desk, so
            // the top edge should cut cleanly under the navigation bar. A soft
            // fade would dissolve the top of the paper itself, which reads as
            // a printing fault rather than as scrolling.
            .scrollEdgeEffectStyle(.hard, for: .top)
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
            // Fit is re-resolved whenever the space changes — a rotation, a
            // sidebar, or full-width mode all move the sheet's own width.
            .onChange(of: outer.size.width, initial: true) { _, width in
                guard isFitToWidth else { return }
                onFitZoomChanged(fitZoom(containerWidth: width))
            }
        }
    }

    /// Sheets cap out at a comfortable reading width and then zoom from there,
    /// mirroring the web app's `min(10.5in, 100%) * zoom`.
    private func sheetWidth(containerWidth: CGFloat) -> CGFloat {
        let scale = isFitToWidth
            ? Double(fitZoom(containerWidth: containerWidth)) / 100.0
            : zoomScale
        return baseSheetWidth(containerWidth: containerWidth) * scale
    }

    private func baseSheetWidth(containerWidth: CGFloat) -> CGFloat {
        min(max(240, containerWidth - 48), 760)
    }

    /// What fit works out to here: the unzoomed sheet against the room it has.
    /// Floored, so a rounded-up fit never spills the sheet past the desk edge.
    private func fitZoom(containerWidth: CGFloat) -> Int {
        let available = max(240, containerWidth - 48)
        let base = baseSheetWidth(containerWidth: containerWidth)
        guard base > 0 else { return PresentationSettings.defaultZoom }
        let percent = Int((available / base * 100).rounded(.down))
        return min(PresentationSettings.maxZoom,
                   max(PresentationSettings.minZoom, percent))
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

    /// The title page, typeset as a full sheet at the front: the title set in
    /// capitals on the upper middle, "written by" and the draft version beneath
    /// it, and the contact block in the bottom-left corner — the same layout the
    /// title-page editor previews and a PDF export puts on page one. Sized off
    /// `unit` like every other sheet, and deliberately given no page number and
    /// no visibility probe so it stays outside the numbered run.
    @ViewBuilder
    private func coverSheet(_ cover: ScreenplayCover, containerWidth: CGFloat) -> some View {
        let width = sheetWidth(containerWidth: containerWidth)
        let unit = width / setup.paper.widthIn
        let height = width / setup.paper.aspectRatio
        let font = ScreenplayFont.sheet(.default, lineHeight: bodyLineHeight(unit: unit))

        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: unit * 0.16) {
                Text(cover.title)
                    .font(font.weight(.bold))
                    .multilineTextAlignment(.center)
                if let writers = cover.writers {
                    Text("written by").font(font)
                    Text(writers)
                        .font(font)
                        .multilineTextAlignment(.center)
                }
                if let version = cover.version {
                    Text(version)
                        .font(font)
                        .padding(.top, unit * 0.12)
                }
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            if let contact = cover.contact {
                Text(contact)
                    .font(font)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(inkColor)
        .padding(.top, setup.margins.topIn * unit)
        .padding(.bottom, setup.margins.bottomIn * unit)
        .padding(.leading, setup.margins.leftIn * unit)
        .padding(.trailing, setup.margins.rightIn * unit)
        .frame(minWidth: width, maxWidth: width,
               minHeight: height, alignment: .topLeading)
        .background(paperColor)
        .overlay {
            Rectangle()
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Title page")
    }

    /// One 12pt line of paper, in screen points — worked out exactly as a sheet
    /// row does, so the cover and the page numbers are set in the same type as
    /// the pages between them.
    private func bodyLineHeight(unit: CGFloat) -> CGFloat {
        ScreenplayLayout.lineHeightPt * unit / ScreenplayLayout.pointsPerInch
    }

    /// Page one is unnumbered by screenplay convention, as in the web app.
    @ViewBuilder
    private func pageNumber(_ page: ScriptPage, unit: CGFloat) -> some View {
        if setup.pageNumbers != .none && page.number > 1 {
            Text("\(page.number).")
                .font(ScreenplayFont.sheet(.default,
                                           lineHeight: bodyLineHeight(unit: unit)))
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

/// The front matter of a script, resolved to what the cover sheet should show.
///
/// The rules match the title-page editor's live preview and the web page-view
/// cover: the title falls back to the project name and is set in capitals, and
/// the "written by", version and contact lines each appear only when they carry
/// text. A script with no title at all has no cover, exactly as the web omits
/// the sheet — so this is a failable initialiser rather than a set of optionals.
struct ScreenplayCover: Equatable {
    let title: String
    let writers: String?
    let version: String?
    let contact: String?

    init?(project: Project) {
        let entered = project.screenplayTitle.trimmed
        let raw = entered.isEmpty ? project.title.trimmed : entered
        guard !raw.isEmpty else { return nil }
        title = raw.uppercased()
        writers = project.writers.trimmedOrNil
        version = project.screenplayVersion.trimmedOrNil
        contact = project.contactInfo.trimmedOrNil
    }
}

private extension Optional where Wrapped == String {
    var trimmed: String {
        (self ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedOrNil: String? {
        let value = trimmed
        return value.isEmpty ? nil : value
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

    /// The page's own face, which is what a sheet is set in unless a block
    /// says otherwise — and what the markers and page furniture always use.
    private var baseFont: Font {
        ScreenplayFont.sheet(.default, lineHeight: lineHeight)
    }

    private func font(for block: Block) -> Font {
        ScreenplayFont.sheet(ScriptFont(serverValue: block.font) ?? .default,
                             lineHeight: lineHeight)
    }

    private func text(for block: Block, type: BlockType) -> String {
        var content = block.content ?? ""
        if content.isEmpty, type.isCharacterCue, let name = block.personName {
            content = name
        }
        switch type {
        case .scene, .character, .dualDialogue, .transition, .shot:
            return CapitalizationSettings.shared.displayCased(content, forBlockType: type)
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
