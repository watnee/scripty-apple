//
//  main.swift
//  Tests/OfflineCreates
//
//  Making things with no connection: a new lyric line, and a whole new song or
//  note.
//
//  Editing offline was covered long before this — the words are held, put on
//  disk and retried. *Creating* was not, in either place, and the two gaps read
//  the same way to a writer: Return did nothing in a lyric, and a song started
//  in a tunnel lived in a text view until somebody closed the sheet. This suite
//  pins the outbox behind both.
//
//  Every failure here is a genuine transport failure — a real `APIClient`
//  pointed at a closed port — travelling the genuine error path, exactly as the
//  SongDrafts suite drives its held saves.
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

let project = decode(Project.self, """
{"id": 1, "title": "Test Script",
 "_links": {"documents": {"href": "/api/projects/1/documents"}}}
""")

let song = decode(TextDocument.self,
    #"{"id": 7, "title": "Test Song", "projectId": 1, "documentType": "SONG"}"#)

/// Two lyric lines advertising the links the editing paths gate on, and a
/// collection that can be added to. The hrefs point at the closed port, so
/// following one fails the way a lost connection does.
func twoLineCollection() -> HALCollection<SongBlock> {
    decode(HALCollection<SongBlock>.self, """
    {
      "_embedded": {
        "songBlockResourceList": [
          {
            "id": 40, "order": 1, "content": "First verse.",
            "_links": {
              "update": {"href": "/api/song-blocks/40"},
              "delete": {"href": "/api/song-blocks/40"},
              "createBelow": {"href": "/api/song-blocks/40/below"}
            }
          },
          {
            "id": 41, "order": 2, "content": "Second verse.",
            "_links": {
              "update": {"href": "/api/song-blocks/41"},
              "delete": {"href": "/api/song-blocks/41"},
              "createBelow": {"href": "/api/song-blocks/41/below"}
            }
          }
        ]
      },
      "_links": {
        "self": {"href": "/api/documents/7/song-blocks"},
        "create": {"href": "/api/documents/7/song-blocks"}
      }
    }
    """)
}

/// A scratch directory a store can be pointed at, wiped per case.
func scratchDirectory(_ name: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("scripty-offline-create-tests-\(name)-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.removeItem(at: url)
    return url
}

@MainActor
func makeLyric(queue: OfflineBlockQueue) -> SongBlockModel {
    let model = SongBlockModel(app: AppModel(), document: song, createQueue: queue)
    model.adopt(twoLineCollection())
    return model
}

// MARK: - Lyric lines

@MainActor
func checkOfflineLyricLines() async {
    print("== Return keeps working with no connection ==")
    do {
        let directory = scratchDirectory("lyric-return")
        let queue = OfflineBlockQueue(scope: "server|alice", directory: directory,
                                      folder: "PendingSongBlocks")
        let model = makeLyric(queue: queue)
        let first = model.blocks[0]

        let made = await model.addLine(below: first)

        check("a line is made", made != nil)
        checkEqual("and it is on screen, below the one Return was pressed in",
                   model.blocks.count, 3)
        check("under a local id, so nothing mistakes it for the server's",
              model.blocks[1].isLocal)
        check("it can be typed into, links or no links", model.blocks[1].isEditable)
        check("the caret is sent to it", model.focusRequest == made)
        check("it counts as work still to send", model.hasUnsavedChanges)
        checkEqual("and it is exactly one line's worth", model.pendingCreateCount, 1)
        check("nothing is alarming about it", model.errorMessage == nil)
        check("and it is on disk, where a relaunch can find it",
              OfflineBlockQueue(scope: "server|alice", directory: directory,
                                folder: "PendingSongBlocks")
                  .pending(projectId: song.id).count == 1)
    }

    print()
    print("== The words typed into it ride the create rather than a PUT ==")
    do {
        let directory = scratchDirectory("lyric-words")
        let queue = OfflineBlockQueue(scope: "server|alice", directory: directory,
                                      folder: "PendingSongBlocks")
        let model = makeLyric(queue: queue)
        let made = await model.addLine(below: model.blocks[0])!

        model.edit(model.blocks[1], text: "A line written in a tunnel.")
        await model.commit(model.blocks[1])

        checkEqual("the words are on screen",
                   model.currentText(model.blocks[1]), "A line written in a tunnel.")
        checkEqual("and in the queued create, not in a draft",
                   queue.pending(projectId: song.id).first?.content,
                   "A line written in a tunnel.")
        check("the line is still held", model.unsavedBlockIds.contains(made))
        check("and this is not a refusal", !model.hasFailedSaves)
    }

    print()
    print("== Three lines written offline chain, and survive a reload ==")
    do {
        let directory = scratchDirectory("lyric-chain")
        let queue = OfflineBlockQueue(scope: "server|alice", directory: directory,
                                      folder: "PendingSongBlocks")
        let model = makeLyric(queue: queue)

        let a = await model.addLine(below: model.blocks[1])!
        let b = await model.addLine(below: model.blocks[2])!
        let c = await model.addLine(below: model.blocks[3])!

        checkEqual("all three are on screen", model.blocks.count, 5)
        check("each hangs off the one before it",
              queue.pending(projectId: song.id).map(\.anchorId) == [41, a, b])
        checkEqual("and they are queued in the order they were written",
                   queue.pending(projectId: song.id).map(\.tempId), [a, b, c])

        // A load replaces the collection wholesale. The writer's un-sent lines
        // have to survive that, or they vanish the first time the app reaches
        // the server for anything else at all.
        model.adopt(twoLineCollection())
        checkEqual("a reload puts them back", model.blocks.count, 5)
        check("still local", model.blocks[2].isLocal && model.blocks[4].isLocal)
        check("and still counted as held", model.unsavedBlockIds.contains(c))
    }

    print()
    print("== Backspace folds away a line this device made ==")
    do {
        let directory = scratchDirectory("lyric-merge")
        let queue = OfflineBlockQueue(scope: "server|alice", directory: directory,
                                      folder: "PendingSongBlocks")
        let model = makeLyric(queue: queue)
        let made = await model.addLine(below: model.blocks[0])!
        model.edit(model.blocks[1], text: "folded")
        await model.commit(model.blocks[1])

        let landed = await model.mergeIntoPrevious(model.blocks[1])

        checkEqual("the caret lands in the line above", landed, 40)
        checkEqual("the folded line is gone", model.blocks.count, 2)
        checkEqual("its words went into the line above",
                   model.currentText(model.blocks[0]), "First verse.folded")
        check("and its queue entry went with it",
              queue.pending(projectId: song.id).isEmpty)
        check("nothing is left flagged for the line that went",
              !model.unsavedBlockIds.contains(made))
    }

    print()
    print("== A queued line can be deleted, and undone ==")
    do {
        let directory = scratchDirectory("lyric-delete")
        let queue = OfflineBlockQueue(scope: "server|alice", directory: directory,
                                      folder: "PendingSongBlocks")
        let model = makeLyric(queue: queue)
        let made = await model.addLine(below: model.blocks[0])!
        model.edit(model.blocks[1], text: "Second thoughts.")
        await model.commit(model.blocks[1])

        let gone = await model.delete(model.blocks[1])
        check("the delete succeeds with no connection at all", gone)
        checkEqual("the line is off the screen", model.blocks.count, 2)
        check("and off the outbox", queue.pending(projectId: song.id).isEmpty)

        await model.undo()
        checkEqual("undo brings it back", model.blocks.count, 3)
        checkEqual("with the words it was holding",
                   model.currentText(model.blocks[1]), "Second thoughts.")
        check("and back in the outbox", queue.pending(projectId: song.id).count == 1)

        await model.redo()
        checkEqual("redo takes it away again", model.blocks.count, 2)
        check("and the outbox is empty once more",
              queue.pending(projectId: song.id).isEmpty)
        _ = made
    }

    print()
    print("== Undo takes back a line Return made ==")
    do {
        let directory = scratchDirectory("lyric-undo-create")
        let queue = OfflineBlockQueue(scope: "server|alice", directory: directory,
                                      folder: "PendingSongBlocks")
        let model = makeLyric(queue: queue)
        _ = await model.addLine(below: model.blocks[0])

        check("the new line is something to undo", model.canUndo)
        await model.undo()
        checkEqual("undo removes it", model.blocks.count, 2)
        check("and empties the outbox", queue.pending(projectId: song.id).isEmpty)

        await model.redo()
        checkEqual("redo makes it again", model.blocks.count, 3)
        check("queued as before", queue.pending(projectId: song.id).count == 1)
    }
}

// MARK: - Whole songs and notes

@MainActor
func checkOfflineDocuments() async {
    print("== A note written with no connection is kept, not lost ==")
    do {
        let directory = scratchDirectory("doc-create")
        let queue = OfflineDocumentQueue(scope: "server|alice", directory: directory)
        let model = ScriptModel(app: AppModel(), project: project, documentQueue: queue)

        let outcome = await model.createDocumentOutcome(
            title: "Ideas", content: "Written on a train.", type: .notes)

        guard case .queued(let made) = outcome else {
            check("the create is queued rather than lost", false)
            return
        }
        check("the stand-in is local", made.isLocal)
        checkEqual("it is in the list at once", model.documents.count, 1)
        checkEqual("under the name the writer gave it", model.documents[0].title, "Ideas")
        check("it counts as work still to send", model.hasHeldWork)
        check("nothing is alarming about it", model.errorMessage == nil)

        let onDisk = OfflineDocumentQueue(scope: "server|alice", directory: directory)
            .pending(projectId: project.id)
        checkEqual("and it is on disk, where a relaunch can find it", onDisk.count, 1)
        checkEqual("with the words in it", onDisk.first?.content, "Written on a train.")
        checkEqual("and its kind", onDisk.first?.type, "NOTES")
    }

    print()
    print("== Typing into it goes into the same entry, not a second document ==")
    do {
        let directory = scratchDirectory("doc-edit")
        let queue = OfflineDocumentQueue(scope: "server|alice", directory: directory)
        let model = ScriptModel(app: AppModel(), project: project, documentQueue: queue)
        guard case .queued(let made) = await model.createDocumentOutcome(
            title: "Ballad", content: "First verse.", type: .song) else {
            check("the create is queued", false)
            return
        }

        let outcome = await model.saveDocumentOutcome(
            made, title: "Ballad of the Lost Hour", content: "First verse. Second verse.")

        check("the save is held, not failed", outcome == .held)
        checkEqual("there is still exactly one document", model.documents.count, 1)
        checkEqual("the list shows the newest name",
                   model.documents[0].title, "Ballad of the Lost Hour")
        let entry = queue.pending(projectId: project.id).first
        checkEqual("and the outbox holds the newest words",
                   entry?.content, "First verse. Second verse.")
        checkEqual("under the newest name", entry?.title, "Ballad of the Lost Hour")
        checkEqual("the editor can read them back when it reopens",
                   model.pendingDocument(for: made.id)?.content,
                   "First verse. Second verse.")
    }

    print()
    print("== A queued document survives the list being reloaded ==")
    do {
        let directory = scratchDirectory("doc-reload")
        let queue = OfflineDocumentQueue(scope: "server|alice", directory: directory)
        let model = ScriptModel(app: AppModel(), project: project, documentQueue: queue)
        _ = await model.createDocumentOutcome(title: "Ideas", content: "Kept.", type: .notes)

        // What a load off the network — or off the offline copy — does to the
        // list. The queued document is in neither, and has to survive both.
        await model.loadDocuments()

        checkEqual("the song written offline is still in the list",
                   model.documents.count, 1)
        check("still local", model.documents[0].isLocal)
        check("and still held", model.hasHeldWork)
    }

    print()
    print("== A queued document can be thrown away ==")
    do {
        let directory = scratchDirectory("doc-delete")
        let queue = OfflineDocumentQueue(scope: "server|alice", directory: directory)
        let model = ScriptModel(app: AppModel(), project: project, documentQueue: queue)
        guard case .queued(let made) = await model.createDocumentOutcome(
            title: "Scrapped", content: "Never mind.", type: .notes) else {
            check("the create is queued", false)
            return
        }

        await model.deleteDocument(made)

        check("the row goes", model.documents.isEmpty)
        check("the outbox entry goes with it",
              queue.pending(projectId: project.id).isEmpty)
        check("and nothing is left claiming to be held work", !model.hasHeldWork)
    }

    print()
    print("== The queue store survives being reopened, and stays in its scope ==")
    do {
        let directory = scratchDirectory("doc-store")
        let store = OfflineDocumentQueue(scope: "server|alice", directory: directory)
        store.enqueue(PendingDocumentCreate(tempId: -1, title: "Ideas", content: "Kept.",
                                            type: "NOTES", createdAt: .now),
                      projectId: 1)

        let reopened = OfflineDocumentQueue(scope: "server|alice", directory: directory)
        checkEqual("the entry survives", reopened.pending(projectId: 1).first?.content, "Kept.")
        check("another account sees nothing",
              OfflineDocumentQueue(scope: "server|bob", directory: directory)
                  .pending(projectId: 1).isEmpty)

        reopened.resolve(tempId: -1, realId: 12, projectId: 1)
        check("a sent entry leaves the queue", reopened.pending(projectId: 1).isEmpty)
        checkEqual("but its new name is remembered, for an editor still open on it",
                   reopened.realId(for: -1, projectId: 1), 12)
        checkEqual("and the next temp id does not reuse it",
                   reopened.nextTempId(projectId: 1), -2)
    }
}

// MARK: - Run

// Point every APIClient at a port nothing is listening on. Connecting is
// refused immediately, which is the transport failure the queue exists for —
// and the only one that reaches it, since a *refusal* is judged differently.
// Without this the suite talks to whatever server the build is configured for
// and gets 401s, which are not retryable and so are never queued.
UserDefaults.standard.set("http://127.0.0.1:1", forKey: AppConfig.baseURLOverrideKey)

await checkOfflineLyricLines()
print()
await checkOfflineDocuments()

print()
if failures == 0 {
    print("ALL CHECKS PASSED")
} else {
    print("\(failures) CHECK(S) FAILED")
}
exit(failures == 0 ? 0 : 1)
