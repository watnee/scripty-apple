//
//  main.swift
//  Tests/ProjectSync
//
//  One screenplay, written on a device with no account and then kept by one.
//
//  The story this suite pins is the one a writer actually lives: start
//  something signed out, sign in and keep it, sign out and carry on writing in
//  it, sign back in and find the account holding what you wrote — one
//  screenplay throughout, never a shelf of copies. Every step of that crossing
//  moves whole documents between two stores, so the way it fails is quiet and
//  expensive: words that arrive somewhere stale, or don't arrive at all.
//
//  Two demo backends stand in for the two sides — one is the device's
//  workspace, the other is the account, which is exactly the job the demo
//  backend does for every other suite here. The account side is driven through
//  a real `APIClient`, so the multipart upload, the archive format and the
//  `replaceFromArchive` affordance are the ones the app really uses.
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

func url(_ path: String) -> URL { URL(string: DemoBackend.baseURL.absoluteString + path)! }
func body(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
func json(_ response: (status: Int, data: Data)) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]) ?? [:]
}
func embedded(_ object: [String: Any]) -> [[String: Any]] {
    guard let map = object["_embedded"] as? [String: Any],
          let first = map.values.first as? [[String: Any]] else { return [] }
    return first
}

func scratchDirectory(_ name: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("scripty-project-sync-\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A `UserDefaults` of its own, so nothing here can read or write the
/// developer's own record of which screenplay is which.
func scratchDefaults(_ name: String) -> UserDefaults {
    let suite = "scripty-project-sync-\(name)-\(UUID().uuidString)"
    UserDefaults.standard.removePersistentDomain(forName: suite)
    return UserDefaults(suiteName: suite)!
}

func decode<T: Decodable>(_ type: T.Type, _ text: String) -> T {
    try! JSONDecoder().decode(T.self, from: Data(text.utf8))
}

// MARK: - Driving the two sides

/// The device's copy of a screenplay, written into the account.
///
/// The same three calls `AppModel.uploadGuestWork` makes, in the same order:
/// one project's archive out of the local backend, the account's own import
/// affordance, and the screenplay the account answers with — which is the only
/// thing that can tell the device *which* screenplay it now has.
@MainActor
func keep(_ localId: Int, from device: DemoBackend, into account: APIClient) async -> Project? {
    guard let root = try? await account.fetch(APIRoot.self, from: account.rootLink),
          let projectsLink = root.link(.projects),
          let collection: HALCollection<Project> = try? await account.fetch(from: projectsLink),
          let importLink = collection.links[.importProject] else { return nil }
    let (status, bundle) = await device.demoProjectsBundle(ids: [localId])
    guard status == 200 else { return nil }
    return try? await account.upload(Project.self, to: importLink,
                                     fileName: "Scripty.scripty.json",
                                     fileData: bundle, mimeType: "application/json")
}

/// The crossing on the way in: what the device wrote, into the screenplay the
/// account already has. `AppModel.push`.
@MainActor
func send(_ localId: Int, from device: DemoBackend,
          into remote: Project, on account: APIClient) async -> Project? {
    guard let replaceLink = remote.links?[.replaceFromArchive] else { return nil }
    let (status, bundle) = await device.demoProjectsBundle(ids: [localId])
    guard status == 200 else { return nil }
    return try? await account.upload(Project.self, to: replaceLink,
                                     fileName: "Scripty.scripty.json",
                                     fileData: bundle, mimeType: "application/json")
}

/// The crossing on the way out: the account's copy, back onto the device.
/// `AppModel.applyMirrors`.
@MainActor
func bringDown(_ remote: Project, into localId: Int,
               on device: DemoBackend, from account: APIClient) async -> Bool {
    guard let archiveLink = remote.links?[.exportArchive],
          let data = try? await account.data(for: archiveLink) else { return false }
    return await device.mirrorProject(localId, fromArchive: data)
}

@MainActor
func project(_ id: Int, on client: APIClient) async -> Project? {
    guard let root = try? await client.fetch(APIRoot.self, from: client.rootLink),
          let projectsLink = root.link(.projects),
          let collection: HALCollection<Project> = try? await client.fetch(from: projectsLink)
    else { return nil }
    return collection.items.first { $0.id == id }
}

/// The lines of a screenplay as the backend holds them, in order.
@MainActor
func lines(_ projectId: Int, on backend: DemoBackend) async -> [String] {
    let response = await backend.respond(method: "GET", url: url("/api/block?projectId=\(projectId)"), body: nil)
    return embedded(json(response)).compactMap { $0["content"] as? String }
}

/// Song and note titles, listed and archived apart.
@MainActor
func documents(_ projectId: Int, on backend: DemoBackend,
               archived: Bool = false) async -> [String] {
    let path = archived
        ? "/api/document/archive?projectId=\(projectId)"
        : "/api/document?projectId=\(projectId)"
    let response = await backend.respond(method: "GET", url: url(path), body: nil)
    return embedded(json(response)).compactMap { $0["title"] as? String }
}

@MainActor
@discardableResult
func write(_ content: String, type: String = "ACTION",
           into projectId: Int, on backend: DemoBackend) async -> Int? {
    let response = await backend.respond(
        method: "POST", url: url("/api/block"),
        body: body(["projectId": projectId, "content": content, "type": type]))
    return json(response)["id"] as? Int
}

// MARK: - The whole crossing, both ways

@MainActor
func checkRoundTrip() async {
    print("== A screenplay written signed out stays one screenplay ==")

    let directory = scratchDirectory("round-trip")
    defer { try? FileManager.default.removeItem(at: directory) }
    let device = DemoBackend(store: LocalWorkspaceStore(directory: directory))
    let account = DemoBackend(store: nil)
    let accountClient = APIClient(baseURL: DemoBackend.baseURL, demo: account)
    let links = ProjectLinkStore(defaults: scratchDefaults("round-trip"))
    let scope = "example.test|writer"

    // 1. Something written with no account behind it.
    let made = json(await device.respond(method: "POST", url: url("/api/project"),
                                         body: body(["title": "Night Shoot"])))
    guard let localId = made["id"] as? Int else {
        check("a screenplay is created without an account", false)
        return
    }
    await write("INT. VAN - NIGHT", type: "SCENE", into: localId, on: device)
    await write("Rain on the windscreen.", into: localId, on: device)
    _ = await device.respond(method: "POST", url: url("/api/document"),
                             body: body(["projectId": localId, "title": "Wet Roads",
                                         "documentType": "NOTES", "content": "Shoot it dry."]))
    check("the device has words the account has never seen",
          await device.hasUnsentWork(projectId: localId))

    // 2. Signing in and keeping it.
    guard let kept = await keep(localId, from: device, into: accountClient) else {
        check("the account takes the screenplay", false)
        return
    }
    links.record(ProjectLink(localId: localId, scope: scope, remoteId: kept.id,
                             syncedRemoteEdited: kept.lastEdited))
    await device.markHandedOff(projectIds: [localId])

    checkEqual("the account has it, whole", await lines(kept.id, on: account),
               ["INT. VAN - NIGHT", "Rain on the windscreen."])
    checkEqual("with its notes", await documents(kept.id, on: account), ["Wet Roads"])
    check("and the device is no longer holding anything unsent",
          await device.hasUnsentWork(projectId: localId) == false)
    checkEqual("the two are recorded as one screenplay",
               links.remoteId(forLocal: localId, in: scope), kept.id)

    // 3. Written in while signed in, then signed out: the device catches up.
    await write("She kills the engine.", into: kept.id, on: account)
    guard let afterEditing = await project(kept.id, on: accountClient) else {
        check("the account's copy can be read back", false)
        return
    }
    check("the account's copy comes down on the way out",
          await bringDown(afterEditing, into: localId, on: device, from: accountClient))
    checkEqual("so signing out lands in the screenplay as the account has it",
               await lines(localId, on: device),
               ["INT. VAN - NIGHT", "Rain on the windscreen.", "She kills the engine."])
    checkEqual("under the id the device already knew it by",
               links.remoteId(forLocal: localId, in: scope), kept.id)
    check("and it is not work waiting to be sent — it just came from there",
          await device.hasUnsentWork(projectId: localId) == false)

    // 4. More writing signed out, then signing back in.
    await write("JUNIPER", type: "CHARACTER", into: localId, on: device)
    check("which the device does now hold", await device.hasUnsentWork(projectId: localId))
    guard let link = links.link(local: localId, in: scope),
          let remote = await project(link.remoteId, on: accountClient) else {
        check("the link still names a screenplay in the account", false)
        return
    }
    checkEqual("and the rule says send it, not copy it",
               AppModel.LinkSync.decide(link, localExists: true, remote: remote,
                                        localHasWork: true),
               .send)
    guard let replaced = await send(localId, from: device, into: remote, on: accountClient) else {
        check("the account takes the update", false)
        return
    }

    checkEqual("it is the same screenplay in the account, not a second one",
               replaced.id, kept.id)
    let shelf: HALCollection<Project>? = await {
        guard let root = try? await accountClient.fetch(APIRoot.self, from: accountClient.rootLink),
              let projectsLink = root.link(.projects) else { return nil }
        return try? await accountClient.fetch(from: projectsLink)
    }()
    checkEqual("so the account's list has not grown",
               shelf?.items.filter { $0.displayTitle == "Night Shoot" }.count, 1)
    checkEqual("holding what was written on the device",
               await lines(kept.id, on: account),
               ["INT. VAN - NIGHT", "Rain on the windscreen.", "She kills the engine.", "JUNIPER"])
}

// MARK: - What the crossing must never lose

@MainActor
func checkNothingIsLost() async {
    print()
    print("== What a replaced screenplay leaves behind is still reachable ==")

    let account = DemoBackend(store: nil)
    let client = APIClient(baseURL: DemoBackend.baseURL, demo: account)
    let device = DemoBackend(store: nil)

    let made = json(await device.respond(method: "POST", url: url("/api/project"),
                                         body: body(["title": "Two Places"])))
    guard let localId = made["id"] as? Int else {
        check("a screenplay to work with", false)
        return
    }
    await write("The new words.", into: localId, on: device)

    guard let kept = await keep(localId, from: device, into: client) else {
        check("the account takes it", false)
        return
    }
    // The account writes a note of its own, which the device has never seen.
    _ = await account.respond(method: "POST", url: url("/api/document"),
                              body: body(["projectId": kept.id, "title": "Only In The Account",
                                          "documentType": "NOTES", "content": "Typed in a browser."]))
    await write("Only in the account.", into: kept.id, on: account)
    guard let remote = await project(kept.id, on: client),
          await send(localId, from: device, into: remote, on: client) != nil else {
        check("the account takes the update", false)
        return
    }

    checkEqual("the note the file did not carry is off the list",
               await documents(kept.id, on: account).contains("Only In The Account"), false)
    let trashed = embedded(json(await account.respond(
        method: "GET", url: url("/api/document/trash?projectId=\(kept.id)"), body: nil)))
        .compactMap { $0["title"] as? String }
    check("but in the trash, whole, rather than gone",
          trashed.contains("Only In The Account"))

    let versions = embedded(json(await account.respond(
        method: "GET", url: url("/api/project/version?projectId=\(kept.id)"), body: nil)))
    check("and the script it replaced is in the version history",
          !versions.isEmpty)
}

@MainActor
func checkArchivedDocumentsSurvive() async {
    print()
    print("== A song put aside crosses as a song put aside ==")

    let device = DemoBackend(store: nil)
    let account = DemoBackend(store: nil)
    let client = APIClient(baseURL: DemoBackend.baseURL, demo: account)

    let made = json(await device.respond(method: "POST", url: url("/api/project"),
                                         body: body(["title": "Set Aside"])))
    guard let localId = made["id"] as? Int else {
        check("a screenplay to work with", false)
        return
    }
    let song = json(await device.respond(
        method: "POST", url: url("/api/document"),
        body: body(["projectId": localId, "title": "Cut Number",
                    "documentType": "SONG", "content": "A verse we dropped."])))
    guard let songId = song["id"] as? Int else {
        check("a song to put aside", false)
        return
    }
    _ = await device.respond(method: "POST", url: url("/api/document/\(songId)/archive"), body: nil)
    checkEqual("it is off the device's list", await documents(localId, on: device), [])
    checkEqual("and in its archive", await documents(localId, on: device, archived: true),
               ["Cut Number"])

    guard let kept = await keep(localId, from: device, into: client) else {
        check("the account takes the screenplay", false)
        return
    }
    checkEqual("the account does not put it back on the list",
               await documents(kept.id, on: account), [])
    checkEqual("it arrives in the archive, where it was",
               await documents(kept.id, on: account, archived: true), ["Cut Number"])
}

/// Folders travel by name, because a name is the only thing the far end can
/// recognise: each side numbers its own folders, so the ids mean nothing across
/// the crossing — the same problem `uid` solves for the songs themselves.
///
/// Worth its own case because this is the flow a writer actually meets it in.
/// Signing in hands the account an archive of the device's work; if folders did
/// not travel, an arrangement built over weeks would arrive as one flat list,
/// with nothing on screen to say what had happened.
@MainActor
func checkFoldersCross() async {
    print()
    print("== A song filed under a folder crosses still filed ==")

    let device = DemoBackend(store: nil)
    let account = DemoBackend(store: nil)
    let client = APIClient(baseURL: DemoBackend.baseURL, demo: account)

    let made = json(await device.respond(method: "POST", url: url("/api/project"),
                                         body: body(["title": "Filed Away"])))
    guard let localId = made["id"] as? Int else {
        check("a screenplay to work with", false)
        return
    }
    let song = json(await device.respond(
        method: "POST", url: url("/api/document"),
        body: body(["projectId": localId, "title": "Opening Number",
                    "documentType": "SONG", "content": "Curtain up."])))
    let loose = json(await device.respond(
        method: "POST", url: url("/api/document"),
        body: body(["projectId": localId, "title": "Stray Verse",
                    "documentType": "SONG", "content": "Nowhere yet."])))
    let folders = json(await device.respond(
        method: "POST", url: url("/api/document/folder?projectId=\(localId)&type=SONG"),
        body: body(["name": "Act One"])))
    guard let songId = song["id"] as? Int, loose["id"] is Int,
          let folderId = embedded(folders).first?["id"] as? Int else {
        check("a folder and two songs to file into it", false)
        return
    }
    _ = await device.respond(method: "POST", url: url("/api/document/\(songId)/folder"),
                             body: body(["folderId": folderId]))

    guard let kept = await keep(localId, from: device, into: client) else {
        check("the account takes the screenplay", false)
        return
    }

    let arrived = embedded(json(await account.respond(
        method: "GET", url: url("/api/document?projectId=\(kept.id)"), body: nil)))
    let filed = arrived.first { $0["title"] as? String == "Opening Number" }
    checkEqual("the folder came with it", filed?["folderName"] as? String, "Act One")
    // The other half of the promise: a document that was in no folder does not
    // arrive in one, so a crossing cannot invent an arrangement either.
    check("and the unfiled song is still unfiled",
          arrived.first { $0["title"] as? String == "Stray Verse" }?["folderId"] == nil)

    let overThere = embedded(json(await account.respond(
        method: "GET", url: url("/api/document/folder?projectId=\(kept.id)&type=SONG"), body: nil)))
    checkEqual("the account made exactly one folder for it", overThere.count, 1)
    checkEqual("named as it was named", overThere.first?["name"] as? String, "Act One")
    // Its own id over there, which is the whole reason the name is what travels.
    check("with an id of its own", overThere.first?["id"] as? Int != nil)
}

// MARK: - The rule that decides what a crossing does

@MainActor
func checkTheRule() {
    print()
    print("== What to do about a linked screenplay ==")

    let link = ProjectLink(localId: 1, scope: "s", remoteId: 9,
                           syncedRemoteEdited: Date(timeIntervalSince1970: 1_000_000))
    func remote(_ edited: Date?) -> Project {
        var project = decode(Project.self, #"{"id": 9, "title": "Night Shoot"}"#)
        project.lastEdited = edited
        return project
    }
    let unchanged = remote(Date(timeIntervalSince1970: 1_000_000))
    let moved = remote(Date(timeIntervalSince1970: 2_000_000))

    checkEqual("a screenplay deleted on the device forgets its link",
               AppModel.LinkSync.decide(link, localExists: false, remote: unchanged,
                                        localHasWork: true),
               .forget)
    checkEqual("so does one deleted in the account",
               AppModel.LinkSync.decide(link, localExists: true, remote: nil,
                                        localHasWork: true),
               .forget)
    checkEqual("nothing written here means nothing to carry",
               AppModel.LinkSync.decide(link, localExists: true, remote: unchanged,
                                        localHasWork: false),
               .nothingToSend)
    checkEqual("words here and a copy nobody else touched: they go up",
               AppModel.LinkSync.decide(link, localExists: true, remote: unchanged,
                                        localHasWork: true),
               .send)
    checkEqual("words in both places: neither version is thrown away",
               AppModel.LinkSync.decide(link, localExists: true, remote: moved,
                                        localHasWork: true),
               .keepBoth)
    checkEqual("a date the server does not give reads as changed",
               AppModel.LinkSync.decide(link, localExists: true, remote: remote(nil),
                                        localHasWork: true),
               .keepBoth)
    checkEqual("and so does a link recorded before this was",
               AppModel.LinkSync.decide(
                    ProjectLink(localId: 1, scope: "s", remoteId: 9, syncedRemoteEdited: nil),
                    localExists: true, remote: unchanged, localHasWork: true),
               .keepBoth)
    checkEqual("a second's drift between two clocks is not a conflict",
               AppModel.LinkSync.decide(link,
                                        localExists: true,
                                        remote: remote(Date(timeIntervalSince1970: 1_000_000.6)),
                                        localHasWork: true),
               .send)
}

// MARK: - The record itself

@MainActor
func checkTheRecord() {
    print()
    print("== Which screenplay here is which screenplay there ==")

    let links = ProjectLinkStore(defaults: scratchDefaults("record"))
    let mine = "server|writer"
    let theirs = "server|other"

    links.record(ProjectLink(localId: 3, scope: mine, remoteId: 41, syncedRemoteEdited: nil))
    checkEqual("a link reads back", links.remoteId(forLocal: 3, in: mine), 41)
    checkEqual("and reads back the other way", links.localId(forRemote: 41, in: mine), 3)
    checkEqual("another account means no link at all",
               links.remoteId(forLocal: 3, in: theirs), nil)
    check("though the screenplay is known to be kept somewhere",
          links.isLinkedAnywhere(local: 3))

    // Two accounts can hold copies of the same local screenplay.
    links.record(ProjectLink(localId: 3, scope: theirs, remoteId: 7, syncedRemoteEdited: nil))
    checkEqual("each account keeps its own", links.remoteId(forLocal: 3, in: mine), 41)
    checkEqual("side by side", links.remoteId(forLocal: 3, in: theirs), 7)

    // Recording over one end replaces it rather than doubling it up.
    links.record(ProjectLink(localId: 3, scope: mine, remoteId: 55, syncedRemoteEdited: nil))
    checkEqual("re-keeping points the link at the new screenplay",
               links.remoteId(forLocal: 3, in: mine), 55)
    checkEqual("and leaves nothing behind pointing at the old one",
               links.localId(forRemote: 41, in: mine), nil)

    // An id the account reused must not end up named by two links.
    links.record(ProjectLink(localId: 4, scope: mine, remoteId: 55, syncedRemoteEdited: nil))
    checkEqual("an account id belongs to one local screenplay",
               links.links(in: mine).filter { $0.remoteId == 55 }.count, 1)
    checkEqual("the newer one", links.localId(forRemote: 55, in: mine), 4)

    links.forget(local: 4, in: mine)
    checkEqual("forgetting takes only that one", links.links(in: mine).count, 0)
    checkEqual("leaving the other account's alone", links.links(in: theirs).count, 1)
}

@MainActor
func checkAWorkspaceCannotBeEmptiedByAccident() async {
    print()
    print("== A screenplay is not cleared on the strength of an unreadable answer ==")

    let device = DemoBackend(store: nil)
    let made = json(await device.respond(method: "POST", url: url("/api/project"),
                                         body: body(["title": "Still Here"])))
    guard let localId = made["id"] as? Int else {
        check("a screenplay to work with", false)
        return
    }
    await write("Words that must survive.", into: localId, on: device)

    checkEqual("nonsense is refused", await device.mirrorProject(localId, fromArchive: Data("no".utf8)), false)
    checkEqual("so is a well-formed document about nothing",
               await device.mirrorProject(localId, fromArchive: body(["format": "scripty-project"])),
               false)
    checkEqual("and a screenplay this device does not have",
               await device.mirrorProject(9_999, fromArchive: body(["project": ["title": "X"]])),
               false)
    checkEqual("the words are where they were",
               await lines(localId, on: device), ["Words that must survive."])
}

// MARK: - The same song, on both sides of the crossing

/// Songs and notes as the backend holds them: the number it files each under,
/// and the name it knows the song by wherever it is kept.
@MainActor
func documentRows(_ projectId: Int,
                  on backend: DemoBackend) async -> [(id: Int, uid: String, title: String)] {
    let response = await backend.respond(
        method: "GET", url: url("/api/document?projectId=\(projectId)"), body: nil)
    return embedded(json(response)).compactMap { entry in
        guard let id = entry["id"] as? Int, let title = entry["title"] as? String else { return nil }
        return (id, entry["uid"] as? String ?? "", title)
    }
}

/// A song's lyric, line by line, as the lyric editor would load it.
@MainActor
func lyric(_ documentId: Int, on backend: DemoBackend) async -> [String] {
    let response = await backend.respond(
        method: "GET", url: url("/api/song/block?documentId=\(documentId)"), body: nil)
    return embedded(json(response)).compactMap { $0["content"] as? String }
}

@MainActor
func addDocument(_ title: String, type: String, content: String,
                 to projectId: Int, on backend: DemoBackend) async -> Int? {
    let response = await backend.respond(
        method: "POST", url: url("/api/document"),
        body: body(["projectId": projectId, "title": title,
                    "documentType": type, "content": content]))
    return json(response)["id"] as? Int
}

@MainActor
func checkSongsAndNotesStayThemselves() async {
    print()
    print("== A song written signed out stays one song ==")

    let directory = scratchDirectory("songs")
    defer { try? FileManager.default.removeItem(at: directory) }
    let device = DemoBackend(store: LocalWorkspaceStore(directory: directory))
    let account = DemoBackend(store: nil)
    let accountClient = APIClient(baseURL: DemoBackend.baseURL, demo: account)

    let made = json(await device.respond(method: "POST", url: url("/api/project"),
                                         body: body(["title": "The Long Way"])))
    guard let localId = made["id"] as? Int,
          let localSong = await addDocument("Opening Number", type: "SONG",
                                            content: "A first line\nA second line",
                                            to: localId, on: device),
          let localNote = await addDocument("Blocking", type: "NOTES",
                                            content: "Stage left.", to: localId, on: device)
    else {
        check("a song and a note are written without an account", false)
        return
    }
    // Load the lyric, which is what splits the text into lines the first time.
    checkEqual("the song has its lines on the device",
               await lyric(localSong, on: device), ["A first line", "A second line"])
    let deviceRows = await documentRows(localId, on: device)
    let songUid = deviceRows.first { $0.id == localSong }?.uid ?? ""
    check("and a name of its own, not just a number", !songUid.isEmpty)

    // 1. Kept into the account.
    guard let kept = await keep(localId, from: device, into: accountClient) else {
        check("the account takes the screenplay", false)
        return
    }
    let accountRows = await documentRows(kept.id, on: account)
    checkEqual("the account has both", accountRows.map(\.title).sorted(),
               ["Blocking", "Opening Number"])
    checkEqual("and knows the song by the name the device gave it",
               accountRows.first { $0.title == "Opening Number" }?.uid, songUid)
    guard let accountSong = accountRows.first(where: { $0.title == "Opening Number" })?.id,
          let accountNote = accountRows.first(where: { $0.title == "Blocking" })?.id else {
        check("the account's song can be found", false)
        return
    }
    checkEqual("with the lyric it was written with",
               await lyric(accountSong, on: account), ["A first line", "A second line"])

    // 2. A verse added in the account, then signing out.
    _ = await account.respond(
        method: "POST", url: url("/api/song/block?documentId=\(accountSong)"),
        body: body(["content": "A third line"]))
    guard let afterEditing = await project(kept.id, on: accountClient),
          await bringDown(afterEditing, into: localId, on: device, from: accountClient) else {
        check("the account's copy comes down on the way out", false)
        return
    }
    let backOnDevice = await documentRows(localId, on: device)
    checkEqual("the device still has one song and one note, not four",
               backOnDevice.count, 2)
    checkEqual("the song is the same row it always was",
               backOnDevice.first { $0.uid == songUid }?.id, localSong)
    checkEqual("holding the verse written in the account",
               await lyric(localSong, on: device),
               ["A first line", "A second line", "A third line"])
    checkEqual("and the note is the same note",
               backOnDevice.first { $0.title == "Blocking" }?.id, localNote)

    // 3. A verse added on the device, then signing back in.
    _ = await device.respond(
        method: "POST", url: url("/api/song/block?documentId=\(localSong)"),
        body: body(["content": "A fourth line"]))
    guard let remote = await project(kept.id, on: accountClient),
          await send(localId, from: device, into: remote, on: accountClient) != nil else {
        check("the account takes the update", false)
        return
    }
    let backInAccount = await documentRows(kept.id, on: account)
    checkEqual("the account still has one song and one note",
               backInAccount.count, 2)
    checkEqual("the song is the row the account already had",
               backInAccount.first { $0.uid == songUid }?.id, accountSong)
    checkEqual("the note likewise",
               backInAccount.first { $0.title == "Blocking" }?.id, accountNote)
    checkEqual("and the lyric is what the writer has been writing",
               await lyric(accountSong, on: account),
               ["A first line", "A second line", "A third line", "A fourth line"])

    // Nothing was trashed on the way: a song written into rather than replaced
    // leaves no wreckage behind it.
    let trashed = embedded(json(await account.respond(
        method: "GET", url: url("/api/document/trash?projectId=\(kept.id)"), body: nil)))
    checkEqual("with nothing left in the trash to explain", trashed.count, 0)
}

// MARK: - Run

await checkRoundTrip()
await checkSongsAndNotesStayThemselves()
await checkNothingIsLost()
await checkArchivedDocumentsSurvive()
await checkFoldersCross()
checkTheRule()
checkTheRecord()
await checkAWorkspaceCannotBeEmptiedByAccident()

print()
if failures == 0 {
    print("All project-sync checks passed.")
} else {
    print("\(failures) project-sync check(s) FAILED.")
    exit(1)
}
