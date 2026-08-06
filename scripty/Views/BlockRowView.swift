//
//  BlockRowView.swift
//  scripty
//
//  Typographic rendering of one screenplay element, roughly following
//  screenplay page conventions inside a centered page column.
//

import SwiftUI
import UIKit

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

/// Which of a row's marks are drawn, where each element sits, and how wide its
/// text column runs.
///
/// Carried in the environment rather than passed down: rows are built in three
/// places — the editor, the pagination preview and the bulk-action strip — and
/// only the script page has the project's view options to hand. Somewhere
/// without them gets the defaults, which is how the rows have always looked.
///
/// It is also what the reading surface lays itself out with, which is the point
/// of the geometry living here rather than in a row: the column, the margins and
/// every element's indent are worked out once for the screen, so an element
/// stays exactly where it was when the script is handed between writing and
/// reading. Two surfaces measuring for themselves is what used to move it.
struct ScriptRowChrome: Equatable {
    /// The printed six-inch measure in points — the column at its full size.
    ///
    /// Sixty characters of `ProseFont.baseSize` in the shipped face, which is
    /// what makes this six inches rather than 711 points: the two are one
    /// setting written twice, and the note on `baseSize` is where the pair is
    /// reckoned. Grow the type without growing this and the writing column
    /// breaks its lines short of where the page does.
    static let printedMeasure: CGFloat = 711

    var showsPins = true
    var showsBookmarks = true
    var showsElementLabels = false
    /// The text column, in points: the printed six-inch measure by default,
    /// the window's width when the window is narrower than the measure, or
    /// the width of whatever contains the row when full width is on.
    var columnWidth: CGFloat = ScriptRowChrome.printedMeasure
    /// The type scale the column was resolved at.
    ///
    /// A measure is a count of characters before it is a width, so the printed
    /// proportions are reckoned *before* the writer's type size is applied and
    /// the answer scaled back up with it. That is what keeps the same sixty
    /// characters on a line as the type grows, and it is why the column has to
    /// remember the size it was resolved at.
    var scale: CGFloat = 1

    /// The OS text-size setting on its own, without the writer's own A−/A+
    /// folded in.
    ///
    /// Only the element labels need it, and they need it separately: the label
    /// is a fixed 9pt tag whose *width* the writing column is inset by, so it
    /// has to grow with Dynamic Type or PARENTHETICAL ellipsizes at an
    /// accessibility size. Growing it with `scale` as well would move the
    /// gutter at every A−/A+ setting, which is a visible layout change for
    /// every writer who has touched that control — and one they did not ask
    /// for by making their system type bigger.
    var dynamicTypeScale: CGFloat = 1

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

    /// The column before the type size was applied — the width the printed
    /// proportions are compared against.
    private var measure: CGFloat {
        scale > 0 ? columnWidth / scale : columnWidth
    }

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
        if measure >= Self.printedMeasure {
            return columnWidth * CGFloat(box.widthFraction)
        }
        return min(columnWidth * CGFloat(phoneFraction),
                   Self.printedMeasure * CGFloat(box.widthFraction) * scale)
    }

    // MARK: - Where an element sits

    /// The width of the box an element's text is set in. Everything that is not
    /// speech runs the whole column, exactly as it does on paper.
    func width(for type: BlockType) -> CGFloat {
        switch type {
        case .dialogue, .lyrics: return dialogueWidth
        case .parenthetical: return parentheticalWidth
        // A cue runs from its indent to the right margin — it has no box of its
        // own, which is the printed page's answer for it too.
        case .character, .dualDialogue: return max(0, columnWidth - indent(for: type))
        default: return columnWidth
        }
    }

    /// How far in from the left of the column that box starts: the element's
    /// real screenplay indent, as a fraction of the six-inch measure.
    ///
    /// Speech used to be *centred* in the column here while the reading surface
    /// and the printed page put it at these indents, so every cue and every line
    /// of dialogue moved sideways the moment the script was handed from one to
    /// the other. There is one answer now and this is it.
    ///
    /// Clamped against the box's own width so a narrowed column — a phone, a
    /// split-view slice, where the speech boxes have already given up their
    /// proportions to stay writable — cannot indent a box off its own right edge.
    func indent(for type: BlockType) -> CGFloat {
        switch type {
        case .character, .dualDialogue:
            return columnWidth * CGFloat(ScreenplayLayout.characterBox.indentFraction)
        case .dialogue, .lyrics:
            return indent(ScreenplayLayout.dialogueBox, width: dialogueWidth)
        case .parenthetical:
            return indent(ScreenplayLayout.parentheticalBox, width: parentheticalWidth)
        default:
            return 0
        }
    }

    private func indent(_ box: ScreenplayLayout.ElementBox, width: CGFloat) -> CGFloat {
        min(columnWidth * CGFloat(box.indentFraction), max(0, columnWidth - width))
    }
}

