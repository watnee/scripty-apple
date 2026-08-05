//
//  main.swift
//  Tests/Offline
//
//  What the writer can still do with no connection: read the copy saved on
//  this device, keep typing into it, and trust the words to sync when the
//  route returns. Drives the real OfflineStore, ConnectivityMonitor and
//  ScriptModel — network failures are genuine (a closed port), and the
//  offline fast-fail is the real APIClient gate.
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

/// A scratch directory a store can be pointed at, wiped per case.
func scratchDirectory(_ name: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("scripty-offline-tests-\(name)-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.removeItem(at: url)
    return url
}

/// A project advertising its block collection — at the closed port, so a live
/// load fails the way a lost connection does.
let project: Project = decode(Project.self, """
{"id": 1, "title": "Test Script",
 "_links": {"blocks": {"href": "/api/projects/1/blocks"}}}
""")

/// The block payload the server would have answered with — the bytes the
/// store keeps and the fallback decodes.
let blocksJSON = """
{
  "_embedded": {
    "blockResourceList": [
      {
        "id": 10, "order": 1, "type": "ACTION", "content": "First line.",
        "_links": {
          "update": {"href": "/api/blocks/10"},
          "delete": {"href": "/api/blocks/10"}
        }
      },
      {
        "id": 11, "order": 2, "type": "ACTION", "content": "Second line.",
        "_links": {
          "update": {"href": "/api/blocks/11"},
          "delete": {"href": "/api/blocks/11"}
        }
      }
    ]
  },
  "_links": {"self": {"href": "/api/projects/1/blocks"}}
}
"""

// MARK: - Cases

@MainActor
func run() async {
    // Point every APIClient at a port nothing is listening on.
    UserDefaults.standard.set("http://127.0.0.1:1", forKey: AppConfig.baseURLOverrideKey)

    await checkStoreRoundTrip()
    print()
    await checkStorePrune()
    print()
    await checkMonitor()
    print()
    await checkFastFail()
    print()
    await checkBlocksFallback()
    print()
    await checkDocumentFallback()
    print()
    await checkPrintableWordsOffline()
    print()
    await checkReconnectHoldsWork()
    print()
    await checkQueueArithmetic()
    print()
    await checkWritingNewElementsOffline()
    print()
    await checkStructuralEditsOffline()
    print()
    await checkUndoOffline()

    print()
    if failures == 0 {
        print("ALL CHECKS PASSED")
    } else {
        print("\(failures) CHECK(S) FAILED")
    }
}

@MainActor
func checkStoreRoundTrip() async {
    print("== The offline copy survives the store being reopened ==")
    let directory = scratchDirectory("roundtrip")
    let store = OfflineStore(scope: "server|alice", directory: directory)
    store.save(Data("root-bytes".utf8), .root)
    store.save(Data(blocksJSON.utf8), .blocks(projectId: 1))

    let reopened = OfflineStore(scope: "server|alice", directory: directory)
    checkEqual("the root payload comes back byte for byte",
               reopened.load(.root).map { String(decoding: $0.data, as: UTF8.self) },
               "root-bytes")
    check("the blocks payload comes back",
          reopened.load(.blocks(projectId: 1)) != nil)
    check("a payload never saved is a miss",
          reopened.load(.projects) == nil)
    check("the saved-at date is recent",
          (reopened.load(.root)?.savedAt).map { abs($0.timeIntervalSinceNow) < 60 } == true)

    print()
    print("== One account's copies are invisible to another ==")
    let bob = OfflineStore(scope: "server|bob", directory: directory)
    check("the other scope sees nothing", bob.load(.root) == nil)
}

@MainActor
func checkStorePrune() async {
    print("== Old project copies age out; the newest dozen and the open one stay ==")
    let directory = scratchDirectory("prune")
    let store = OfflineStore(scope: "server|alice", directory: directory)

    // Fifteen cached projects; make ids 1...15 progressively newer so the
    // eviction order is deterministic.
    for id in 1...15 {
        store.save(Data("blocks-\(id)".utf8), .blocks(projectId: id))
        let url = directory.appendingPathComponent("server%7Calice/project-\(id)/blocks.json")
        try? FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: TimeInterval(-(20 - id)) * 60)],
            ofItemAtPath: url.path)
    }
    store.prune(keeping: 1)

    check("the newest copy stays", store.load(.blocks(projectId: 15)) != nil)
    check("the twelfth-newest stays", store.load(.blocks(projectId: 4)) != nil)
    check("the thirteenth-newest is evicted", store.load(.blocks(projectId: 3)) == nil)
    check("the open project is never evicted, whatever its age",
          store.load(.blocks(projectId: 1)) != nil)

    // A copy past the month horizon goes even when the count is fine.
    let stale = directory.appendingPathComponent("server%7Calice/project-15/blocks.json")
    try? FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: -40 * 24 * 60 * 60)],
        ofItemAtPath: stale.path)
    store.prune(keeping: 1)
    check("a month-old copy ages out", store.load(.blocks(projectId: 15)) == nil)
}

