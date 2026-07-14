//
//  ScreenplayLayout.swift
//  scripty
//
//  Page geometry for a screenplay element, expressed as fractions of the page
//  body the way the web does it (see `--screenplay-*-indent` in scripty.css).
//  Both the inline editor and the read-only renderer measure from here, so a
//  block sits in the same place whether or not it has the caret.
//

import SwiftUI

struct ScreenplayLayout {
    /// Left inset, as a fraction of the page body width.
    var indent: CGFloat = 0
    /// Width, as a fraction of the page body width.
    var width: CGFloat = 1
    var alignment: Alignment = .leading
    var isUppercase = false
    var isBold = false
    var isItalic = false

    /// Standard US screenplay measures: a 6" body inside a US Letter page.
    /// Dialogue runs 3.5" starting 1" in; a character cue sits 2.2" in.
    static func of(_ type: BlockType) -> ScreenplayLayout {
        switch type {
        case .scene:
            return ScreenplayLayout(isUppercase: true, isBold: true)
        case .character, .dualDialogue:
            return ScreenplayLayout(indent: 0.36667, width: 0.63333, isUppercase: true)
        case .dialogue:
            return ScreenplayLayout(indent: 0.16667, width: 0.58333)
        case .parenthetical:
            return ScreenplayLayout(indent: 0.25, width: 0.33333, isItalic: true)
        case .lyrics:
            return ScreenplayLayout(indent: 0.16667, width: 0.58333, isItalic: true)
        case .transition:
            return ScreenplayLayout(alignment: .trailing, isUppercase: true)
        case .shot:
            return ScreenplayLayout(isUppercase: true, isBold: true)
        case .centered:
            return ScreenplayLayout(alignment: .center)
        case .section:
            return ScreenplayLayout(isBold: true)
        case .synopsis:
            return ScreenplayLayout(isItalic: true)
        case .action, .text, .note, .pageBreak:
            return ScreenplayLayout()
        }
    }

    /// Blank line before a scene heading — the industry rhythm the web applies
    /// with `margin-top: 1em` on scene rows.
    static func topPadding(for type: BlockType) -> CGFloat {
        switch type {
        case .scene, .section: return 18
        case .character, .transition, .shot: return 10
        default: return 0
        }
    }

    /// Courier is the screenplay convention; the web honours a per-block font
    /// override, so mirror that.
    static func font(for block: Block, size: CGFloat = 16) -> UIFont {
        let design: UIFontDescriptor.SystemDesign
        switch block.font {
        case "ARIAL", "TIMES_NEW_ROMAN": design = .default
        default: design = .monospaced
        }
        let base = UIFont.systemFont(ofSize: size)
        guard let descriptor = base.fontDescriptor.withDesign(design) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}
