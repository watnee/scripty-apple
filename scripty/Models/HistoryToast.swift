//
//  HistoryToast.swift
//  scripty
//
//  The one line a step through history leaves behind.
//
//  Undo is the one gesture whose effect can be nowhere near the finger that
//  asked for it. A step can bring back an element — or a lyric line — that
//  scrolled off the screen minutes ago, and a writer left looking at unchanged
//  words has no way to tell a step that worked from one that never fired. So
//  every surface keeping a document-wide history says what the step did, in
//  the same words and for the same few seconds the browser does.
//
//  A token beside the words rather than the words alone, because two identical
//  messages in a row — ⌘Z twice over, "Change undone" both times — have to read
//  as two events. The token is what makes the second one a change the view can
//  see.
//
//  Shared rather than nested in one model: the screenplay and the lyric keep
//  their own histories and their own stacks, and the pair of them showing the
//  same confirmation in the same corner is the whole point. The screenplay's
//  offline notices borrow it too — they are the other thing that happens to a
//  document while nobody is looking at that part of it.
//

import Foundation

struct HistoryToast: Equatable {
    var token: Int
    var text: String

    /// The next confirmation after `previous`, whose only job is to carry a
    /// token nothing has shown yet. Kept here so no model has to keep a
    /// counter of its own beside the value it already holds.
    static func next(after previous: HistoryToast?, _ text: String) -> HistoryToast {
        HistoryToast(token: (previous?.token ?? 0) + 1, text: text)
    }

    /// What a step is called when it moved no elements — the plain
    /// acknowledgement both histories fall back to. `restored` above it is the
    /// case worth naming: a step that brought things back.
    static func message(undoing: Bool, restored: Int, noun: String) -> String {
        if restored > 0 {
            return "Restored \(restored) \(noun)\(restored == 1 ? "" : "s")"
        }
        return undoing ? "Change undone" : "Change redone"
    }
}