@MainActor
func checkMonitor() async {
    print("== The monitor reports transitions, and fires exactly on reconnect ==")
    let monitor = ConnectivityMonitor(startMonitoring: false)
    check("assumed online until told otherwise", monitor.isOnline)
    await monitor.waitForFirstVerdict()
    check("a hand-driven monitor never blocks on a first verdict", true)

    var fired = 0
    monitor.onOnline = { fired += 1 }
    monitor.adopt(false)
    check("an unsatisfied path reads as offline", !monitor.isOnline)
    checkEqual("going offline fires nothing", fired, 0)
    monitor.adopt(false)
    checkEqual("repeating the verdict fires nothing", fired, 0)
    monitor.adopt(true)
    check("a restored path reads as online", monitor.isOnline)
    checkEqual("the reconnect fires once", fired, 1)
    monitor.adopt(true)
    checkEqual("staying online fires nothing more", fired, 1)
}

@MainActor
func checkFastFail() async {
    print("== While offline, a request fails now instead of waiting ==")
    let client = APIClient()
    client.offlineCheck = { true }
    let started = Date()
    var failedOffline = false
    do {
        _ = try await client.data(for: HALLink(href: "/api/anything"))
    } catch APIError.offline {
        failedOffline = true
    } catch {}
    check("the failure is named offline", failedOffline)
    check("and arrives immediately, not after a connection wait",
          Date().timeIntervalSince(started) < 1)

    // The same promise without the gate: nothing is listening on the port, and
    // a refused connection must come back as a refused connection. It is worth
    // pinning because `waitsForConnectivity` quietly breaks it — URLSession
    // reads "nothing is listening" as a wait-and-see condition, parks the
    // request for the whole 120s resource timeout, and then reports a timeout.
    // Two minutes per save whenever the API is down, and a test suite that
    // looks hung. See the session configuration in APIClient.
    let unguarded = APIClient()
    let refusedAt = Date()
    var refusedAsOffline = false
    do {
        _ = try await unguarded.data(for: HALLink(href: "/api/anything"))
    } catch APIError.offline {
        refusedAsOffline = true
    } catch {}
    check("a refused connection is refused, not waited out",
          Date().timeIntervalSince(refusedAt) < 5)
    check("and reads as offline rather than a timeout", refusedAsOffline)
}

@MainActor
func checkBlocksFallback() async {
    print("== A script the network can't fetch opens from the copy on this device ==")
    let directory = scratchDirectory("fallback")
    let store = OfflineStore(scope: "server|alice", directory: directory)
    store.save(Data(blocksJSON.utf8), .blocks(projectId: 1))
    // A draft from an interrupted session, newer than the cached copy.
    let drafts = UnsavedDraftStore(scope: "server|alice",
                                   directory: directory.appendingPathComponent("drafts"))
    drafts.save(UnsavedDraft(blockId: 10, text: "First line, rewritten offline.",
                             baseText: "First line.", savedAt: .now),
                projectId: 1)

    // Hand-driven and offline, like every other case here: the verdict this
    // case needs is "no route", and asking the system for it would make the
    // check depend on whether the machine running it happens to have one.
    let offline = ConnectivityMonitor(startMonitoring: false)
    offline.adopt(false)
    let model = ScriptModel(app: AppModel(connectivity: offline), project: project,
                            draftStore: drafts, offlineStore: store)
    await model.loadBlocks()

    checkEqual("the cached elements are on screen", model.blocks.count, 2)
    check("and marked as the offline copy", model.isShowingOfflineCopy)
    check("no error alert over the readable script", model.errorMessage == nil)
    checkEqual("the draft is the newest thing on screen",
               model.currentText(model.blocks[0]), "First line, rewritten offline.")
    check("and still flagged unsaved", model.unsavedBlockIds.contains(10))

    print()
    print("== A project never cached still reports the failure ==")
    let bare = ScriptModel(app: AppModel(connectivity: offline), project: project,
                           draftStore: nil,
                           offlineStore: OfflineStore(scope: "server|alice",
                                                      directory: scratchDirectory("empty")))
    await bare.loadBlocks()
    check("the writer hears about it", bare.errorMessage != nil)
    check("and nothing pretends to be a cached copy", !bare.isShowingOfflineCopy)
}

