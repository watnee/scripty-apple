//
//  DismissedNotices.swift
//  scripty
//
//  Which standing notices the writer has closed.
//
//  The offline and held-work strips say something worth saying once — the words
//  are on this device and a retry is already in flight — and then go on saying
//  it for as long as the connection is out, taking a band off the top of the
//  page the whole time. Closing one is not the writer disagreeing; it is the
//  writer having read it. The toolbar cloud goes on reporting the same state in
//  the corner, so nothing is lost by letting the strip go.
//
//  A dismissal is about one situation, not about a kind of notice forever. Each
//  caller hands in a key for *what* the notice is about and a short string for
//  *which* situation is on: going back online and offline again, or a refusal
//  arriving on top of held work, is a new situation and speaks up again.
//
//  Nothing is written to disk on purpose. A relaunch is a fresh start, and an
//  app that opens offline should say so rather than stay quiet about it because
//  of a tap in some earlier session.
//
//  Shared rather than owned, for the same reason the appearance setting is: the
//  writer closed a notice, not a view — walking to another screen and back
//  should not undo the tap.
//

import Foundation
import Observation

@Observable
@MainActor
final class DismissedNotices {
    static let shared = DismissedNotices()

    /// Notice key → the situation string that was on screen when it was closed.
    private var closed: [String: String] = [:]

    /// Whether this notice, saying this, has already been put down.
    func isDismissed(_ key: String, state: String) -> Bool {
        closed[key] == state
    }

    func dismiss(_ key: String, state: String) {
        closed[key] = state
    }

    /// The situation moved on — to a different one, or to none at all. What was
    /// closed was closed about the old one, so it stops applying: the next time
    /// this notice has something to say, it says it.
    func situationChanged(_ key: String) {
        closed[key] = nil
    }

    // MARK: - Shared spellings

    /// One song's stale-copy notice. Named here rather than spelled out at each
    /// call site because two screens raise it — the song editor and the songs
    /// workspace — and closing it in one is meant to close it in the other.
    static func offlineCopyKey(songId: Int) -> String {
        "song.offlineCopy.\(songId)"
    }

    /// One document's stale-copy notice — the words of a note, or of a song the
    /// server keeps as prose. Kept apart from the song key above even though the
    /// ids come from one table: those are a lyric's lines and these are a
    /// document's text, two payloads cached separately, and one of them being
    /// old says nothing about the other. Two screens raise this one too — the
    /// note editor and the notes workspace.
    static func documentCopyKey(documentId: Int) -> String {
        "document.offlineCopy.\(documentId)"
    }

    /// The situation string for a copy read back from disk. A newer copy is a
    /// different thing to be told, and those same two screens have to agree on
    /// what they are telling.
    static func offlineCopyState(savedAt: Date) -> String {
        "\(savedAt.timeIntervalSinceReferenceDate)"
    }
}
