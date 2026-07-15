//
//  EditableBlockRow.swift
//  scripty
//
//  An editable screenplay element: the same typographic treatment as
//  BlockRowView, but backed by a live UITextView so the writer types into
//  the page directly. Only rendered for blocks the server says are editable.
//

import SwiftUI
import UIKit

struct EditableBlockRow: View {
    let model: ScriptModel
    let block: Block

    private static let pageWidth: CGFloat = 640
    private static let dialogueWidth: CGFloat = 400
    private static let parentheticalWidth: CGFloat = 320

    var body: some View {
        BlockTextView(model: model, block: block,
                      font: uiFont, alignment: nsAlignment, autocapitalize: capitalization)
            .frame(maxWidth: columnWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: pageAlignment)
            .padding(.top, topPadding)
            .overlay(alignment: .topTrailing) { badges }
            .contextMenu { contextMenu }
    }

    // MARK: - Row actions

    @ViewBuilder
    private var contextMenu: some View {
        if block.hasLink(.togglePinned) {
            Button {
                Task { await model.togglePinned(block) }
            } label: {
                Label(block.isPinned ? "Unpin" : "Pin",
                      systemImage: block.isPinned ? "pin.slash" : "pin")
            }
        }
        if block.hasLink(.toggleBookmark) {
            Button {
                Task { await model.toggleBookmark(block) }
            } label: {
                Label(block.isBookmarked ? "Remove Bookmark" : "Bookmark",
                      systemImage: block.isBookmarked ? "bookmark.slash" : "bookmark")
            }
        }
        if block.hasLink(.delete) {
            Button(role: .destructive) {
                Task { await model.deleteBlock(block) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 4) {
            if block.isPinned { Image(systemName: "pin.fill") }
            if block.isBookmarked { Image(systemName: "bookmark.fill") }
        }
        .font(.caption2)
        .foregroundStyle(.orange)
    }

    // MARK: - Per-type layout

    private var columnWidth: CGFloat {
        switch block.blockType {
        case .dialogue, .lyrics: return Self.dialogueWidth
        case .parenthetical: return Self.parentheticalWidth
        default: return Self.pageWidth
        }
    }

    private var pageAlignment: Alignment {
        switch block.blockType {
        case .character, .dualDialogue, .dialogue, .parenthetical, .lyrics, .centered:
            return .center
        case .transition:
            return .trailing
        default:
            return .leading
        }
    }

    private var nsAlignment: NSTextAlignment {
        switch block.blockType {
        case .character, .dualDialogue, .centered: return .center
        case .transition: return .right
        default: return .left
        }
    }

    private var topPadding: CGFloat {
        switch block.blockType {
        case .scene: return 18
        case .character, .dualDialogue, .transition, .shot: return 10
        case .section: return 14
        default: return 4
        }
    }

    private var capitalization: UITextAutocapitalizationType {
        switch block.blockType {
        case .scene, .character, .dualDialogue, .transition, .shot: return .allCharacters
        default: return .sentences
        }
    }

    private var uiFont: UIFont {
        let size: CGFloat = 16
        let base: UIFont
        switch block.font {
        case "ARIAL", "TIMES_NEW_ROMAN":
            base = .systemFont(ofSize: size)
        default:
            base = .monospacedSystemFont(ofSize: size, weight: .regular)
        }

        var traits: UIFontDescriptor.SymbolicTraits = []
        switch block.blockType {
        case .scene: traits.insert(.traitBold)
        case .shot: traits.insert(.traitBold)
        case .parenthetical, .lyrics, .synopsis: traits.insert(.traitItalic)
        default: break
        }
        if block.textBold ?? false { traits.insert(.traitBold) }
        if block.textItalic ?? false { traits.insert(.traitItalic) }

        if let descriptor = base.fontDescriptor.withSymbolicTraits(traits) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return base
    }
}