@MainActor
func checkDocumentFallback() async {
    print("== A note the network can't fetch opens from the copy on this device ==")
    let directory = scratchDirectory("document-fallback")
    let store = OfflineStore(scope: "server|alice", directory: directory)
    // What the server answered the last time this note was opened. The list
    // row carries only a preview, so without this copy there is nothing but a
    // truncated line to put on screen — and typing into *that* would eventually
    // send it back over the whole note.
    let noteJSON = """
    {"id": 7, "projectId": 1, "title": "Casting thoughts",
     "documentType": "NOTES",
     "content": "Maya reads younger than the part.\\nAsk about the accent.",
     "_links": {"self": {"href": "/api/documents/7"},
                "update": {"href": "/api/documents/7"}}}
    """
    store.save(Data(noteJSON.utf8), .document(projectId: 1, documentId: 7))

    let offline = ConnectivityMonitor(startMonitoring: false)
    offline.adopt(false)
    let model = ScriptModel(app: AppModel(connectivity: offline), project: project,
                            draftStore: nil, offlineStore: store)
    // The list's version of the row: a preview, no content — exactly what the
    // editor is handed before it fetches.
    let row: TextDocument = decode(TextDocument.self, """
    {"id": 7, "projectId": 1, "title": "Casting thoughts",
     "documentType": "NOTES", "preview": "Maya reads younger…",
     "_links": {"self": {"href": "/api/documents/7"},
                "update": {"href": "/api/documents/7"}}}
    """)

    let fetched = await model.fetchDocument(row)
    checkEqual("the whole note comes back, not the preview",
               fetched?.content,
               "Maya reads younger than the part.\nAsk about the accent.")
    check("and is stamped as the copy kept on this device",
          model.documentCopySavedAt[7] != nil)
    check("no error alert over a readable note", model.errorMessage == nil)

    print()
    print("== A note never cached still reports the failure ==")
    let bare = ScriptModel(app: AppModel(connectivity: offline), project: project,
                           draftStore: nil,
                           offlineStore: OfflineStore(scope: "server|alice",
                                                      directory: scratchDirectory("no-document")))
    let missing = await bare.fetchDocument(row)
    check("nothing is invented", missing == nil)
    check("the writer hears about it", bare.errorMessage != nil)
    check("and nothing pretends to be a cached copy", bare.documentCopySavedAt[7] == nil)

    print()
    print("== A rename refuses to work from a copy this device is only guessing at ==")
    check("the rename is not attempted", await model.renameDocument(row, title: "Casting") == false)
}

@MainActor
func checkPrintableWordsOffline() async {
    print("== A song or note prints from the copy this device kept ==")
    let directory = scratchDirectory("printable")
    let store = OfflineStore(scope: "server|alice", directory: directory)
    // A song is lyric lines on the server, so its cache is a line collection —
    // out of order here, as a server's page of them may well be.
    let lyricJSON = """
    {"_embedded": {"songBlockResourceList": [
        {"id": 21, "documentId": 3, "order": 2, "content": "and the barn door swings"},
        {"id": 20, "documentId": 3, "order": 1, "content": "The horse is out again"},
        {"id": 22, "documentId": 3, "order": 3, "content": ""}
    ]}}
    """
    store.save(Data(lyricJSON.utf8), .songBlocks(projectId: 1, documentId: 3))
    let noteJSON = """
    {"id": 7, "projectId": 1, "title": "Casting thoughts", "documentType": "NOTES",
     "content": "Maya reads younger than the part.\\nAsk about the accent.",
     "_links": {"self": {"href": "/api/documents/7"}}}
    """
    store.save(Data(noteJSON.utf8), .document(projectId: 1, documentId: 7))

    let offline = ConnectivityMonitor(startMonitoring: false)
    offline.adopt(false)
    let model = ScriptModel(app: AppModel(connectivity: offline), project: project,
                            draftStore: nil, offlineStore: store)

    let song: TextDocument = decode(TextDocument.self, """
    {"id": 3, "projectId": 1, "title": "Barn Song", "documentType": "SONG",
     "preview": "The horse is out…"}
    """)
    checkEqual("the lyric comes back in its own order, blank lines and all",
               model.cachedDocumentLines(song) ?? [],
               ["The horse is out again", "and the barn door swings", ""])

    let note: TextDocument = decode(TextDocument.self, """
    {"id": 7, "projectId": 1, "title": "Casting thoughts", "documentType": "NOTES",
     "preview": "Maya reads younger…"}
    """)
    checkEqual("a note comes back as its lines",
               model.cachedDocumentLines(note) ?? [],
               ["Maya reads younger than the part.", "Ask about the accent."])

    // The row's truncated preview is deliberately not a source: half a note on
    // paper looking like the whole of it is worse than saying it needs a route.
    let uncached: TextDocument = decode(TextDocument.self, """
    {"id": 9, "projectId": 1, "title": "Never opened", "documentType": "NOTES",
     "preview": "The first line of it…"}
    """)
    check("a document this device never held prints nothing",
          model.cachedDocumentLines(uncached) == nil)

    // A fetched document carries its own words, which is what the archive and
    // the editors hand over.
    let inHand: TextDocument = decode(TextDocument.self, """
    {"id": 9, "projectId": 1, "title": "In hand", "documentType": "NOTES",
     "content": "One line.\\n\\nAnother."}
    """)
    checkEqual("but one holding its own content does",
               model.cachedDocumentLines(inHand) ?? [],
               ["One line.", "", "Another."])
}

