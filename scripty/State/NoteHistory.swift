//
//  NoteHistory.swift
//  scripty
//
//  Undo and redo for a note, kept on this device.
//
//  A note has no history on the server. The `undo` link walks the project's
//  *blocks*, so pointing a note's ⌘Z at it would revert the screenplay behind
//  the sheet instead of the paragraph in front of it — the browser makes the
//  same call, and refuses to escalate out of a note for exactly that reason.
//  Which is also what makes this one feature rather than two: nothing here
//  asks anything of the network, so a note undoes the same on a train as it
//  does at a desk.
//
//  Not UIKit's `UndoManager`, which the note editor used until now, because the
//  two things a note editor does constantly are the two things that empty it:
//  writing the text from outside (the full document landing after the list's
//  preview, words held offline being taken back up) wipes the field's history,
//  and the manager itself comes up the responder chain, so the caret going to
//  the title field takes undo with it. A writer who tabbed up to fix a title
//  came back to a note that could no longer be walked back at all.
//
//  Snapshots, not diffs: a note is prose — a page of it is a few kilobytes —
//  and a hundred copies of a few kilobytes is nothing next to being sure that
//  what undo restores is exactly what was there. The stack is in memory, like
//  the screenplay's `LocalHistory` and like the browser's: the durable draft
//  guarantees the *current* words survive a relaunch, and a history that
//  outlived the sheet would be a history of somewhere else.
//

import Foundation

/// The undo and redo stacks for one note, as a value.
///
/// `entries[index]` always mirrors what is on screen — every mutation here
/// keeps that true, and the editor keeps its side of the bargain by telling
/// this about words that arrived from anywhere but the keyboard.
struct NoteHistory: Equatable {
    /// A note as it stood, and where the caret was in it. Undo that leaves the
    /// caret at the end of the document is undo you have to hunt after.
    struct Snapshot: Equatable {
        /// Which field a step was typed into. Carried so undo can put the caret
        /// back where the writer made the change — a name taken back with the
        /// caret left in the words is a step whose effect happens off screen.
        enum Field: Equatable {
            case title, body
        }

        /// The name the document was under. One stack covers both fields
        /// because a writer has one document and one ⌘Z: a new song opens with
        /// the caret in its title, and a history that began at the first line
        /// of the lyric would have nothing to say about the twenty keystrokes
        /// before it.
        var title: String
        var text: String
        /// The selection in the text view's own units — UTF-16 offsets, which
        /// is what `NSRange` counts in. Nothing here interprets them; they are
        /// carried so the caret can be put back where it was.
        ///
        /// Always the *body's* selection, whichever field the step belongs to:
        /// a title is one line, and putting its caret at the end is what
        /// assigning the field does anyway.
        var start: Int
        var end: Int
        var field: Field

        init(title: String = "", text: String, start: Int, end: Int,
             field: Field = .body) {
            self.title = title
            self.text = text
            self.start = start
            self.end = end
            self.field = field
        }

        /// A note with the caret at its end — what words arriving from outside
        /// the keyboard get, since there is no caret in them to preserve.
        init(title: String = "", text: String, field: Field = .body) {
            self.init(title: title, text: text, start: (text as NSString).length,
                      end: (text as NSString).length, field: field)
        }

        /// The same words under a different name: a title step, which leaves
        /// the note and the caret in it exactly where they were.
        func renamed(to title: String) -> Snapshot {
            var copy = self
            copy.title = title
            copy.field = .title
            return copy
        }
    }

    /// How many steps back a note can go. The browser's figure; a hundred
    /// paragraphs of history is more than any writer has ever asked for and
    /// still bounded, which is the point.
    static let limit = 100

    /// A burst of typing inside this long is one step. Without it, ⌘Z walks
    /// back a letter at a time and undo becomes useless for the thing it is
    /// actually for — taking back the sentence you just wrote. The browser
    /// waits the same 600ms.
    static let coalesceWindow: TimeInterval = 0.6

    private var entries: [Snapshot]
    private var index: Int

    /// When the last step was pushed, on whatever monotonic clock the caller
    /// keeps. Nil means "the next capture starts a step of its own", which is
    /// how a restored state refuses to have the next keystroke folded onto it.
    private var lastCapture: TimeInterval?

    init(title: String = "", text: String = "") {
        entries = [Snapshot(title: title, text: text)]
        index = 0
    }

    /// What the note should be showing.
    var current: Snapshot { entries[index] }

    var canUndo: Bool { index > 0 }
    var canRedo: Bool { index < entries.count - 1 }

    /// How many states are held, counting the one on screen. For the checks.
    var depth: Int { entries.count }

    /// Start again from `text` — a different note, or the same one arriving
    /// from the server. Everything held described somewhere else.
    ///
    /// Keeps the name it already had, for the surfaces that have no title field
    /// of their own: the workspace's panes are the words alone.
    mutating func reset(to text: String) {
        reset(title: entries[index].title, to: text)
    }

    /// The same, for a surface that names the document as well as writing it.
    mutating func reset(title: String, to text: String) {
        entries = [Snapshot(title: title, text: text)]
        index = 0
        lastCapture = nil
    }

    /// Record what the note now says.
    ///
    /// `coalescing` is what typing does: a run of keystrokes inside the window
    /// folds into the step it started. Anything that changes the note in one
    /// gesture — the formatting bar adding a bullet, an offline draft being
    /// taken back up — passes false, so one press of undo takes back exactly
    /// that gesture and no more of the typing around it.
    mutating func capture(_ snapshot: Snapshot, at now: TimeInterval,
                          coalescing: Bool = true) {
        guard snapshot.text != entries[index].text
                || snapshot.title != entries[index].title else {
            // The caret moved and the document did not. Not a step — but the
            // entry on screen has to keep the caret it actually has, or an
            // undo from here would put it back somewhere the writer left long
            // ago.
            entries[index] = snapshot
            return
        }
        // Writing after an undo forfeits the redo branch, as every editor does.
        if index < entries.count - 1 {
            entries.removeSubrange((index + 1)...)
        }
        // Never across fields, however fast the writer moved between them: a
        // step that took back a name *and* a line of the lyric would undo
        // something the writer cannot see happening.
        let sameField = entries[index].field == snapshot.field
        let withinBurst = coalescing && sameField
            && lastCapture.map { now - $0 < Self.coalesceWindow } == true
        // Never onto entry 0: that is the note as it was before any of this
        // typing, and folding the first keystroke into it would make the
        // writer's own starting point unreachable.
        if withinBurst && index > 0 {
            entries[index] = snapshot
        } else {
            entries.append(snapshot)
            if entries.count > Self.limit {
                entries.removeFirst(entries.count - Self.limit)
            }
            index = entries.count - 1
        }
        lastCapture = now
    }

    /// Step back, or nil when there is nowhere to step back to.
    mutating func undo() -> Snapshot? {
        guard canUndo else { return nil }
        index -= 1
        lastCapture = nil
        return entries[index]
    }

    mutating func redo() -> Snapshot? {
        guard canRedo else { return nil }
        index += 1
        lastCapture = nil
        return entries[index]
    }
}
