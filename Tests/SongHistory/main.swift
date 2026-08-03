//
//  main.swift
//  Tests/SongHistory
//
//  Undo and redo in a lyric, on both sides of the connection.
//
//  With a route to the server, a step is the server's: the app POSTs the link
//  it advertised and adopts the lyric that comes back, so the client walks the
//  same history the browser does. Those cases run against the in-process demo
//  backend, so the PUT, the checkpoint it leaves and the POST that walks back
//  to it all really happen.
//
//  Without a route there is no link to POST to, and the writer's one reflex
//  used to be dead exactly where they are most on their own. The edits held on
//  the device are changes only the device knows, and this suite pins what
//  taking them back has to mean: the words go back on screen *and* on disk, the
//  steps come back one at a time in the order they were made, a backoff retry
//  is not a new step, a gesture that was rolled back leaves none, and a sync
//  that falls short keeps every one of them.
//
//  Either way the step says what it did, as the screenplay's does: a lyric is
//  rewritten whole, so the line a step brings back may be one the writer cannot
//  see from where they are standing.
//
//  The offline cases drive real models through a real APIClient with the
//  connectivity monitor held down by hand, which is the same fail-fast path a
//  writer on a train takes — no socket, no stub.
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

func checkEqual<T: Equatable>(_ label: String, _ actual: T, _ expected: T) {
    let ok = actual == expected
    print(ok ? "  PASS  \(label)"
             : "  FAIL  \(label)\n          expected: \(expected)\n          actual:   \(actual)")
    if !ok { failures += 1 }
}

func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T {
    try! JSONDecoder().decode(T.self, from: Data(json.utf8))
}

// MARK: - Harness

