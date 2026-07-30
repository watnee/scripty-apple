//
//  LocalHistory.swift
//  scripty
//
//  Undo/redo for the changes the server never saw. Online, undo is a server
//  affair — the app POSTs to the `undo` link and adopts the answer — but with
//  no connection that link is unreachable, which used to leave the writer's
//  one reflex dead exactly when they were most on their own. This records the
//  changes the offline machinery holds on the device (text kept for retry,
//  elements queued for creation, offline retypes and deletes) as reversible
//  steps, so ⌘Z can walk them back without asking anyone.
//
//  Only the record lives here; applying a step means touching `blocks`, the
//  live text and the outbox, which is `ScriptModel`'s to do. The stacks are
//  in memory on purpose: the durable stores already guarantee the *current*
//  words survive a relaunch, and a history that outlives the state it
//  describes would be a history of somewhere else.
//

import Foundation

/// One reversible change made on this device while the server was out of
/// reach. `before`/`after` pairs read in document terms: undo applies the
/// `before` side, redo the `after`.
enum LocalChange: Equatable {
    /// A block's text, as held for retry or in a queued create.
    case text(blockId: Int, before: String, after: String)
    /// A pending element's type (raw server strings, like the queue keeps).
    case retype(blockId: Int, before: String, after: String)
    /// An element written offline came into being.
    case create(row: LocalHistory.Row)
    /// Pending elements were removed — a delete takes its whole anchored
    /// chain with it, so this holds every row that went.
    case remove(rows: [LocalHistory.Row])
}

/// One press of undo. Usually a single change; a gesture that does two things
/// at once (a split that retypes the line it splits) records them together so
/// one press takes the whole gesture back.
struct LocalStep: Equatable {
    var changes: [LocalChange]
}

/// The two stacks, plus the per-block bookkeeping that keeps text steps
/// contiguous: each step's `before` must be the previous step's `after`, not
/// the server content frozen underneath them.
struct LocalHistory: Equatable {
    /// A queued element and where it stood on screen — enough to take it off
    /// and to put it back.
    struct Row: Equatable {
        var entry: PendingBlockCreate
        var index: Int
    }

    private(set) var undoSteps: [LocalStep] = []
    private(set) var redoSteps: [LocalStep] = []

    /// The last text this history recorded (or applied) per block. While a
    /// block's writes keep failing, its `content` never moves, so this — not
    /// the block — is where the previous step's `after` is remembered.
    private var lastText: [Int: String] = [:]

    var canUndo: Bool { !undoSteps.isEmpty }
    var canRedo: Bool { !redoSteps.isEmpty }
    var isEmpty: Bool { undoSteps.isEmpty && redoSteps.isEmpty }

    /// The text change recording `current` for this block would mean, or nil
    /// when nothing actually changed — which is what a retry re-reporting the
    /// same failed words looks like, and why recording is idempotent.
    func textChange(blockId: Int, to current: String, lastSaved: String) -> LocalChange? {
        let before = lastText[blockId] ?? lastSaved
        guard before != current else { return nil }
        return .text(blockId: blockId, before: before, after: current)
    }

    /// Push one step. Recording anything new forfeits the redo stack, as
    /// every undo model does.
    mutating func record(_ changes: [LocalChange]) {
        guard !changes.isEmpty else { return }
        for case let .text(blockId, _, after) in changes { lastText[blockId] = after }
        undoSteps.append(LocalStep(changes: changes))
        redoSteps.removeAll()
    }

    /// Take back the most recent record, if it is the single text change the
    /// caller describes. For the speculative writes (a merge, a split) that
    /// record on failure and then roll the screen back — the record must roll
    /// back with it or undo would replay a change nobody kept.
    mutating func unrecordText(blockId: Int, after: String) {
        guard let last = undoSteps.last, last.changes.count == 1,
              case let .text(id, before, stepAfter) = last.changes[0],
              id == blockId, stepAfter == after else { return }
        undoSteps.removeLast()
        lastText[blockId] = before
    }

    mutating func popUndo() -> LocalStep? {
        undoSteps.popLast()
    }

    /// File an undone step for redo. Separate from `record` so redo survives.
    mutating func pushUndone(_ step: LocalStep) {
        redoSteps.append(step)
    }

    mutating func popRedo() -> LocalStep? {
        redoSteps.popLast()
    }

    /// Put a redone step back on the undo side, without touching redo.
    mutating func pushRedone(_ step: LocalStep) {
        undoSteps.append(step)
    }

    /// A step was applied and this block now shows `text` — keep the chain
    /// contiguous for whatever is recorded next.
    mutating func noteApplied(blockId: Int, text: String) {
        lastText[blockId] = text
    }

    /// The server accepted this block's text; its content is authoritative
    /// again and the next offline step measures from there.
    mutating func noteSaved(blockId: Int) {
        lastText[blockId] = nil
    }

    /// Everything here describes state that no longer exists — the sync
    /// landed, a server undo rewrote the script, another edition is on
    /// screen. Server history owns undo again.
    mutating func clear() {
        undoSteps.removeAll()
        redoSteps.removeAll()
        lastText.removeAll()
    }
}
