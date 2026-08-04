//
//  BlockSelectionModel.swift
//  scripty
//
//  Which elements the writer has selected for a bulk action.
//
//  The web app has two unrelated selection systems — a set of row checkboxes
//  that drives every bulk endpoint, and a separate Notion-style drag selection
//  that is purely visual. Only the first one means anything to the server, so
//  only the first one is modelled here; on a touch device a tap-to-select mode
//  is the natural equivalent of the checkbox column.
//

import Foundation
import Observation

@Observable
@MainActor
final class BlockSelectionModel {
    /// Whether the script is in selection mode. Leaving it clears the
    /// selection, so a stale set can't be applied to a later action.
    var isSelecting = false {
        didSet {
            guard isSelecting != oldValue else { return }
            if !isSelecting { selected.removeAll() }
        }
    }

    private(set) var selected: Set<Int> = []

    var count: Int { selected.count }
    var isEmpty: Bool { selected.isEmpty }

    func isSelected(_ id: Int) -> Bool { selected.contains(id) }

    func toggle(_ id: Int) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }

    /// Picks an element out without the toolbar: the mode comes on if it was
    /// off, and the element is then taken or dropped exactly as a tap inside
    /// the mode would take or drop it.
    ///
    /// What a swipe across a row means — see `SwipeToSelect`. The rule lives
    /// here rather than at the gesture because it is a rule about the mode
    /// rather than about a finger: the same two steps would be wanted by any
    /// other shortcut into selection, and only one of them is obvious.
    func toggleEnteringMode(_ id: Int) {
        isSelecting = true
        toggle(id)
    }

    func clear() { selected.removeAll() }

    /// Selects every element currently listed. The web app's select-all
    /// deliberately honours an active search filter — "all" means all the
    /// writer can see — so callers pass the visible set, not the whole script.
    func selectAll(_ ids: [Int]) {
        selected.formUnion(ids)
    }

    func select(_ ids: [Int]) {
        selected = Set(ids)
    }

    /// Drop any selection that no longer exists, so a bulk delete or a sync
    /// that removed blocks can't leave phantom ids behind to be posted.
    func prune(toExisting ids: [Int]) {
        let existing = Set(ids)
        selected.formIntersection(existing)
    }

    /// Selection order follows the script, not the order things were tapped —
    /// the server renumbers by position anyway and a stable order makes the
    /// request reproducible.
    ///
    /// Elements written offline are left out: every bulk action names its
    /// elements by server id, and one that has never been sent has no id the
    /// server would recognise. Including it would fail the whole request and
    /// take the rest of the selection down with it.
    func orderedIds(in blocks: [Block]) -> [Int] {
        blocks.filter { !$0.isLocal && selected.contains($0.id) }.map(\.id)
    }
}