@MainActor
func checkReconnectHoldsWork() async {
    print("== A reconnect that still can't reach the server never drops the words ==")
    let directory = scratchDirectory("reconnect")
    let store = OfflineStore(scope: "server|alice", directory: directory)
    store.save(Data(blocksJSON.utf8), .blocks(projectId: 1))

    // Offline for the reading and the typing, so neither waits on a route this
    // machine may not have — see the note in checkBlocksFallback.
    let monitor = ConnectivityMonitor(startMonitoring: false)
    monitor.adopt(false)
    let model = ScriptModel(app: AppModel(connectivity: monitor), project: project,
                            draftStore: nil, offlineStore: store)
    await model.loadBlocks()
    model.liveEdit(model.blocks[0], text: "Typed while offline.")
    await model.blur(model.blocks[0])
    check("the edit is held before the reconnect", model.unsavedBlockIds.contains(10))

    // The route came back but the server is still refusing (the closed port):
    // the push fails, and the words must survive exactly as before. This is the
    // one request in the file that really goes out — the case is about a
    // failure the monitor cannot see, so it has to be a real one.
    monitor.adopt(true)
    await model.syncHeldWork()
    checkEqual("the words are still on screen",
               model.currentText(model.blocks[0]), "Typed while offline.")
    check("and still flagged unsaved", model.unsavedBlockIds.contains(10))
    check("no premature all-synced toast", model.historyToast == nil)
}

