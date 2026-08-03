//
//  main.swift
//  Tests/Conflicts
//
//  Two versions of the same words, and what the app does with them.
//
//  Every check here is about one promise: words the writer typed are never
//  thrown away by a client that cannot ask. Before conflicts existed, a draft
//  whose base no longer matched the server was deleted — the only safe move
//  for the *other* version, and a lossy one for this one. Now both are kept
//  until somebody chooses, so the suite pins the keeping (the store, and that
//  it survives a relaunch), the finding (a stale draft becomes a conflict
//  rather than a toast), and the choosing (mine goes out or is held, theirs
//  simply stands).
//
//  The offline halves drive real models with the connectivity monitor held
//  down by hand, so every request fails at the client's own gate — no socket,
//  and much faster than a closed port. The online halves run against the
//  in-process demo backend, so a chosen version really is written and really
//  can be read back.
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

func scratchDirectory(_ name: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("scripty-conflicts-\(name)-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.removeItem(at: url)
    return url
}

// MARK: - Fixtures

let project = decode(Project.self, """
{"id": 1, "title": "Test Script",
 "_links": {"blocks": {"href": "/api/projects/1/blocks"}}}
""")

let song = decode(TextDocument.self,
    #"{"id": 7, "title": "Test Song", "documentType": "SONG"}"#)

/// Two elements advertising the links the editing paths gate on. Never
/// fetched in the offline halves: the monitor is held down, so the client
/// refuses each request on its own doorstep — what a writer with no route
/// actually meets.
let blocksJSON = """
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
"""

func twoLineLyric() -> HALCollection<SongBlock> {
    decode(HALCollection<SongBlock>.self, """
    {
      "_embedded": {
        "songBlockResourceList": [
          {
            "id": 40, "order": 1, "content": "First verse.",
            "_links": {"update": {"href": "/api/song-blocks/40"}}
          },
          {
            "id": 41, "order": 2, "content": "Second verse.",
            "_links": {"update": {"href": "/api/song-blocks/41"}}
          }
        ]
      },
      "_links": {"self": {"href": "/api/documents/7/song-blocks"}}
    }
    """)
}

@MainActor
func offlineApp() -> AppModel {
    let monitor = ConnectivityMonitor(startMonitoring: false)
    monitor.adopt(false)
    return AppModel(connectivity: monitor)
}

func conflict(_ subject: SyncConflict.Subject, mine: String, theirs: String,
              at date: Date = .now) -> SyncConflict {
    SyncConflict(subject: subject, reason: .changedElsewhere, mine: mine,
                 theirs: theirs, label: "Action", detectedAt: date)
}

// MARK: - The store

@MainActor
func checkStoreOutlivesTheLaunch() {
    print("== A conflict nobody answered is still there next launch ==")
    let directory = scratchDirectory("store")
    let store = ConflictStore(scope: "server|alice", directory: directory)
    store.record(conflict(.block(id: 10), mine: "Mine.", theirs: "Theirs."),
                 collectionId: 1)

    // A second store over the same directory is what a relaunch looks like:
    // nothing in memory, everything read back off disk.
    let reopened = ConflictStore(scope: "server|alice", directory: directory)
    checkEqual("it is read back", reopened.conflicts(collectionId: 1).count, 1)
    checkEqual("with the writer's words", reopened.conflicts(collectionId: 1).first?.mine, "Mine.")
    checkEqual("and the server's", reopened.conflicts(collectionId: 1).first?.theirs, "Theirs.")
    check("and something to answer", reopened.hasPending(collectionId: 1))

    let otherAccount = ConflictStore(scope: "server|bob", directory: directory)
    check("another account sees none of it", otherAccount.conflicts(collectionId: 1).isEmpty)

    // Song line ids and screenplay block ids are different id spaces, so the
    // lyric editor's store is given a folder of its own (`folder:`, which the
    // app reaches through the default path). Within one store, collections
    // are separate for the same reason: project 1 and project 2 must never
    // read each other's questions.
    check("and another collection in the same store sees none of it",
          reopened.conflicts(collectionId: 2).isEmpty)

    reopened.remove(id: "block-10", collectionId: 1)
    check("answering it clears the file",
          ConflictStore(scope: "server|alice", directory: directory)
              .conflicts(collectionId: 1).isEmpty)
}

@MainActor
func checkStoreKeepsWhenItBegan() {
    print("== Seeing the same disagreement twice is not two disagreements ==")
    let store = ConflictStore(scope: "server|alice", directory: scratchDirectory("repeat"))
    let began = Date(timeIntervalSinceNow: -3600)
    store.record(conflict(.block(id: 10), mine: "Mine.", theirs: "Theirs.", at: began),
                 collectionId: 1)
    store.record(conflict(.block(id: 10), mine: "Mine, again.", theirs: "Theirs, newer.",
                          at: .now),
                 collectionId: 1)

    checkEqual("still one row", store.conflicts(collectionId: 1).count, 1)
    checkEqual("carrying the newest words on this side",
               store.conflicts(collectionId: 1).first?.mine, "Mine, again.")
    checkEqual("and on the other", store.conflicts(collectionId: 1).first?.theirs,
               "Theirs, newer.")
    checkEqual("but dated from when the two parted",
               store.conflicts(collectionId: 1).first?.detectedAt, began)
}

@MainActor
func checkStoreForgetsTheAncient() {
    print("== A conflict from two months ago is not asked about ==")
    let directory = scratchDirectory("horizon")
    let store = ConflictStore(scope: "server|alice", directory: directory)
    store.record(conflict(.block(id: 10), mine: "Old.", theirs: "Older.",
                          at: Date(timeIntervalSinceNow: -60 * 24 * 60 * 60)),
                 collectionId: 1)
    store.record(conflict(.block(id: 11), mine: "New.", theirs: "Newer."), collectionId: 1)

    let reopened = ConflictStore(scope: "server|alice", directory: directory)
    checkEqual("only the one still worth asking about survives the read",
               reopened.conflicts(collectionId: 1).map(\.id), ["block-11"])
}

// MARK: - Finding one in a screenplay

@MainActor
func checkStaleDraftBecomesAChoice() async {
    print("== A draft the server has moved past is kept, not dropped ==")
    let directory = scratchDirectory("script")
    let offline = OfflineStore(scope: "server|alice", directory: directory)
    offline.save(Data(blocksJSON.utf8), .blocks(projectId: 1))
    let drafts = UnsavedDraftStore(scope: "server|alice",
                                   directory: directory.appendingPathComponent("drafts"))
    let conflicts = ConflictStore(scope: "server|alice",
                                  directory: directory.appendingPathComponent("conflicts"))
    // Typed while offline against words the server no longer has.
    drafts.save(UnsavedDraft(blockId: 10, text: "Words typed offline.",
                             baseText: "An older line.", savedAt: .now),
                projectId: 1)

    let model = ScriptModel(app: offlineApp(), project: project, draftStore: drafts,
                            offlineStore: offline, conflictStore: conflicts)
    await model.loadBlocks()

    checkEqual("the newer words stay on screen", model.currentText(model.blocks[0]),
               "First line.")
    check("the draft leaves the retry machinery", drafts.drafts(projectId: 1).isEmpty)
    checkEqual("one thing to answer", model.conflicts.count, 1)
    check("and the screen has a reason to say so", model.hasConflicts)
    let found = model.conflicts[0]
    checkEqual("the writer's version is kept whole", found.mine, "Words typed offline.")
    checkEqual("beside the server's", found.theirs, "First line.")
    checkEqual("with what they both started from", found.base, "An older line.")
    checkEqual("named by what it is", found.label, "Action")
    checkEqual("and why it happened", found.reason, .changedElsewhere)
    check("it can be sent", found.canKeepMine)

    // Durable: the answer is owed even if the app goes down before it is given.
    checkEqual("and it is on disk, not just on screen",
               ConflictStore(scope: "server|alice",
                             directory: directory.appendingPathComponent("conflicts"))
                   .conflicts(collectionId: 1).count, 1)
}

@MainActor
func checkKeepTheirsSimplyStops() async {
    print("== Keeping the cloud's version asks nothing of the network ==")
    let directory = scratchDirectory("theirs")
    let offline = OfflineStore(scope: "server|alice", directory: directory)
    offline.save(Data(blocksJSON.utf8), .blocks(projectId: 1))
    let drafts = UnsavedDraftStore(scope: "server|alice",
                                   directory: directory.appendingPathComponent("drafts"))
    let conflicts = ConflictStore(scope: "server|alice",
                                  directory: directory.appendingPathComponent("conflicts"))
    drafts.save(UnsavedDraft(blockId: 10, text: "Words typed offline.",
                             baseText: "An older line.", savedAt: .now),
                projectId: 1)
    let model = ScriptModel(app: offlineApp(), project: project, draftStore: drafts,
                            offlineStore: offline, conflictStore: conflicts)
    await model.loadBlocks()

    model.keepTheirs(model.conflicts[0])

    check("nothing is left to answer", model.conflicts.isEmpty)
    check("nor on disk", !conflicts.hasPending(collectionId: 1))
    checkEqual("and the server's words are what is on screen",
               model.currentText(model.blocks[0]), "First line.")
    check("with nothing held on this device", !model.hasUnsavedChanges)
}

@MainActor
func checkKeepMineOfflineIsHeldNotLost() async {
    print("== Keeping your own version with no connection holds it, safely ==")
    let directory = scratchDirectory("mine-offline")
    let offline = OfflineStore(scope: "server|alice", directory: directory)
    offline.save(Data(blocksJSON.utf8), .blocks(projectId: 1))
    let drafts = UnsavedDraftStore(scope: "server|alice",
                                   directory: directory.appendingPathComponent("drafts"))
    let conflicts = ConflictStore(scope: "server|alice",
                                  directory: directory.appendingPathComponent("conflicts"))
    drafts.save(UnsavedDraft(blockId: 10, text: "Words typed offline.",
                             baseText: "An older line.", savedAt: .now),
                projectId: 1)
    let model = ScriptModel(app: offlineApp(), project: project, draftStore: drafts,
                            offlineStore: offline, conflictStore: conflicts)
    await model.loadBlocks()

    let outcome = await model.keepMine(model.conflicts[0])

    checkEqual("the write could not get out, and says so", outcome, .held)
    check("the question is answered all the same", model.conflicts.isEmpty)
    check("and not left on disk to be asked again", !conflicts.hasPending(collectionId: 1))
    checkEqual("the chosen words are on screen", model.currentText(model.blocks[0]),
               "Words typed offline.")
    check("held by the ordinary machinery", model.unsavedBlockIds.contains(10))
    checkEqual("which has them on disk too, where a relaunch will find them",
               drafts.drafts(projectId: 1)[10]?.text, "Words typed offline.")
    checkEqual("judged from here on against what the server actually says",
               drafts.drafts(projectId: 1)[10]?.baseText, "First line.")
}

@MainActor
func checkKeepMineOnlineIsSent() async {
    print("== Keeping your own version with a connection sends it ==")
    let app = AppModel()
    await app.enterDemo(persisted: false)
    guard let projectsLink = app.apiRoot?.link(.projects),
          let projects: HALCollection<Project> = try? await app.client.fetch(from: projectsLink),
          let demoProject = projects.items.first else {
        check("the demo has a project", false)
        return
    }
    let directory = scratchDirectory("mine-online")
    let drafts = UnsavedDraftStore(scope: "demo", directory: directory)
    let conflicts = ConflictStore(scope: "demo",
                                  directory: directory.appendingPathComponent("conflicts"))
    let model = ScriptModel(app: app, project: demoProject, draftStore: drafts,
                            conflictStore: conflicts)
    await model.loadBlocks()
    guard let target = model.blocks.first(where: { $0.hasLink(.update) }) else {
        check("the demo has an editable element", false)
        return
    }
    let server = model.currentText(target)
    // What a stale draft looks like by the time the sweep finds it.
    drafts.save(UnsavedDraft(blockId: target.id, text: "Chosen offline words.",
                             baseText: "Not what the server says.", savedAt: .now),
                projectId: demoProject.id)
    model.adoptPersistedDrafts()
    checkEqual("the stale draft is a question, not a write", model.conflicts.count, 1)
    checkEqual("and the element still reads as the server left it",
               model.currentText(target), server)

    let outcome = await model.keepMine(model.conflicts[0])

    checkEqual("the chosen version goes out", outcome, .sent)
    check("nothing is left to answer", model.conflicts.isEmpty)
    check("nothing is left held", !model.hasUnsavedChanges)
    await model.loadBlocks()
    checkEqual("and the server says what the writer chose",
               model.blocks.first { $0.id == target.id }.map { model.currentText($0) },
               "Chosen offline words.")
}

// MARK: - A note

@MainActor
func checkNoteConflictCanBeChosen() async {
    print("== A note edited in two places keeps both, then takes the answer ==")
    let app = AppModel()
    await app.enterDemo(persisted: false)
    guard let projectsLink = app.apiRoot?.link(.projects),
          let projects: HALCollection<Project> = try? await app.client.fetch(from: projectsLink),
          let demoProject = projects.items.first else {
        check("the demo has a project", false)
        return
    }
    let directory = scratchDirectory("note")
    let documents = UnsavedDocumentStore(scope: "demo", directory: directory)
    let conflicts = ConflictStore(scope: "demo",
                                  directory: directory.appendingPathComponent("conflicts"))
    let model = ScriptModel(app: app, project: demoProject, documentDrafts: documents,
                            conflictStore: conflicts)
    await model.loadDocuments()
    guard let note = model.documents.first(where: { $0.hasLink(.update) }),
          let full = await model.fetchDocument(note) else {
        check("the demo has an editable document", false)
        return
    }
    let server = full.content ?? ""
    documents.save(UnsavedDocumentDraft(documentId: note.id, title: full.title ?? "",
                                        content: "A paragraph written on the train.",
                                        baseTitle: full.title,
                                        baseContent: "Not what the server says.",
                                        savedAt: .now),
                   projectId: demoProject.id)

    await model.syncHeldWork()

    checkEqual("the sweep asks rather than clobbering", model.conflicts.count, 1)
    checkEqual("keeping the writer's paragraph", model.conflicts[0].mine,
               "A paragraph written on the train.")
    checkEqual("and the server's", model.conflicts[0].theirs, server)
    check("the note stops being counted as held work", !model.hasHeldWork)
    checkEqual("and the sheet over that note sees its own question",
               model.conflicts(forDocument: note.id).count, 1)

    let outcome = await model.keepMine(model.conflicts[0])

    checkEqual("the chosen version goes out", outcome, .sent)
    check("with nothing left to answer", model.conflicts.isEmpty)
    let after = await model.fetchDocument(note)
    checkEqual("and the server says what the writer chose", after?.content,
               "A paragraph written on the train.")
}

// MARK: - A lyric

@MainActor
func checkLyricConflict() async {
    print("== A lyric line written in two places waits for the writer ==")
    let directory = scratchDirectory("lyric")
    let drafts = UnsavedDraftStore(scope: "server|alice", directory: directory,
                                   folder: "SongDrafts")
    let conflicts = ConflictStore(scope: "server|alice",
                                  directory: directory.appendingPathComponent("conflicts"),
                                  folder: "SongConflicts")
    drafts.save(UnsavedDraft(blockId: 40, text: "A verse from the train.",
                             baseText: "What the server used to say.", savedAt: .now),
                projectId: song.id)

    let model = SongBlockModel(app: offlineApp(), document: song, draftStore: drafts,
                               conflictStore: conflicts)
    model.adopt(twoLineLyric())
    model.adoptPersistedDrafts()

    checkEqual("one thing to answer", model.conflicts.count, 1)
    checkEqual("the writer's line is kept", model.conflicts[0].mine, "A verse from the train.")
    checkEqual("beside the server's", model.conflicts[0].theirs, "First verse.")
    checkEqual("named by where it is", model.conflicts[0].label, "Line 1")
    checkEqual("and the line on screen is still the server's",
               model.currentText(model.blocks[0]), "First verse.")
    check("with no alert demanding a tap before the next word",
          model.errorMessage == nil)

    let outcome = await model.keepMine(model.conflicts[0])
    checkEqual("choosing offline holds the words rather than losing them", outcome, .held)
    checkEqual("which are now the line", model.currentText(model.blocks[0]),
               "A verse from the train.")
    check("held by the ordinary machinery", model.unsavedBlockIds.contains(40))
    check("and nothing is left to answer", model.conflicts.isEmpty)
}

@MainActor
func checkOfflineCopyNeverAccuses() async {
    print("== An old cached lyric is never evidence that words changed elsewhere ==")
    // The cache is only as fresh as the last full load: a save that landed
    // after it makes the writer's own newer draft read as "changed
    // elsewhere". Over the offline copy every draft is adopted, and no
    // question is raised — the reconnect push is last-write-wins.
    let directory = scratchDirectory("stale-cache")
    let offline = OfflineStore(scope: "server|alice", directory: directory)
    let cached = """
    {
      "_embedded": {
        "songBlockResourceList": [
          {"id": 40, "order": 1, "content": "What the cache remembers.",
           "_links": {"update": {"href": "/api/song-blocks/40"}}}
        ]
      },
      "_links": {"self": {"href": "/api/documents/7/song-blocks"}}
    }
    """
    let cachedSong = decode(TextDocument.self, """
    {"id": 7, "projectId": 1, "title": "Test Song", "documentType": "SONG",
     "_links": {"songBlocks": {"href": "/api/documents/7/song-blocks"}}}
    """)
    offline.save(Data(cached.utf8), .songBlocks(projectId: 1, documentId: 7))
    let drafts = UnsavedDraftStore(scope: "server|alice",
                                   directory: directory.appendingPathComponent("drafts"),
                                   folder: "SongDrafts")
    let conflicts = ConflictStore(scope: "server|alice",
                                  directory: directory.appendingPathComponent("conflicts"),
                                  folder: "SongConflicts")
    drafts.save(UnsavedDraft(blockId: 40, text: "Newer than the cache.",
                             baseText: "Something the cache never saw.", savedAt: .now),
                projectId: 7)

    let model = SongBlockModel(app: offlineApp(), document: cachedSong,
                               draftStore: drafts, offlineStore: offline,
                               conflictStore: conflicts)
    await model.load()

    check("the offline copy is what is on screen", model.isShowingOfflineCopy)
    check("no question is raised against a copy that cannot judge", model.conflicts.isEmpty)
    checkEqual("and the writer's newer words are the line",
               model.currentText(model.blocks[0]), "Newer than the cache.")
    check("still held, still on disk", drafts.drafts(projectId: 7)[40] != nil)
}

// MARK: - Run

@MainActor
func run() async {
    checkStoreOutlivesTheLaunch()
    print()
    checkStoreKeepsWhenItBegan()
    print()
    checkStoreForgetsTheAncient()
    print()
    await checkStaleDraftBecomesAChoice()
    print()
    await checkKeepTheirsSimplyStops()
    print()
    await checkKeepMineOfflineIsHeldNotLost()
    print()
    await checkKeepMineOnlineIsSent()
    print()
    await checkNoteConflictCanBeChosen()
    print()
    await checkLyricConflict()
    print()
    await checkOfflineCopyNeverAccuses()
}

await run()

print()
if failures == 0 {
    print("Conflict checks passed.")
    exit(0)
} else {
    print("\(failures) conflict check(s) FAILED.")
    exit(1)
}
