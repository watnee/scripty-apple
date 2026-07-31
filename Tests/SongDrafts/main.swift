//
//  main.swift
//  Tests/SongDrafts
//
//  What happens to a lyric line's — or a note's — words when a save doesn't
//  land.
//
//  The screenplay editor has held unsaved words since the offline work landed;
//  this suite pins the same promises onto the song and note editors, which
//  used to keep the words in memory only. The failure cases drive real models
//  against a real APIClient pointed at a closed port, so the failures are
//  genuine transport failures travelling the genuine error path; the drain
//  cases run against the in-process demo backend, so the PUT that finally
//  lands really lands.
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
    print("== A lyric the network can't fetch opens from the copy on this device ==")
    do {
        let directory = scratchDirectory("lyric-cache")
        let store = OfflineStore(scope: "server|alice", directory: directory)
        let cachedSong = decode(TextDocument.self, """
        {"id": 7, "projectId": 1, "title": "Test Song", "documentType": "SONG",
         "_links": {"songBlocks": {"href": "/api/documents/7/song-blocks"}}}
        """)
        // What a live load would have saved: the collection's raw bytes.
        store.save(Data("""
        {
          "_embedded": {
            "songBlockResourceList": [
              {"id": 40, "order": 1, "content": "First verse.",
               "_links": {"update": {"href": "/api/song-blocks/40"}}},
              {"id": 41, "order": 2, "content": "Second verse.",
               "_links": {"update": {"href": "/api/song-blocks/41"}}}
            ]
          },
          "_links": {"self": {"href": "/api/documents/7/song-blocks"}}
        }
        """.utf8), .songBlocks(projectId: 1, documentId: 7))

        // Held words from an earlier run lay on top of the cached copy. The
        // second draft's base doesn't match the cache — because the cache is
        // old, not because anyone edited elsewhere: its save landed after the
        // cache was written. The staleness gate must not fire against a copy
        // that stale; over the offline copy every draft is adopted and kept.
        let draftDirectory = scratchDirectory("lyric-cache-drafts")
        let drafts = UnsavedDraftStore(scope: "server|alice", directory: draftDirectory)
        drafts.save(UnsavedDraft(blockId: 40, text: "Rewritten offline.",
                                 baseText: "First verse.", savedAt: .now),
                    projectId: 7)
        drafts.save(UnsavedDraft(blockId: 41, text: "Newer than the cache.",
                                 baseText: "What the server had after the cache", savedAt: .now),
                    projectId: 7)

        let model = SongBlockModel(app: AppModel(), document: cachedSong,
                                   draftStore: drafts, offlineStore: store)
        await model.load()

        checkEqual("the cached lines are on screen", model.blocks.count, 2)
        check("and marked as the offline copy", model.isShowingOfflineCopy)
        check("with no alert raised", model.errorMessage == nil)
        checkEqual("the held draft is the newest thing on screen",
                   model.blocks.first.map { model.currentText($0) }, "Rewritten offline.")
        check("and flagged unsaved", model.unsavedBlockIds.contains(40))
        checkEqual("a draft the stale cache can't judge is adopted, not set aside",
                   model.blocks.last.map { model.currentText($0) }, "Newer than the cache.")
        check("and stays on disk for the live load to judge",
              drafts.drafts(projectId: 7)[41] != nil)
    }

    print()
    print("== A lyric never cached still reports the failure ==")
    do {
        let directory = scratchDirectory("lyric-uncached")
        let store = OfflineStore(scope: "server|alice", directory: directory)
        let unseenSong = decode(TextDocument.self, """
        {"id": 8, "projectId": 1, "title": "Never Opened", "documentType": "SONG",
         "_links": {"songBlocks": {"href": "/api/documents/8/song-blocks"}}}
        """)
        let model = SongBlockModel(app: AppModel(), document: unseenSong, offlineStore: store)
        await model.load()
        check("the lyric stays empty", model.blocks.isEmpty)
        check("nothing claims to be an offline copy", !model.isShowingOfflineCopy)
        check("and the failure is reported", model.errorMessage != nil)
    }

    print()
    print("== A create that cannot get out is not a refusal ==")
    do {
        // The editor's first autosave of a new song or note is a POST. Offline
        // it must come back as "unreachable" and stay quiet: the sheet's own
        // status line says where the words are, and an alert per debounce over
        // a document the writer is still typing the title of would bury them.
        let project = decode(Project.self, """
        {"id": 1, "title": "Test Script",
         "_links": {"documents": {"href": "/api/document?projectId=1"}}}
        """)
        let model = ScriptModel(app: AppModel(), project: project)
        var unreachable = false
        if case .unreachable = await model.createDocumentOutcome(
            title: "Ballad of the Closed Port", content: "First verse.", type: .song) {
            unreachable = true
        }
        check("the outcome is unreachable, not failed", unreachable)
        check("and raises no alert", model.errorMessage == nil)
        check("and nothing was added to the list", model.documents.isEmpty)
    }

    print()
    await checkNoteDraftStore()
    print()
    await checkHeldNoteSave()
    print()
    await checkNoteDraftDrain()
    print()
    await checkDocumentCreate()

    print()
    if failures == 0 {
        print("ALL CHECKS PASSED")
    } else {
        print("\(failures) CHECK(S) FAILED")
    }
}

