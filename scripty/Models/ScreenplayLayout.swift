//
//  ScreenplayLayout.swift
//  scripty
//
//  Screenplay page geometry, ported from the server's ScreenplayLayout.java so
//  the iPad lays a page out exactly the way the web app prints one. Everything
//  is expressed in inches because that is what the Java holds; the derived
//  values the views actually want (points, character columns) hang off it.
//
//  Only Character, Dialogue and Parenthetical have their own geometry. Every
//  other element shares the full six-inch action column and differs only in
//  casing, alignment and styling — matching the CSS, where the percentages are
//  just these inch values over that six-inch column.
//

import Foundation

enum ScreenplayLayout {
    // MARK: - Page

    static let pageWidthIn: Double = 8.5
    static let pageHeightIn: Double = 11.0
    static let marginLeftIn: Double = 1.5   // binding gutter
    static let marginRightIn: Double = 1.0
    static let marginTopIn: Double = 1.0
    static let marginBottomIn: Double = 1.0

    /// The printable column: 8.5 − 1.5 − 1.0.
    static let textWidthIn: Double = 6.0

    static let pointsPerInch: Double = 72.0

    // MARK: - Type

    static let fontSizePt: Double = 12.0
    /// Leading equals the type size — the CSS is `line-height: 1`.
    static let lineHeightPt: Double = 12.0
    /// One blank line between elements, carried as space *before*.
    static let elementSpacingPt: Double = 12.0
    /// Scene headings get two blank lines.
    static let sceneSpacingPt: Double = 24.0
    /// Parentheticals and dialogue hug the character cue above them.
    static let speechGroupSpacingPt: Double = 0.0

    /// Courier at 12pt is exactly ten characters to the inch, which is what
    /// makes a screenplay page countable rather than measurable.
    static let charactersPerInch: Double = 10.0

    /// 9 inches of usable height at 12pt leading. The web app's page-view
    /// divisor of 55 is one line of slack on top of this.
    static let linesPerPage: Int = 54

    // MARK: - Element geometry

    /// Indent from the left margin and column width for one element type,
    /// both in inches. A nil `widthIn` means "run to the right margin".
    struct ElementBox {
        var indentIn: Double
        var widthIn: Double?

        /// Width actually available for text, resolving the nil case.
        var textWidthIn: Double {
            widthIn ?? (ScreenplayLayout.textWidthIn - indentIn)
        }

        /// How many Courier characters fit on one line of this element.
        var columns: Int {
            max(1, Int((textWidthIn * ScreenplayLayout.charactersPerInch).rounded(.down)))
        }

        /// Indent as a fraction of the action column, which is how the CSS
        /// custom properties express it (2.2in / 6in = 36.667%, and so on).
        var indentFraction: Double {
            indentIn / ScreenplayLayout.textWidthIn
        }

        /// Width as a fraction of the action column.
        var widthFraction: Double {
            textWidthIn / ScreenplayLayout.textWidthIn
        }
    }

    static let actionBox = ElementBox(indentIn: 0.0, widthIn: 6.0)
    static let characterBox = ElementBox(indentIn: 2.2, widthIn: nil)
    static let parentheticalBox = ElementBox(indentIn: 1.5, widthIn: 2.0)
    static let dialogueBox = ElementBox(indentIn: 1.0, widthIn: 3.5)

    /// The box an element type occupies. Everything that is not a cue,
    /// parenthetical or dialogue lives in the action column.
    static func box(for type: BlockType) -> ElementBox {
        switch type {
        case .character, .dualDialogue: return characterBox
        case .parenthetical: return parentheticalBox
        case .dialogue: return dialogueBox
        default: return actionBox
        }
    }

    /// Blank lines reserved *above* an element, in line units. Dialogue and
    /// parentheticals hug the cue; scene headings get a double break.
    static func spacingLines(for type: BlockType) -> Int {
        switch type {
        case .dialogue, .parenthetical: return Int(speechGroupSpacingPt / lineHeightPt)
        case .scene: return Int(sceneSpacingPt / lineHeightPt)
        default: return Int(elementSpacingPt / lineHeightPt)
        }
    }
}
