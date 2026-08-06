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
//  number is done would be the opposite of what that means. The songs workspace
//  does offer a Lock All Songs, and it changes nothing here: it asks for one of
//  these per song and sets each in turn, so a writer who then unlocks the one
//  number being rewritten still has the rest of the book closed. There is no
//  project-level flag to fall out of step with the documents under it. It goes
//  one narrower still — per edition, falling back to the document — for the
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

/// A bell rung whenever any document's lock changes, so that every reader of
/// that lock redraws.
///
/// The lock lives in `UserDefaults`, and more than one reader now looks at the
/// same document: the songs list holds one per row, the songs workspace holds
/// one per song, and each editor holds its own. Nothing was wrong with that
/// while the switch was in the editor only — a lock set there was read fresh
/// the next time a screen was built. It stopped being true when the list and
/// the workspace grew switches of their own: the list sits alive underneath the
/// workspace, so a song locked up there left a padlock missing on the list the
/// writer came back to.
///
/// A counter rather than the locks themselves. Every reader already knows how
/// to answer from `UserDefaults` — what none of them had was a reason to look
/// again. Observing this in the getter gives them one, and leaves the stored
/// answer where it is rather than making a second copy of it to fall out of
/// step in its own way.
@Observable
@MainActor
final class DocumentLockChanges {
    static let shared = DocumentLockChanges()

    private(set) var generation = 0

    func changed() { generation += 1 }
}

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
    /// Which family of keys this reader answers from. Not private: a screen
    /// holding one of these per row has to notice when a document changes kind
    /// under it, and re-make the reader against the other family.
    let kind: Kind
    private let defaults: UserDefaults

    /// The edition currently open, when the song has more than one.
    var editionId: Int?

    /// Read-only until unlocked. Asked of the store every time rather than kept
    /// here: the same document is read by a row on the list, a section on the
    /// workspace and the editor over both, and a lock taken off in one of them
    /// has to reach the other two. `DocumentLockChanges` is what makes a reader
    /// look again — without it this getter would be a value SwiftUI has no
    /// reason to re-evaluate.
    ///
    /// No setter of its own: the value depends on which edition is open, and
    /// adopting the document's lock when an edition has none must not write
    /// that inherited value back.
    var isEditingLocked: Bool {
        // Observed for its own sake, so a change anywhere redraws here.
        _ = DocumentLockChanges.shared.generation
        return readLock()
    }

    func setEditingLocked(_ locked: Bool) {
        guard locked != isEditingLocked else { return }
        defaults.set(locked, forKey: lockKey())
        DocumentLockChanges.shared.changed()
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
    }
}