extension View {
    /// Places an element where the screenplay puts it: a box of its own width,
    /// at its own indent from the left of the column.
    ///
    /// The row still spans the whole column afterwards, so a lazy stack cannot
    /// size itself to whichever element it happened to have built — and, being
    /// shared by the writing column and the reading surface, an element is in
    /// the same place on both.
    func screenplayBox(_ type: BlockType,
                       in chrome: ScriptRowChrome,
                       alignment: Alignment = .leading) -> some View {
        frame(maxWidth: chrome.width(for: type), alignment: alignment)
            .padding(.leading, chrome.indent(for: type))
            .frame(maxWidth: chrome.columnWidth, alignment: .leading)
    }
}

extension Block {
    /// Where this element's lines sit inside their own box, as UIKit wants it.
    ///
    /// One answer for all three surfaces: the writer's own alignment where they
    /// set one, and otherwise the element's — centred for a centred element,
    /// right for a transition, left for everything else. It used to be resolved
    /// separately by the text views and by the two read-only surfaces, in two
    /// different types, which is two chances to disagree about a line the writer
    /// centred.
    var nsTextAlignment: NSTextAlignment {
        if let override = TextAlign(serverValue: textAlign) {
            switch override {
            case .left: return .left
            case .center: return .center
            case .right: return .right
            }
        }
        switch blockType {
        case .centered: return .center
        case .transition: return .right
        default: return .left
        }
    }
}

/// One element of a screenplay that cannot be typed into: the reading surface's
/// line, and a locked row's.
///
/// A `UITextView` rather than SwiftUI `Text`, and that is the whole point of it.
/// SwiftUI and TextKit break lines differently — at the identical width in the
/// identical font, SwiftUI gives up on a word roughly one earlier — so a wrapped
/// element came out with a different number of lines on the surface the writer
/// was reading from than on the one they had been typing into, and everything
/// below it moved down the page. The writing column is a `UITextView`
/// (`BlockTextView`), so these are too, set up the same way: same font, same
/// alignment, same underline attribute, same zero insets.
///
/// Deliberately inert — not selectable, no gestures of its own. It is a
/// renderer. Everything a reader can do to a line (two taps to write in it, hold
/// for the menu) belongs to the row around it, and a text view that answered
/// touches itself would swallow both.
struct ScriptText: UIViewRepresentable {
    let text: String
    let font: UIFont
    let alignment: NSTextAlignment
    let isUnderlined: Bool
    /// Drawn in the secondary colour: sections and synopses, which are the
    /// writer's own marginalia rather than the script.
    var isSecondary = false

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = false
        view.isScrollEnabled = false
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        // Spoken by the row, which names the element type and reads the whole
        // of it — see `BlockRowView.accessibilityDescription`.
        view.isAccessibilityElement = false
        apply(to: view)
        return view
    }

    /// Wrap at the width SwiftUI offers rather than at the text's own idea of
    /// how wide it wants to be — and round the height up exactly as the
    /// editable row does, so the two stack to the same place.
    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView: UITextView,
                      context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        let fitted = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitted.height))
    }

    func updateUIView(_ view: UITextView, context: Context) {
        apply(to: view)
    }

    @MainActor
    private func apply(to view: UITextView) {
        let colour: UIColor = isSecondary ? .secondaryLabel : .label
        // One assignment, as an attributed string: the underline is the one
        // style a `UIFont` cannot carry, and nothing here is ever typed into,
        // so there is no caret arithmetic to protect the way `BlockTextView`
        // has to protect its own.
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: colour
        ]
        if isUnderlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        attributes[.paragraphStyle] = paragraph

        let attributed = NSAttributedString(string: text, attributes: attributes)
        if view.attributedText != attributed { view.attributedText = attributed }
    }
}

/// The screenplay's name, at the head of the column — on both surfaces.
///
/// Here rather than in either of them for the reason the chrome above is here:
/// the writing column and the reader each head the page with the project's
/// title, and each resolved the type for itself. They disagreed twice. The
/// column asked for the *shipped* face rather than the writer's chosen one, so a
/// script set in Times was headed in Courier until it was read; and it sized the
/// heading against the writer's type control alone while the reader folded
/// Dynamic Type in as well, so at any OS text size but the default the two names
/// were set at different sizes and everything under them started at a different
/// height.
@MainActor
enum ScriptTitleType {
    /// The heading's size: one line of the column, at whatever scale the screen
    /// resolved — which carries the writer's type-size control and the system's
    /// Dynamic Type setting together, exactly as the elements below it do.
    static func size(scale: CGFloat) -> CGFloat { ProseFont.baseSize * scale }

