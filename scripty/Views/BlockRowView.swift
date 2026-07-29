//
//  BlockRowView.swift
//  scripty
//
//  Typographic rendering of one screenplay element, roughly following
//  screenplay page conventions inside a centered page column.
//

import SwiftUI

/// The writer's chosen type size, as a multiplier. Read by every element row
/// so one setting scales the whole script.
private struct ScriptTextScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

extension EnvironmentValues {
    var scriptTextScale: Double {
        get { self[ScriptTextScaleKey.self] }
        set { self[ScriptTextScaleKey.self] = newValue }
    }
}

/// Which of a row's marks are drawn, and how wide its text column runs.
///
/// Carried in the environment rather than passed down: rows are built in three
/// places — the editor, the pagination preview and the bulk-action strip — and
/// only the script page has the project's view options to hand. Somewhere
/// without them gets the defaults, which is how the rows have always looked.
struct ScriptRowChrome: Equatable {
    /// The printed six-inch measure in points — the column at its full size.
    static let printedMeasure: CGFloat = 640

    var showsPins = true
    var showsBookmarks = true
    var showsElementLabels = false
    /// The text column, in points: the printed six-inch measure by default,
    /// the window's width when the window is narrower than the measure, or
    /// the width of whatever contains the row when full width is on.
    var columnWidth: CGFloat = ScriptRowChrome.printedMeasure
    /// Whether that width was measured against the window rather than being the
    /// fixed measure. The editable row grows its column with the type size, and
    /// a measured width must not be grown a second time.
    var isFullWidth = false

    /// The room kept beside the column for what hangs in the margins: the
    /// element labels on the left, the marks on the right.
    ///
    /// Equal on both sides where the window can afford it, so the column stays
    /// centred on the page; lopsided where it cannot, because a phone would
    /// rather give up one margin than have text run under a badge. Somewhere
    /// without a script page to measure — a preview, the bulk-action strip —
    /// keeps the marks' side and nothing else.
    var leadingGutter: CGFloat = 0
    var trailingGutter: CGFloat = BlockMarkerBadges.gutter

    /// The dialogue column, in points. On the full measure this is the printed
    /// 3.5in-of-6in proportion, and a widened column keeps that proportion so a
    /// full-width script is still recognisably a script. A *narrowed* column
    /// does not: 58% of a phone is too little to write in, so the box holds its
    /// printed size while it fits and then follows the web's phone stylesheet —
    /// `max-width: min(78%, 3.5in)` — down.
    var dialogueWidth: CGFloat {
        speechWidth(ScreenplayLayout.dialogueBox, phoneFraction: 0.78)
    }

    /// The parenthetical column, the same way: 2in of 6in on the measure, 55%
    /// of the column on a phone (the web's `min(55%, …)` rule).
    var parentheticalWidth: CGFloat {
        speechWidth(ScreenplayLayout.parentheticalBox, phoneFraction: 0.55)
    }

    private func speechWidth(_ box: ScreenplayLayout.ElementBox,
                             phoneFraction: Double) -> CGFloat {
        if columnWidth >= Self.printedMeasure {
            return columnWidth * CGFloat(box.widthFraction)
        }
        return min(columnWidth * CGFloat(phoneFraction),
                   Self.printedMeasure * CGFloat(box.widthFraction))
    }
}

private struct ScriptRowChromeKey: EnvironmentKey {
    static let defaultValue = ScriptRowChrome()
}

extension EnvironmentValues {
    var scriptRowChrome: ScriptRowChrome {
        get { self[ScriptRowChromeKey.self] }
        set { self[ScriptRowChromeKey.self] = newValue }
    }
}

/// The element's type, set small in the left margin — the counterpart of the
/// web row's element label. Hidden unless the writer asks for it.
///
/// Offset out of the text column rather than laid out beside it: the column is
/// the printed measure and must not move when the labels are switched on, or
/// every line in the script would re-wrap. The margin is made wide enough to
/// hold them in `ScriptView.rowChrome` instead.
struct ElementLabelTag: View {
    let type: BlockType

    /// Room for the longest of them, PARENTHETICAL, without an ellipsis.
    static let width: CGFloat = 94
    /// That, plus the gap between the label and the text it names.
    static let gutter: CGFloat = width + 12

