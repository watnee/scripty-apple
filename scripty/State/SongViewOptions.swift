//
//  SongViewOptions.swift
//  scripty
//
//  Whether a lyric can be typed into.
//
//  The screenplay has had an editing lock since it shipped: a finished draft
//  that is being read from — at a table read, on a phone in a rehearsal room —
//  should not gain a stray character because a thumb landed on it. A lyric is
//  read from in exactly those places and had no such switch, so every scroll
//  through a locked show's songs was a chance to edit one by accident.
//
//  Scoped to one song rather than to the project: songs are locked as they are
//  finished, one at a time, and locking the whole book the moment the first
//  number is done would be the opposite of what that means. It goes one
//  narrower still — per edition of a song, falling back to the song — for the
//  screenplay's reason: locking the performed lyric while a rewrite stays open
//  is the point of a song having editions.
//
//  Its own key family (`scripty-song-edit-locked-…`) rather than the
//  screenplay's `scripty-block-edit-locked-…`: a song edition and a script
//  edition are different things, and sharing a key would let one lock the
//  other if their ids ever met. Nothing here reaches the server — this is a
//  choice about typing, not about the song.
//

import Foundation
import Observation

@Observable
@MainActor
final class SongViewOptions {
    private let documentId: Int
    private let defaults: UserDefaults

    /// The edition currently open, when the song has more than one.
    var editionId: Int? {
        didSet {
            guard editionId != oldValue else { return }
            isEditingLocked = readLock()
        }
    }

    /// Read-only until unlocked. A private setter because the value depends on
    /// which edition is open, and adopting the song's lock when an edition has
    /// none of its own must not write that inherited value back.
    private(set) var isEditingLocked: Bool

    func setEditingLocked(_ locked: Bool) {
        guard locked != isEditingLocked else { return }
        isEditingLocked = locked
        defaults.set(locked, forKey: lockKey())
    }

    // MARK: - Storage

    private static func lockKey(edition: Int) -> String {
        "scripty-song-edit-locked-edition-\(edition)"
    }

    private static func lockKey(document: Int) -> String {
        "scripty-song-edit-locked-document-\(document)"
    }

    /// Where a change to the lock is written: the edition when one is open, so
    /// locking a rewrite leaves the song's default lyric as it was.
    private func lockKey() -> String {
        if let editionId { return Self.lockKey(edition: editionId) }
        return Self.lockKey(document: documentId)
    }

    /// An edition with no lock of its own inherits the song's, so opening a
    /// rewrite of a locked lyric does not hand back the keyboard.
    private func readLock() -> Bool {
        if let editionId,
           let own = defaults.object(forKey: Self.lockKey(edition: editionId)) as? Bool {
            return own
        }
        return defaults.bool(forKey: Self.lockKey(document: documentId))
    }

    init(documentId: Int, editionId: Int? = nil, defaults: UserDefaults = .standard) {
        self.documentId = documentId
        self.editionId = editionId
        self.defaults = defaults

        isEditingLocked = false
        isEditingLocked = readLock()
    }
}
