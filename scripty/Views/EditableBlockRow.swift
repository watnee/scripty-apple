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
    /// Shared with every other row, so only the element being typed into can
    /// have a list open.
    let autocomplete: ScriptAutocomplete
    /// Opens the comment thread for an element. Handed in so the sheet lives
    /// on the script view rather than one per row.
    var onComment: (Block) -> Void = { _ in }

    /// The writer's chosen type size. Scaling the column along with the type
    /// keeps the same number of characters on a line, so the shape of the page
    /// does not change as the text grows.
    @Environment(\.scriptTextScale) private var textScale
    @Environment(\.scriptRowChrome) private var chrome

    private var pageWidth: CGFloat { chrome.columnWidth }
    private var dialogueWidth: CGFloat {
        pageWidth * CGFloat(ScreenplayLayout.dialogueBox.widthFraction)
    }
    private var parentheticalWidth: CGFloat {
        pageWidth * CGFloat(ScreenplayLayout.parentheticalBox.widthFraction)
    }

    var body: some View {
        BlockTextView(model: model, block: block, autocomplete: autocomplete,
                      font: uiFont, alignment: nsAlignment, autocapitalize: capitalization,
                      spellChecks: spellChecks,
                      accessibilityLabel: accessibilityDescription)
            .blockHighlight(block)
            .frame(maxWidth: columnWidth, alignment: .leading)
            // Speech is centred inside the page column rather than inside the
            // window, so the label below can hang off the column's own margin.
            .frame(maxWidth: pageWidth, alignment: pageAlignment)
            .padding(.top, topPadding)
            .overlay(alignment: .topLeading) { elementLabel }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topTrailing) { badges }
            .contextMenu { contextMenu }
            .overlay(alignment: .bottomLeading) { suggestionList }
            // A list hanging below the line has to draw over the elements it
            // covers, which in a LazyVStack means winning on z order.
            .zIndex(isSuggesting ? 1 : 0)
    }

    private var isSuggesting: Bool {
        autocomplete.isOpen && autocomplete.blockId == block.id
    }

    /// The completions for the line being typed, hung under it.
    ///
    /// Anchored to the row's *bottom* and then pushed down by its own height,
    /// so it sits below the line rather than on top of it and needs no
    /// measurement of either.
    @ViewBuilder
    private var suggestionList: some View {
        if isSuggesting {
            ScriptSuggestionList(autocomplete: autocomplete) { suggestion in
                let block = block
                autocomplete.clear()
                Task { await model.accept(suggestion, on: block) }
            }
            .alignmentGuide(.bottom) { $0[.top] }
        }
    }

    /// Names the element type — and any badge — for VoiceOver, which otherwise
    /// hears an anonymous text field per line. Deliberately the *label* on the
    /// text view rather than a wrapper element: the value stays the block's own
    /// text, so reading, editing and caret navigation all still work.
    private var accessibilityDescription: String {
        var parts = [block.blockType.label]
        if block.isPinned && chrome.showsPins { parts.append("Pinned") }
        if block.isBookmarked && chrome.showsBookmarks { parts.append("Bookmarked") }
        if let comments = CommentCountBadge.spokenLabel(model.commentCount(for: block)) {
            parts.append(comments)
        }
        return parts.joined(separator: ", ")
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
        // Retype this element, the web block menu's "Elements" submenu. The
        // element-type bar covers the same ground for the common types, but
        // curates them down and leaves Text, Dual Dialogue and Page Break off;
        // this is the only touch route to those three, since the full-set
        // Format menu is a hardware-keyboard affordance.
        if block.hasLink(.setType) {
            Menu {
                ForEach(BlockType.allCases) { type in
                    Button {
                        Task { await model.changeType(block, to: type) }
                    } label: {
                        if type == block.blockType {
                            Label(type.label, systemImage: "checkmark")
                        } else {
                            Text(type.label)
                        }
                    }
                }
            } label: {
                Label("Change Type", systemImage: "textformat")
            }
        }
        // A per-block highlight, the way the web's block menu offers it. It
        // rides the bulk-format link with a single id rather than a dedicated
        // per-block endpoint, so one tap is one undo step — the same call the
        // multi-select bar makes, just without entering selection mode first.
        if model.canBulkFormat && block.isEditable {
            Menu {
                ForEach(BlockHighlight.allCases) { colour in
                    Button {
                        Task { await model.bulkSetHighlight([block.id], highlight: colour) }
                    } label: {
                        Label(colour.label, systemImage: "circle.fill")
                    }
                }
                Button("None") {
                    Task { await model.bulkSetHighlight([block.id], highlight: nil) }
                }
            } label: {
                Label("Highlight", systemImage: "highlighter")
            }
        }
        // The clipboard trio sits in its own section, below the marks and above
        // the delete — the order the web's block menu uses.
        Section {
            Button {
                model.copyBlocks([block])
            } label: {
                Label("Copy Element", systemImage: "doc.on.doc")
            }
            if model.canCut(block) {
                Button {
                    Task { await model.cutBlocks([block]) }
                } label: {
                    Label("Cut Element", systemImage: "scissors")
                }
            }
            if model.canPaste(below: block) {
                Button {
                    Task { await model.pasteBlocks(below: block) }
                } label: {
                    Label("Paste Below", systemImage: "doc.on.clipboard")
                }
            }
        }
        // Start a fresh element of any type below this one — the element half
        // of the web's create-below "+" menu (its Songs/Notes sections are the
        // Insert submenus below). Return already creates the following-type
        // element; this places one of a chosen type in a single action.
        if block.hasLink(.createBelow) {
            Section {
                Menu {
                    ForEach(BlockType.allCases) { type in
                        Button(type.label) {
                            Task { await model.insertBlock(below: block, type: type) }
                        }
                    }
                } label: {
                    Label("Add Element Below", systemImage: "plus")
                }
            }
        }
        // Drop a song's lyrics or a note's text in right here — the web's
        // create-below "Songs" / "Notes" sections, which let a writer place a
        // document at a chosen point rather than only appending it to the end.
        if model.canInsertDocuments {
            Section {
                if !model.insertableSongs.isEmpty {
                    Menu {
                        ForEach(model.insertableSongs) { document in
                            Button(document.displayTitle) {
                                Task { await model.insertDocument(document, afterBlockId: block.id) }
                            }
                        }
                    } label: {
                        Label("Insert Song", systemImage: "music.note")
                    }
                }
                if !model.insertableNotes.isEmpty {
                    Menu {
                        ForEach(model.insertableNotes) { document in
                            Button(document.displayTitle) {
                                Task { await model.insertDocument(document, afterBlockId: block.id) }
                            }
                        }
                    } label: {
                        Label("Insert Note", systemImage: "note.text")
                    }
                }
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
    private var elementLabel: some View {
        if chrome.showsElementLabels {
            ElementLabelTag(type: block.blockType)
                .padding(.top, topPadding + 5)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 4) {
            // The writer's own marks share one tint; the comment badge brings
            // its own, since it is other people's.
            HStack(spacing: 4) {
                if block.isPinned && chrome.showsPins { Image(systemName: "pin.fill") }
                if block.isBookmarked && chrome.showsBookmarks { Image(systemName: "bookmark.fill") }
            }
            .foregroundStyle(.orange)
            CommentCountBadge(count: model.commentCount(for: block))
        }
        .font(.caption2)
        // Every badge here is already spoken as part of the row's label.
        .accessibilityHidden(true)
    }

    // MARK: - Per-type layout

    private var columnWidth: CGFloat {
        let base: CGFloat
        switch block.blockType {
        case .dialogue, .lyrics: base = dialogueWidth
        case .parenthetical: base = parentheticalWidth
        default: base = pageWidth
        }
        // A full-width column was measured against the window, so it is already
        // as wide as it can be; the type grows inside it rather than pushing it
        // off the edge of the screen.
        return chrome.isFullWidth ? base : base * textScale
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

    /// Whether this line auto-capitalizes as the writer types. Scene headings,
    /// cues, transitions and shots default to caps, but each is a preference the
    /// server stores — turning one off matches the case the export will carry.
    private var capitalization: UITextAutocapitalizationType {
        CapitalizationSettings.shared.isOn(forBlockType: block.blockType) ? .allCharacters : .sentences
    }

    /// Whether the keyboard underlines what it does not recognise. Read here
    /// rather than passed down from the script view, the way capitalization is:
    /// both are device-wide settings, and the observation is what makes every
    /// visible row re-draw when one is switched.
    private var spellChecks: Bool {
        PresentationSettings.shared.isSpellcheckEnabled
    }

    private var uiFont: UIFont {
        var traits: UIFontDescriptor.SymbolicTraits = []
        switch block.blockType {
        case .scene: traits.insert(.traitBold)
        case .shot: traits.insert(.traitBold)
        case .parenthetical, .lyrics, .synopsis: traits.insert(.traitItalic)
        default: break
        }
        if block.textBold ?? false { traits.insert(.traitBold) }
        if block.textItalic ?? false { traits.insert(.traitItalic) }

        return Self.font(family: ScriptFont(serverValue: block.font),
                         size: 16 * textScale,
                         traits: traits)
    }

    /// Resolved fonts, kept between updates.
    ///
    /// Every keystroke invalidates the observed editing state, so SwiftUI
    /// re-runs the update for each visible row — and building a `UIFont` from
    /// a descriptor is not free. A whole script only ever uses a handful of
    /// (family, size, traits) combinations, so they are worth holding onto:
    /// the work collapses to a dictionary lookup after the first row of each
    /// kind. Bounded by the type-size control having a fixed set of steps.
    @MainActor private static var fontCache: [FontKey: UIFont] = [:]

    private struct FontKey: Hashable {
        let family: ScriptFont?
        let size: CGFloat
        /// `SymbolicTraits` is an OptionSet and so isn't Hashable on its own.
        let traits: UInt32
    }

    @MainActor
    private static func font(family: ScriptFont?,
                             size: CGFloat,
                             traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        let key = FontKey(family: family, size: size, traits: traits.rawValue)
        if let cached = fontCache[key] { return cached }

        let base: UIFont
        switch family {
        case .arial:
            base = UIFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size)
        case .timesNewRoman:
            base = UIFont(name: "TimesNewRomanPSMT", size: size) ?? .systemFont(ofSize: size)
        case .courierPrime, .none:
            base = .monospacedSystemFont(ofSize: size, weight: .regular)
        }

        let resolved = base.fontDescriptor.withSymbolicTraits(traits)
            .map { UIFont(descriptor: $0, size: size) } ?? base
        fontCache[key] = resolved
        return resolved
    }
}
