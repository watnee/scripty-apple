//
//  Note undo/redo checks
//
//  The stack a note's ⌘Z walks. All of it is off-by-one territory — which
//  entry mirrors the screen, which keystroke folds into the one before it,
//  what a redo branch does when you type over it — and every one of those is
//  invisible until the press that goes one step too far and takes a paragraph
//  with it.
//
//  Run via Tests/run.sh.
//

import Foundation

var failures = 0

func check(_ label: String, _ actual: some Equatable, _ expected: some Equatable) {
    if "\(actual)" == "\(expected)" {
        print("  PASS  \(label)")
    } else {
        failures += 1
        print("  FAIL  \(label) — expected \(expected), got \(actual)")
    }
}

/// Typing, as the editor reports it: the whole note, with the caret at the end
/// of it, at a given moment on the clock.
extension NoteHistory {
    mutating func type(_ text: String, at now: TimeInterval) {
        capture(Snapshot(text: text), at: now)
    }

    /// A gesture rather than typing — the formatting bar, or an offline draft
    /// taken back up.
    mutating func gesture(_ text: String, at now: TimeInterval) {
        capture(Snapshot(text: text), at: now, coalescing: false)
    }
}

print("An untouched note")
do {
    let history = NoteHistory(text: "Scene one.")
    check("has nothing to undo", history.canUndo, false)
    check("has nothing to redo", history.canRedo, false)
    check("and shows what it opened with", history.current.text, "Scene one.")
}

print("")
print("A burst of typing")
do {
    var history = NoteHistory(text: "")
    history.type("T", at: 0.0)
    history.type("Th", at: 0.1)
    history.type("The", at: 0.2)
    check("is one step, not three", history.depth, 2)
    _ = history.undo()
    check("which undo takes back whole", history.current.text, "")

    // The pause is what separates a sentence from the one before it.
    var paused = NoteHistory(text: "")
    paused.type("The", at: 0.0)
    paused.type("The cat", at: 5.0)
    check("but a pause starts a new one", paused.depth, 3)
    check("so undo takes back the second half", paused.undo()?.text, Optional("The"))
    check("and then the first", paused.undo()?.text, Optional(""))
    check("and then stops", paused.undo()?.text, Optional<String>.none)
}

print("")
print("The note as it was before any typing")
do {
    // The first keystroke must never be folded into the baseline: the words
    // the writer opened with are the one state undo has to be able to reach.
    var history = NoteHistory(text: "Scene one.")
    history.type("Scene one.X", at: 0.0)
    history.type("Scene one.XY", at: 0.1)
    check("is always reachable", history.undo()?.text, Optional("Scene one."))
    check("even from a single burst", history.canUndo, false)
}

print("")
print("Undo and redo")
do {
    var history = NoteHistory(text: "one")
    history.type("one two", at: 0.0)
    history.type("one two three", at: 5.0)
    check("walk back", history.undo()?.text, Optional("one two"))
    check("and forward again", history.redo()?.text, Optional("one two three"))
    check("and stop at the top", history.redo()?.text, Optional<String>.none)
    _ = history.undo()
    _ = history.undo()
    check("and at the bottom", history.undo()?.text, Optional<String>.none)
    check("leaving the note as it started", history.current.text, "one")
}

print("")
print("Typing after an undo")
do {
    var history = NoteHistory(text: "one")
    history.type("one two", at: 0.0)
    history.type("one two three", at: 5.0)
    _ = history.undo()
    check("has a redo to forfeit", history.canRedo, true)
    history.type("one two THREE", at: 10.0)
    check("and forfeits it", history.canRedo, false)
    check("keeping what was typed", history.current.text, "one two THREE")
    check("over what was undone", history.undo()?.text, Optional("one two"))
}

print("")
print("A keystroke straight after an undo")
do {
    // The restored state is a place the writer asked to be at. Folding the
    // next letter onto it would rewrite the thing they just came back to.
    var history = NoteHistory(text: "one")
    history.type("one two", at: 0.0)
    _ = history.undo()
    history.type("oneX", at: 0.1)
    check("is a step of its own", history.undo()?.text, Optional("one"))
}

print("")
print("A gesture")
do {
    // A bullet added by the bar lands mid-burst, and must still come off in
    // one press rather than taking the sentence around it too.
    var history = NoteHistory(text: "milk")
    history.type("milk!", at: 0.0)
    history.gesture("- milk!", at: 0.1)
    check("is never folded into the typing", history.undo()?.text, Optional("milk!"))
    check("which is still there under it", history.undo()?.text, Optional("milk"))
}

print("")
print("The caret")
do {
    var history = NoteHistory(text: "one")
    history.capture(NoteHistory.Snapshot(text: "one two", start: 7, end: 7), at: 0.0)
    _ = history.undo()
    check("comes back with the words", history.current.start, 3)

    // Moving the caret is not an edit — but the entry on screen has to follow
    // it, or an undo from here would put it back where it was minutes ago.
    var moved = NoteHistory(text: "one")
    moved.capture(NoteHistory.Snapshot(text: "one", start: 0, end: 0), at: 1.0)
    check("moving it alone is not a step", moved.depth, 1)
    check("but is remembered", moved.current.start, 0)
}

print("")
print("A note written all day")
do {
    var history = NoteHistory(text: "0")
    for step in 1...(NoteHistory.limit + 20) {
        history.type("\(step)", at: TimeInterval(step) * 5)
    }
    check("holds a bounded history", history.depth, NoteHistory.limit)
    check("of the most recent states", history.current.text, "\(NoteHistory.limit + 20)")
    check("and can still walk back through it", history.undo()?.text,
          Optional("\(NoteHistory.limit + 19)"))
}

print("")
print("A note the server sends again")
do {
    var history = NoteHistory(text: "draft")
    history.type("draft, edited", at: 0.0)
    history.reset(to: "what the server holds")
    check("starts the history over", history.canUndo, false)
    check("at what arrived", history.current.text, "what the server holds")
    // And a burst that began before the reset must not fold onto it.
    history.type("what the server holds!", at: 0.1)
    check("with nothing folded into it", history.undo()?.text,
          Optional("what the server holds"))
}

print("")
if failures == 0 {
    print("Note undo/redo checks passed.")
    exit(0)
} else {
    print("\(failures) note undo/redo check(s) FAILED.")
    exit(1)
}
