//
//  main.swift
//  Tests/FastDelete
//
//  Deleting faster than the server can answer.
//
//  Backspace at the head of a line repeats while the key is held, and every
//  repeat used to start a whole fresh removal of the same element — the words
//  went into the line above a second time, and a second DELETE went out for an
//  element the first one had already taken away. A server asked to remove
//  something that is no longer there cannot tell that from an element this
//  writer may not touch, so it answers 403, and the writer gets "You don't
//  have permission to do that" over a line they deleted themselves.
//
//  The same window swallows a save: a debounce armed by the last keystroke
//  before the delete fires into the gap the DELETE is already in, and the PUT
//  lands on a server that has just removed the element. That refusal is louder
//  than an alert — it flags the vanished element as still holding unsaved
//  words, so the badge claims work in hand for an element that is gone.
//
//  Driven against the in-process demo backend, which is a real actor: two
//  requests started together really do overlap, which is the whole condition
//  under test. The demo answers a request for a vanished element 404 where the
//  deployed server answers 403 — either way the writer is told something about
//  a delete that worked, which is what these cases refuse.
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
    guard model.blocks.count >= 3 else {
        check("the demo screenplay has elements to delete", false)
        return nil
    }
    return model
}

/// A song from the same project, kept as separately stored lyric lines.
@MainActor
func openASong() async -> SongBlockModel? {
    let app = AppModel()
    await app.enterDemo(persisted: false)
    guard let projectsLink = app.apiRoot?.link(.projects),
          let projects: HALCollection<Project> = try? await app.client.fetch(from: projectsLink),
          let project = projects.items.first
    else {
        check("the demo has a project", false)
        return nil
    }
    let script = ScriptModel(app: app, project: project)
    await script.loadDocuments()
    guard let song = script.documents.first(where: { $0.kind == .song && $0.hasLink(.songBlocks) })
    else {
        check("the demo has a song kept as lyric lines", false)
        return nil
    }
    let model = SongBlockModel(app: app, document: song)
    await model.load()
    return model
}

// MARK: - Cases

/// The reported bug: hold Backspace at the head of an element and the repeats
/// pile up on the same element.
@MainActor
func checkHeldBackspaceInAScript() async {
    print("== Backspace held at the head of an element ==")
    guard let model = await openAScript() else { return }

    let first = model.blocks[0]
    let second = model.blocks[1]
    let firstText = model.currentText(first)
    let secondText = model.currentText(second)
    let count = model.blocks.count

    // Two repeats of the same keypress, started together: the second arrives
    // while the first is still waiting on the server, which is exactly how
    // fast the key repeats compared to a round trip.
    async let firstPress: Void = model.mergeIntoPrevious(second)
    async let secondPress: Void = model.mergeIntoPrevious(second)
    _ = await (firstPress, secondPress)

    checkEqual("one element went, not two", model.blocks.count, count - 1)
    checkEqual("the words joined the line above once",
               model.currentText(model.blocks[0]), firstText + secondText)
    checkSilent("and nothing was said about a delete that worked",
                model.errorMessage)
}

/// The same key held over a lyric, where a line is stored the same way.
@MainActor
func checkHeldBackspaceInALyric() async {
    print()
    print("== Backspace held at the head of a lyric line ==")
    guard let model = await openASong() else { return }
    guard model.blocks.count >= 3 else {
        check("the song has lines to fold together", false)
        return
    }

    let first = model.blocks[0]
    let second = model.blocks[1]
    let firstText = first.text
    let secondText = second.text
    let count = model.blocks.count

    async let firstPress = model.mergeIntoPrevious(second)
    async let secondPress = model.mergeIntoPrevious(second)
    _ = await (firstPress, secondPress)

    checkEqual("one line went, not two", model.blocks.count, count - 1)
    checkEqual("the words joined the line above once",
               model.blocks.first?.text, firstText + secondText)
    checkSilent("and nothing was said about a fold that worked",
                model.errorMessage)
}

/// Delete chosen twice before the first answer lands — the same shape as the
/// held key, reached through the row's own menu.
@MainActor
func checkDeleteChosenTwice() async {
    print()
    print("== Delete chosen twice in a row ==")
    guard let model = await openAScript() else { return }

    let block = model.blocks[1]
    let count = model.blocks.count

    async let firstTap: Void = model.deleteBlock(block)
    async let secondTap: Void = model.deleteBlock(block)
    _ = await (firstTap, secondTap)

    checkEqual("one element went", model.blocks.count, count - 1)
    checkSilent("and the second press was not reported as a refusal",
                model.errorMessage)
}

/// A save still in flight when the element is deleted. The words are already
/// on their way out; what must not happen is the writer being told off for it,
/// or the element leaving a held-work flag behind after it is gone.
@MainActor
func checkDeleteWhileASaveIsInFlight() async {
    print()
    print("== Deleted while its last keystroke was still going out ==")
    guard let model = await openAScript() else { return }

    let block = model.blocks[1]
    model.liveEdit(block, text: "a word typed a moment before it went")

    // The flush the debounce was about to do, against the delete: on a real
    // connection these overlap whenever the writer deletes within the
    // debounce of their last keystroke.
    async let saved: Void = model.blur(block)
    async let removed: Void = model.deleteBlock(block)
    _ = await (saved, removed)

    check("the element is gone", !model.blocks.contains { $0.id == block.id })
    checkSilent("nothing was said about it", model.errorMessage)
    check("and it left no words behind to hold",
          !model.hasUnsavedChanges && !model.hasFailedSaves)
}

// MARK: - Run

await checkHeldBackspaceInAScript()
await checkHeldBackspaceInALyric()
await checkDeleteChosenTwice()
await checkDeleteWhileASaveIsInFlight()

print()
print(failures == 0 ? "All fast-delete checks passed." : "\(failures) fast-delete check(s) failed.")
exit(failures == 0 ? 0 : 1)