// MARK: - Note drafts

@MainActor
func checkNoteDraftStore() async {
    print("== Note drafts survive the store being reopened ==")
    let directory = scratchDirectory("note-roundtrip")
    let store = UnsavedDocumentStore(scope: "server|alice", directory: directory)
    store.save(UnsavedDocumentDraft(documentId: 9, title: "Ideas", content: "Kept words.",
                                    baseTitle: "Ideas", baseContent: "Old words.", savedAt: .now),
               projectId: 1)

    let reopened = UnsavedDocumentStore(scope: "server|alice", directory: directory)
    let draft = reopened.draft(documentId: 9, projectId: 1)
    checkEqual("the content survives", draft?.content, "Kept words.")
    checkEqual("the base survives", draft?.baseContent, "Old words.")
    check("the other scope sees nothing",
          UnsavedDocumentStore(scope: "server|bob", directory: directory)
              .drafts(projectId: 1).isEmpty)

    reopened.remove(documentId: 9, projectId: 1)
    check("a removed draft stays removed",
          UnsavedDocumentStore(scope: "server|alice", directory: directory)
              .drafts(projectId: 1).isEmpty)
}

@MainActor
func checkHeldNoteSave() async {
    print("== A note save that cannot get out is held, on disk, quietly ==")
    let directory = scratchDirectory("note-hold")
    let store = UnsavedDocumentStore(scope: "server|alice", directory: directory)
    let project = decode(Project.self, #"{"id": 1, "title": "Test Script"}"#)
    let note = decode(TextDocument.self, """
    {"id": 9, "title": "Ideas", "documentType": "NOTE", "content": "First thoughts.",
     "_links": {"self": {"href": "/api/documents/9"}, "update": {"href": "/api/documents/9"}}}
    """)
    let model = ScriptModel(app: AppModel(), project: project, documentDrafts: store)

    let outcome = await model.saveDocumentOutcome(
        note, title: "Ideas", content: "Rewritten on a train.",
        baseTitle: "Ideas", baseContent: "First thoughts.")
    check("the outcome is held, not failed", outcome == .held)
    check("the model flags the document", model.heldDocumentIds.contains(9))
    check("held work is reported", model.hasHeldWork)

    let onDisk = UnsavedDocumentStore(scope: "server|alice", directory: directory)
        .draft(documentId: 9, projectId: 1)
    checkEqual("the words are on disk", onDisk?.content, "Rewritten on a train.")
    checkEqual("with the server's content as the base", onDisk?.baseContent, "First thoughts.")

    // A second hold keeps the original base — divergence began there.
    _ = await model.saveDocumentOutcome(
        note, title: "Ideas", content: "Rewritten twice.",
        baseTitle: "Ideas", baseContent: "Rewritten on a train.")
    checkEqual("a later hold keeps the newest words",
               store.draft(documentId: 9, projectId: 1)?.content, "Rewritten twice.")
    checkEqual("but the original base",
               store.draft(documentId: 9, projectId: 1)?.baseContent, "First thoughts.")

    model.discardDocumentDraft(for: 9)
    check("a discard drops the draft", store.drafts(projectId: 1).isEmpty)
    check("and the flag", !model.heldDocumentIds.contains(9))
}

@MainActor
func checkNoteDraftDrain() async {
    print("== The reconnect sweep sends held notes — but never over newer words ==")
    let app = AppModel()
    await app.enterDemo()
    guard let projectsLink = app.apiRoot?.link(.projects),
          let projects: HALCollection<Project> = try? await app.client.fetch(from: projectsLink),
          let project = projects.items.first else {
        check("the demo has a project", false)
        return
    }
    let directory = scratchDirectory("note-drain")
    let store = UnsavedDocumentStore(scope: "demo", directory: directory)
    let model = ScriptModel(app: app, project: project, documentDrafts: store)
    await model.loadDocuments()
    guard let note = model.documents.first(where: { $0.hasLink(.update) }),
          let full = await model.fetchDocument(note) else {
        check("the demo has an editable document", false)
        return
    }

    // A draft whose base matches the server: the sweep sends it.
    store.save(UnsavedDocumentDraft(documentId: note.id,
                                    title: full.title ?? "", content: "Written on the train.",
                                    baseTitle: full.title, baseContent: full.content ?? "",
                                    savedAt: .now),
               projectId: project.id)
    await model.syncHeldWork()
    check("the sent draft leaves the store", store.drafts(projectId: project.id).isEmpty)
    let after = await model.fetchDocument(note)
    checkEqual("and the server now says it", after?.content, "Written on the train.")

    // A draft whose base no longer matches: someone edited elsewhere, so the
    // sweep sets it aside rather than clobbering their words.
    store.save(UnsavedDocumentDraft(documentId: note.id,
                                    title: full.title ?? "", content: "Stale offline words.",
                                    baseTitle: full.title, baseContent: "Not what the server says.",
                                    savedAt: .now),
               projectId: project.id)
    await model.syncHeldWork()
    check("the stale draft is set aside", store.drafts(projectId: project.id).isEmpty)
    let unchanged = await model.fetchDocument(note)
    checkEqual("and the server's words stand", unchanged?.content, "Written on the train.")

    // A draft for a note that no longer exists: with the list loaded, the
    // sweep sets it aside rather than counting a ghost in the badge forever.
    store.save(UnsavedDocumentDraft(documentId: 987654,
                                    title: "Gone", content: "Held for a deleted note.",
                                    baseTitle: nil, baseContent: nil, savedAt: .now),
               projectId: project.id)
    await model.syncHeldWork()
    check("a draft for a deleted note is set aside",
          store.drafts(projectId: project.id).isEmpty)
}

@MainActor
func checkDocumentCreate() async {
    print("== A created document can be saved again without being reopened ==")
    // What the editor sheet needs from a create now that there is no Save
    // button: the document that comes back has to be a document it can go on
    // editing, or the second autosave would be a second POST and the writer
    // would end the sitting with a list full of half-typed duplicates.
    let app = AppModel()
    await app.enterDemo()
    guard let projectsLink = app.apiRoot?.link(.projects),
          let projects: HALCollection<Project> = try? await app.client.fetch(from: projectsLink),
          let project = projects.items.first else {
        check("the demo has a project", false)
        return
    }
    let model = ScriptModel(app: app, project: project)
    await model.loadDocuments()
    let before = model.documents.count

    var created: TextDocument?
    if case .created(let document) = await model.createDocumentOutcome(
        title: "Ballad of the Lost Hour", content: "First verse.", type: .song) {
        created = document
    }
    guard let created else {
        check("the create lands", false)
        return
    }
    checkEqual("the title is what was typed", created.title, "Ballad of the Lost Hour")
    check("it advertises an update link, so the next save is a PUT",
          created.hasLink(.update))
    check("and an insert link, so it can go into the script from the same sheet",
          created.hasLink(.insert))
    checkEqual("the list has it", model.documents.count, before + 1)

    // The second save: an edit to what was just created, sent the way the
    // editor's debounce sends it.
    let outcome = await model.saveDocumentOutcome(
        created, title: "Ballad of the Lost Hour", content: "First verse.\nSecond verse.",
        baseTitle: "Ballad of the Lost Hour", baseContent: "First verse.")
    check("the second save is a save, not a create", outcome == .saved)
    await model.loadDocuments()
    checkEqual("and made no second document", model.documents.count, before + 1)
    let full = await model.fetchDocument(created)
    checkEqual("the server has both verses", full?.content, "First verse.\nSecond verse.")

    // A document written without a title goes under the name the list already
    // draws for it, rather than not going at all. The editor supplies it, so
    // what is pinned here is that the server takes it and that a real title
    // typed afterwards is an ordinary rename rather than a second document.
    var untitled: TextDocument?
    if case .created(let document) = await model.createDocumentOutcome(
        title: "Untitled Notes", content: "Ask props for a second machine.",
        type: .notes) {
        untitled = document
    }
    guard let untitled else {
        check("an untitled document is created too", false)
        return
    }
    checkEqual("it is filed under the name the list draws",
               untitled.displayTitle, "Untitled Notes")
    let renamed = await model.saveDocumentOutcome(
        untitled, title: "Props List", content: "Ask props for a second machine.",
        baseTitle: "Untitled Notes", baseContent: "Ask props for a second machine.")
    check("naming it later is a rename, not a refusal", renamed == .saved)
    await model.loadDocuments()
    checkEqual("and still one document", model.documents.count, before + 2)
    checkEqual("under its new name",
               model.documents.first { $0.id == untitled.id }?.title, "Props List")
}

await run()
exit(failures == 0 ? 0 : 1)