    /// The script's own face — the writer's chosen default, never the shipped
    /// one, for the reason `ScriptFont.element` gives.
    ///
    /// Bold in the font itself rather than through `.fontWeight`, because the
    /// writing column's heading is a `TextField` while it is being typed over,
    /// and a weight modifier on the view around a field does not reach the text
    /// inside it.
    static func font(scale: CGFloat) -> Font {
        Font(PresentationSettings.shared.defaultFont
            .uiFont(size: size(scale: scale), traits: .traitBold))
    }

    /// The air under it: two blank lines, the way a title page leaves them.
    static func gap(scale: CGFloat) -> CGFloat { size(scale: scale) * 2 }
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
    /// The OS text-size setting as a multiplier — `ScriptRowChrome
    /// .dynamicTypeScale`, which is also what sized the gutter this label
    /// hangs in. The two must be given the same number or the label either
    /// truncates or overlaps the words it names.
    var dynamicTypeScale: CGFloat = 1

    /// Room for the longest of them, PARENTHETICAL, without an ellipsis.
    ///
    /// A function of the type size rather than a constant: an absolute 9pt
    /// ignored Dynamic Type entirely, so the tag stayed 9pt at every
    /// accessibility size — and simply scaling the font without the width
    /// would have ellipsized PARENTHETICAL instead.
    static func width(scale: CGFloat) -> CGFloat { 94 * scale }
    /// That, plus the gap between the label and the text it names.
    static func gutter(scale: CGFloat) -> CGFloat { width(scale: scale) + 12 * scale }

