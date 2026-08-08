//
//  ScriptAutocomplete.swift
//  scripty
//
//  Which suggestions are showing, and what accepting one does.
//
//  The list itself is worked out in `ScriptSuggestions`; this is the part that
//  has to be shared, because two very different things need to agree on it —
//  the SwiftUI overlay that draws the list, and the UITextView that has to know
//  whether Return means "accept this" or "split the element". One observable
//  object between them is what keeps those two answers from disagreeing.
//

import Foundation
import Observation

@Observable
@MainActor
final class ScriptAutocomplete {
    private(set) var blockId: Int?
    private(set) var suggestions: [ScriptSuggestion] = []
    private(set) var selectedIndex = 0

    /// The text that was on screen when the writer dismissed the list. It stays
    /// shut until they type something else — otherwise Escape would be undone
    /// by the very next keystroke, or by nothing at all.
    private var dismissedFor: String?

    /// The harvested source lists, cached across keystrokes. Building them
    /// walks the whole script with locale-aware compares — real work on a
    /// feature-length draft — and their inputs only change when the script
    /// reloads or the cast does. Comparing `[Block]`/`[Person]` hits the
    /// identity fast-path, so the staleness check is O(1) per keystroke.
    /// Ignored by observation: a cache refresh is not a redraw.
    @ObservationIgnored private var memoBlocks: [Block] = []
    @ObservationIgnored private var memoCharacters: [Person] = []
    @ObservationIgnored private var memoCueNames: [(name: String, personId: Int?)] = []
    @ObservationIgnored private var memoHeadings: [String] = []
    @ObservationIgnored private var hasMemo = false

    var isOpen: Bool { blockId != nil && !suggestions.isEmpty }

    var selected: ScriptSuggestion? {
        guard suggestions.indices.contains(selectedIndex) else { return nil }
        return suggestions[selectedIndex]
    }

    /// Recomputes the list for the line being typed.
    func update(blockId: Int,
                text: String,
                type: BlockType,
                blocks: [Block],
                characters: [Person]) {
        if dismissedFor == text && self.blockId == blockId {
            if !suggestions.isEmpty { suggestions = [] }
            return
        }
        dismissedFor = nil

        if !hasMemo || blocks != memoBlocks || characters != memoCharacters {
            memoBlocks = blocks
            memoCharacters = characters
            memoCueNames = ScriptSuggestions.cueNames(blocks: blocks, characters: characters)
            memoHeadings = ScriptSuggestions.sceneHeadings(in: blocks)
            hasMemo = true
        }
        let fresh = ScriptSuggestions.suggestions(forText: text, type: type,
                                                  cueNames: memoCueNames,
                                                  headings: memoHeadings)
        // Keep the writer's place when the list is unchanged — a keystroke that
        // narrows nothing shouldn't move the highlight off what they were
        // about to accept.
        //
        // All three are written only when they move, and that is a performance
        // rule as much as a correctness one. This object is read from every
        // visible element's body (`isOpen` decides which row draws the list and
        // wins on z order), and `@Observable` publishes an assignment whether
        // or not the value changed — so re-stating an empty list, which is what
        // typing an action line does on every single character, was redrawing
        // the whole column for a list nobody is looking at.
        let changed = fresh != suggestions
        if self.blockId != blockId || changed {
            if selectedIndex != 0 { selectedIndex = 0 }
        }
        if self.blockId != blockId { self.blockId = blockId }
        if changed { suggestions = fresh }
    }

    func moveSelection(by delta: Int) {
        guard !suggestions.isEmpty else { return }
        // Wraps, so holding Down walks the list rather than sticking at the end.
        selectedIndex = (selectedIndex + delta + suggestions.count) % suggestions.count
    }

    func select(_ index: Int) {
        guard suggestions.indices.contains(index) else { return }
        selectedIndex = index
    }

    /// Escape, or a tap outside: shut until the line changes.
    func dismiss(showing text: String) {
        dismissedFor = text
        suggestions = []
    }

    /// The element lost focus, so there is nothing to complete.
    func clear() {
        blockId = nil
        suggestions = []
        selectedIndex = 0
        dismissedFor = nil
    }
}

extension ScriptModel {
    /// Replaces the line with the suggestion, and follows through on what
    /// accepting it implied.
    ///
    /// Two requests in the retyping case, and deliberately in this order: the
    /// words go first, so a failure to change the element type still leaves the
    /// writer with the name they picked. The retype carries no content of its
    /// own, so it cannot overwrite what the first request stored.
    func accept(_ suggestion: ScriptSuggestion, on block: Block) async {
        // On screen straight away — the round trip is not the writer's problem.
        showLive(block, text: suggestion.text)

        let personId = suggestion.personId ?? block.personId
        let saved = await updateBlock(block,
                                      content: suggestion.text,
                                      personId: personId,
                                      tags: block.tags)
        guard saved else { return }
        showLive(block, text: nil)

        if let type = suggestion.becomesType, type != block.blockType,
           let refreshed = blocks.first(where: { $0.id == block.id }) {
            await changeType(refreshed, to: type)
        }
        focus(block.id, caret: suggestion.text.count)
    }
}
