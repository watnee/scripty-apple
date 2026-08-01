//
//  DocumentViewOptions.swift
//  scripty
//
//  Whether a song or a note can be typed into.
//
//  The screenplay has had an editing lock since it shipped: a finished draft
//  that is being read from — at a table read, on a phone in a rehearsal room —
//  should not gain a stray character because a thumb landed on it. A lyric is
//  read from in exactly those places and had no such switch, so every scroll
//  through a locked show's songs was a chance to edit one by accident.
//
//  A note is read from in those places too — the shot list held up on set, the
//  production notes open on a stand — and it was the last writing surface in the
//  app with no lock at all, which is why this is no longer named after songs.
//  The two kinds keep separate key families (`scripty-song-edit-locked-…` and
//  `scripty-note-edit-locked-…`) rather than one shared document family: the
//  song keys are already on writers' devices, re-keying them would silently
//  unlock every locked song, and a key that says what it locks is worth more
//  than one fewer branch here.
//
//  Scoped to one document rather than to the project: songs are locked as they
//  are finished, one at a time, and locking the whole book the moment the first
//  number is done would be the opposite of what that means. It goes one
//  narrower still — per edition, falling back to the document — for the
//  screenplay's reason: locking the performed lyric while a rewrite stays open
//  is the point of a song having editions. A note has no editions, so it simply
//  never passes one.
//
//  Its own key family rather than the screenplay's `scripty-block-edit-locked-…`
//  either way: a document edition and a script edition are different things, and
//  sharing a key would let one lock the other if their ids ever met. Nothing
//  here reaches the server — this is a choice about typing, not about the words.
//

import Foundation
import Observation

@Observable
@MainActor
final class DocumentViewOptions {
    /// Which kind of document is being locked, and so which family of keys
    /// holds the answer. Its own small enum rather than `DocumentType`: this
    /// store has two answers to give, the server's type has three, and "other"
    /// is a note as far as every screen in this app is concerned.
    enum Kind: Sendable {
        case song
        case note

        /// The word in the middle of the key.
        var keyword: String {
            switch self {
            case .song: return "song"
            case .note: return "note"
            }
        }
    }

    private let documentId: Int
    private let kind: Kind
    private let defaults: UserDefaults

    /// The edition currently open, when the song has more than one.
    var editionId: Int? {
        didSet {
            guard editionId != oldValue else { return }
            isEditingLocked = readLock()
        }
    }

    /// Read-only until unlocked. A private setter because the value depends on
    /// which edition is open, and adopting the document's lock when an edition
    /// has none of its own must not write that inherited value back.
    private(set) var isEditingLocked: Bool

    func setEditingLocked(_ locked: Bool) {
        guard locked != isEditingLocked else { return }
        isEditingLocked = locked
        defaults.set(locked, forKey: lockKey())
    }

    // MARK: - Storage

    private func lockKey(edition: Int) -> String {
        "scripty-\(kind.keyword)-edit-locked-edition-\(edition)"
    }

    private func lockKey(document: Int) -> String {
        "scripty-\(kind.keyword)-edit-locked-document-\(document)"
    }

    /// Where a change to the lock is written: the edition when one is open, so
    /// locking a rewrite leaves the song's default lyric as it was.
    private func lockKey() -> String {
        if let editionId { return lockKey(edition: editionId) }
        return lockKey(document: documentId)
    }

    /// An edition with no lock of its own inherits the document's, so opening a
    /// rewrite of a locked lyric does not hand back the keyboard.
    private func readLock() -> Bool {
        if let editionId,
           let own = defaults.object(forKey: lockKey(edition: editionId)) as? Bool {
            return own
        }
        return defaults.bool(forKey: lockKey(document: documentId))
    }

    init(documentId: Int, kind: Kind = .song, editionId: Int? = nil,
         defaults: UserDefaults = .standard) {
        self.documentId = documentId
        self.kind = kind
        self.editionId = editionId
        self.defaults = defaults

        isEditingLocked = false
        isEditingLocked = readLock()
    }
}