    var body: some View {
        Text(type.label.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .frame(width: Self.width, alignment: .trailing)
            .offset(x: -Self.gutter)
            .accessibilityHidden(true)
    }
}

extension BlockHighlight {
    /// The tints from the web app's stylesheet, so a highlighted line looks the
    /// same in either client. Each carries a light and a dark value — a
    /// paper-coloured wash would go muddy in dark mode.
    func color(for scheme: ColorScheme) -> Color {
        let light: (Double, Double, Double)
        let dark: (Double, Double, Double)
        switch self {
        case .yellow:
            light = (0.992, 0.953, 0.827); dark = (0.294, 0.235, 0.078)
        case .green:
            light = (0.875, 0.949, 0.890); dark = (0.122, 0.251, 0.161)
        case .blue:
            light = (0.859, 0.914, 0.973); dark = (0.110, 0.227, 0.333)
        case .red:
            light = (0.984, 0.878, 0.867); dark = (0.302, 0.153, 0.141)
        case .gray:
            light = (0.914, 0.925, 0.937); dark = (0.227, 0.259, 0.314)
        }
        let (r, g, b) = scheme == .dark ? dark : light
        return Color(red: r, green: g, blue: b)
    }
}

/// Paints a block's highlight tint behind its text, and nothing when it has
/// none. Shared so the read-only and editable rows tint identically.
struct BlockHighlightBackground: ViewModifier {
    let block: Block
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if let highlight = BlockHighlight(serverValue: block.highlight) {
            content
                .padding(.horizontal, 4)
                .background(highlight.color(for: colorScheme),
                            in: RoundedRectangle(cornerRadius: 3))
        } else {
            content
        }
    }
}

extension View {
    func blockHighlight(_ block: Block) -> some View {
        modifier(BlockHighlightBackground(block: block))
    }
}

struct BlockRowView: View {
    let block: Block
    /// How many comments sit on this element. Defaults to none so the row can
    /// still be rendered somewhere the counts aren't loaded — the bulk-action
    /// preview strip, for one.
    var commentCount: Int = 0
    /// Opens this element's comment thread. Handed in by the script page, which
    /// owns the sheet; nil elsewhere, and then the bubble is a badge only.
    var onComment: (() -> Void)?

    @Environment(\.scriptTextScale) private var textScale
    @Environment(\.scriptRowChrome) private var chrome