/// The song the lyric belongs to. Only its id matters here — it keys the
/// draft file.
let song: TextDocument = decode(TextDocument.self,
    #"{"id": 7, "title": "Test Song", "documentType": "SONG"}"#)

/// Two lyric lines advertising the links the editing paths gate on. Nothing
/// here is ever fetched: the monitor is held offline, so the client refuses
/// each request on its own doorstep, which is what a writer with no route
/// actually meets.
func twoLineCollection() -> HALCollection<SongBlock> {
    decode(HALCollection<SongBlock>.self, """
    {
      "_embedded": {
        "songBlockResourceList": [
          {
            "id": 40, "order": 1, "content": "First verse.",
            "_links": {
              "update": {"href": "/api/song-blocks/40"},
              "delete": {"href": "/api/song-blocks/40"}
            }
          },
          {
            "id": 41, "order": 2, "content": "Second verse.",
            "_links": {
              "update": {"href": "/api/song-blocks/41"},
              "delete": {"href": "/api/song-blocks/41"}
            }
          }
        ]
      },
      "_links": {"self": {"href": "/api/documents/7/song-blocks"}}
    }
    """)
}

func scratchDirectory(_ name: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("scripty-song-history-\(name)-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.removeItem(at: url)
    return url
}

/// A lyric on a device with no route to the network. Hand-driven rather than
/// asked of the system, so the verdict does not depend on whether the machine
/// running the suite happens to have a connection.
@MainActor
func offlineModel(draftStore: UnsavedDraftStore? = nil) -> SongBlockModel {
    let monitor = ConnectivityMonitor(startMonitoring: false)
    monitor.adopt(false)
    let model = SongBlockModel(app: AppModel(connectivity: monitor),
                               document: song, draftStore: draftStore)
    model.adopt(twoLineCollection())
    return model
}

/// The first line as the model currently holds it — a snapshot taken before a
/// save is stale afterwards.
@MainActor
func firstLine(_ model: SongBlockModel) -> SongBlock { model.blocks[0] }

// MARK: - Offline

@MainActor
func checkTypingIsAStep() async {
    print("== Words the server never heard are still a change to take back ==")
    let model = offlineModel()

    model.edit(firstLine(model), text: "First verse, rewritten.")
    await model.commit(firstLine(model))

    check("the line is held", model.unsavedBlockIds.contains(40))
    check("and there is somewhere to step back to", model.canUndo)
    check("with nothing forward yet", !model.canRedo)
    check("so the pair belongs on screen", model.offersUndoRedo)
    check("even though this song's history link was never advertised",
          !model.hasUndoStack)
    checkEqual("one step, not one per keystroke", model.localHistory.undoSteps.count, 1)
}

@MainActor
func checkUndoPutsTheWordsBack() async {
    print("== Undo puts the words back, on screen and on disk ==")
    let store = UnsavedDraftStore(scope: "server|alice",
                                  directory: scratchDirectory("undo"))
    let model = offlineModel(draftStore: store)

    model.edit(firstLine(model), text: "First verse, rewritten.")
    await model.commit(firstLine(model))
    checkEqual("the failed save left the words on disk",
               store.drafts(projectId: song.id)[40]?.text, "First verse, rewritten.")

    await model.undo()

    checkEqual("the line reads as it did", model.currentText(firstLine(model)),
               "First verse.")
    check("there is nothing further back", !model.canUndo)
    check("and the change can be put forward again", model.canRedo)
    checkEqual("the copy on disk followed the screen at once, without waiting "
               + "out the debounce",
               store.drafts(projectId: song.id)[40]?.text, "First verse.")

    // The save the undo re-armed: these words are the server's already, so it
    // lands without a request and the line stops being held.
    await model.commit(firstLine(model))
    check("the line is no longer held", !model.unsavedBlockIds.contains(40))
    check("and its draft is gone from disk", store.drafts(projectId: song.id).isEmpty)
    check("but the step is still there to redo", model.canRedo)
}

@MainActor
func checkRedoTypesItAgain() async {
    print("== Redo types it again, and it is held again ==")
    let model = offlineModel()

    model.edit(firstLine(model), text: "First verse, rewritten.")
    await model.commit(firstLine(model))
    await model.undo()
    await model.commit(firstLine(model))

    await model.redo()
    await model.commit(firstLine(model))

    checkEqual("the words are back", model.currentText(firstLine(model)),
               "First verse, rewritten.")
    check("held, as they were when they were typed", model.unsavedBlockIds.contains(40))
    check("with the step back on the undo side", model.canUndo)
    check("and nothing left forward", !model.canRedo)
}

@MainActor
func checkStepsComeBackOneAtATime() async {
    print("== Two edits to one line come back one at a time ==")
    let model = offlineModel()

    model.edit(firstLine(model), text: "First verse, once.")
    await model.commit(firstLine(model))
    model.edit(firstLine(model), text: "First verse, twice.")
    await model.commit(firstLine(model))

    checkEqual("both were recorded", model.localHistory.undoSteps.count, 2)

    await model.undo()
    checkEqual("the first undo reaches the edit before it",
               model.currentText(firstLine(model)), "First verse, once.")

    // That restored text is still not what the server has, so the save behind
    // the step fails too — and a failure is where an edit enters the history.
    // A step this history just applied must not be recorded as a new one, or
    // undo would never reach past it and the redo it just filed would go.
    await model.commit(firstLine(model))
    checkEqual("applying a step does not record one", model.localHistory.undoSteps.count, 1)
    check("so the way forward survives the save that failed behind it",
          model.canRedo)

    await model.undo()
    checkEqual("the second undo reaches the words the server has",
               model.currentText(firstLine(model)), "First verse.")
    check("and there is nothing further back", !model.canUndo)
}

@MainActor
func checkRetriesAreNotSteps() async {
    print("== A backoff retry is the same change, not another one ==")
    let model = offlineModel()

    model.edit(firstLine(model), text: "First verse, rewritten.")
    await model.commit(firstLine(model))
    // What the retry timer does when the route is still gone. The words have
    // not moved, so neither has the history.
    await model.commit(firstLine(model))
    await model.commit(firstLine(model))

    checkEqual("three failed attempts, one step", model.localHistory.undoSteps.count, 1)

    await model.undo()
    checkEqual("which takes the line all the way back",
               model.currentText(firstLine(model)), "First verse.")
    check("in a single press", !model.canUndo)
}

@MainActor
func checkRolledBackGesturesLeaveNothing() async {
    print("== A fold that could not be persisted leaves nothing to undo ==")
    let model = offlineModel()

    // Backspace at the head of the second line: the merged text cannot be
    // written, so the lyric is put back exactly as it stood. The failed write
    // recorded itself on the way through, and that record has to go with it —
    // the merged line is not a change the writer ever saw, let alone kept.
    let landed = await model.mergeIntoPrevious(model.blocks[1])

    checkEqual("the fold backs out", landed, nil)
    checkEqual("both lines are still there", model.blocks.count, 2)
    checkEqual("the line above is untouched",
               model.currentText(firstLine(model)), "First verse.")
    check("and there is nothing to undo", model.localHistory.isEmpty)
    check("so no undo button is offered", !model.canUndo && !model.canRedo)
}

@MainActor
func checkSyncKeepsWhatItCouldNotPush() async {
    print("== A sync that falls short keeps every step ==")
    let model = offlineModel()

    model.edit(firstLine(model), text: "First verse, rewritten.")
    await model.commit(firstLine(model))

    // The route came back as far as the app knows, but the push still fails.
    // The writer is effectively offline, and these steps are still the only
    // undo there is.
    await model.syncHeldWork()

    check("the words are still on screen and still held",
          model.unsavedBlockIds.contains(40))
    check("and undo still reaches them", model.canUndo)
    checkEqual("with the step intact", model.localHistory.undoSteps.count, 1)
}

@MainActor
func checkSyncClearsWhatLanded() async {
    print("== Once everything has landed, the server owns undo again ==")
    let model = offlineModel()

    model.edit(firstLine(model), text: "First verse, rewritten.")
    await model.commit(firstLine(model))
    // Taken back to the words the server already has, which is a save that
    // needs no request — so by the time the sweep runs, this device is holding
    // nothing.
    await model.undo()
    await model.commit(firstLine(model))
    check("nothing is held before the sweep", !model.hasUnsavedChanges)

    await model.syncHeldWork()

    check("the local steps are gone", model.localHistory.isEmpty)
    check("so ⌘Z no longer replays the offline session", !model.canUndo)
    check("nor the way back into it", !model.canRedo)
}

@MainActor
func checkOfflineStepsSayWhatTheyDid() async {
    print("== A step taken offline still says it happened ==")
    let model = offlineModel()

    check("nothing has been stepped, so there is nothing to say",
          model.historyToast == nil)

    model.edit(firstLine(model), text: "First verse, rewritten.")
    await model.commit(firstLine(model))
    check("typing is not a step and says nothing", model.historyToast == nil)

    await model.undo()
    checkEqual("undo says so", model.historyToast?.text, "Change undone")
    let afterUndo = model.historyToast?.token

    await model.redo()
    checkEqual("and so does redo", model.historyToast?.text, "Change redone")
    check("as a confirmation of its own, not the last one again",
          model.historyToast?.token != afterUndo)

    // Two identical messages in a row have to read as two events — the whole
    // reason the value carries a token rather than being the words alone.
    await model.undo()
    let firstUndo = model.historyToast?.token
    await model.redo()
    await model.undo()
    checkEqual("a second identical message is still a second message",
               model.historyToast?.text, "Change undone")
    check("carrying a token nothing has shown yet",
          model.historyToast?.token != firstUndo)
}

// MARK: - Online

/// The demo project's first song, with its lyric loaded. The demo backend
/// answers in process and keeps a real per-edition undo stack, so the whole
/// round trip runs.
@MainActor
func openADemoSong() async -> SongBlockModel? {
    let app = AppModel()
    await app.enterDemo()
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

@MainActor
func checkServerHistory() async {
    print("== With a connection, a step is the server's ==")
    guard let model = await openADemoSong(), !model.blocks.isEmpty else {
        check("the demo song has lines", false)
        return
    }

    check("the server keeps a history for this song", model.hasUndoStack)
    let original = model.blocks[0].text

    model.edit(model.blocks[0], text: "Rewritten with a connection.")
    await model.commit(model.blocks[0])

    check("nothing is held on the device", !model.hasUnsavedChanges)
    check("no local step was recorded", model.localHistory.isEmpty)
    // The commit refreshes the status without waiting for it — a keystroke must
    // never queue behind a status — so the button arms a round trip later. Here
    // that round trip is awaited rather than raced.
    await model.refreshUndoRedo()
    check("but the edit left a checkpoint behind it", model.canUndo)

    await model.undo()
    checkEqual("undo restores the line the server remembers",
               model.blocks[0].text, original)
    check("and offers the way forward", model.canRedo)

    await model.redo()
    checkEqual("redo puts the edit back", model.blocks[0].text,
               "Rewritten with a connection.")

    // Leave the demo song as it was found.
    await model.undo()
}

@MainActor
func checkRestoredLinesAreCounted() async {
    print("== A step that brings a line back says how many ==")
    guard let model = await openADemoSong(), model.blocks.count > 1 else {
        check("the demo song has lines to lose", false)
        return
    }

    let count = model.blocks.count
    let deleted = await model.delete(model.blocks[0])
    check("the line went", deleted)
    checkEqual("leaving one fewer", model.blocks.count, count - 1)
    await model.refreshUndoRedo()

    await model.undo()
    checkEqual("undo brings it back", model.blocks.count, count)
    checkEqual("and names what came back", model.historyToast?.text, "Restored 1 line")

    await model.redo()
    checkEqual("redo takes it away again", model.blocks.count, count - 1)
    checkEqual("with the plain acknowledgement, since nothing came back",
               model.historyToast?.text, "Change redone")

    // Leave the demo song as it was found.
    await model.undo()
    checkEqual("the song is as it was found", model.blocks.count, count)
}

// MARK: - Run

@MainActor
func run() async {
    await checkTypingIsAStep()
    print()
    await checkUndoPutsTheWordsBack()
    print()
    await checkRedoTypesItAgain()
    print()
    await checkStepsComeBackOneAtATime()
    print()
    await checkRetriesAreNotSteps()
    print()
    await checkRolledBackGesturesLeaveNothing()
    print()
    await checkSyncKeepsWhatItCouldNotPush()
    print()
    await checkSyncClearsWhatLanded()
    print()
    await checkOfflineStepsSayWhatTheyDid()
    print()
    await checkServerHistory()
    print()
    await checkRestoredLinesAreCounted()
}

await run()

print()
if failures == 0 {
    print("Lyric history checks passed.")
    exit(0)
} else {
    print("\(failures) lyric history check(s) FAILED.")
    exit(1)
}
