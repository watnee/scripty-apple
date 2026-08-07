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
    /// The script's selection, so a sideways swipe across the line can pick it
    /// out without a trip to the toolbar — nil where selection would lead
    /// nowhere, and then no swipe is offered. Carried down to the text view,
    /// which is where the gesture has to live: see `SwipeToSelect`.
    var selection: BlockSelectionModel?
    /// Opens the comment thread for an element. Handed in so the sheet lives
    /// on the script view rather than one per row.
    var onComment: (Block) -> Void = { _ in }

    /// The writer's chosen type size. Scaling the column along with the type
    /// keeps the same number of characters on a line, so the shape of the page
    /// does not change as the text grows.
    @Environment(\.scriptTextScale) private var textScale
    @Environment(\.scriptRowChrome) private var chrome
    /// Read for the highlight swatches, which are drawn rather than tinted and
    /// so have to be told which side of light and dark they are on.
    @Environment(\.colorScheme) private var colorScheme

    /// Drives the per-block "Edit Tags" prompt. The draft is seeded from the
    /// block's current tags when the field opens.
    @State private var isEditingTags = false
    @State private var tagDraft = ""

    private let settings = PresentationSettings.shared

    /// What "Add Element Below" offers — narrowed while the script is collapsed
    /// to its outline, the way the element-type bar is: adding a dialogue line
    /// there would file the writer's next words behind the mode, which reads as
    /// a menu item that did nothing.
    private var insertableTypes: [BlockType] {
        settings.isOutlineMode ? BlockType.outlineTypes : BlockType.allCases
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            BlockTextView(model: model, block: block, autocomplete: autocomplete,
                          // Read here, not inside the representable: the row body
                          // is cheap to re-evaluate on another block's keystroke,
                          // the representable's UIKit work is not — and Equatable
                          // lets untouched rows skip it entirely.
                          liveText: model.liveText[block.id],
                          caretRequest: model.caretRequests[block.id],
                          isFocused: model.focusedBlockId == block.id,
                          font: uiFont, alignment: nsAlignment,
                          autocapitalize: capitalization,
                          spellChecks: spellChecks,
                          spellcheckRevision: spellcheckRevision,
                          accessibilityLabel: accessibilityDescription,
                          selection: selection)
                .equatable()
                .blockHighlight(block)
                .noteCard(block.blockType)
                // At the element's own screenplay indent inside the page column,
                // which is where the reading surface and the printed page put it
                // too — so a line does not move when the script is handed between
                // them. The label below hangs off the column's own margin.
                .screenplayBox(block.blockType, in: chrome, alignment: boxAlignment)
            // Under the element, as the read-only row draws them: an element
            // that grew a badge only once editing was locked took the rest of
            // the script down the page with it.
            BlockTagRow(block: block)
        }
            .padding(.top, topPadding)
            .overlay(alignment: .topLeading) { elementLabel }
            .blockMarkers(block,
                          commentCount: model.commentCount(for: block),
                          // Past the row's own top padding, so a mark sits
                          // beside the element's first line rather than above
                          // it.
                          topInset: topPadding,
                          onComment: { onComment(block) })
            .frame(maxWidth: .infinity)
            .contextMenu { contextMenu }
            .alert("Tags", isPresented: $isEditingTags) {
                TextField("e.g. funny, action", text: $tagDraft)
                    .textInputAutocapitalization(.never)
                Button("Save") {
                    Task { await model.setTags(block, to: tagDraft) }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Separate tags with commas. Clearing the field removes them.")
            }
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
        // Gated like the two above, and for the reason the read-only row
        // records: a mode that empties the margin has to empty what is spoken
        // of it as well.
        if chrome.showsComments,
           let comments = CommentCountBadge.spokenLabel(model.commentCount(for: block)) {
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
        // Not on an element that exists only on this device: highlighting goes
        // through the bulk-format endpoint, which can only name ids the server
        // has issued. The line gets its colour once it has been sent.
        if model.canBulkFormat && block.isEditable && !block.isLocal {
            Menu {
                ForEach(BlockHighlight.allCases) { colour in
                    Button {
                        Task { await model.bulkSetHighlight([block.id], highlight: colour) }
                    } label: {
                        Label { Text(colour.label) } icon: { colour.swatch(for: colorScheme) }
                    }
                }
                Button {
                    Task { await model.bulkSetHighlight([block.id], highlight: nil) }
                } label: {
                    Label("None", systemImage: "circle.dashed")
                }
            } label: {
                Label("Highlight", systemImage: "highlighter")
            }
        }
        // The web block editor's "Tags (comma separated)" field, brought to the
        // element menu. Editing rides the same `update` PUT as a text save, so
        // it is gated on the block being editable rather than on a bulk link.
        // Same reasoning as Highlight: tags ride the per-block PUT, and there
        // is nothing to PUT to until the element has been created.
        if block.isEditable && !block.isLocal {
            Button {
                tagDraft = block.tagList.joined(separator: ", ")
                isEditingTags = true
            } label: {
                Label("Edit Tags", systemImage: "tag")
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
                    ForEach(insertableTypes) { type in
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
        // A local element has no delete link and never will until it is sent,
        // but the writer must still be able to take back a line they just
        // typed — `deleteBlock` handles that by forgetting the queued create.
        if block.hasLink(.delete) || block.isLocal {
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
            ElementLabelTag(type: block.blockType,
                            dynamicTypeScale: chrome.dynamicTypeScale)
                .padding(.top, topPadding + 5)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Per-type layout

    /// Where the element sits inside its own box. Speech has a box of its own
    /// and starts at the left of it; everything else has the whole column and
    /// sits where its type belongs on the page.
    private var boxAlignment: Alignment {
        switch block.blockType {
        case .centered: return .center
        case .transition: return .trailing
        default: return .leading
        }
    }

    /// An explicit alignment set by the writer wins; otherwise the element
    /// type's screenplay-convention default applies — resolved by
    /// `Block.nsTextAlignment`, which the two read-only surfaces ask as well, so
    /// a line the writer centred is centred on all three.
    ///
    /// A cue is *placed* at its indent rather than centred now, so its text is
    /// set from the left of the box it was placed in — centring it inside a box
    /// that already begins at 2.2 inches would push the name off to the right
    /// of where the reader and the printed page put it.
    private var nsAlignment: NSTextAlignment { block.nsTextAlignment }

    /// The air above the element, in the screenplay's own line units — the rule
    /// the reader and the paginator use, so the rhythm holds across a mode
    /// change: two lines above a scene heading, none between a cue and what it
    /// says, one everywhere else.
    private var topPadding: CGFloat {
        CGFloat(ScreenplayLayout.spacing(for: block.blockType,
                                         lineHeight: Double(fontSize)))
    }

    /// One line of the writing column, in points.
    private var fontSize: CGFloat { ProseFont.baseSize * CGFloat(textScale) }

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

    /// Read for the same reason: ignoring a word from one element's menu has to
    /// clear the underline under the same word everywhere else on the page.
    private var spellcheckRevision: Int {
        SpellcheckDictionary.shared.revision
    }

    /// Sized from the same base as the note and lyric surfaces, and resolved
    /// through the same one the locked rows and the reader use — see
    /// `ScriptFont.element`.
    private var uiFont: UIFont {
        ScriptFont.element(block, size: fontSize)
    }
}