/// The outbox's own arithmetic, driven directly: temp ids, the persisted
/// mapping, and what happens to a chain when its head is abandoned. These are
/// the parts a live server can't be asked about.
@MainActor
func checkQueueArithmetic() async {
    print("== The outbox hands out ids, remembers them, and survives a reopen ==")
    let directory = scratchDirectory("queue")
    let queue = OfflineBlockQueue(scope: "server|alice", directory: directory)

    let first = queue.nextTempId(projectId: 1)
    checkEqual("the first temp id is negative", first, -1)
    queue.enqueue(PendingBlockCreate(tempId: first, anchorId: 10, type: "ACTION",
                                     content: "One.", personId: nil, createdAt: .now),
                  projectId: 1)
    let second = queue.nextTempId(projectId: 1)
    checkEqual("the next id steps past the one in the queue", second, -2)
    queue.enqueue(PendingBlockCreate(tempId: second, anchorId: first, type: "ACTION",
                                     content: "Two.", personId: nil, createdAt: .now),
                  projectId: 1)

    checkEqual("both are queued", queue.pending(projectId: 1).count, 2)
    checkEqual("in the order they were written",
               queue.pending(projectId: 1).map(\.tempId), [first, second])
    checkEqual("another project's queue is its own",
               queue.pending(projectId: 2).count, 0)

    queue.updateContent(tempId: first, to: "One, rewritten.", projectId: 1)
    checkEqual("the words are kept up to date",
               queue.pending(projectId: 1).first?.content, "One, rewritten.")
    queue.updateType(tempId: first, to: "SCENE", projectId: 1)
    checkEqual("and so is the type",
               queue.pending(projectId: 1).first?.type, "SCENE")

    let reopened = OfflineBlockQueue(scope: "server|alice", directory: directory)
    checkEqual("a reopened queue still holds both",
               reopened.pending(projectId: 1).map(\.tempId), [first, second])
    checkEqual("with the newest words",
               reopened.pending(projectId: 1).first?.content, "One, rewritten.")
    let bob = OfflineBlockQueue(scope: "server|bob", directory: directory)
    checkEqual("another account sees nothing", bob.pending(projectId: 1).count, 0)

    print()
    print("== A resolved element is remembered by id and leaves the queue ==")
    reopened.resolve(tempId: first, realId: 99, projectId: 1)
    checkEqual("the mapping is recorded", reopened.realId(for: first, projectId: 1), 99)
    checkEqual("and the entry is gone", reopened.pending(projectId: 1).map(\.tempId), [second])
    let afterResolve = OfflineBlockQueue(scope: "server|alice", directory: directory)
    checkEqual("the mapping outlives the process — a half-finished run resumes",
               afterResolve.realId(for: first, projectId: 1), 99)
    check("and an id already spoken for is never handed out again",
          afterResolve.nextTempId(projectId: 1) < second)

    print()
    print("== Abandoning an element abandons the chain hanging off it ==")
    let chain = OfflineBlockQueue(scope: "server|carol", directory: directory)
    let a = chain.nextTempId(projectId: 1)
    chain.enqueue(PendingBlockCreate(tempId: a, anchorId: 10, type: "ACTION",
                                     content: "A", personId: nil, createdAt: .now),
                  projectId: 1)
    let b = chain.nextTempId(projectId: 1)
    chain.enqueue(PendingBlockCreate(tempId: b, anchorId: a, type: "ACTION",
                                     content: "B", personId: nil, createdAt: .now),
                  projectId: 1)
    let c = chain.nextTempId(projectId: 1)
    chain.enqueue(PendingBlockCreate(tempId: c, anchorId: b, type: "ACTION",
                                     content: "C", personId: nil, createdAt: .now),
                  projectId: 1)
    // An element anchored to something outside the chain must survive.
    let loose = chain.nextTempId(projectId: 1)
    chain.enqueue(PendingBlockCreate(tempId: loose, anchorId: 10, type: "ACTION",
                                     content: "Loose", personId: nil, createdAt: .now),
                  projectId: 1)

    let dropped = chain.drop(tempId: a, projectId: 1)
    checkEqual("the whole chain is dropped, however deep", Set(dropped), Set([a, b, c]))
    checkEqual("and only the chain — the queue drains rather than blocking",
               chain.pending(projectId: 1).map(\.tempId), [loose])

    print()
    print("== A refusal drops one entry; its dependents re-anchor and survive ==")
    // `drop`'s cascade is for a deliberate delete. A create the *server*
    // refused takes only itself: what hung off it re-anchors one link up, so
    // the rest of a night's writing still lands — one line short, not gone.
    let refusal = OfflineBlockQueue(scope: "server|dave", directory: directory)
    let x = refusal.nextTempId(projectId: 1)
    refusal.enqueue(PendingBlockCreate(tempId: x, anchorId: 10, type: "ACTION",
                                       content: "X", personId: nil, createdAt: .now),
                    projectId: 1)
    let y = refusal.nextTempId(projectId: 1)
    refusal.enqueue(PendingBlockCreate(tempId: y, anchorId: x, type: "ACTION",
                                       content: "Y", personId: nil, createdAt: .now),
                    projectId: 1)
    let z = refusal.nextTempId(projectId: 1)
    refusal.enqueue(PendingBlockCreate(tempId: z, anchorId: y, type: "ACTION",
                                       content: "Z", personId: nil, createdAt: .now),
                    projectId: 1)
    refusal.dropSingle(tempId: x, projectId: 1)
    checkEqual("only the refused entry leaves the queue",
               refusal.pending(projectId: 1).map(\.tempId), [y, z])
    checkEqual("its dependent re-anchors to what the refused one hung off",
               refusal.pending(projectId: 1).first?.anchorId, 10)
    checkEqual("the deeper chain is untouched",
               refusal.pending(projectId: 1).last?.anchorId, y)
    let refusalReopened = OfflineBlockQueue(scope: "server|dave", directory: directory)
    checkEqual("and the re-anchoring is on disk, not just in memory",
               refusalReopened.pending(projectId: 1).first?.anchorId, 10)
}

