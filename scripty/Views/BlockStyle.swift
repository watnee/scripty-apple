//
//  BlockStyle.swift
//  scripty
//
//  UIKit typography for the inline editor, echoing the read-only page
//  conventions in BlockRowView so a block looks the same whether you're
//  reading it or typing into it.
//

import UIKit

enum BlockStyle {
    private static let baseSize: CGFloat = 16

    static func font(for type: BlockType) -> UIFont {
        let mono = UIFont.monospacedSystemFont(ofSize: baseSize, weight: weight(for: type))
        switch type {
        case .parenthetical, .lyrics, .synopsis:
            return italic(mono)
        default:
            return mono
        }
    }

    static func alignment(for type: BlockType) -> NSTextAlignment {
        switch type {
        case .character, .dualDialogue, .centered:
            return .center
        case .transition:
            return .right
        default:
            return .left
        }
    }

    /// Scene headings, cues and transitions are conventionally uppercase;
    /// setting the keyboard to caps means typing them yields the right case
    /// without the editor rewriting stored content.
    static func autocapitalization(for type: BlockType) -> UITextAutocapitalizationType {
        switch type {
        case .scene, .character, .dualDialogue, .transition, .shot:
            return .allCharacters
        default:
            return .sentences
        }
    }

    private static func weight(for type: BlockType) -> UIFont.Weight {
        switch type {
        case .scene: return .bold
        case .shot, .section: return .semibold
        default: return .regular
        }
    }

    private static func italic(_ font: UIFont) -> UIFont {
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) else {
            return font
        }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }
}
