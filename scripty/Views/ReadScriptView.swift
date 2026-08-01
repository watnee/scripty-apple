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
//  It shares that geometry literally rather than by agreement: the column, the
//  margins, the indents and the type size all arrive in `ScriptRowChrome`,
//  worked out once by the screen for whichever surface is up. This view used to
//  measure the window and resolve a column of its own, and being a *slightly*
//  different answer is what made entering the mode slide every line of the
//  script sideways — which is a worse fault than being wrong, because the writer
//  cannot say what moved, only that something did.
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

    /// The column, the margins and every element's indent, worked out once for
    /// the whole script screen — the writing surface draws from the same value.
    ///
    /// This view used to measure the window and resolve a column of its own,
    /// which is what made entering the mode move the script sideways: two
    /// surfaces answering the same question, each with a slightly different
    /// margin and each placing speech its own way. The answer is the screen's
    /// now, so a line is in the same place in both.
    @Environment(\.scriptRowChrome) private var chrome
    /// The type size the writing column is set at, so switching into the mode
    /// re-typesets the script rather than resizing it. It carries the writer's
    /// own type-size control and the system's Dynamic Type setting together —
    /// see `ScriptView.textScale`.
    @Environment(\.scriptTextScale) private var textScale

    /// Room kept either side of the column, matching the writing column's own
    /// row padding — the chrome's widths were measured against it.
    private static let horizontalPadding: CGFloat = 24

    private var fontSize: CGFloat { ProseFont.baseSize * CGFloat(textScale) }

    /// Whether the remembered position has been restored. Until it has, the
    /// scroll spy stays quiet — the first rows to appear are the top of the
    /// script, and recording those would overwrite the very thing being
    /// restored. State rather than a constant because the blocks may land
    /// after the mode is entered, and the restore has to wait for them.
    @State private var hasRestoredPosition = false

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
                .frame(maxWidth: chrome.columnWidth, alignment: .leading)
                // The margins the writing column keeps for what hangs in them —
                // the element labels on the left, the marks on the right. The
                // reader draws neither, but it leaves the same room: giving the
                // column back those points would slide every line of the script
                // sideways on the way into the mode, which is the whole thing
                // this surface is trying not to do.
                .padding(.leading, chrome.leadingGutter)
                .padding(.trailing, chrome.trailingGutter)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Self.horizontalPadding)
                .padding(.vertical, 24)
                .textSelection(.enabled)
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
            .font(.custom(PresentationSettings.shared.defaultFont.postScriptName,
                          fixedSize: fontSize))
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

    /// Blank lines above an element, in the same line units the paginator, the
    /// printed page and the writing column use: two above a scene heading, none
    /// between a cue and what it says, one everywhere else. Set solid, so a
    /// line is the type size.
    private func spacing(for type: BlockType) -> CGFloat {
        CGFloat(ScreenplayLayout.spacing(for: type, lineHeight: Double(fontSize)))
    }

    @ViewBuilder
    private func row(_ block: Block, isFirst: Bool) -> some View {
        element(block)
            // How the lines of a wrapped element line up with each other, the
            // way the writing column's text views set it — a centred element
            // centres each of its lines rather than centring as a block.
            .multilineTextAlignment(multilineAlignment(block))
            .padding(.top, isFirst ? 0 : spacing(for: block.blockType))
    }

    /// See `EditableBlockRow.nsAlignment`, which answers the same question for
    /// the surface this one replaces.
    private func multilineAlignment(_ block: Block) -> TextAlignment {
        if let override = TextAlign(serverValue: block.textAlign) {
            switch override {
            case .left: return .leading
            case .center: return .center
            case .right: return .trailing
            }
        }
        switch block.blockType {
        case .centered: return .center
        case .transition: return .trailing
        default: return .leading
        }
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
                .screenplayBox(block.blockType, in: chrome)

        case .parenthetical:
            line(parenthesized(text), block)
                .screenplayBox(block.blockType, in: chrome)

        case .dialogue, .lyrics:
            line(text, block)
                .screenplayBox(block.blockType, in: chrome)

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
                        .screenplayBox(.character, in: chrome)
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
    ///
    /// Resolved through `ScriptFont.element`, which is what the writing column
    /// asks for too: the same face at the same size measures the same, so a
    /// line breaks in the same place on both surfaces and everything under it
    /// stays where it was.
    private func line(_ text: String, _ block: Block) -> Text {
        Text(text.isEmpty ? " " : text)
            .font(Font(ScriptFont.element(block, size: fontSize)))
            .underline(block.textUnderline ?? false)
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
