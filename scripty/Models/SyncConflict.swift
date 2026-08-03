//
//  SyncConflict.swift
//  scripty
//
//  Two versions of the same words: the ones typed on this device while it
//  could not reach the server, and the ones the server has now.
//
//  Until this existed, that situation had exactly one outcome — the device's
//  copy was deleted and a toast said so. The server is last-write-wins, so
//  pushing an offline draft over words written elsewhere in the meantime would
//  clobber them; dropping the draft was the only safe move a client that could
//  not ask anybody could make. But the words being dropped were typed by the
//  writer, never seen to land, and often no longer anywhere else at all: the
//  safe move for the other version was the lossy one for this one.
//
//  A conflict is that decision, deferred and made durable. Both versions are
//  kept, off to one side of the ordinary held-work machinery (nothing retries
//  a conflict — it is waiting on a person, not on a connection), until the
//  writer says which one wins.
//

import Foundation

/// What became of a "Keep Mine". The middle case is why this is not a Bool:
/// a resolution that could not get out is not a failure — the words are back
/// in the ordinary held-work machinery, on disk and retrying — and a sheet
/// that said "couldn't" over them would send the writer looking for words
/// that are perfectly safe.
enum ConflictResolution: Equatable {
    /// The server has the chosen version.
    case sent
    /// Chosen, kept on this device, and on its way when the connection is.
    case held
    /// Refused, or there was nothing left to write to.
    case failed
}

/// One unresolved disagreement between this device's words and the server's.
///
/// `Codable` because these outlive the session that found them: a conflict
/// discovered on a reconnect sweep with the sheet closed must still be there
/// to answer the next time the writer opens that note.
struct SyncConflict: Codable, Equatable, Identifiable {
    /// What the two versions are of. The id inside is what the resolution is
    /// applied to, and what a second conflict for the same thing replaces.
    enum Subject: Codable, Equatable, Hashable {
        /// A screenplay element.
        case block(id: Int)
        /// One line of a song's lyric.
        case lyricLine(id: Int)
        /// A whole note, or a prose song — title and body together.
        case document(id: Int)

        var id: Int {
            switch self {
            case let .block(id), let .lyricLine(id), let .document(id): return id
            }
        }
    }

    /// Why the device's copy could not simply be sent. Only the wording
    /// changes with it — every reason ends in the same question — but a writer
    /// deciding between two paragraphs deserves to know which of the three
    /// happened, because the answer differs: one is a race with another
    /// person, one is a race with a deletion, and one is the server saying no.
    enum Reason: String, Codable {
        /// Someone edited this elsewhere after the save failed here.
        case changedElsewhere
        /// The thing these words belong to was deleted while they were held.
        case targetDeleted
        /// The server refused the write outright — a failure no retry fixes.
        case refused
    }

    var subject: Subject
    var reason: Reason

    /// The words held on this device: the writing that never reached the
    /// server. `mineTitle` is set for documents only, where the title is part
    /// of what diverged.
    var mine: String
    var mineTitle: String?

    /// What the server had when the conflict was found. Empty for a deleted
    /// target — there is nothing on the other side to keep.
    var theirs: String
    var theirsTitle: String?

    /// What both versions started from, when this device knew it. Shown as
    /// context ("you both changed this line") and nothing more: the merge is
    /// the writer's to make, and a client guessing at one would be inventing a
    /// third version nobody wrote.
    var base: String?

    /// What to call the thing on screen — an element's type ("Action"), a
    /// note's title, a lyric's first words. Captured at detection because the
    /// thing itself may be gone by the time anyone looks.
    var label: String

    /// When this device gave up trying to send and started asking instead.
    var detectedAt: Date

    /// Stable across a relaunch: the file is the list, and a row identified by
    /// its position would shuffle under the writer as others are resolved.
    var id: String {
        switch subject {
        case let .block(id): return "block-\(id)"
        case let .lyricLine(id): return "line-\(id)"
        case let .document(id): return "document-\(id)"
        }
    }

    /// Whether "Keep Mine" can actually be carried out. False when the thing
    /// the words belong to no longer exists: there is nowhere to put them, and
    /// a button promising otherwise would fail on every press. Those conflicts
    /// offer copying the words out instead.
    var canKeepMine: Bool { reason != .targetDeleted }

    /// Whether there is a server version to keep. A deleted target has none —
    /// "Keep Theirs" there means letting the deletion stand.
    var hasTheirs: Bool { reason != .targetDeleted }

    /// One line naming what happened, in the writer's terms rather than the
    /// sync machinery's.
    var headline: String {
        switch reason {
        case .changedElsewhere: return "Changed in two places"
        case .targetDeleted: return "Deleted elsewhere"
        case .refused: return "The server wouldn't take this"
        }
    }

    /// The sentence under the headline: what the two versions are, and what
    /// choosing does.
    var explanation: String {
        switch reason {
        case .changedElsewhere:
            return "You edited this on this device while it was offline, and it "
                + "also changed somewhere else. Both versions are here — keeping "
                + "one replaces the other."
        case .targetDeleted:
            return "This was deleted somewhere else while your edit was waiting "
                + "to be sent. Your words are kept here; there is nothing left "
                + "to put them back into, so copy anything you still want."
        case .refused:
            return "The server refused this change and no amount of waiting will "
                + "fix it. Your words are kept here so nothing is lost — try "
                + "again, or discard them."
        }
    }
}
