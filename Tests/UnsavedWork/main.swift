//
//  main.swift
//  Tests/UnsavedWork
//
//  What happens to the writer's words when a save doesn't land.
//
//  Every case here drives a real ScriptModel against a real APIClient pointed
//  at a closed port, so the failures are genuine transport failures travelling
//  the genuine error path — no stubbed-out client, no injected error. The
//  question each one asks is the same: after the write fails, is what the
//  writer typed still there?
//

import Foundation

// MARK: - Harness

// Line-buffer stdout so a run that is killed — by the harness watchdog, or by
// hand — still shows which case it had reached. Piped into anything, the
// default block buffering throws all of it away and a stall looks like a suite
// that printed nothing at all.
_ = setvbuf(stdout, nil, _IOLBF, 0)

var failures = 0

func check(_ label: String, _ condition: Bool) {
    print(condition ? "  PASS  \(label)" : "  FAIL  \(label)")
    if !condition { failures += 1 }
}

func checkEqual<T: Equatable>(_ label: String, _ actual: T, _ expected: T) {
    let ok = actual == expected
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)\n          expected: \(expected)\n          actual:   \(actual)")
    if !ok { failures += 1 }
}

func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T {
    try! JSONDecoder().decode(T.self, from: Data(json.utf8))
}

/// A project with no links: nothing this suite drives needs one, and their
/// absence keeps the model from reaching for endpoints the test doesn't care
/// about (undo/redo status, sync polling).
let project: Project = decode(Project.self, #"{"id": 1, "title": "Test Script"}"#)

/// Two adjacent editable elements, each advertising the update and delete
/// links the editing paths gate on. The hrefs point at the closed port, so
/// following one fails the way a lost connection does.
func twoBlockCollection() -> HALCollection<Block> {
    decode(HALCollection<Block>.self, """
    {
      "_embedded": {
        "blockResourceList": [
          {
            "id": 10, "order": 1, "type": "ACTION", "content": "First line.",
            "_links": {
              "update": {"href": "/api/blocks/10"},
              "delete": {"href": "/api/blocks/10"},
              "createBelow": {"href": "/api/blocks/10/below"}
            }
          },
          {
            "id": 11, "order": 2, "type": "ACTION", "content": "Second line.",
            "_links": {
              "update": {"href": "/api/blocks/11"},
              "delete": {"href": "/api/blocks/11"},
              "createBelow": {"href": "/api/blocks/11/below"}
            }
          }
        ]
      },
      "_links": {"self": {"href": "/api/projects/1/blocks"}}
    }
    """)
}

/// The same two elements, but the first has lost the links the editing paths
/// gate on — the shape the server sends once a document is locked, or once the
/// writer's access to it narrows to reading. Reaching this state mid-edit is
/// the case where a save has nowhere to go and the words must still be kept.
func lockedFirstBlockCollection() -> HALCollection<Block> {
    decode(HALCollection<Block>.self, """
    {
      "_embedded": {
        "blockResourceList": [
          {
            "id": 10, "order": 1, "type": "ACTION", "content": "First line.",
            "_links": {}
          },
          {
            "id": 11, "order": 2, "type": "ACTION", "content": "Second line.",
            "_links": {
              "update": {"href": "/api/blocks/11"},
              "createBelow": {"href": "/api/blocks/11/below"}
            }
          }
        ]
      },
      "_links": {"self": {"href": "/api/projects/1/blocks"}}
    }
    """)
}

@MainActor
func makeModel() -> ScriptModel {
    let model = ScriptModel(app: AppModel(), project: project)
    model.adopt(twoBlockCollection())
    return model
}

@MainActor
func blocks(_ model: ScriptModel) -> (first: Block, second: Block) {
    (model.blocks[0], model.blocks[1])
}

// MARK: - Cases

@MainActor
func run() async {
    // Point every APIClient at a port nothing is listening on. Connecting is
    // refused immediately, which is the transport failure the retry and
    // hold-the-text logic exists for.
    UserDefaults.standard.set("http://127.0.0.1:1", forKey: AppConfig.baseURLOverrideKey)

    print("== A failed commit keeps the typing ==")
    do {
        let model = makeModel()
        let (first, _) = blocks(model)

        model.liveEdit(first, text: "First line, rewritten.")
        await model.blur(first)

        checkEqual("the rewritten text is still on screen",
                   model.currentText(model.blocks[0]), "First line, rewritten.")
        check("the block is flagged unsaved", model.unsavedBlockIds.contains(first.id))
        check("the model reports unsaved work", model.hasUnsavedChanges)
    }

    print()
    print("== A failed split leaves the line whole ==")
    do {
        let model = makeModel()
        let (first, _) = blocks(model)

        model.liveEdit(first, text: "Before and after.")
        // Return pressed between "Before" and " and after."
        await model.splitBlock(model.blocks[0], caret: 6)

        checkEqual("no new element was created", model.blocks.count, 2)
        checkEqual("the whole line survives in the original block",
                   model.currentText(model.blocks[0]), "Before and after.")
        check("the block is flagged unsaved", model.unsavedBlockIds.contains(first.id))
    }

    print()
    print("== A failed merge leaves both elements alone ==")
    do {
        let model = makeModel()
        let (first, second) = blocks(model)

        await model.mergeIntoPrevious(second)

        checkEqual("both elements are still there", model.blocks.count, 2)
        checkEqual("the first keeps its own text",
                   model.currentText(model.blocks[0]), "First line.")
        checkEqual("the second keeps its own text",
                   model.currentText(model.blocks[1]), "Second line.")
        check("neither shows the merged text twice",
              !model.currentText(model.blocks[0]).contains("Second line."))
        check("nothing is left flagged unsaved", !model.unsavedBlockIds.contains(first.id))
    }

    print()
    print("== A failed retype keeps the typing ==")
    do {
        let model = makeModel()
        let (first, _) = blocks(model)

        model.liveEdit(first, text: "INT. KITCHEN - DAY")
        await model.changeType(model.blocks[0], to: .scene)

        checkEqual("the text survives the failed type change",
                   model.currentText(model.blocks[0]), "INT. KITCHEN - DAY")
        check("the block is flagged unsaved", model.unsavedBlockIds.contains(first.id))
    }

    print()
    print("== Transport failures are named, not leaked ==")
    do {
        checkEqual("a refused connection reads as offline",
                   APIError.from(transportError: URLError(.cannotConnectToHost)),
                   APIError.offline)
        checkEqual("a dropped connection reads as offline",
                   APIError.from(transportError: URLError(.networkConnectionLost)),
                   APIError.offline)
        check("offline is worth retrying", APIError.offline.isRetryable)
        check("a timeout is worth retrying", APIError.timedOut.isRetryable)
        check("a 503 is worth retrying", APIError.server(status: 503).isRetryable)
        check("a 403 is not", !APIError.forbidden.isRetryable)
        check("a validation failure is not", !APIError.validation([:]).isRetryable)
        check("an unusable link is not", !APIError.invalidLink("nope").isRetryable)
        check("the offline message mentions the work is kept",
              APIError.offline.errorDescription?.contains("kept on this device") == true)
    }

    print()
    await checkDraftStore()
    print()
    await checkDraftPersistence()
    print()
    await checkDraftRestore()
    print()
    await checkWriteWithNowhereToGo()

    print()
    if failures == 0 {
        print("ALL CHECKS PASSED")
    } else {
        print("\(failures) CHECK(S) FAILED")
    }
}

/// A scratch directory a store can be pointed at, wiped per case.
func scratchDirectory(_ name: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("scripty-draft-tests-\(name)-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.removeItem(at: url)
    return url
}

@MainActor
func checkDraftStore() async {
    print("== Drafts survive the store being reopened ==")
    do {
        let directory = scratchDirectory("roundtrip")
        let store = UnsavedDraftStore(scope: "server|alice", directory: directory)
        store.save(UnsavedDraft(blockId: 10, text: "Kept words.", baseText: "Old.", savedAt: .now),
                   projectId: 1)
        store.save(UnsavedDraft(blockId: 11, text: "More words.", baseText: nil, savedAt: .now),
                   projectId: 1)

        let reopened = UnsavedDraftStore(scope: "server|alice", directory: directory)
        let drafts = reopened.drafts(projectId: 1)
        checkEqual("both drafts come back", drafts.count, 2)
        checkEqual("the text survives", drafts[10]?.text, "Kept words.")
        checkEqual("the base survives", drafts[10]?.baseText, "Old.")

        reopened.remove(blockId: 10, projectId: 1)
        let afterRemove = UnsavedDraftStore(scope: "server|alice", directory: directory)
        checkEqual("a removed draft stays removed", afterRemove.drafts(projectId: 1).count, 1)

        afterRemove.removeAll(projectId: 1)
        let afterClear = UnsavedDraftStore(scope: "server|alice", directory: directory)
        check("removeAll empties the project", afterClear.drafts(projectId: 1).isEmpty)
    }

    print()
    print("== One account's drafts are invisible to another ==")
    do {
        let directory = scratchDirectory("scopes")
        let alice = UnsavedDraftStore(scope: "server|alice", directory: directory)
        let bob = UnsavedDraftStore(scope: "server|bob", directory: directory)
        alice.save(UnsavedDraft(blockId: 10, text: "Alice's words.", baseText: nil, savedAt: .now),
                   projectId: 1)
        check("the other scope sees nothing", bob.drafts(projectId: 1).isEmpty)
        checkEqual("the owner still sees the draft",
                   UnsavedDraftStore(scope: "server|alice", directory: directory)
                       .drafts(projectId: 1)[10]?.text,
                   "Alice's words.")
    }

    print()
    print("== The draft scope names the account, and only a real one ==")
    do {
        let signedOut = AppModel()
        check("signed out means no scope", signedOut.draftScope == nil)

        let signedIn = AppModel()
        signedIn.client.credentials = Credentials(username: "Writer@Example.com", password: "pw")
        check("a signed-in scope carries the account",
              signedIn.draftScope?.hasSuffix("|writer@example.com") == true)
    }
}

@MainActor
func checkDraftPersistence() async {
    print("== A failed save writes the words to disk; a landed one clears them ==")
    let directory = scratchDirectory("persist")
    let store = UnsavedDraftStore(scope: "server|alice", directory: directory)
    let model = ScriptModel(app: AppModel(), project: project, draftStore: store)
    model.adopt(twoBlockCollection())
    let (first, _) = blocks(model)

    model.liveEdit(first, text: "First line, rewritten.")
    await model.blur(first)

    let onDisk = UnsavedDraftStore(scope: "server|alice", directory: directory)
        .drafts(projectId: project.id)[first.id]
    checkEqual("the draft is on disk", onDisk?.text, "First line, rewritten.")
    checkEqual("with the server's content as its base", onDisk?.baseText, "First line.")

    // The save lands (a retry got through): the block comes back rewritten.
    let saved = decode(Block.self, #"{"id": 10, "order": 1, "type": "ACTION", "content": "First line, rewritten."}"#)
    model.adoptRewritten(saved)
    check("a landed save removes the draft",
          UnsavedDraftStore(scope: "server|alice", directory: directory)
              .drafts(projectId: project.id)[first.id] == nil)
}

@MainActor
func checkDraftRestore() async {
    print("== A relaunch takes the drafts back up — but never over newer words ==")
    let directory = scratchDirectory("restore")
    let store = UnsavedDraftStore(scope: "server|alice", directory: directory)
    store.save(UnsavedDraft(blockId: 10, text: "Rewritten offline.",
                            baseText: "First line.", savedAt: .now),
               projectId: project.id)
    // Stale: the server no longer matches this draft's base — someone edited
    // that element elsewhere, so the draft must be dropped, not pushed.
    store.save(UnsavedDraft(blockId: 11, text: "Old offline words.",
                            baseText: "What the server used to say.", savedAt: .now),
               projectId: project.id)

    let model = ScriptModel(app: AppModel(), project: project, draftStore: store)
    model.adopt(twoBlockCollection())
    model.adoptPersistedDrafts()

    checkEqual("the fresh draft is live again",
               model.currentText(model.blocks[0]), "Rewritten offline.")
    check("and flagged unsaved", model.unsavedBlockIds.contains(10))
    checkEqual("the stale draft leaves the server's words alone",
               model.currentText(model.blocks[1]), "Second line.")
    check("and is gone from disk",
          store.drafts(projectId: project.id)[11] == nil)

    // A draft whose text the server already has is finished business.
    store.save(UnsavedDraft(blockId: 11, text: "Second line.",
                            baseText: "Second line.", savedAt: .now),
               projectId: project.id)
    model.adoptPersistedDrafts()
    check("an already-saved draft is not re-adopted", !model.unsavedBlockIds.contains(11))
    check("and is cleared from disk", store.drafts(projectId: project.id)[11] == nil)
}

@MainActor
func checkWriteWithNowhereToGo() async {
    print("== A save with nowhere to go holds the words rather than losing them ==")
    do {
        let directory = scratchDirectory("nolink")
        let store = UnsavedDraftStore(scope: "server|alice", directory: directory)
        let model = ScriptModel(app: AppModel(), project: project, draftStore: store)
        model.adopt(lockedFirstBlockCollection())

        model.liveEdit(model.blocks[0], text: "Words written into a locked line.")
        await model.blur(model.blocks[0])

        checkEqual("the typing is still on screen",
                   model.currentText(model.blocks[0]), "Words written into a locked line.")
        check("the block is flagged unsaved", model.unsavedBlockIds.contains(10))
        check("and flagged failed rather than retrying",
              model.failedBlockIds.contains(10))
        checkEqual("the words are on disk",
                   UnsavedDraftStore(scope: "server|alice", directory: directory)
                       .drafts(projectId: project.id)[10]?.text,
                   "Words written into a locked line.")
        check("and the writer is told why",
              model.errorMessage == APIError.forbidden.errorDescription)
    }

    print()
    print("== A write that changed nothing is still finished business ==")
    do {
        let directory = scratchDirectory("nochange")
        let store = UnsavedDraftStore(scope: "server|alice", directory: directory)
        let model = ScriptModel(app: AppModel(), project: project, draftStore: store)
        model.adopt(lockedFirstBlockCollection())

        // Retyping the same words over a locked line is not an edit, so it is
        // not a refusal either — nothing is held and nothing is said.
        model.liveEdit(model.blocks[0], text: "First line.")
        await model.blur(model.blocks[0])

        check("nothing is flagged unsaved", !model.unsavedBlockIds.contains(10))
        check("nothing is on disk",
              UnsavedDraftStore(scope: "server|alice", directory: directory)
                  .drafts(projectId: project.id)[10] == nil)
        check("and no alert is raised", model.errorMessage == nil)
    }

    print()
    print("== An accepted suggestion is held like any other writing ==")
    do {
        let directory = scratchDirectory("accepted")
        let store = UnsavedDraftStore(scope: "server|alice", directory: directory)
        let model = ScriptModel(app: AppModel(), project: project, draftStore: store)
        model.adopt(twoBlockCollection())
        let (first, _) = blocks(model)

        // What accepting a character suggestion does: the name goes on screen
        // at once through `showLive`, which arms no save of its own because
        // the caller is about to write the words itself — and that write is
        // the one that fails here.
        let suggestion = ScriptSuggestion(text: "MARGARET", personId: nil, becomesType: nil)
        await model.accept(suggestion, on: first)

        checkEqual("the name the writer picked is still on screen",
                   model.currentText(model.blocks[0]), "MARGARET")
        check("and is held as unsaved work", model.unsavedBlockIds.contains(first.id))

        // The point of the case. `flushPendingCommits` used to walk the
        // debounce tasks, and `showLive` arms none — so the trip to the
        // background skipped these words entirely and a launch after the
        // system killed the app showed the half-typed cue again.
        await model.flushPendingCommits()
        checkEqual("and reaches disk when the app goes to the background",
                   UnsavedDraftStore(scope: "server|alice", directory: directory)
                       .drafts(projectId: project.id)[first.id]?.text,
                   "MARGARET")
    }

    print()
    print("== A merge with no way to remove the absorbed line backs out whole ==")
    do {
        let model = ScriptModel(app: AppModel(), project: project)
        // The second element has an update link but no delete link: the merged
        // text can be written, and then the absorbed line cannot be taken away.
        model.adopt(decode(HALCollection<Block>.self, """
        {
          "_embedded": {
            "blockResourceList": [
              {
                "id": 10, "order": 1, "type": "ACTION", "content": "First line.",
                "_links": {"update": {"href": "/api/blocks/10"}}
              },
              {
                "id": 11, "order": 2, "type": "ACTION", "content": "Second line.",
                "_links": {"update": {"href": "/api/blocks/11"}}
              }
            ]
          },
          "_links": {"self": {"href": "/api/projects/1/blocks"}}
        }
        """))

        await model.mergeIntoPrevious(model.blocks[1])

        checkEqual("both elements are still there", model.blocks.count, 2)
        check("the first does not show the merged text",
              !model.currentText(model.blocks[0]).contains("Second line."))
        checkEqual("the second keeps its own words",
                   model.currentText(model.blocks[1]), "Second line.")
    }
}

await run()
exit(failures == 0 ? 0 : 1)

// `APIError` carries associated values, so equality for the assertions above
// is spelled out rather than synthesised.
extension APIError: Equatable {
    static func == (lhs: APIError, rhs: APIError) -> Bool {
        switch (lhs, rhs) {
        case (.unauthorized, .unauthorized), (.forbidden, .forbidden),
             (.notFound, .notFound), (.offline, .offline), (.timedOut, .timedOut),
             (.cancelled, .cancelled):
            return true
        case (.validation(let a), .validation(let b)): return a == b
        case (.server(let a), .server(let b)): return a == b
        case (.invalidLink(let a), .invalidLink(let b)): return a == b
        case (.transport(let a), .transport(let b)): return a == b
        default: return false
        }
    }
}
