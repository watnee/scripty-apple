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

    /// The writer's chosen type size. Scaling the column along with the type
    /// keeps the same number of characters on a line, so the shape of the page
    /// does not change as the text grows.
    @Environment(\.scriptTextScale) private var textScale

    private static let pageWidth: CGFloat = 640
    private static var dialogueWidth: CGFloat {
        pageWidth * CGFloat(ScreenplayLayout.dialogueBox.widthFraction)
    }
    private static var parentheticalWidth: CGFloat {
        pageWidth * CGFloat(ScreenplayLayout.parentheticalBox.widthFraction)
    }

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
        // Reordering lives in the context menu rather than on a drag handle:
        // the script is a LazyVStack, so rows outside the rendered window
        // don't exist as drop targets and a drag-to-reorder gesture would
        // also fight the text view's own selection drag. A menu pair is
        // reliable at any scroll position and works with VoiceOver.
        if model.canMoveUp(block) {
            Button {
                Task { await model.moveBlockUp(block) }
            } label: {
                Label("Move Up", systemImage: "arrow.up")
            }
        }
        if model.canMoveDown(block) {
            Button {
                Task { await model.moveBlockDown(block) }
            } label: {
                Label("Move Down", systemImage: "arrow.down")
            }
        }
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
        let base: CGFloat
        switch block.blockType {
        case .dialogue, .lyrics: base = Self.dialogueWidth
        case .parenthetical: base = Self.parentheticalWidth
        default: base = Self.pageWidth
        }
        return base * textScale
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

    /// An explicit alignment set by the writer wins; otherwise the element
    /// type's screenplay-convention default applies.
    private var nsAlignment: NSTextAlignment {
        if let override = TextAlign(serverValue: block.textAlign) {
            switch override {
            case .left: return .left
            case .center: return .center
            case .right: return .right
            }
        }
        switch block.blockType {
        case .character, .dualDialogue, .centered: return .center
        case .transition: return .right
        default: return .left
        }
    }

    private var topPadding: CGFloat {
        let base: CGFloat
        switch block.blockType {
        case .scene: base = 18
        case .character, .dualDialogue, .transition, .shot: base = 10
        case .section: base = 14
        default: base = 4
        }
        return base * textScale
    }

    private var capitalization: UITextAutocapitalizationType {
        switch block.blockType {
        case .scene, .character, .dualDialogue, .transition, .shot: return .allCharacters
        default: return .sentences
        }
    }

    private var uiFont: UIFont {
        let size: CGFloat = 16 * textScale
        let base: UIFont
        switch ScriptFont(serverValue: block.font) {
        case .arial:
            base = UIFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size)
        case .timesNewRoman:
            base = UIFont(name: "TimesNewRomanPSMT", size: size) ?? .systemFont(ofSize: size)
        case .courierPrime, .none:
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