    var body: some View {
        Text(type.label.uppercased())
            .font(.system(size: 9 * dynamicTypeScale, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .frame(width: Self.width(scale: dynamicTypeScale), alignment: .trailing)
            .offset(x: -Self.gutter(scale: dynamicTypeScale))
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

    /// A dot in the tint, for the menus that offer the colours.
    ///
    /// Drawn rather than named: a menu renders a `systemImage` as a template
    /// and paints it in the menu's own label colour, so five `circle.fill`
    /// rows come out as five identical black dots and the one thing the row
    /// is choosing is the one thing it cannot show. An image handed over as
    /// `.alwaysOriginal` is the way past that.
    ///
    /// The ring is what keeps the washes legible: they are paper tints meant
    /// to sit behind text, and pale yellow on a white menu reads as an empty
    /// circle without an edge drawn round it.
    ///
    /// Drawn once for all ten — five colours either side of light and dark —
    /// and looked up thereafter. One caller is a `contextMenu` builder, which
    /// takes its items as a plain (non-escaping) closure and so may well be
    /// run with the row's body rather than when the menu is opened; that body
    /// is re-evaluated on every keystroke in the element beside it. Ten small
    /// bitmaps held for the life of the app is the cheaper end of that bet.
    func swatch(for scheme: ColorScheme) -> Image {
        Self.swatches[Swatch(colour: self, scheme: scheme)] ?? drawSwatch(for: scheme)
    }

    private func drawSwatch(for scheme: ColorScheme) -> Image {
        let side: CGFloat = 16
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let drawn = renderer.image { _ in
            let circle = UIBezierPath(ovalIn: CGRect(x: 0.5, y: 0.5,
                                                     width: side - 1, height: side - 1))
            UIColor(color(for: scheme)).setFill()
            circle.fill()
            UIColor(white: scheme == .dark ? 1 : 0, alpha: 0.3).setStroke()
            circle.lineWidth = 1
            circle.stroke()
        }
        return Image(uiImage: drawn.withRenderingMode(.alwaysOriginal))
    }

    private struct Swatch: Hashable {
        let colour: BlockHighlight
        let scheme: ColorScheme
    }

    private static let swatches: [Swatch: Image] = {
        var drawn: [Swatch: Image] = [:]
        for colour in BlockHighlight.allCases {
            for scheme in [ColorScheme.light, .dark] {
                drawn[Swatch(colour: colour, scheme: scheme)] = colour.drawSwatch(for: scheme)
            }
        }
        return drawn
    }()
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

/// An element's tags, under it as small badges — the way the web row shows
/// them. Nothing is drawn when a block has none, which is most of them.
///
/// Drawn by the editable row as well as the read-only one. They used to belong
/// to the read-only row alone, so locking editing grew a badge under every
/// tagged element and pushed the rest of the script down the page; and a tag was
/// something the writer could set from the element menu and then never see.
struct BlockTagRow: View {
    let block: Block

    var body: some View {
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
            // Spoken as part of the element's own label on both rows.
            .accessibilityHidden(true)
        }
    }
}

/// A note's yellow card, and nothing at all for every other element.
///
/// Shared by the read-only and the editable row for the same reason the
/// highlight is: the card carries eight points of padding, and a note that had
/// it in one row and not in the other stepped sideways the moment editing was
/// locked.
struct NoteCard: ViewModifier {
    let type: BlockType

    func body(content: Content) -> some View {
        if type == .note {
            content
                .padding(8)
                .background(Color.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
        } else {
            content
        }
    }
}

extension View {
    func noteCard(_ type: BlockType) -> some View {
        modifier(NoteCard(type: type))
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
    /// the speech boxes are placed at the real screenplay proportions rather
    /// than at hand-picked numbers — see `ScriptRowChrome`, which resolves both
    /// their widths and their indents against the room the column actually has.
    private var pageWidth: CGFloat { chrome.columnWidth }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            elementView
                // How the lines of a wrapped element line up with each other is
                // the text view's own business now — `ScriptText` carries the
                // block's alignment in its paragraph style, the way the
                // editable row hands `BlockTextView` the same value.
                .blockHighlight(block)
            BlockTagRow(block: block)
        }
        // The air above the element, in the screenplay's own line units rather
        // than in numbers picked per type — the same rule the reader and the
        // paginator use, so the rhythm of the page survives a mode change.
        .padding(.top, topSpacing)
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

    /// The read-only case for this block's text: the web's per-element caps as
    /// a display transform, honouring the same auto-caps preference the editor
    /// obeys while typing. A bare `.uppercased()` would force a toggled-off
    /// element to caps here even though the editor leaves it in typed case.
    private func cased(_ content: String) -> String {
        CapitalizationSettings.shared.displayCased(content, forBlockType: block.blockType)
    }

    // The weight and the italics live in the font itself now — see
    // `styledText` — so a case here only says where the element sits and what
    // colour it is drawn in. A `.fontWeight` or a `.font` of its own is what
    // used to make a locked line come out a different size from the editable
    // one it replaced, and take the rest of the script with it.
    @ViewBuilder
    private var elementView: some View {
        switch block.blockType {
        case .scene:
            styledText(cased(displayContent))
                .frame(maxWidth: .infinity, alignment: alignment)

        case .character, .dualDialogue:
            styledText(cased(displayContent))
                .screenplayBox(block.blockType, in: chrome)

        case .dialogue:
            styledText(displayContent)
                .screenplayBox(block.blockType, in: chrome)

        case .parenthetical:
            styledText(parenthesized(displayContent))
                .screenplayBox(block.blockType, in: chrome)

        case .transition:
            styledText(cased(displayContent))
                .frame(maxWidth: .infinity, alignment: .trailing)

        case .shot:
            styledText(cased(displayContent))
                .frame(maxWidth: .infinity, alignment: alignment)

        case .centered:
            styledText(displayContent)
                .frame(maxWidth: .infinity, alignment: .center)

        case .lyrics:
            styledText(displayContent)
                .screenplayBox(block.blockType, in: chrome)

        case .section:
            styledText(displayContent, secondary: true)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .synopsis:
            styledText(displayContent, secondary: true)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .note:
            styledText(displayContent)
                .noteCard(block.blockType)
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
            ElementLabelTag(type: block.blockType,
                            dynamicTypeScale: chrome.dynamicTypeScale)
                .padding(.top, topSpacing + 3)
        }
    }

    /// The space this element leaves above its first line, which is also where
    /// its marks and its label belong — a pin drawn at the top of a scene
    /// heading's row floats clear of the heading and looks like it belongs to
    /// the line before.
    private var topSpacing: CGFloat {
        CGFloat(ScreenplayLayout.spacing(for: block.blockType,
                                         lineHeight: Double(fontSize)))
    }

    private var markerTopInset: CGFloat { topSpacing }

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

    /// One line of a locked element, through the same text engine the writer
    /// types into — see `ScriptText`. `secondary` is the marginalia colour a
    /// section and a synopsis are drawn in, which used to be a
    /// `.foregroundStyle` on the view and cannot be, now that the view is a
    /// text view that colours its own glyphs.
    private func styledText(_ string: String, secondary: Bool = false) -> some View {
        ScriptText(text: string.isEmpty ? " " : string,
                   font: ScriptFont.element(block, size: fontSize),
                   alignment: block.nsTextAlignment,
                   isUnderlined: block.textUnderline ?? false,
                   isSecondary: secondary)
    }

    /// One line of the writing column, in points — the same base every other
    /// prose surface is set from, at the writer's chosen scale.
    private var fontSize: CGFloat { ProseFont.baseSize * CGFloat(textScale) }
}
