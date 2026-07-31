//
//  ReadScriptView.swift
//  scripty
//
//  Read Script mode: the screenplay as prose, for reading rather than writing.
//  Ported from the web app's reader template, which drops the editing chrome,
//  sets the script in a serif face at a comfortable measure, and leaves out the
//  working annotations — synopses and notes are for the writer, not the reader.
//
//  Deliberately not a page-accurate view; that is what page view is for. This
//  one optimises for reading on a screen.
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

    /// The reader's measure: roughly the 40rem column the web app uses.
    ///
    /// Scaled with the type, because a measure is a count of characters before
    /// it is a width. Held at a fixed 640 points it was the right line length
    /// at the default size and a narrower and narrower ribbon above it — worst
    /// exactly where the extra room a bigger window brings should be going.
    private var measure: CGFloat { 640 * scale }

    /// The OS text-size setting, as a multiplier.
    ///
    /// This view sets its type in fixed points to hold the reader's
    /// proportions — a scene heading is deliberately a shade larger than the
    /// prose — which meant it ignored Dynamic Type entirely. Folding the
    /// setting in as a *multiplier* keeps those proportions while still
    /// honouring the size someone chose system-wide, and composes with the
    /// script's own type-size control rather than overriding it.
    @ScaledMetric(relativeTo: .body) private var dynamicTypeScale: CGFloat = 1

    private var scale: CGFloat { CGFloat(textScale) * dynamicTypeScale }

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
                    Text(title.isEmpty ? "Untitled Project" : title)
                        .font(.system(size: 28 * scale, weight: .bold, design: .serif))
                        .padding(.bottom, 24)

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
                .frame(maxWidth: measure, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
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

    @ViewBuilder
    private func row(_ block: Block, isFirst: Bool) -> some View {
        let text = displayText(for: block)

        switch block.blockType {
        case .scene:
            VStack(alignment: .leading, spacing: 0) {
                if !isFirst {
                    Divider().padding(.bottom, 16)
                }
                Text(cased(text, block))
                    .font(.system(size: 17 * scale, weight: .bold, design: .serif))
                    .tracking(0.7)
                    // Read back in its written case: VoiceOver spells out
                    // all-caps runs letter by letter, which turns every scene
                    // heading into an initialism.
                    .accessibilityLabel(text)
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(.top, isFirst ? 0 : 16)
            .padding(.bottom, 16)

        case .section:
            Text(text)
                .font(.system(size: 20 * scale, weight: .semibold, design: .serif))
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 20)
                .padding(.bottom, 12)

        case .character, .dualDialogue:
            Text(cased(text, block))
                .font(.system(size: 16 * scale, weight: .bold, design: .serif))
                .tracking(0.9)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityLabel(text)
                .padding(.top, 12)
                .padding(.bottom, 4)

        case .parenthetical:
            prose(text.hasPrefix("(") ? text : "(\(text))", block: block)
                .italic()
                .frame(maxWidth: .infinity, alignment: .center)

        case .dialogue, .lyrics:
            prose(text, block: block)
                .italic(block.blockType == .lyrics)
                .padding(.horizontal, 32)
                .padding(.bottom, 14)

        case .transition:
            prose(cased(text, block), block: block)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.vertical, 10)

        case .centered:
            prose(text, block: block)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 14)

        default:
            VStack(alignment: .leading, spacing: 4) {
                // The reader labels a speaker that is attached to a non-cue
                // element, since there is no cue line to carry the name.
                if let name = block.personName, !name.isEmpty,
                   !block.blockType.isCharacterCue {
                    Text(name.uppercased())
                        .font(.system(size: 15 * scale, weight: .bold, design: .serif))
                        .tracking(0.9)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                prose(text, block: block)
            }
            .padding(.bottom, 14)
        }
    }

    /// Body copy shared by the prose-like elements, honouring the writer's
    /// character formatting but not the screenplay indents.
    private func prose(_ text: String, block: Block) -> Text {
        var result = Text(text.isEmpty ? " " : text)
            .font(.system(size: 17 * scale, design: .serif))
        if block.textBold ?? false { result = result.bold() }
        if block.textItalic ?? false { result = result.italic() }
        if block.textUnderline ?? false { result = result.underline() }
        return result
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