    /// The continuous column stands in for the printed six-inch text block, so
    /// the speech widths are the real screenplay proportions rather than
    /// hand-picked numbers — see `ScriptRowChrome`, which resolves them against
    /// the room the column actually has.
    private var pageWidth: CGFloat { chrome.columnWidth }
    private var dialogueWidth: CGFloat { chrome.dialogueWidth }
    private var parentheticalWidth: CGFloat { chrome.parentheticalWidth }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            elementView
                .blockHighlight(block)
            tagRow
        }
        .frame(maxWidth: pageWidth, alignment: .leading)
        // The label hangs off the column, so it is attached here rather than to
        // the centring frame below — otherwise it would sit at the far left of
        // the window instead of beside the line it names.
        .overlay(alignment: .topLeading) { elementLabel }
        // A screenplay is carried by which *kind* of line each one is: sighted
        // readers get that from the indentation and the capitalisation, both of
        // which are purely visual. Without naming the type, VoiceOver reads a
        // scene heading, a character cue and a transition identically.
        //
        // Applied to the text rather than to the whole row: the marks hang off
        // it, and one of them is the button that opens the thread — swallowing
        // the row's children would take the only route to it on a line that
        // cannot be edited.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .blockMarkers(block, commentCount: commentCount,
                      topInset: markerTopInset, onComment: onComment)
        .frame(maxWidth: .infinity)
    }

    private var accessibilityDescription: String {
        if block.blockType == .pageBreak { return "Page break" }

        var parts = [block.blockType.label]
        let content = displayContent.trimmingCharacters(in: .whitespacesAndNewlines)
        parts.append(content.isEmpty ? "empty" : content)

        let tags = block.tagList
        if !tags.isEmpty {
            parts.append("Tagged " + tags.joined(separator: ", "))
        }
        // Only the marks that are actually drawn: a writer who has hidden the
        // pins has said they are not interested in hearing about them either.
        if block.isPinned && chrome.showsPins { parts.append("Pinned") }
        if block.isBookmarked && chrome.showsBookmarks { parts.append("Bookmarked") }
        if let comments = CommentCountBadge.spokenLabel(commentCount) {
            parts.append(comments)
        }
        return parts.joined(separator: ". ")
    }

    /// Tags sit under the element as small badges, the way the web row shows
    /// them. Nothing is drawn when a block has none.
    @ViewBuilder
    private var tagRow: some View {
        let tags = block.tagList
        if !tags.isEmpty {
            HStack(spacing: 4) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The read-only case for this block's text: the web's per-element caps as
    /// a display transform, honouring the same auto-caps preference the editor
    /// obeys while typing. A bare `.uppercased()` would force a toggled-off
    /// element to caps here even though the editor leaves it in typed case.
    private func cased(_ content: String) -> String {
        CapitalizationSettings.shared.displayCased(content, forBlockType: block.blockType)
    }

    @ViewBuilder
    private var elementView: some View {
        switch block.blockType {
        case .scene:
            styledText(cased(displayContent))
                .fontWeight(.bold)
                .frame(maxWidth: .infinity, alignment: alignment)
                .padding(.top, 18)

        case .character, .dualDialogue:
            styledText(cased(displayContent))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 10)

        case .dialogue:
            styledText(displayContent)
                .frame(maxWidth: dialogueWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)

        case .parenthetical:
            styledText(parenthesized(displayContent))
                .italic()
                .frame(maxWidth: parentheticalWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)

        case .transition:
            styledText(cased(displayContent))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 10)

        case .shot:
            styledText(cased(displayContent))
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: alignment)
                .padding(.top, 10)

        case .centered:
            styledText(displayContent)
                .frame(maxWidth: .infinity, alignment: .center)

        case .lyrics:
            styledText(displayContent)
                .italic()
                .frame(maxWidth: dialogueWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)

        case .section:
            styledText(displayContent)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 14)

        case .synopsis:
            styledText(displayContent)
                .italic()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .note:
            styledText(displayContent)
                .font(.callout)
                .padding(8)
                .background(Color.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: .infinity, alignment: .leading)

        case .pageBreak:
            HStack(spacing: 12) {
                line
                Text("PAGE BREAK")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                line
            }
            .padding(.vertical, 8)

        case .action, .text:
            styledText(displayContent)
                .frame(maxWidth: .infinity, alignment: alignment)
        }
    }

    private var line: some View {
        Rectangle()
            .fill(.tertiary)
            .frame(height: 1)
    }

    @ViewBuilder
    private var elementLabel: some View {
        if chrome.showsElementLabels, block.blockType != .pageBreak {
            ElementLabelTag(type: block.blockType)
                .padding(.top, 3)
        }
    }

    /// The space this element leaves above its first line, which is where its
    /// marks belong — a pin drawn at the top of a scene heading's row floats
    /// clear of the heading and looks like it belongs to the line before.
    private var markerTopInset: CGFloat {
        switch block.blockType {
        case .scene: return 18
        case .section: return 14
        case .character, .dualDialogue, .transition, .shot: return 10
        case .pageBreak: return 8
        default: return 0
        }
    }

    /// Character cues carry the speaker name as content; fall back to the
    /// linked character when the content is empty.
    private var displayContent: String {
        let content = block.content ?? ""
        if content.isEmpty, block.blockType.isCharacterCue, let name = block.personName {
            return name
        }
        return content
    }

    private func parenthesized(_ text: String) -> String {
        text.hasPrefix("(") ? text : "(\(text))"
    }

    private var alignment: Alignment {
        switch TextAlign(serverValue: block.textAlign) {
        case .center: return .center
        case .right: return .trailing
        case .left, .none: return .leading
        }
    }

    private func styledText(_ string: String) -> Text {
        var text = Text(string.isEmpty ? " " : string)
            .font(baseFont)
        if block.textBold ?? false { text = text.bold() }
        if block.textItalic ?? false { text = text.italic() }
        if block.textUnderline ?? false { text = text.underline() }
        return text
    }

    private var baseFont: Font {
        let family = ScriptFont(serverValue: block.font) ?? .default
        // Fixed size: the script's own type-size control is the scale here,
        // and letting Dynamic Type multiply it again would compound the two.
        return .custom(family.postScriptName, fixedSize: 16 * textScale)
    }
}
