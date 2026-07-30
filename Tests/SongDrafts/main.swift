//
//  main.swift
//  Tests/SongDrafts
//
//  What happens to a lyric line's words when a save doesn't land.
//
//  The screenplay editor has held unsaved words since the offline work landed;
//  this suite pins the same promises onto the song editor, which used to show
//  an alert and keep the words in memory only. Every case drives a real
//  SongBlockModel against a real APIClient pointed at a closed port, so the
//  failures are genuine transport failures travelling the genuine error path.
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

/// Two lyric lines advertising the links the editing paths gate on. The hrefs
/// point at the closed port, so following one fails the way a lost connection
/// does.
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

/// A scratch directory a store can be pointed at, wiped per case.
func scratchDirectory(_ name: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("scripty-song-draft-tests-\(name)-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.removeItem(at: url)
    return url
}

@MainActor
func makeModel(store: UnsavedDraftStore? = nil) -> SongBlockModel {
    let model = SongBlockModel(app: AppModel(), document: song, draftStore: store)
    model.adopt(twoLineCollection())
    return model
}

// MARK: - Cases

@MainActor
func run() async {
    // Point every APIClient at a port nothing is listening on. Connecting is
    // refused immediately, which is the transport failure the hold-the-words
    // logic exists for.
    UserDefaults.standard.set("http://127.0.0.1:1", forKey: AppConfig.baseURLOverrideKey)

    print("== A failed commit keeps the typing, quietly ==")
    do {
        let model = makeModel()
        let first = model.blocks[0]

        model.edit(first, text: "First verse, rewritten.")
        await model.commit(first)

        checkEqual("the rewritten text is still on screen",
                   model.currentText(model.blocks[0]), "First verse, rewritten.")
        check("the line is flagged unsaved", model.unsavedBlockIds.contains(first.id))
        check("the model reports unsaved work", model.hasUnsavedChanges)
        check("an offline failure is not a refusal", !model.hasFailedSaves)
        check("and raises no alert", model.errorMessage == nil)
    }

    print()
    print("== A failed merge leaves both lines alone ==")
    do {
        let model = makeModel()
        let second = model.blocks[1]

        let landed = await model.mergeIntoPrevious(second)

        check("the merge reports nowhere to fold", landed == nil)
        checkEqual("both lines are still there", model.blocks.count, 2)
        checkEqual("the first keeps its own text",
                   model.currentText(model.blocks[0]), "First verse.")
        checkEqual("the second keeps its own text",
                   model.currentText(model.blocks[1]), "Second verse.")
        check("nothing is left flagged unsaved", !model.hasUnsavedChanges)
    }

    print()
    print("== A failed save writes the words to disk; a landed one clears them ==")
    do {
        let directory = scratchDirectory("persist")
        let store = UnsavedDraftStore(scope: "server|alice", directory: directory)
        let model = makeModel(store: store)
        let first = model.blocks[0]

        model.edit(first, text: "Rewritten on a train.")
        await model.commit(first)

        let onDisk = UnsavedDraftStore(scope: "server|alice", directory: directory)
            .drafts(projectId: song.id)[first.id]
        checkEqual("the draft is on disk", onDisk?.text, "Rewritten on a train.")
        checkEqual("with the server's content as its base", onDisk?.baseText, "First verse.")

        // Typing back to exactly what the server has: nothing left to save,
        // nothing worth holding.
        model.edit(first, text: "First verse.")
        await model.commit(first)
        check("matching the server clears the draft",
              store.drafts(projectId: song.id)[first.id] == nil)
        check("and the unsaved flag", !model.hasUnsavedChanges)
    }

    print()
    print("== A relaunch takes the drafts back up — but never over newer words ==")
    do {
        let directory = scratchDirectory("restore")
        let store = UnsavedDraftStore(scope: "server|alice", directory: directory)
        store.save(UnsavedDraft(blockId: 40, text: "Rewritten offline.",
                                baseText: "First verse.", savedAt: .now),
                   projectId: song.id)
        // Stale: the server no longer matches this draft's base — someone
        // edited the line elsewhere, so the draft must be dropped, not pushed.
        store.save(UnsavedDraft(blockId: 41, text: "Old offline words.",
                                baseText: "What the server used to say.", savedAt: .now),
                   projectId: song.id)

        let model = makeModel(store: store)
        model.adoptPersistedDrafts()

        checkEqual("the fresh draft is live again",
                   model.currentText(model.blocks[0]), "Rewritten offline.")
        check("and flagged unsaved", model.unsavedBlockIds.contains(40))
        checkEqual("the stale draft leaves the server's words alone",
                   model.currentText(model.blocks[1]), "Second verse.")
        check("and is gone from disk", store.drafts(projectId: song.id)[41] == nil)
        check("the set-aside words are named to the writer", model.errorMessage != nil)
    }

    print()
    print("== The reconnect sweep pushes held lines ==")
    do {
        // Held work synced against the demo backend, which answers in-process:
        // the closed port makes the hold, the demo would make the push land.
        // Here the port stays closed, so the sweep must simply survive —
        // holding again, never dropping the words.
        let model = makeModel()
        let first = model.blocks[0]
        model.edit(first, text: "Still only here.")
        await model.commit(first)
        check("the line is held before the sweep", model.hasUnsavedChanges)

        await model.syncHeldWork()
        checkEqual("a sweep that cannot get out keeps the words",
                   model.currentText(model.blocks[0]), "Still only here.")
        check("and the line stays flagged", model.unsavedBlockIds.contains(first.id))
    }

    print()
    print("== Deleting a line drops its held words deliberately ==")
    do {
        let directory = scratchDirectory("delete")
        let store = UnsavedDraftStore(scope: "server|alice", directory: directory)
        let model = makeModel(store: store)
        let first = model.blocks[0]

        model.edit(first, text: "Words the writer then deletes.")
        await model.commit(first)
        check("the draft exists before the delete",
              store.drafts(projectId: song.id)[first.id] != nil)

        _ = await model.delete(first)
        check("the draft goes with the line",
              store.drafts(projectId: song.id)[first.id] == nil)
        check("nothing is left flagged unsaved", !model.unsavedBlockIds.contains(first.id))
    }

    print()
    if failures == 0 {
        print("ALL CHECKS PASSED")
    } else {
        print("\(failures) CHECK(S) FAILED")
    }
}

await run()
exit(failures == 0 ? 0 : 1)