/// The point of the whole feature: with no connection, Return still starts a
/// new line, and nothing typed into it is lost.
@MainActor
func checkWritingNewElementsOffline() async {
    print("== With no connection, a new element can still be written ==")
    // These elements advertise `createBelow`, unlike the shared payload above:
    // the case is about a create the *network* refuses, so the affordance has
    // to be there and the request has to genuinely go out and fail. A missing
    // link would exercise the permission path instead, which is a no-op.
    let editableBlocksJSON = """
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
    """
    let directory = scratchDirectory("writing")
    let store = OfflineStore(scope: "server|alice", directory: directory)
    store.save(Data(editableBlocksJSON.utf8), .blocks(projectId: 1))
    let queue = OfflineBlockQueue(scope: "server|alice",
                                  directory: directory.appendingPathComponent("queue"))

    let monitor = ConnectivityMonitor(startMonitoring: false)
    monitor.adopt(false)
    let model = ScriptModel(app: AppModel(connectivity: monitor), project: project,
                            draftStore: nil, offlineStore: store, createQueue: queue)
    await model.loadBlocks()
    checkEqual("the cached script opens", model.blocks.count, 2)

    // Return at the end of the first line: the create can't get out, so the
    // new element has to be held on this device instead of refused.
    await model.splitBlock(model.blocks[0], caret: 11)
    checkEqual("the new element is on screen", model.blocks.count, 3)
    let created = model.blocks[1]
    check("it is a local one", created.isLocal)
    check("the writer can type into it", created.isEditable)
    check("it is queued to be sent", queue.hasPending(projectId: 1))
    check("and counted as work held on this device",
          model.unsavedBlockIds.contains(created.id))
    checkEqual("one element is pending creation", model.pendingCreateCount, 1)
    check("no error alert — Return is not a failure", model.errorMessage == nil)

    // Typing into it keeps the queued copy current.
    model.liveEdit(created, text: "Written on a train.")
    await model.blur(created)
    checkEqual("the queued words follow the writer",
               queue.pending(projectId: 1).first?.content, "Written on a train.")
    checkEqual("and are what the row shows",
               model.currentText(model.blocks[1]), "Written on a train.")

    // Return again, this time below an element that itself only exists here.
    await model.splitBlock(model.blocks[1], caret: 19)
    checkEqual("a second new element chains off the first", model.blocks.count, 4)
    checkEqual("both are queued", queue.pending(projectId: 1).count, 2)
    checkEqual("the second is anchored to the first, not to the server's line",
               queue.pending(projectId: 1).last?.anchorId, created.id)

    print()
    print("== Retyping and deleting work on an element that only exists here ==")
    await model.changeType(model.blocks[1], to: .character)
    checkEqual("the queued type follows the element-type bar",
               queue.pending(projectId: 1).first?.type, "CHARACTER")
    checkEqual("and the row shows it", model.blocks[1].blockType, .character)

    let chained = model.blocks[2]
    await model.deleteBlock(model.blocks[1])
    check("deleting a local element removes it", !model.blocks.contains { $0.id == created.id })
    check("along with what was anchored to it",
          !model.blocks.contains { $0.id == chained.id })
    checkEqual("and the queue is empty again", queue.pending(projectId: 1).count, 0)
    checkEqual("leaving the server's own elements alone", model.blocks.count, 2)

    print()
    print("== The queue survives a relaunch, and a reconnect that still fails ==")
    await model.splitBlock(model.blocks[0], caret: 11)
    model.liveEdit(model.blocks[1], text: "Survives a relaunch.")
    await model.blur(model.blocks[1])

    // A fresh model over the same store, as a relaunch would build.
    let relaunched = ScriptModel(app: AppModel(connectivity: monitor), project: project,
                                 draftStore: nil, offlineStore: store,
                                 createQueue: OfflineBlockQueue(
                                     scope: "server|alice",
                                     directory: directory.appendingPathComponent("queue")))
    await relaunched.loadBlocks()
    checkEqual("the un-sent element is back on screen", relaunched.blocks.count, 3)
    checkEqual("with the words that were typed into it",
               relaunched.currentText(relaunched.blocks[1]), "Survives a relaunch.")
    check("still marked as held on this device", relaunched.blocks[1].isLocal)

    // The route returns but the server is still refusing (the closed port).
    // Nothing may be dropped: the create is retryable, so it stays queued.
    monitor.adopt(true)
    await relaunched.syncHeldWork()
    checkEqual("a replay that can't reach the server keeps the element",
               relaunched.pendingCreateCount, 1)
    checkEqual("and keeps it queued",
               queue.pending(projectId: 1).count, 1)
    checkEqual("with the words intact",
               relaunched.currentText(relaunched.blocks[1]), "Survives a relaunch.")
    check("and says nothing about having synced", relaunched.historyToast == nil)
}

