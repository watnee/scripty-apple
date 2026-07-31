//
//  ReadScriptView.swift
//  scripty
//
//  Read Script mode: the screenplay set as a screenplay, for reading rather
//  than writing — the editing chrome and the working annotations dropped,
//  nothing else changed. Synopses and notes are for the writer, not the reader.
//
//  It used to set the script as serif prose at a reading measure, which read
//  well and looked nothing like a script: a scene heading became a subhead, a
//  cue a centred name, and the shape a reader recognises a screenplay by was
//  gone. It is Courier at the screenplay indents now, sharing the geometry in
//  `ScreenplayLayout` with the writing column and the paper, so all three
//  surfaces are the same document at different distances.
//
//  Still deliberately not page-accurate; that is what page view is for. The
//  reader runs continuously — no sheets, no page numbers, no (MORE)/(CONT'D) —
//  and its type is sized to be read on a screen rather than to fit 55 lines on
//  a sheet, so lines wrap where the screen says rather than where the page does.
//
//  Not a screen of its own: this is one of the script screen's surfaces, the
//  way page view is — the mode swaps the writing column for this one in place,
//  and the toolbar, the View menu and the reading position all stay put. The
//  screen it is embedded in owns the narrator and the transport bar, so a
//  reading aloud carries straight across the mode change in both directions.
//

import SwiftUI

struct ReadScriptView: View {
    let title: String
    let blocks: [Block]
    let textScale: Double
    /// The script screen's narrator, watched so the element being read is
    /// spotlighted and kept on screen. Playing is asked for through
    /// `onReadFrom`, so preparing the run stays the owner's job.
    var narrator: ScriptNarrator
    /// Whether the script is still on its way. Only ever true now that a
    /// screenplay can *open* into this mode rather than only be switched into
    /// it: entered by hand there were always elements to show, but on the way
    /// in from a cold launch the blocks land after the surface does, and a
    /// script that has not arrived yet must not be announced as one with
    /// nothing in it.
    var isLoading = false
    /// The script screen's navigator, listened to the way the editor listens:
    /// an outline tap should land here too. Jumps to elements the reader
    /// leaves out — synopses, notes — find no row and quietly do nothing.
    var navigator: ScriptNavigator
    /// Where to open: the element the writer was at on the surface this mode
    /// replaced. Nil opens at the top.
    var initialBlockId: Int?
    /// Reports the element at the top of the screen as the reading scrolls,
    /// so the surfaces keep handing one position back and forth.
    var onTopVisibleBlock: (Int) -> Void = { _ in }
    /// The context menu's "Read Aloud From Here". A closure rather than a call
    /// on the narrator, because starting a reading means preparing the run
    /// first and the blocks belong to the screen that owns the voice.
    var onReadFrom: (Int) -> Void = { _ in }
    /// Reports finger-driven scrolling, for the same chrome fold the editor
    /// and the paper have — reading is the posture the fold exists for.
    var onUserScroll: (_ delta: CGFloat, _ fromTop: CGFloat) -> Void = { _, _ in }

    /// The type size the writing column is set at, so switching into the mode
    /// re-typesets the script rather than resizing it.
    private static let baseFontSize: CGFloat = 16

    /// Room kept either side of the column, and the part of the window the
    /// column therefore never had.
    private static let horizontalPadding: CGFloat = 20

    /// The OS text-size setting, as a multiplier.
    ///
    /// This view sets its type in fixed points — a screenplay is measured in
    /// characters, so the type has to hold still against the column it is
    /// measured into — which meant it ignored Dynamic Type entirely. Folding
    /// the setting in as a *multiplier* scales the column with the type so the
    /// measure survives, and composes with the script's own type-size control
    /// rather than overriding it.
    @ScaledMetric(relativeTo: .body) private var dynamicTypeScale: CGFloat = 1

    private var scale: CGFloat { CGFloat(textScale) * dynamicTypeScale }

    private var fontSize: CGFloat { Self.baseFontSize * scale }

    /// The window, so the column can be given up where there isn't room for it.
    @State private var availableWidth: CGFloat = 0

