//
//  ScriptModel+Outline.swift
//  scripty
//
//  Derived views of the already-loaded blocks: statistics, the outline lists,
//  and the bookmark/pin filters. All computed client-side — none of this costs
//  a request, so none of it is link-gated; it is simply hidden while the
//  script is empty.
//

import Foundation

extension ScriptModel {
    /// Screenplay statistics for the blocks currently loaded.
    var stats: ScriptStats { ScriptStats(blocks: blocks) }

    /// Outline, character, location and song navigation lists.
    var outline: ScriptOutline { ScriptOutline(blocks: blocks) }

    /// Blocks the writer flagged, in document order.
    var bookmarkedBlocks: [Block] { blocks.filter(\.isBookmarked) }

    /// Blocks the writer pinned, in document order.
    var pinnedBlocks: [Block] { blocks.filter(\.isPinned) }

    /// Blocks somebody has commented on, in document order.
    ///
    /// Comments are the one mark on a line the writer did not put there, and
    /// until now the only way to find one was to scroll past its badge.
    var commentedBlocks: [Block] {
        blocks.filter { commentCount(for: $0) > 0 }
    }

    /// Note elements, in document order.
    ///
    /// The one navigable list whose elements can be missing from the script
    /// entirely: Show ▸ Notes takes them off the page, and a note taken off the
    /// page was, until this list, unreachable without turning it back on and
    /// scrolling for it.
    var noteBlocks: [Block] { blocks.filter { $0.blockType == .note } }

    /// True once there is anything worth navigating or measuring.
    var hasScriptContent: Bool { !blocks.isEmpty }

    func block(id: Int) -> Block? {
        blocks.first { $0.id == id }
    }
}