/// The structural edits — Return mid-line, Backspace at the seam — keep
/// working offline on lines the server already has. The half that needs a PUT
/// is held on this device exactly as plain typing is; the half that needs a
/// new element rides the outbox.
@MainActor
func checkStructuralEditsOffline() async {
    print("== Return splits an edited line even with no connection ==")
    let editableBlocksJSON = """
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
    """
    let directory = scratchDirectory("structural")
    let store = OfflineStore(scope: "server|alice", directory: directory)
    store.save(Data(editableBlocksJSON.utf8), .blocks(projectId: 1))
    let queue = OfflineBlockQueue(scope: "server|alice",
                                  directory: directory.appendingPathComponent("queue"))

    let monitor = ConnectivityMonitor(startMonitoring: false)
    monitor.adopt(false)
    let model = ScriptModel(app: AppModel(connectivity: monitor), project: project,
                            draftStore: nil, offlineStore: store, createQueue: queue)
    await model.loadBlocks()

    // The line is reworded, then Return is pressed mid-line. The PUT of the
    // head cannot get out — the split must go ahead on this device anyway,
    // not silently swallow the keystroke.
    model.liveEdit(model.blocks[0], text: "First line, rewritten offline.")
    await model.splitBlock(model.blocks[0], caret: 11)
    checkEqual("the line is split on screen", model.blocks.count, 3)
    checkEqual("the head keeps the words before the caret",
               model.currentText(model.blocks[0]), "First line,")
    check("and is flagged unsaved for the retry", model.unsavedBlockIds.contains(10))
    check("the tail is an element held on this device", model.blocks[1].isLocal)
    checkEqual("carrying the words after the caret",
               model.currentText(model.blocks[1]), " rewritten offline.")
    checkEqual("queued behind the server's own line",
               queue.pending(projectId: 1).first?.anchorId, 10)
    checkEqual("the caret lands in the tail", model.focusedBlockId, model.blocks[1].id)

    print()
    print("== Backspace merges the tail back even with no connection ==")
    // Backspace at the start of the tail: the merged head can't be PUT either,
    // but its words are held, and the absorbed element only ever existed here.
    await model.mergeIntoPrevious(model.blocks[1])
    checkEqual("the line is whole again", model.blocks.count, 2)
    checkEqual("with all the words in the head",
               model.currentText(model.blocks[0]), "First line, rewritten offline.")
    check("still flagged unsaved", model.unsavedBlockIds.contains(10))
    checkEqual("and nothing left queued", queue.pending(projectId: 1).count, 0)

    print()
    print("== Backspace merges into the line written offline, not past it ==")
    // Two lines written offline in a row: Backspace on the second must fold
    // it into the first — the nearest editable line — not skip the pending
    // line (which advertises no links) and splice into the server line above.
    await model.insertBlock(below: model.blocks[1], type: .action)
    model.liveEdit(model.blocks[2], text: "Written offline.")
    await model.blur(model.blocks[2])
    await model.splitBlock(model.blocks[2], caret: 16)
    model.liveEdit(model.blocks[3], text: " And more.")
    await model.blur(model.blocks[3])
    await model.mergeIntoPrevious(model.blocks[3])
    checkEqual("the two offline lines fold into one",
               model.currentText(model.blocks[2]), "Written offline. And more.")
    checkEqual("the server line above them is untouched",
               model.currentText(model.blocks[1]), "Second line.")
    checkEqual("one queued element remains", queue.pending(projectId: 1).count, 1)

    print()
    print("== A force marker retypes a line written offline ==")
    model.liveEdit(model.blocks[2], text: ".INT KITCHEN")
    await model.retypeLive(model.blocks[2], to: .scene)
    checkEqual("the row reflows mid-keystroke", model.blocks[2].blockType, .scene)
    checkEqual("and the queued create carries the new type",
               queue.pending(projectId: 1).first?.type, "SCENE")

    print()
    print("== A draft whose line changed elsewhere is kept for the writer to choose ==")
    let conflictDirectory = scratchDirectory("conflict")
    let conflictStore = OfflineStore(scope: "server|alice", directory: conflictDirectory)
    conflictStore.save(Data(blocksJSON.utf8), .blocks(projectId: 1))
    let drafts = UnsavedDraftStore(scope: "server|alice",
                                   directory: conflictDirectory.appendingPathComponent("drafts"))
    drafts.save(UnsavedDraft(blockId: 10, text: "Words typed offline.",
                             baseText: "An older line.", savedAt: .now),
                projectId: 1)
    let conflicted = ScriptModel(app: AppModel(connectivity: monitor), project: project,
                                 draftStore: drafts, offlineStore: conflictStore)
    await conflicted.loadBlocks()
    checkEqual("the stale draft is not pushed over the newer words",
               conflicted.currentText(conflicted.blocks[0]), "First line.")
    check("and is off the retry machinery", drafts.drafts(projectId: 1).isEmpty)
    check("but the words are kept, not dropped",
          conflicted.conflicts.first?.mine == "Words typed offline.")
    check("beside the server's version",
          conflicted.conflicts.first?.theirs == "First line.")
    check("and the writer is told",
          conflicted.historyToast?.text.contains("needs your choice") == true)
}

