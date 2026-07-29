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
    await checkReconnectHoldsWork()

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
    await model.connectionRestored()
    checkEqual("the words are still on screen",
               model.currentText(model.blocks[0]), "Typed while offline.")
    check("and still flagged unsaved", model.unsavedBlockIds.contains(10))
    check("no premature all-synced toast", model.historyToast == nil)
}

await run()
exit(failures == 0 ? 0 : 1)
