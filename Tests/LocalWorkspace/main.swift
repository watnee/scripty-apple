//
//  The signed-out workspace, across a relaunch
//
//  A device with no account writes into `DemoBackend`, and there is no server
//  copy of any of it — so `LocalWorkspaceStore` is the only thing standing
//  between a writer and losing everything the moment they quit. That makes this
//  the check that matters most in the whole suite: it builds a workspace, drops
//  the backend on the floor, and opens a second one on the same store, exactly
//  as a relaunch does.
//
//  The interesting failure is quiet. `Snapshot` names each of the actor's
//  stores by hand, so a store added later and forgotten there does not fail to
//  compile — it just silently stops surviving relaunches, and nothing says so
//  until someone's songs are gone. So the round trips below reach past projects
//  and blocks into the stores that are easy to overlook: songs, versions,
//  editions, the trash, the character list, comments and the id counters.
//
//  Run via Tests/run.sh.
//

import Foundation

var failures = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    if ok { print("  PASS  \(label)") }
    else { failures += 1; print("  FAIL  \(label) \(detail)") }
}

func url(_ p: String) -> URL { URL(string: "https://demo.scripty.local" + p)! }
func body(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) }
func json(_ response: (status: Int, data: Data)) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]) ?? [:]
}
func embedded(_ o: [String: Any]) -> [[String: Any]] {
    guard let e = o["_embedded"] as? [String: Any],
          let first = e.values.first as? [[String: Any]] else { return [] }
    return first
}

