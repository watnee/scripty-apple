//
//  ScriptNavigator.swift
//  scripty
//
//  The one piece of shared state between the navigation surfaces (outline,
//  search, stats) and the scrolling script page. A view that wants to send the
//  reader somewhere sets `pendingScrollTarget`; ScriptView's ScrollViewReader
//  observes it, scrolls, and clears it back to nil so the same block can be
//  targeted twice in a row.
//

import Foundation
import Observation

@Observable @MainActor
final class ScriptNavigator {
    /// Where in the window the target should come to rest.
    enum Placement {
        /// The middle of the screen: a block arrived at from somewhere else —
        /// an outline entry, a search hit — reads best with its surroundings
        /// either side of it.
        case centered
        /// The top of the screen, which is what restoring a remembered
        /// position needs: the element recorded is the one that was at the top,
        /// so putting it back anywhere else shifts the page the writer left.
        case atTop
    }

    /// The block id the script page should scroll to, or nil when there is
    /// nothing pending. ScriptView clears this once it has scrolled.
    var pendingScrollTarget: Int?

    /// How the pending target should be placed. Set alongside the target, so
    /// it is already right by the time the scroll runs.
    private(set) var pendingPlacement: Placement = .centered

    /// Ask the script page to bring `blockId` into view.
    func jump(to blockId: Int, placement: Placement = .centered) {
        pendingPlacement = placement
        pendingScrollTarget = blockId
    }

    /// Called by the script page after the scroll has been performed.
    func consumeScrollTarget() {
        pendingScrollTarget = nil
    }
}
