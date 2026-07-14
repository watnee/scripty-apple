//
//  BlockStyle.swift
//  scripty
//
//  Screenplay page metrics for one element type — the single place that
//  decides how a block looks, so the text the writer types sits exactly
//  where the finished page will print it.
//

import SwiftUI

struct BlockStyle {
    var alignment: TextAlignment = .leading
    /// Width of the element's column; nil fills the page width. Dialogue and
    /// parentheticals are inset from the margins the way a script page insets them.
    var maxWidth: CGFloat?
    var isBold = false
    var isItalic = false
    var isSecondary = false
    var topPadding: CGFloat = 0

    static let pageWidth: CGFloat = 640
    static let dialogueWidth: CGFloat = 400
    static let parentheticalWidth: CGFloat = 320

    static func of(_ type: BlockType) -> BlockStyle {
        switch type {
        case .scene:
            return BlockStyle(isBold: true, topPadding: 18)
        case .action, .text:
            return BlockStyle()
        case .character, .dualDialogue:
            return BlockStyle(alignment: .center, maxWidth: dialogueWidth,
                              topPadding: 10)
        case .dialogue:
            return BlockStyle(maxWidth: dialogueWidth)
        case .parenthetical:
            return BlockStyle(maxWidth: parentheticalWidth, isItalic: true)
        case .lyrics:
            return BlockStyle(maxWidth: dialogueWidth, isItalic: true)
        case .transition:
            return BlockStyle(alignment: .trailing, topPadding: 10)
        case .shot:
            return BlockStyle(isBold: true, topPadding: 10)
        case .centered:
            return BlockStyle(alignment: .center)
        case .section:
            return BlockStyle(isBold: true, isSecondary: true, topPadding: 14)
        case .synopsis:
            return BlockStyle(isItalic: true, isSecondary: true)
        case .note:
            return BlockStyle()
        case .pageBreak:
            return BlockStyle(alignment: .center, isSecondary: true, topPadding: 8)
        }
    }

    /// Character cues and dialogue share the dialogue column, so a cue centres
    /// over the words it introduces rather than over the whole page.
    var columnAlignment: Alignment {
        maxWidth == nil ? .leading : .center
    }

    /// What an untouched block of this type invites you to write.
    static func placeholder(for type: BlockType) -> String {
        switch type {
        case .scene: return "INT. LOCATION - DAY"
        case .character, .dualDialogue: return "CHARACTER"
        case .dialogue: return "What they say"
        case .parenthetical: return "(beat)"
        case .transition: return "CUT TO:"
        case .shot: return "ANGLE ON"
        case .pageBreak: return "==="
        default: return type.label
        }
    }
}