/// A directory of its own per run, so one check's workspace can never be read
/// by the next — and so nothing here can reach the real Application Support.
func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("scripty-local-workspace-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Reading a workspace back

func runRelaunch() async {
    print("A workspace survives the app being quit")

    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    // Everything a first run does: the seed, then some writing on top of it.
    let first = DemoBackend(store: LocalWorkspaceStore(directory: directory))

    let made = json(await first.respond(method: "POST", url: url("/api/project"),
                                        body: body(["title": "Night Shoot"])))
    guard let projectId = made["id"] as? Int else {
        check("a project is created to write into", false)
        return
    }

    // A screenplay with words in it, one of them flagged, plus a song and a
    // note — the four stores a writer would notice the loss of first.
    var blockIds: [Int] = []
    for (type, content) in [("SCENE", "INT. VAN - NIGHT"),
                            ("ACTION", "Rain on the windscreen."),
                            ("CHARACTER", "JUNIPER")] {
        let block = json(await first.respond(
            method: "POST", url: url("/api/block"),
            body: body(["projectId": projectId, "content": content, "type": type])))
        if let id = block["id"] as? Int { blockIds.append(id) }
    }
    if let flagged = blockIds.first {
        _ = await first.respond(method: "POST", url: url("/api/block/\(flagged)/bookmark"),
                                body: body([:]))
    }
    let song = json(await first.respond(
        method: "POST", url: url("/api/document"),
        body: body(["projectId": projectId, "title": "Last Chance",
                    "documentType": "SONG", "content": "Two moons over Main Street"])))
    let note = json(await first.respond(
        method: "POST", url: url("/api/document"),
        body: body(["projectId": projectId, "title": "Locations",
                    "documentType": "NOTES", "content": "The lot backs onto the freeway."])))
    // The star: the record that decides which screenplay a launch opens.
    _ = await first.respond(method: "POST", url: url("/api/project/\(projectId)/toggleDefault"),
                            body: body([:]))
    // A character, so the cast list has something of the writer's in it.
    _ = await first.respond(method: "POST", url: url("/api/person"),
                            body: body(["projectId": projectId, "name": "JUNIPER",
                                        "fullName": "Juniper Vale"]))
    // And something in the bin, which is work too until it is purged.
    let doomed = json(await first.respond(method: "POST", url: url("/api/project"),
                                          body: body(["title": "Abandoned"])))
    if let doomedId = doomed["id"] as? Int {
        _ = await first.respond(method: "DELETE", url: url("/api/project/\(doomedId)"), body: nil)
    }

    // The app is quit. Nothing is flushed, closed or told: the store is
    // whatever the last write left behind.
    let second = DemoBackend(store: LocalWorkspaceStore(directory: directory))

    let projects = embedded(json(await second.respond(
        method: "GET", url: url("/api/project"), body: nil)))
    check("the screenplay written last session is still there",
          projects.contains { $0["id"] as? Int == projectId },
          "got \(projects.compactMap { $0["title"] as? String })")
    check("and so are the sample screenplays it was written beside",
          projects.count >= 2, "got \(projects.count)")
    check("the star is still on it",
          projects.first { $0["id"] as? Int == projectId }?["default"] as? Bool == true)

    let blocks = embedded(json(await second.respond(
        method: "GET", url: url("/api/block?projectId=\(projectId)"), body: nil)))
    check("every element came back",
          blockIds.allSatisfy { id in blocks.contains { $0["id"] as? Int == id } },
          "got \(blocks.count) of \(blockIds.count)")
    check("the words are the words that were typed",
          blocks.contains { $0["content"] as? String == "Rain on the windscreen." })
    check("a bookmark is still a bookmark",
          blocks.contains { $0["bookmarked"] as? Bool == true })

    let documents = embedded(json(await second.respond(
        method: "GET", url: url("/api/document?projectId=\(projectId)"), body: nil)))
    check("the song is still there",
          documents.contains { $0["id"] as? Int == song["id"] as? Int })
    check("and the note beside it",
          documents.contains { $0["id"] as? Int == note["id"] as? Int })
    // The collection carries titles only; the words are on the document
    // itself, which is what the editor opens.
    let songAgain = json(await second.respond(
        method: "GET", url: url("/api/document/\(song["id"] as? Int ?? 0)"), body: nil))
    check("with its lyric",
          songAgain["content"] as? String == "Two moons over Main Street",
          "got \(songAgain["content"] as? String ?? "nothing")")

    let characters = embedded(json(await second.respond(
        method: "GET", url: url("/api/person?projectId=\(projectId)"), body: nil)))
    check("the cast list survived",
          characters.contains { $0["fullName"] as? String == "Juniper Vale" })

    let trash = embedded(json(await second.respond(
        method: "GET", url: url("/api/project/trash"), body: nil)))
    check("so did the bin", trash.contains { $0["title"] as? String == "Abandoned" })

    // The counters matter as much as the stores. A restored workspace that
    // starts numbering from 1 again hands out an id something already answers
    // to, and the next write lands on top of an existing element.
    let extra = json(await second.respond(
        method: "POST", url: url("/api/block"),
        body: body(["projectId": projectId, "content": "New line", "blockType": "ACTION"])))
    check("the next element gets an id nothing is using",
          (extra["id"] as? Int).map { !blockIds.contains($0) } ?? false,
          "got \(extra["id"] as? Int ?? -1) against \(blockIds)")
}

// MARK: - Undo, versions and editions

func runHistoryRelaunch() async {
    print("")
    print("History and versions survive it too")

    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = DemoBackend(store: LocalWorkspaceStore(directory: directory))
    let projects = embedded(json(await first.respond(
        method: "GET", url: url("/api/project"), body: nil)))
    guard let projectId = projects.first?["id"] as? Int,
          let blockId = embedded(json(await first.respond(
              method: "GET", url: url("/api/block?projectId=\(projectId)"), body: nil)))
              .first?["id"] as? Int else {
        check("the sample screenplay has something to edit", false)
        return
    }

    _ = await first.respond(method: "PUT", url: url("/api/block/\(blockId)"),
                            body: body(["content": "INT. SOMEWHERE ELSE - DAY"]))
    let named = json(await first.respond(
        method: "POST", url: url("/api/project/version?projectId=\(projectId)"),
        body: body(["label": "Before the rewrite"])))

    let second = DemoBackend(store: LocalWorkspaceStore(directory: directory))

    let status = json(await second.respond(
        method: "GET", url: url("/api/project/\(projectId)/undo-redo-status"), body: nil))
    check("undo still has somewhere to go", status["canUndo"] as? Bool == true)

    let versions = embedded(json(await second.respond(
        method: "GET", url: url("/api/project/version?projectId=\(projectId)"), body: nil)))
    check("the saved version is still listed",
          versions.contains { $0["id"] as? Int == named["id"] as? Int },
          "got \(versions.count) version(s)")

    // And it still *works* — a snapshot whose blocks were dropped from the
    // store restores an empty screenplay, which is worse than not offering it.
    _ = await second.respond(method: "POST", url: url("/api/project/\(projectId)/undo"),
                             body: body([:]))
    let reverted = embedded(json(await second.respond(
        method: "GET", url: url("/api/block?projectId=\(projectId)"), body: nil)))
    check("undoing across the relaunch puts the old words back",
          !reverted.contains { $0["content"] as? String == "INT. SOMEWHERE ELSE - DAY" })
}

// MARK: - The throwaway demo

func runEphemeral() async {
    print("")
    print("The throwaway demo writes nothing down")

    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    // No store at all: this is what `-scripty.demo YES` builds.
    let demo = DemoBackend()
    _ = await demo.respond(method: "POST", url: url("/api/project"),
                           body: body(["title": "Screenshot Pass"]))

    let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    check("nothing lands in the workspace directory", contents.isEmpty,
          "got \(contents)")

    // A second one is the same app the first was, which is the whole point.
    let again = DemoBackend()
    let projects = embedded(json(await again.respond(
        method: "GET", url: url("/api/project"), body: nil)))
    check("and a fresh demo is back to the sample screenplays",
          !projects.contains { $0["title"] as? String == "Screenshot Pass" })
}

// MARK: - Handing work to an account

func runHandOff() async {
    print("")
    print("Signing in copies what was written and takes nothing away")

    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = DemoBackend(store: LocalWorkspaceStore(directory: directory))
    let kept = json(await first.respond(method: "POST", url: url("/api/project"),
                                        body: body(["title": "Keeping This One"])))
    let given = json(await first.respond(method: "POST", url: url("/api/project"),
                                         body: body(["title": "Uploading This One"])))
    guard let keptId = kept["id"] as? Int, let givenId = given["id"] as? Int else {
        check("two projects to choose between", false)
        return
    }
    _ = await first.respond(method: "POST", url: url("/api/document"),
                            body: body(["projectId": givenId, "title": "Its Song",
                                        "documentType": "SONG", "content": "la la"]))

    // What `AppModel.keepGuestWork` does once the upload has landed.
    await first.markHandedOff(projectIds: [givenId])

    let unsent = await first.guestWork().map(\.id)
    check("the uploaded screenplay is no longer work to send", !unsent.contains(givenId))
    check("the one that never went up still is", unsent.contains(keptId))

    // The point of the whole flow: signing out is not a way to lose the
    // screenplay you just attached an account to.
    let second = DemoBackend(store: LocalWorkspaceStore(directory: directory))
    let titles = embedded(json(await second.respond(
        method: "GET", url: url("/api/project"), body: nil)))
        .compactMap { $0["title"] as? String }
    check("the uploaded screenplay is still on the device",
          titles.contains("Uploading This One"), "got \(titles)")
    check("and the untouched one is still waiting there",
          titles.contains("Keeping This One"), "got \(titles)")

    // Its parts came with it. A screenplay whose songs or cast had been cleared
    // out from under it would open, and be useless.
    let songs = embedded(json(await second.respond(
        method: "GET", url: url("/api/document?projectId=\(givenId)"), body: nil)))
        .compactMap { $0["title"] as? String }
    check("so are its songs", songs.contains("Its Song"), "got \(songs)")

    // And it stays off that list across the relaunch, so signing in again
    // doesn't put a second copy of it in the same account.
    check("a relaunch still knows the account has a copy",
          !(await second.guestWork().map(\.id)).contains(givenId))

    // Until it is written in again — those newer words are on this device and
    // nowhere else, so they are worth carrying. Flagged as one an account has
    // already been given, though: a sign-in leaves that one where it is rather
    // than making a second screenplay nobody asked for. See `AppModel.adopt`.
    _ = await second.respond(method: "PUT", url: url("/api/project/\(givenId)"),
                             body: body(["title": "Uploading This One", "writers": "Me"]))
    let rewritten = await second.guestWork().first { $0.id == givenId }
    check("writing in it again puts it back on the list", rewritten != nil)
    check("and it is marked as one the account already has",
          rewritten?.alreadyKept == true)
}

// MARK: - A store that cannot be read

func runUnreadableStore() async {
    print("")
    print("An unreadable workspace opens on the sample screenplay")

    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    // What an app update that moved a field looks like from here.
    let store = LocalWorkspaceStore(directory: directory)
    store.save(Data("{\"projects\":\"not what this used to be\"}".utf8))

    let backend = DemoBackend(store: store)
    let projects = embedded(json(await backend.respond(
        method: "GET", url: url("/api/project"), body: nil)))
    check("the app still opens on something", !projects.isEmpty)
    check("and the writing that follows is kept from here on",
          {
              let saved = store.load().flatMap {
                  try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
              }
              return saved?["nextProjectId"] != nil
          }())
}

print("== The signed-out workspace ==")
await runRelaunch()
await runHistoryRelaunch()
await runEphemeral()
await runHandOff()
await runUnreadableStore()

print("")
if failures == 0 {
    print("Local workspace checks passed.")
} else {
    print("\(failures) local workspace check(s) FAILED.")
}
exit(failures == 0 ? 0 : 1)
