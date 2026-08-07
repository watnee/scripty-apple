//
//  main.swift
//  Tests/UndoRace
//
//  Pressing undo while a save is still counting down.
//
//  The server's undo is not an edit to the elements on screen: it deletes every
//  element in the edition and re-inserts the snapshot, so every id the app is
//  holding stops existing the moment the step lands. A writer types and reaches
//  straight for undo — well inside the 600ms debounce — and the PUT that
//  keystroke armed fires into the gap the rebuild opens. The server cannot tell
//  a request for an element it has just destroyed from a request for one this
//  writer may not touch, so it answers 403, and the writer is told "You don't
//  have permission to do that" over an undo that worked perfectly. The refusal
//  also flags the vanished element as still holding unsaved words, so the badge
//  claims work in hand that nothing can ever save.
//
//  The refusal itself is out of reach here, and deliberately not faked. It
//  needs the window between the server committing the rebuild and this device
//  finishing its reload — a round trip wide on a phone, and sub-millisecond
//  against an in-process backend that keeps its ids besides. What these cases
//  pin is the state the fix settles, which is the same fix and reproduces
//  every time: words still in the debounce reach the server before the step
//  goes out, and nothing is left on screen or in the badge describing a script
//  the server has already replaced.
//
//  Run via Tests/run.sh.
//

import Foundation

_ = setvbuf(stdout, nil, _IOLBF, 0)

var failures = 0

func check(_ label: String, _ condition: Bool) {
    print(condition ? "  PASS  \(label)" : "  FAIL  \(label)")
    if !condition { failures += 1 }
}

/// The alert the writer would have been shown, quoted in the failure so the
/// suite says *what* was said rather than only that something was.
func checkSilent(_ label: String, _ message: String?) {
    check(message.map { "\(label) — said: \($0)" } ?? label, message == nil)
}

func checkEqual<T: Equatable>(_ label: String, _ actual: T, _ expected: T) {
    let ok = actual == expected
    print(ok ? "  PASS  \(label)"
             : "  FAIL  \(label)\n          expected: \(expected)\n          actual:   \(actual)")
    if !ok { failures += 1 }
}

// MARK: - Harness

/// Long enough for a debounce armed before the step to have fired afterwards.
/// The point of every case here is what the app does in that window, so the
/// window has to actually elapse.
func waitOutTheDebounce() async {
    try? await Task.sleep(for: .milliseconds(1200))
}

/// The demo project's screenplay, loaded and ready to type into.
@MainActor
func openAScript() async -> ScriptModel? {
    let app = AppModel()
    await app.enterDemo(persisted: false)
    guard let projectsLink = app.apiRoot?.link(.projects),
          let projects: HALCollection<Project> = try? await app.client.fetch(from: projectsLink),
          let project = projects.items.first
    else {
        check("the demo has a project", false)
        return nil
    }
    let model = ScriptModel(app: app, project: project)
    await model.open()
    guard !model.blocks.isEmpty else {
        check("the demo screenplay has elements to type into", false)
        return nil
    }
    return model
}

// MARK: - Cases

/// One press, one change. Words that never got out are still a change the
/// writer made, and a step that goes out around them takes back the change
/// *before* them as well — two edits undone by one press, and the newer of the
/// two thrown away silently, since nothing is left on screen to put it back on.
@MainActor
func checkOnePressTakesBackOneChange() async {
    print("== A press with words that have not been saved yet ==")
    guard let model = await openAScript() else { return }

    // Two changes, in order: an element added (and saved), then words typed
    // into it that are still inside the debounce when undo is pressed.
    guard await model.createBlock(content: "A new line", type: .action, personId: nil),
          let created = model.blocks.last else {
        check("a fresh element could be added", false)
        return
    }
    await model.refreshUndoRedo()
    guard model.canUndo else {
        check("the server offers a step to walk back", false)
        return
    }
    model.liveEdit(created, text: "Half a sentence")
    await model.undo()
    await waitOutTheDebounce()

    guard let after = model.blocks.first(where: { $0.id == created.id }) else {
        check("the element is still there — one press took back the typing, "
              + "not the typing and the element it was typed into", false)
        return
    }
    checkEqual("and it reads what it did before those words",
               model.currentText(after), "A new line")
    checkSilent("with nothing said about an undo that worked", model.errorMessage)
    check("and nothing left flagged as holding words that cannot be saved",
          !model.hasUnsavedChanges)
}

/// The quieter half of the same race: the element survives the step, so the
/// stray write lands rather than being refused — and silently puts back the
/// very words the writer pressed undo to be rid of.
@MainActor
func checkTypingIsTakenBackRatherThanReappearing() async {
    print()
    print("== The words typed a moment before the press ==")
    guard let model = await openAScript() else { return }

    let target = model.blocks[0]
    // A committed edit first, so undo has somewhere to land that is not the
    // state the script opened in.
    model.liveEdit(target, text: "First words")
    await model.blur(target)
    await model.refreshUndoRedo()
    guard model.canUndo else {
        check("the server offers a step to walk back", false)
        return
    }

    // Type again, and press undo before the save goes out.
    model.liveEdit(target, text: "Second words")
    await model.undo()
    await waitOutTheDebounce()

    guard let after = model.blocks.first(where: { $0.id == target.id }) else {
        check("the element is still in the script", false)
        return
    }
    checkEqual("the element reads what it did before the last thing typed",
               model.currentText(after), "First words")
    checkSilent("and nothing was said about it", model.errorMessage)
    check("with nothing left held", !model.hasUnsavedChanges)
}

/// Redo walks the same path and rebuilds the script the same way, so it needs
/// the same quiet before it goes out.
@MainActor
func checkRedoCarriesTheSameGuard() async {
    print()
    print("== Redo, with a save still counting down ==")
    guard let model = await openAScript() else { return }

    let target = model.blocks[0]
    model.liveEdit(target, text: "First words")
    await model.blur(target)
    await model.refreshUndoRedo()
    await model.undo()
    guard model.canRedo else {
        check("the step can be walked forward again", false)
        return
    }

    model.liveEdit(target, text: "Typed after the undo")
    await model.redo()
    await waitOutTheDebounce()

    checkSilent("nothing was said about a redo that worked", model.errorMessage)
    check("and nothing is left flagged unsaved", !model.hasUnsavedChanges)
}

await checkOnePressTakesBackOneChange()
await checkTypingIsTakenBackRatherThanReappearing()
await checkRedoCarriesTheSameGuard()

print()
print(failures == 0 ? "All undo-race checks passed." : "\(failures) undo-race check(s) failed.")
exit(failures == 0 ? 0 : 1)
