//
//  SpotlightIndex.swift
//  scripty
//
//  Putting the entities where they can be found: type half a screenplay's title
//  into Spotlight and the screenplay is a result, which opens it.
//
//  Donated from the same two publishers that feed the widgets, off the same
//  snapshots, so there is one moment at which the outside world learns what this
//  account has — and, more to the point, one moment at which it is made to
//  forget. Signing out clears the index exactly as it clears both widgets and
//  the Home Screen menu: the next person to pick up the phone should not be able
//  to read the last writer's titles out of Spotlight either.
//
//  Every call is fire-and-forget and swallows its failure. An index is a
//  convenience laid over data the app already holds; a device that will not take
//  a donation is not a device to interrupt someone's work over.
//

import AppIntents
import CoreSpotlight
import Foundation

enum SpotlightIndex {
    /// Replaces what is indexed for one entity type.
    ///
    /// `gone` is what the previous snapshot held and this one does not — a
    /// screenplay deleted or a song renamed away. Indexing alone would never
    /// remove those, and a stale Spotlight result that opens nothing is worse
    /// than no result: it looks like the app lost the screenplay.
    static func replace<Entity: IndexedEntity>(_ entities: [Entity],
                                               removing gone: [Entity.ID]) {
        Task {
            let index = CSSearchableIndex.default()
            if !gone.isEmpty {
                try? await index.deleteAppEntities(identifiedBy: gone, ofType: Entity.self)
            }
            try? await index.indexAppEntities(entities)
        }
    }

    /// Takes everything back out. Sign-out goes through here.
    ///
    /// Everything, not one entity type — the index is this app's own, so there
    /// is nothing else in it to lose, and "all of it" cannot be the call that
    /// quietly leaves a type behind. That does mean both widget publishers'
    /// `clear()` wipe the whole index rather than their own half; they are only
    /// ever called together, at sign-out, in scriptyApp. A third caller wanting
    /// to clear one type on its own would want `deleteAppEntities` instead.
    static func clear() {
        Task {
            try? await CSSearchableIndex.default().deleteAllSearchableItems()
        }
    }
}