/// Undo with no connection: the changes held on this device — text kept for
/// retry, elements queued for creation, offline retypes and deletes — can be
/// walked back and forward again without the server's history.
@MainActor
func checkUndoOffline() async {
    print("== With no connection, undo takes back the writing held on this device ==")
    let editableBlocksJSON = """
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
    """
    let directory = scratchDirectory("undo")
    let store = OfflineStore(scope: "server|alice", directory: directory)
    store.save(Data(editableBlocksJSON.utf8), .blocks(projectId: 1))
    let queue = OfflineBlockQueue(scope: "server|alice",
                                  directory: directory.appendingPathComponent("queue"))

    let monitor = ConnectivityMonitor(startMonitoring: false)
    monitor.adopt(false)
    let model = ScriptModel(app: AppModel(connectivity: monitor), project: project,
                            draftStore: nil, offlineStore: store, createQueue: queue)
    await model.loadBlocks()

    check("nothing to undo yet, and the pair stays out of the bar",
          !model.canUndo && !model.canRedo && !model.offersUndoRedo)
    await model.undo()
    check("an idle undo is a quiet no-op, not an alert", model.errorMessage == nil)

    // A failed save is a change only this device knows — and now an undoable one.
    model.liveEdit(model.blocks[0], text: "First line, rewritten offline.")
    await model.blur(model.blocks[0])
    check("a held edit arms undo", model.canUndo)
    check("and puts the pair in the bar", model.offersUndoRedo)

    await model.undo()
    checkEqual("undo puts the saved words back",
               model.currentText(model.blocks[0]), "First line.")
    checkEqual("and says so", model.historyToast?.text, "Change undone")
    check("the step moved to redo", model.canRedo && !model.canUndo)
    await model.redo()
    checkEqual("redo brings the offline words back",
               model.currentText(model.blocks[0]), "First line, rewritten offline.")
    check("and moves the step back", model.canUndo && !model.canRedo)

    print()
    print("== Undo removes an element written offline; redo re-queues it ==")
    await model.splitBlock(model.blocks[1], caret: 12)
    checkEqual("Return put a new element on screen", model.blocks.count, 3)
    await model.undo()
    checkEqual("undo takes it off again", model.blocks.count, 2)
    checkEqual("and out of the outbox", queue.pending(projectId: 1).count, 0)
    await model.redo()
    checkEqual("redo restores it", model.blocks.count, 3)
    check("back in the outbox too", queue.pending(projectId: 1).count == 1
          && model.blocks[2].isLocal)

    print()
    print("== Typing and retyping on a pending element are steps of their own ==")
    model.liveEdit(model.blocks[2], text: "Written on a train.")
    await model.blur(model.blocks[2])
    await model.changeType(model.blocks[2], to: .character)
    checkEqual("the retype landed", model.blocks[2].blockType, .character)
    await model.undo()
    checkEqual("undo returns the retype first", model.blocks[2].blockType, .action)
    checkEqual("in the outbox as well", queue.pending(projectId: 1).first?.type, "ACTION")
    checkEqual("without touching the words",
               model.currentText(model.blocks[2]), "Written on a train.")
    await model.undo()
    checkEqual("the next undo returns the words",
               model.currentText(model.blocks[2]), "")
    await model.redo()
    checkEqual("and redo brings them back",
               model.currentText(model.blocks[2]), "Written on a train.")

    print()
    print("== A deleted pending element comes back, words and all ==")
    await model.deleteBlock(model.blocks[2])
    checkEqual("the element is gone", model.blocks.count, 2)
    check("a fresh change forfeits redo", !model.canRedo)
    await model.undo()
    checkEqual("undo restores it", model.blocks.count, 3)
    checkEqual("with the words it held",
               model.currentText(model.blocks[2]), "Written on a train.")
    checkEqual("and its outbox entry",
               queue.pending(projectId: 1).first?.content, "Written on a train.")
    checkEqual("named as a restoration", model.historyToast?.text, "Restored 1 element")
    check("still counted as unsaved work",
          model.unsavedBlockIds.contains(model.blocks[2].id))
}

await run()
exit(failures == 0 ? 0 : 1)