    /// Whether the remembered position has been restored. Until it has, the
    /// scroll spy stays quiet — the first rows to appear are the top of the
    /// script, and recording those would overwrite the very thing being
    /// restored. State rather than a constant because the blocks may land
    /// after the mode is entered, and the restore has to wait for them.
    @State private var hasRestoredPosition = false

    // MARK: - Column

    /// The column at 100% type, which is what the screenplay proportions are
    /// reckoned against: the printed six-inch measure, or whatever a narrower
    /// window can pay for. Resolved before the type size is applied so that
    /// growing the type grows the column with it, leaving the same sixty
    /// characters to the line — a measure is a count of characters before it is
    /// a width, and `ScriptRowChrome` already knows how the speech boxes
    /// narrow when the column cannot hold the full measure.
    private var baseChrome: ScriptRowChrome {
        var chrome = ScriptRowChrome()
        guard availableWidth > 0, scale > 0 else { return chrome }
        let usable = max(0, availableWidth - Self.horizontalPadding * 2)
        chrome.columnWidth = min(ScriptRowChrome.printedMeasure,
                                 max(240, usable / scale))
        return chrome
    }

    private var columnWidth: CGFloat { baseChrome.columnWidth * scale }
    private var dialogueWidth: CGFloat { baseChrome.dialogueWidth * scale }
    private var parentheticalWidth: CGFloat { baseChrome.parentheticalWidth * scale }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Walked once per redraw rather than once per row: the
                // first-element test below needs the head of the list, and
                // asking `readableBlocks` for it inside the ForEach would
                // re-filter the whole script for every line it drew.
                let readable = readableBlocks
                let firstId = readable.first?.id
                // Lazy for the same reason the editor and the page view
                // are: reading aloud republishes `currentBlockId` on every
                // line, and each one rebuilds this body. Eagerly stacked,
                // that re-laid-out every element of a feature-length script
                // per spoken line — for a highlight the reader can only see
                // one of. Lazily, only the elements on screen are built at
                // all, so the cost per line is the window rather than the
                // script, and entering the mode no longer typesets an hour
                // of screenplay before showing the first page of it.
                LazyVStack(alignment: .leading, spacing: 0) {
                    titleHeading

                    ForEach(readable) { block in
                        row(block, isFirst: block.id == firstId)
                            .background(alignment: .center) { spotlight(block) }
                            .id(block.id)
                            .contextMenu {
                                Button("Read Aloud From Here", systemImage: "play") {
                                    onReadFrom(block.id)
                                }
                            }
                    }
                }
                // Marks the rows as scroll targets so the spy below can name
                // the one at the top. No behaviour is attached — nothing snaps.
                .scrollTargetLayout()
                // Take the whole measure rather than settling on the
                // widest element. A lazy stack is only as wide as the rows
                // it has actually built, so without this the column's width
                // — and, being centred, its left edge — would shift as
                // scrolling brought a longer line into the window.
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(maxWidth: columnWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Self.horizontalPadding)
                .padding(.vertical, 24)
                .textSelection(.enabled)
            }
            // The indents are fractions of the column, so the column has to be
            // measured before a single one of them is right.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                availableWidth = $0
            }
            // Follow the voice. Centred rather than at the top, because a
            // line read at the very top of the screen has no context above
            // it and the next one is always a jump.
            .onChange(of: narrator.currentBlockId) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            // An outline tap lands here the way it lands in the editor. The
            // `initial` catches a target set while another surface was up —
            // the handoff when the mode is entered mid-jump.
            .onChange(of: navigator.pendingScrollTarget, initial: true) { _, target in
                guard let target else { return }
                let anchor: UnitPoint =
                    navigator.pendingPlacement == .atTop ? .top : .center
                withAnimation { proxy.scrollTo(target, anchor: anchor) }
                navigator.consumeScrollTarget()
            }
            // Reading opens where the writing left off, and the blocks may
            // arrive after the mode does — `initial` covers the usual case
            // where they were here all along.
            .onChange(of: blocks, initial: true) { _, _ in
                restorePosition(with: proxy)
            }
            // Where the reading is, in the same element ids the other
            // surfaces record — the element at the top of the screen is the
            // honest answer to "where was I".
            .onScrollTargetVisibilityChange(idType: Int.self) { visible in
                guard hasRestoredPosition, let top = visible.first else { return }
                onTopVisibleBlock(top)
            }
            .onUserScroll(onUserScroll)
        }
        .overlay { emptyState }
    }

    /// The project's title, set the way a title page sets it: centred, in caps,
    /// in the script's own face rather than in a display face borrowed from
    /// somewhere else.
    private var titleHeading: some View {
        Text((title.isEmpty ? "Untitled Project" : title).uppercased())
            .font(.custom(ScriptFont.default.postScriptName, fixedSize: fontSize))
            .fontWeight(.bold)
            .accessibilityLabel(title.isEmpty ? "Untitled Project" : title)
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, fontSize * 2)
    }

    /// Scrolls to the element the mode was entered at, once, as soon as there
    /// is a script to scroll. Without animation: the surface should come up
    /// already in place, as the paper does, not travel there.
    private func restorePosition(with proxy: ScrollViewProxy) {
        guard !hasRestoredPosition, !blocks.isEmpty else { return }
        hasRestoredPosition = true
        guard let id = initialBlockId,
              let target = readableBlock(atOrAfter: id) else { return }
        proxy.scrollTo(target, anchor: .top)
    }

    /// The first element the reader actually shows at or after the one named —
    /// the position may have been recorded on a note or a synopsis, which this
    /// surface leaves out.
    private func readableBlock(atOrAfter id: Int) -> Int? {
        guard let start = blocks.firstIndex(where: { $0.id == id }) else { return nil }
        let readable = Set(readableBlocks.map(\.id))
        return blocks[start...].first { readable.contains($0.id) }?.id
    }

    // MARK: - Reading aloud

    /// The element being read, marked without moving anything: the background
    /// is inset outwards so switching it on cannot reflow the page.
    @ViewBuilder
    private func spotlight(_ block: Block) -> some View {
        if narrator.currentBlockId == block.id {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.16))
                .padding(.horizontal, -10)
                .padding(.vertical, -2)
        }
    }

    /// Notes, synopses and page breaks are working marks that the reader view
    /// leaves out, matching the reader template and the print stylesheet.
    private var readableBlocks: [Block] {
        blocks.filter { block in
            switch block.blockType {
            case .synopsis, .note, .pageBreak: return false
            default: return true
            }
        }
    }

    /// Display case for a rendered element, honouring the auto-caps preference
    /// the way the editor does — the reader transforms on display instead of
    /// forcing caps, so a toggled-off scene/cue/transition reads in typed case.
    private func cased(_ text: String, _ block: Block) -> String {
        CapitalizationSettings.shared.displayCased(text, forBlockType: block.blockType)
    }

    // MARK: - Rows

    /// Blank lines above an element, in the same line units the paginator and
    /// the printed page use: two above a scene heading, none between a cue and
    /// what it says, one everywhere else. Set solid, so a line is the type size.
    private func spacing(for type: BlockType) -> CGFloat {
        CGFloat(ScreenplayLayout.spacingLines(for: type)) * fontSize
    }

    @ViewBuilder
    private func row(_ block: Block, isFirst: Bool) -> some View {
        element(block)
            .padding(.top, isFirst ? 0 : spacing(for: block.blockType))
    }

    @ViewBuilder
    private func element(_ block: Block) -> some View {
        let text = displayText(for: block)

        switch block.blockType {
        case .scene:
            line(cased(text, block), block)
                // Read back in its written case: VoiceOver spells out all-caps
                // runs letter by letter, which turns every scene heading into
                // an initialism.
                .accessibilityLabel(text)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: alignment(block))

        case .shot:
            line(cased(text, block), block)
                .accessibilityLabel(text)
                .frame(maxWidth: .infinity, alignment: alignment(block))

        case .section:
            line(text, block)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .character, .dualDialogue:
            line(cased(text, block), block)
                .accessibilityLabel(text)
                .indented(by: indent(ScreenplayLayout.characterBox))

        case .parenthetical:
            line(parenthesized(text), block)
                .speechBox(width: parentheticalWidth,
                           indent: indent(ScreenplayLayout.parentheticalBox,
                                          width: parentheticalWidth))

        case .dialogue, .lyrics:
            line(text, block)
                .speechBox(width: dialogueWidth,
                           indent: indent(ScreenplayLayout.dialogueBox,
                                          width: dialogueWidth))

        case .transition:
            line(cased(text, block), block)
                .accessibilityLabel(text)
                .frame(maxWidth: .infinity, alignment: .trailing)

        case .centered:
            line(text, block)
                .frame(maxWidth: .infinity, alignment: .center)

        default:
            VStack(alignment: .leading, spacing: 0) {
                // The reader labels a speaker that is attached to a non-cue
                // element, since there is no cue line to carry the name — set
                // at the cue's own indent, where a name belongs.
                if let name = block.personName, !name.isEmpty,
                   !block.blockType.isCharacterCue {
                    line(name.uppercased(), block)
                        .accessibilityLabel(name)
                        .indented(by: indent(ScreenplayLayout.characterBox))
                }
                line(text, block)
                    .frame(maxWidth: .infinity, alignment: alignment(block))
            }
        }
    }

    /// One line of script, in the block's own face and character formatting.
    /// The screenplay's own emphasis — a parenthetical's italics, a heading's
    /// weight — is folded in with the writer's, so a bolded word inside a
    /// scene heading does not un-bold the heading around it.
    private func line(_ text: String, _ block: Block) -> Text {
        let family = ScriptFont(serverValue: block.font) ?? .default
        return Text(text.isEmpty ? " " : text)
            .font(.custom(family.postScriptName, fixedSize: fontSize))
            .fontWeight(weight(for: block))
            .italic(isItalic(block))
            .underline(block.textUnderline ?? false)
    }

    private func weight(for block: Block) -> Font.Weight {
        if block.textBold ?? false { return .bold }
        switch block.blockType {
        case .scene: return .bold
        case .shot, .section: return .semibold
        default: return .regular
        }
    }

    private func isItalic(_ block: Block) -> Bool {
        if block.textItalic ?? false { return true }
        return block.blockType == .parenthetical || block.blockType == .lyrics
    }

    /// An explicit alignment set by the writer wins; otherwise the element sits
    /// where its own case in the switch above puts it.
    private func alignment(_ block: Block) -> Alignment {
        switch TextAlign(serverValue: block.textAlign) {
        case .center: return .center
        case .right: return .trailing
        case .left, .none: return .leading
        }
    }

    /// An element's indent from the left of the column, as the fraction of the
    /// printed six inches it occupies on paper. Clamped against the box's own
    /// width so a narrowed column — a phone, a split-view slice, where the
    /// speech boxes have already given up their proportions to stay writable —
    /// cannot indent a box off its own right edge.
    private func indent(_ box: ScreenplayLayout.ElementBox,
                        width: CGFloat? = nil) -> CGFloat {
        let full = columnWidth * CGFloat(box.indentFraction)
        guard let width else { return full }
        return min(full, max(0, columnWidth - width))
    }

    private func parenthesized(_ text: String) -> String {
        text.hasPrefix("(") ? text : "(\(text))"
    }

    private func displayText(for block: Block) -> String {
        let content = block.content ?? ""
        if content.isEmpty, block.blockType.isCharacterCue, let name = block.personName {
            return name
        }
        return content
    }

    @ViewBuilder
    private var emptyState: some View {
        if readableBlocks.isEmpty {
            if isLoading {
                ProgressView()
            } else {
                ContentUnavailableView(
                    "Nothing to Read",
                    systemImage: "book",
                    description: Text("This script has no elements yet."))
            }
        }
    }
}

private extension View {
    /// Placed at a screenplay indent, in a row that still spans the column —
    /// the row has to keep its full width or the lazy stack would size itself
    /// to whichever element it happened to have built.
    func indented(by indent: CGFloat) -> some View {
        padding(.leading, indent)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A speech element: a box of its own width, at its own indent.
    func speechBox(width: CGFloat, indent: CGFloat) -> some View {
        frame(maxWidth: width, alignment: .leading)
            .indented(by: indent)
    }
}
