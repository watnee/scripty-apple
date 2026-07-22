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
            suggestions = []
            return
        }
        dismissedFor = nil

        let fresh = ScriptSuggestions.suggestions(forText: text, type: type,
                                                  blocks: blocks, characters: characters)
        // Keep the writer's place when the list is unchanged — a keystroke that
        // narrows nothing shouldn't move the highlight off what they were
        // about to accept.
        if self.blockId != blockId || fresh != suggestions { selectedIndex = 0 }
        self.blockId = blockId
        suggestions = fresh
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
