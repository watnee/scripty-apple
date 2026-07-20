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
    /// Opens the comment thread for an element. Handed in so the sheet lives
    /// on the script view rather than one per row.
    var onComment: (Block) -> Void = { _ in }

    /// The writer's chosen type size. Scaling the column along with the type
    /// keeps the same number of characters on a line, so the shape of the page
    /// does not change as the text grows.
    @Environment(\.scriptTextScale) private var textScale

    /// Read for the element-label toggle; shared app-wide like the rest of
    /// presentation.
    private let settings = PresentationSettings.shared

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
            .blockHighlight(block)
            .frame(maxWidth: columnWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: pageAlignment)
            .padding(.top, topPadding)
            .overlay(alignment: .topTrailing) { badges }
            .overlay(alignment: .topLeading) { elementLabel }
            .contextMenu { contextMenu }
    }

    /// Names the element's type out in the margin, when the writer has asked
    /// for labels.
    ///
    /// Drawn as an overlay rather than as a column beside the text so turning
    /// labels on does not reflow the script — the measure a line breaks at is
    /// the shape of the page, and a toggle about *naming* elements has no
    /// business changing where the words fall.
    @ViewBuilder
    private var elementLabel: some View {
        if settings.showsElementLabels {
            Text(block.blockType.marginLabel)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
                .padding(.top, topPadding)
                // Out into the gutter the script view opens up when labels are
                // on. Without this the label lands on top of the first word of
                // every left-aligned element.
                .offset(x: -44, y: -1)
                .frame(width: 40, alignment: .trailing)
                .allowsHitTesting(false)
                .accessibilityHidden(true)   // the row already announces its type
        }
    }

    // MARK: - Row actions

    @ViewBuilder
    private var contextMenu: some View {
        // Commenting needs only read access, so it sits above the editing
        // actions and appears even when none of them do.
        if block.hasLink(.comments) {
            Button {
                onComment(block)
            } label: {
                Label("Comments", systemImage: "bubble.left")
            }
        }
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
        if model.canDuplicate(block) {
            Button {
                Task { await model.duplicateBlock(block) }
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
        }
        // Only when the pasteboard actually holds a script. Ordinary copied
        // text pastes into the element the caret is in, the way it always
        // has — this is the menu entry for "and paste it as its own rows".
        if model.canPasteElements {
            Button {
                Task { await model.pasteElements(after: block) }
            } label: {
                Label("Paste Elements", systemImage: "doc.on.clipboard")
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

    /// Capitals for the types the writer has asked for, sentence case for the
    /// rest. The preference is the writer's, not this device's, because the
    /// exporters bake the case into the file.
    private var capitalization: UITextAutocapitalizationType {
        model.app.capitalization.preferences.applies(to: block.blockType)
            ? .allCharacters
            : .sentences
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
