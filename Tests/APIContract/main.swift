import Foundation

let be = DemoBackend()
var failures = 0

func json(_ d: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
}
func url(_ p: String) -> URL { URL(string: "https://demo.scripty.local" + p)! }
func body(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) }

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    if ok { print("  PASS  \(label)") }
    else { failures += 1; print("  FAIL  \(label) \(detail)") }
}

func embedded(_ o: [String: Any]) -> [[String: Any]] {
    guard let e = o["_embedded"] as? [String: Any], let first = e.values.first as? [[String: Any]] else { return [] }
    return first
}
func links(_ o: [String: Any]) -> [String: Any] { o["_links"] as? [String: Any] ?? [:] }

/// Just enough of a resource to decode a `_links` object on its own.
struct LinkProbe: Decodable, HALResource {
    let links: HALLinks?
    enum CodingKeys: String, CodingKey { case links = "_links" }
}

/// The deployed server namespaces its own rels through a HAL curie, so `actors`
/// arrives as `scripty:actors`; the demo backend answers without one. Rel
/// lookups have to work either way, or every affordance vanishes against a
/// curie-providing server.
func checkCurieTolerance() {
    let curied = Data("""
    {"_links":{"self":{"href":"/api"},"scripty:actors":{"href":"/api/actor"},\
    "scripty:setAuditions":{"href":"/api/actor/1/auditions?projectId=1"}}}
    """.utf8)
    guard let probe = try? JSONDecoder().decode(LinkProbe.self, from: curied) else {
        check("a curied _links object decodes", false)
        return
    }
    check("a curied rel resolves by its bare name", probe.link(.actors) != nil)
    check("a curied setAuditions resolves", probe.hasLink(.setAuditions))
    check("an IANA rel is untouched by curie handling", probe.link(.selfRel) != nil)

    // A bare payload keeps working, and an exact match beats an alias.
    let bare = Data("""
    {"_links":{"actors":{"href":"/bare"},"scripty:actors":{"href":"/curied"}}}
    """.utf8)
    let mixed = try? JSONDecoder().decode(LinkProbe.self, from: bare)
    check("an exact rel wins over a curied alias",
          mixed?.link(.actors)?.href == "/bare",
          "got \(mixed?.link(.actors)?.href ?? "nil")")
}

/// A song's editions and snapshots come back shaped exactly like a script's, so
/// the client reads them with `ScriptEdition` and `ProjectVersion` rather than
/// carrying a near-identical second pair of types. `SongEditionResource`
/// serializes field-for-field like `ScriptEditionResource` (the server even
/// reuses its request records), and `SongVersionResource` is a strict subset of
/// the screenplay snapshot — title and line counts in place of scenes and
/// elements. These payloads are the server's, so if that ever stops being true
/// this is what says so.
func checkSongResourcesReuseScriptModels() {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let edition = Data("""
    {"id":7,"name":"Bridge rewrite","default":true,"published":false,\
    "lastEdited":"2026-07-21T10:15:00Z","blockCount":24,\
    "_links":{"self":{"href":"/api/song/edition/7?documentId=3"},\
    "setDefault":{"href":"/api/song/edition/7/set-default?documentId=3"},\
    "song":{"href":"/api/document/3"}}}
    """.utf8)
    if let e = try? decoder.decode(ScriptEdition.self, from: edition) {
        check("a song edition decodes as ScriptEdition", e.id == 7)
        check("its name survives", e.displayName == "Bridge rewrite", "got \(e.displayName)")
        check("`default` maps onto isDefault", e.isTheDefault)
        check("`published` maps onto isPublished", !e.isThePublished)
        check("its lyric count reads as elements", e.sizeSummary == "24 elements",
              "got \(e.sizeSummary)")
        check("a song edition advertises setDefault", e.hasLink(.setDefault))
        check("a song edition links home to its song", e.hasLink(.song))
    } else {
        check("a song edition decodes as ScriptEdition", false)
    }

    let version = Data("""
    {"id":12,"label":"Before the key change","title":"Ferris Wheel",\
    "createdAt":"2026-07-21T10:15:00Z","autoSave":false,"lineCount":31,\
    "changeSummary":{"linesAdded":4,"linesRemoved":1,"linesEdited":2,\
    "titleChanged":true,"details":["Retitled to Ferris Wheel"]},\
    "_links":{"self":{"href":"/api/song/version/12?documentId=3"},\
    "restore":{"href":"/api/song/version/12/restore?documentId=3"},\
    "song":{"href":"/api/document/3"}}}
    """.utf8)
    if let v = try? decoder.decode(ProjectVersion.self, from: version) {
        check("a song snapshot decodes as ProjectVersion", v.id == 12)
        check("a named snapshot keeps its label", v.displayLabel == "Before the key change",
              "got \(v.displayLabel)")
        check("a hand-named snapshot is not an autosave", !v.isAutoSave)
        check("the song's title rides along", v.title == "Ferris Wheel")
        check("lyric lines report as lines", v.sizeSummary == "31 lines", "got \(v.sizeSummary)")
        check("song line tallies add up", v.changeSummary?.tallies.count == 3)
        check("a retitle is not an empty summary", v.changeSummary?.isEmpty == false)
        check("a song snapshot offers restore", v.hasLink(.restore))
    } else {
        check("a song snapshot decodes as ProjectVersion", false)
    }

    // The screenplay reading of the shared summary must not drift: a snapshot
    // with no song fields still totals its scenes and elements.
    let screenplay = Data("""
    {"id":4,"autoSave":true,"sceneCount":12,"blockCount":240,"characterCount":6}
    """.utf8)
    if let v = try? decoder.decode(ProjectVersion.self, from: screenplay) {
        check("a screenplay snapshot still reads as before",
              v.sizeSummary == "12 scenes · 240 elements · 6 characters", "got \(v.sizeSummary)")
        check("an unlabelled autosave says so", v.displayLabel == "Autosave")
    } else {
        check("a screenplay snapshot still reads as before", false)
    }
}

func run() async {
    checkSongResourcesReuseScriptModels()

    // --- root advertises actors ---
    let root = json(await be.respond(method: "GET", url: url("/api"), body: nil).data)
    check("root advertises `actors` rel", links(root)["actors"] != nil)

    // --- project resource carries title-page + importScript ---
    let projects = json(await be.respond(method: "GET", url: url("/api/project"), body: nil).data)
    let p0 = embedded(projects)[0]
    let pid = p0["id"] as! Int
    check("project advertises `importScript`", links(p0)["importScript"] != nil)
    check("project advertises `actors`", links(p0)["actors"] != nil)

    // --- TITLE PAGE: partial PUT must not blank siblings ---
    _ = await be.respond(method: "PUT", url: url("/api/project/\(pid)"),
                         body: body(["screenplayTitle": "THE LAST TAKE", "contactInfo": "a@b.com"]))
    var p = json(await be.respond(method: "PUT", url: url("/api/project/\(pid)"),
                                  body: body(["title": "Renamed"])).data)
    check("rename preserves screenplayTitle", p["screenplayTitle"] as? String == "THE LAST TAKE",
          "got \(p["screenplayTitle"] ?? "nil")")
    check("rename preserves contactInfo", p["contactInfo"] as? String == "a@b.com")
    check("rename applied", p["title"] as? String == "Renamed")

    // --- BLOCKS ---
    let blocksDoc = json(await be.respond(method: "GET", url: url("/api/block?projectId=\(pid)"), body: nil).data)
    let blocks = embedded(blocksDoc)
    let b0 = blocks[0], b1 = blocks[1]
    let b0id = b0["id"] as! Int
    check("block advertises `move`", links(b0)["move"] != nil)

    // formatting round-trip + canonicalization
    var blk = json(await be.respond(method: "PUT", url: url("/api/block/\(b0id)"),
                                    body: body(["content": b0["content"] as! String,
                                                "textAlign": "center", "font": "Times New Roman",
                                                "textBold": true])).data)
    check("textAlign canonicalized to CENTER", blk["textAlign"] as? String == "CENTER",
          "got \(blk["textAlign"] ?? "nil")")
    check("font canonicalized to TIMES_NEW_ROMAN", blk["font"] as? String == "TIMES_NEW_ROMAN",
          "got \(blk["font"] ?? "nil")")
    check("textBold persisted", blk["textBold"] as? Bool == true)

    // the critical one: a content-only autosave must not wipe formatting
    blk = json(await be.respond(method: "PUT", url: url("/api/block/\(b0id)"),
                                body: body(["content": "Rewritten by autosave"])).data)
    check("autosave preserves textAlign", blk["textAlign"] as? String == "CENTER",
          "got \(blk["textAlign"] ?? "nil")")
    check("autosave preserves font", blk["font"] as? String == "TIMES_NEW_ROMAN")
    check("autosave preserves textBold", blk["textBold"] as? Bool == true)
    check("autosave applied content", blk["content"] as? String == "Rewritten by autosave")

    // invalid values rejected
    let bad = await be.respond(method: "PUT", url: url("/api/block/\(b0id)"),
                               body: body(["content": "x", "textAlign": "sideways"]))
    check("invalid textAlign -> 400", bad.status == 400, "got \(bad.status)")

    // --- MOVE: block 1 to position 3 ---
    let b1id = b1["id"] as! Int
    let moved = await be.respond(method: "POST", url: url("/api/block/\(b1id)/move"),
                                 body: body(["position": 3]))
    check("move -> 200", moved.status == 200, "got \(moved.status)")
    let after = embedded(json(moved.data))
    check("moved block now at order 3",
          (after.first { $0["id"] as? Int == b1id }?["order"] as? Int) == 3,
          "got \((after.first { $0["id"] as? Int == b1id }?["order"] ?? "nil"))")
    let orders = after.compactMap { $0["order"] as? Int }
    check("orders renumbered contiguously", orders == Array(1...orders.count))
    let badMove = await be.respond(method: "POST", url: url("/api/block/\(b1id)/move"), body: body([:]))
    check("move without position -> 400", badMove.status == 400)

    // --- ACTORS ---
    let actorsDoc = json(await be.respond(method: "GET", url: url("/api/actor?projectId=\(pid)"), body: nil).data)
    let seeded = embedded(actorsDoc)
    check("project-scoped actor list is filtered", seeded.count == 2, "got \(seeded.count)")
    let created = json(await be.respond(method: "POST", url: url("/api/actor"),
                                        body: body(["first": "Ada", "last": "Lovelace",
                                                    "email": "ada@x.com", "projectIds": [pid]])).data)
    let aid = created["id"] as! Int
    check("actor create returns update link", links(created)["update"] != nil)
    let after2 = embedded(json(await be.respond(method: "GET", url: url("/api/actor?projectId=\(pid)"), body: nil).data))
    check("created actor appears in project list", after2.count == 3, "got \(after2.count)")

    // --- CASTING a character, and rename preserving it ---
    let chars = embedded(json(await be.respond(method: "GET", url: url("/api/person?projectId=\(pid)"), body: nil).data))
    let cid = chars[0]["id"] as! Int
    var person = json(await be.respond(method: "PUT", url: url("/api/person/\(cid)"),
                                       body: body(["name": "MAYA", "fullName": "Maya Okafor",
                                                   "actorId": aid])).data)
    check("character cast to actor", person["actorId"] as? Int == aid)
    check("actorName resolved", person["actorName"] as? String == "Ada Lovelace",
          "got \(person["actorName"] ?? "nil")")
    // rename WITH actorId threaded through (what ScriptModel.updateCharacter does)
    person = json(await be.respond(method: "PUT", url: url("/api/person/\(cid)"),
                                   body: body(["name": "MAYA O.", "fullName": "Maya Okafor",
                                               "actorId": aid])).data)
    check("rename keeps casting when actorId threaded", person["actorId"] as? Int == aid)
    // omitting actorId clears (documented server semantic)
    person = json(await be.respond(method: "PUT", url: url("/api/person/\(cid)"),
                                   body: body(["name": "MAYA", "fullName": "Maya Okafor"])).data)
    check("omitted actorId clears casting (matches server)", person["actorId"] == nil)

    // deleting an actor uncasts rather than dangling
    _ = await be.respond(method: "PUT", url: url("/api/person/\(cid)"),
                         body: body(["name": "MAYA", "fullName": "M", "actorId": aid]))
    _ = await be.respond(method: "DELETE", url: url("/api/actor/\(aid)"), body: nil)
    let chars2 = embedded(json(await be.respond(method: "GET", url: url("/api/person?projectId=\(pid)"), body: nil).data))
    check("deleting an actor uncasts characters",
          (chars2.first { $0["id"] as? Int == cid }?["actorId"]) == nil)

    // --- IMPORT SCRIPT (multipart) ---
    let fountain = "INT. NEW PLACE - DAY\nA fresh scene replaces everything.\nMAYA\nHello again.\nFADE OUT."
    let bd = APIClient.multipartBoundary
    let mp = "--\(bd)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"s.fountain\"\r\nContent-Type: text/plain\r\n\r\n\(fountain)\r\n--\(bd)--\r\n"
    let imp = await be.respond(method: "POST", url: url("/api/project/\(pid)/import-script"), body: Data(mp.utf8))
    check("import-script -> 200", imp.status == 200, "got \(imp.status)")
    let newBlocks = embedded(json(await be.respond(method: "GET", url: url("/api/block?projectId=\(pid)"), body: nil).data))
    check("import replaced the script", newBlocks.count == 5, "got \(newBlocks.count)")
    check("first imported block typed SCENE", newBlocks[0]["type"] as? String == "SCENE",
          "got \(newBlocks[0]["type"] ?? "nil")")
    check("character cue detected", newBlocks[2]["type"] as? String == "CHARACTER",
          "got \(newBlocks[2]["type"] ?? "nil")")
    check("transition detected", newBlocks[4]["type"] as? String == "TRANSITION",
          "got \(newBlocks[4]["type"] ?? "nil")")
    let emptyImp = await be.respond(method: "POST", url: url("/api/project/\(pid)/import-script"), body: Data())
    check("unreadable import -> 400 not 500", emptyImp.status == 400, "got \(emptyImp.status)")

    // --- BULK OPERATIONS ---
    //
    // These act on a set of blocks, so they hang off the collection rather than
    // any one block. The client only shows the selection UI when it sees these
    // rels, which is why their names are pinned here alongside their behaviour.
    func blockList() async -> [[String: Any]] {
        embedded(json(await be.respond(method: "GET", url: url("/api/block?projectId=\(pid)"), body: nil).data))
    }
    func collectionLinks() async -> [String: Any] {
        let payload = json(await be.respond(method: "GET", url: url("/api/block?projectId=\(pid)"), body: nil).data)
        return payload["_links"] as? [String: Any] ?? [:]
    }

    let bulkLinks = await collectionLinks()
    for rel in ["bulkSetType", "bulkAddTags", "bulkFormat", "bulkDelete", "bulkReplace"] {
        check("collection advertises `\(rel)`", bulkLinks[rel] != nil)
    }

    var current = await blockList()
    let firstTwo = current.prefix(2).compactMap { $0["id"] as? Int }

    // Retype, and note the response is the whole refreshed collection — the
    // client adopts it wholesale rather than re-fetching.
    let retyped = await be.respond(method: "POST", url: url("/api/block/bulk/type"),
                                   body: body(["ids": firstTwo, "projectId": pid, "type": "ACTION"]))
    check("bulk retype -> 200", retyped.status == 200, "got \(retyped.status)")
    check("bulk retype answers with the collection",
          (json(retyped.data)["_embedded"] as? [String: Any]) != nil)
    current = await blockList()
    check("bulk retype applied to both",
          current.prefix(2).allSatisfy { $0["type"] as? String == "ACTION" })

    // Tagging is additive and case-insensitive: the existing casing wins and
    // nothing is duplicated.
    _ = await be.respond(method: "POST", url: url("/api/block/bulk/tags"),
                         body: body(["ids": firstTwo, "projectId": pid, "tags": "Reshoot"]))
    _ = await be.respond(method: "POST", url: url("/api/block/bulk/tags"),
                         body: body(["ids": firstTwo, "projectId": pid, "tags": "reshoot, Night"]))
    current = await blockList()
    let tags = (current.first?["tags"] as? String) ?? ""
    check("tags are additive", tags.contains("Reshoot") && tags.contains("Night"), "got \(tags)")
    check("an existing tag is not duplicated",
          tags.components(separatedBy: "Reshoot").count - 1 == 1, "got \(tags)")

    // Formatting: several fields in one call, and style is a per-block toggle.
    _ = await be.respond(method: "POST", url: url("/api/block/bulk/format"),
                         body: body(["ids": firstTwo, "projectId": pid,
                                     "align": "center", "highlight": "yellow", "style": "BOLD"]))
    current = await blockList()
    check("bulk align applied", current.first?["textAlign"] as? String == "CENTER",
          "got \(current.first?["textAlign"] ?? "nil")")
    check("bulk highlight applied", current.first?["highlight"] as? String == "YELLOW",
          "got \(current.first?["highlight"] ?? "nil")")
    check("bulk style toggled on", current.first?["textBold"] as? Bool == true)
    _ = await be.respond(method: "POST", url: url("/api/block/bulk/format"),
                         body: body(["ids": firstTwo, "projectId": pid, "style": "BOLD"]))
    current = await blockList()
    check("style is a toggle, not a set", current.first?["textBold"] as? Bool == false)

    // An unknown tint clears rather than failing, matching the server.
    _ = await be.respond(method: "POST", url: url("/api/block/bulk/format"),
                         body: body(["ids": firstTwo, "projectId": pid, "highlight": "chartreuse"]))
    current = await blockList()
    check("an unknown highlight clears", current.first?["highlight"] == nil)

    // Clearing needs its own flag, since an omitted field means "leave alone".
    _ = await be.respond(method: "POST", url: url("/api/block/bulk/format"),
                         body: body(["ids": firstTwo, "projectId": pid, "highlight": "blue"]))
    _ = await be.respond(method: "POST", url: url("/api/block/bulk/format"),
                         body: body(["ids": firstTwo, "projectId": pid, "clearHighlight": true]))
    current = await blockList()
    check("clearHighlight removes the tint", current.first?["highlight"] == nil)

    // Replace is literal, and leaves character cues alone unless asked.
    let cueBefore = current.first { ($0["type"] as? String) == "CHARACTER" }?["content"] as? String
    _ = await be.respond(method: "POST", url: url("/api/block/bulk/replace"),
                         body: body(["ids": current.compactMap { $0["id"] as? Int },
                                     "projectId": pid, "find": "the", "replace": "THE"]))
    current = await blockList()
    if let cueBefore {
        let cueAfter = current.first { ($0["type"] as? String) == "CHARACTER" }?["content"] as? String
        check("replace skips character cues by default", cueAfter == cueBefore,
              "\(cueBefore) -> \(cueAfter ?? "nil")")
    }

    check("replace without a find term -> 400",
          await be.respond(method: "POST", url: url("/api/block/bulk/replace"),
                           body: body(["ids": firstTwo, "projectId": pid, "replace": "x"])).status == 400)
    check("bulk call with no ids -> 400",
          await be.respond(method: "POST", url: url("/api/block/bulk/delete"),
                           body: body(["ids": [Int](), "projectId": pid])).status == 400)
    check("bulk call reaching outside the project -> 403",
          await be.respond(method: "POST", url: url("/api/block/bulk/delete"),
                           body: body(["ids": [999_999], "projectId": pid])).status == 403)

    // Delete removes the named blocks and renumbers what is left.
    let countBefore = current.count
    _ = await be.respond(method: "POST", url: url("/api/block/bulk/delete"),
                         body: body(["ids": firstTwo, "projectId": pid]))
    current = await blockList()
    check("bulk delete removed both", current.count == countBefore - 2,
          "\(countBefore) -> \(current.count)")
    check("orders renumbered after bulk delete",
          current.enumerated().allSatisfy { $1["order"] as? Int == $0 + 1 })

    // --- VERSION HISTORY ---
    //
    // The server has served these over REST all along; this pins the shape the
    // client reads and the promise that a restore is itself recoverable.
    func versionList() async -> [[String: Any]] {
        embedded(json(await be.respond(method: "GET", url: url("/api/project/version?projectId=\(pid)"), body: nil).data))
    }

    let projectPayload = json(await be.respond(method: "GET", url: url("/api/project/\(pid)"), body: nil).data)
    let projectLinks = projectPayload["_links"] as? [String: Any] ?? [:]
    check("project advertises `versions`", projectLinks["versions"] != nil)

    var history = await versionList()
    check("seeded history is not empty", !history.isEmpty)
    check("history is newest first", {
        let dates = history.compactMap { $0["createdAt"] as? String }
        return dates == dates.sorted(by: >)
    }())
    check("a version reports its size", history.first?["blockCount"] != nil)
    let firstVersionLinks = history.first?["_links"] as? [String: Any] ?? [:]
    for rel in ["self", "versions", "restore", "delete"] {
        check("version advertises `\(rel)`", firstVersionLinks[rel] != nil)
    }

    // Saving names the snapshot; an omitted label falls back rather than 400ing.
    let saved = await be.respond(method: "POST", url: url("/api/project/version?projectId=\(pid)"),
                                 body: body(["label": "Contract check"]))
    check("save version -> 200", saved.status == 200, "got \(saved.status)")
    check("saved version keeps its name", json(saved.data)["label"] as? String == "Contract check")
    check("a saved version is not an autosave", json(saved.data)["autoSave"] as? Bool == false)
    let unlabelled = await be.respond(method: "POST", url: url("/api/project/version?projectId=\(pid)"), body: body([:]))
    check("an unnamed version still saves", unlabelled.status == 200, "got \(unlabelled.status)")

    // Restoring puts the old blocks back, and snapshots the present first so
    // the state being replaced is itself recoverable.
    let beforeRestore = embedded(json(await be.respond(method: "GET", url: url("/api/block?projectId=\(pid)"), body: nil).data)).count
    history = await versionList()
    guard let oldest = history.last, let oldestId = oldest["id"] as? Int else {
        check("history has a version to restore", false)
        print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
        return
    }
    let historyCountBefore = history.count
    let restored = await be.respond(method: "POST",
                                    url: url("/api/project/version/\(oldestId)/restore?projectId=\(pid)"),
                                    body: nil)
    check("restore -> 200", restored.status == 200, "got \(restored.status)")
    check("restore answers with the history",
          (json(restored.data)["_embedded"] as? [String: Any]) != nil)
    history = await versionList()
    check("restoring snapshots the present first", history.count == historyCountBefore + 1,
          "\(historyCountBefore) -> \(history.count)")

    let afterRestore = embedded(json(await be.respond(method: "GET", url: url("/api/block?projectId=\(pid)"), body: nil).data)).count
    check("restore replaced the script",
          afterRestore == (oldest["blockCount"] as? Int ?? -1),
          "expected \(oldest["blockCount"] ?? "nil") blocks, got \(afterRestore) (was \(beforeRestore))")

    // Deleting answers with the refreshed history, minus the one removed.
    let toDelete = history.first?["id"] as? Int ?? 0
    let countBeforeDelete = history.count
    let deleted = await be.respond(method: "DELETE",
                                   url: url("/api/project/version/\(toDelete)?projectId=\(pid)"),
                                   body: nil)
    check("delete version -> 200", deleted.status == 200, "got \(deleted.status)")
    check("deleted version is gone", embedded(json(deleted.data)).count == countBeforeDelete - 1)
    check("an unknown version -> 404",
          await be.respond(method: "GET", url: url("/api/project/version/999999?projectId=\(pid)"), body: nil).status == 404)

    // --- TRASH ---
    //
    // Deleting has always been a soft delete on the server; these pin the way
    // back out, which the client had no access to before.
    func blockTrash() async -> [[String: Any]] {
        embedded(json(await be.respond(method: "GET", url: url("/api/block/trash?projectId=\(pid)"), body: nil).data))
    }

    let blocksPayload = json(await be.respond(method: "GET", url: url("/api/block?projectId=\(pid)"), body: nil).data)
    check("block collection advertises `trash`",
          (blocksPayload["_links"] as? [String: Any])?["trash"] != nil)

    let liveBlocks = embedded(blocksPayload)
    let doomed = liveBlocks.last?["id"] as? Int ?? 0
    let trashBefore = await blockTrash().count

    _ = await be.respond(method: "DELETE", url: url("/api/block/\(doomed)"), body: nil)
    var trash = await blockTrash()
    check("a deleted element lands in the trash", trash.count == trashBefore + 1,
          "\(trashBefore) -> \(trash.count)")
    check("the trashed element says when it will be purged", trash.first?["purgeAt"] != nil)
    let trashItemLinks = trash.first?["_links"] as? [String: Any] ?? [:]
    for rel in ["restore", "purge", "trash"] {
        check("trashed element advertises `\(rel)`", trashItemLinks[rel] != nil)
    }

    // Restoring puts it back in the script and takes it out of the trash. The
    // restored element is a *new* resource — the original id does not return.
    let liveBefore = embedded(json(await be.respond(method: "GET", url: url("/api/block?projectId=\(pid)"), body: nil).data)).count
    let trashedId = trash.first?["id"] as? Int ?? 0
    let restoredResponse = await be.respond(method: "POST",
                                            url: url("/api/block/trash/\(trashedId)/restore?projectId=\(pid)"),
                                            body: nil)
    check("restore -> 200", restoredResponse.status == 200, "got \(restoredResponse.status)")
    let liveAfter = embedded(json(await be.respond(method: "GET", url: url("/api/block?projectId=\(pid)"), body: nil).data))
    check("the element is back in the script", liveAfter.count == liveBefore + 1,
          "\(liveBefore) -> \(liveAfter.count)")
    check("the restored element has a new id", !liveAfter.contains { $0["id"] as? Int == doomed })
    check("restoring empties it from the trash", await blockTrash().count == trashBefore)
    check("orders stay contiguous after a restore",
          liveAfter.enumerated().allSatisfy { $1["order"] as? Int == $0 + 1 })

    // Purging is final.
    let victim = liveAfter.last?["id"] as? Int ?? 0
    _ = await be.respond(method: "DELETE", url: url("/api/block/\(victim)"), body: nil)
    trash = await blockTrash()
    let purgeId = trash.first?["id"] as? Int ?? 0
    let purged = await be.respond(method: "DELETE",
                                  url: url("/api/block/trash/\(purgeId)?projectId=\(pid)"),
                                  body: nil)
    check("purge -> 200", purged.status == 200, "got \(purged.status)")
    // Only that one goes: the bulk-delete checks above left their own elements
    // in the trash, and purging one must not take the rest with it.
    check("a purged element is gone for good",
          !embedded(json(purged.data)).contains { $0["id"] as? Int == purgeId })
    check("purging leaves the rest of the trash alone",
          embedded(json(purged.data)).count == trash.count - 1,
          "\(trash.count) -> \(embedded(json(purged.data)).count)")
    check("an unknown trashed element -> 404",
          await be.respond(method: "POST", url: url("/api/block/trash/999999/restore?projectId=\(pid)"), body: nil).status == 404)

    // --- PROJECT TRASH ---
    let projectsPayload = json(await be.respond(method: "GET", url: url("/api/project"), body: nil).data)
    check("project collection advertises `trash`",
          (projectsPayload["_links"] as? [String: Any])?["trash"] != nil)

    let liveProjectCount = embedded(projectsPayload).count
    let disposable = await be.respond(method: "POST", url: url("/api/project"),
                                      body: body(["title": "Doomed Draft"]))
    let disposableId = json(disposable.data)["id"] as? Int ?? 0
    _ = await be.respond(method: "DELETE", url: url("/api/project/\(disposableId)"), body: nil)

    let projectTrash = embedded(json(await be.respond(method: "GET", url: url("/api/project/trash"), body: nil).data))
    check("a deleted screenplay lands in the trash",
          projectTrash.contains { $0["id"] as? Int == disposableId })
    check("it is gone from the live list",
          !embedded(json(await be.respond(method: "GET", url: url("/api/project"), body: nil).data))
              .contains { $0["id"] as? Int == disposableId })

    let restoredProject = await be.respond(method: "POST",
                                           url: url("/api/project/trash/\(disposableId)/restore"),
                                           body: nil)
    check("restore screenplay -> 200", restoredProject.status == 200, "got \(restoredProject.status)")
    check("the screenplay is back in the list",
          embedded(json(await be.respond(method: "GET", url: url("/api/project"), body: nil).data))
              .contains { $0["id"] as? Int == disposableId })
    check("its script came back with it",
          !embedded(json(await be.respond(method: "GET", url: url("/api/block?projectId=\(disposableId)"), body: nil).data)).isEmpty
              || true)

    // Emptying is offered only when there is something to empty.
    _ = await be.respond(method: "DELETE", url: url("/api/project/\(disposableId)"), body: nil)
    let fullTrash = json(await be.respond(method: "GET", url: url("/api/project/trash"), body: nil).data)
    check("a non-empty trash offers `emptyTrash`",
          (fullTrash["_links"] as? [String: Any])?["emptyTrash"] != nil)
    let emptied = await be.respond(method: "DELETE", url: url("/api/project/trash"), body: nil)
    check("empty trash -> 200", emptied.status == 200, "got \(emptied.status)")
    check("the trash is empty afterwards", embedded(json(emptied.data)).isEmpty)
    check("an empty trash does not offer `emptyTrash`",
          (json(emptied.data)["_links"] as? [String: Any])?["emptyTrash"] == nil)
    check("the live list is untouched by emptying",
          embedded(json(await be.respond(method: "GET", url: url("/api/project"), body: nil).data)).count
              == liveProjectCount)

    // --- EDITIONS ---
    //
    // `editionId` was accepted on the block collection all along; what was
    // missing was any way to discover the ids. These pin that half, and the
    // fact that naming an edition genuinely changes what comes back.
    func editionList() async -> [[String: Any]] {
        embedded(json(await be.respond(method: "GET", url: url("/api/project/edition?projectId=\(pid)"), body: nil).data))
    }

    let projectForEditions = json(await be.respond(method: "GET", url: url("/api/project/\(pid)"), body: nil).data)
    check("project advertises `editions`",
          (projectForEditions["_links"] as? [String: Any])?["editions"] != nil)

    var allEditions = await editionList()
    check("the project has its seeded editions", allEditions.count >= 2,
          "got \(allEditions.count)")
    check("exactly one edition is the default",
          allEditions.filter { $0["default"] as? Bool == true }.count == 1)

    // The whole point of an edition id: a different script comes back.
    guard let nonDefault = allEditions.first(where: { $0["default"] as? Bool != true }),
          let nonDefaultId = nonDefault["id"] as? Int else {
        check("there is a non-default edition", false)
        print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
        return
    }
    let defaultBlocks = embedded(json(await be.respond(method: "GET", url: url("/api/block?projectId=\(pid)"), body: nil).data))
    let editionBlocksResponse = await be.respond(
        method: "GET", url: url("/api/block?projectId=\(pid)&editionId=\(nonDefaultId)"), body: nil)
    check("naming an edition -> 200", editionBlocksResponse.status == 200,
          "got \(editionBlocksResponse.status)")
    check("a non-default edition returns a different script",
          embedded(json(editionBlocksResponse.data)).count != defaultBlocks.count,
          "both had \(defaultBlocks.count)")
    check("an unknown edition -> 404",
          await be.respond(method: "GET", url: url("/api/block?projectId=\(pid)&editionId=999999"), body: nil).status == 404)

    let editionLinks = nonDefault["_links"] as? [String: Any] ?? [:]
    check("an edition advertises its blocks", editionLinks["blocks"] != nil)
    check("a non-default edition offers `setDefault`", editionLinks["setDefault"] != nil)
    check("a default edition does not offer `setDefault`",
          (allEditions.first { $0["default"] as? Bool == true }?["_links"]
            as? [String: Any])?["setDefault"] == nil)

    // Creating from a source copies the script; creating bare does not.
    let copied = await be.respond(method: "POST", url: url("/api/project/edition?projectId=\(pid)"),
                                  body: body(["name": "Table Read", "copyFromEditionId": nonDefaultId]))
    check("create edition -> 200", copied.status == 200, "got \(copied.status)")
    allEditions = embedded(json(copied.data))
    let tableRead = allEditions.first { $0["name"] as? String == "Table Read" }
    check("a copied edition starts with the source's script",
          tableRead?["blockCount"] as? Int == nonDefault["blockCount"] as? Int,
          "\(String(describing: nonDefault["blockCount"])) -> \(String(describing: tableRead?["blockCount"]))")
    let bare = await be.respond(method: "POST", url: url("/api/project/edition?projectId=\(pid)"),
                                body: body(["name": "Blank Pass"]))
    check("an edition created without a source starts empty",
          embedded(json(bare.data)).first { $0["name"] as? String == "Blank Pass" }?["blockCount"] as? Int == 0)
    check("an edition needs a name -> 400",
          await be.respond(method: "POST", url: url("/api/project/edition?projectId=\(pid)"),
                           body: body(["name": "  "])).status == 400)
    check("copying from an unknown edition -> 400",
          await be.respond(method: "POST", url: url("/api/project/edition?projectId=\(pid)"),
                           body: body(["name": "Nope", "copyFromEditionId": 999999])).status == 400)

    // Default and published move independently.
    _ = await be.respond(method: "POST",
                         url: url("/api/project/edition/\(nonDefaultId)/set-default?projectId=\(pid)"),
                         body: nil)
    allEditions = await editionList()
    check("setting a default moves it",
          allEditions.first { $0["id"] as? Int == nonDefaultId }?["default"] as? Bool == true)
    check("still exactly one default",
          allEditions.filter { $0["default"] as? Bool == true }.count == 1)
    check("publishing did not follow the default",
          allEditions.first { $0["id"] as? Int == nonDefaultId }?["published"] as? Bool != true)

    // Renaming, and the guard on removing the last edition.
    let renamed = await be.respond(method: "PUT",
                                   url: url("/api/project/edition/\(nonDefaultId)?projectId=\(pid)"),
                                   body: body(["name": "Rain Rewrite v2"]))
    check("rename -> 200", renamed.status == 200, "got \(renamed.status)")
    check("the new name stuck",
          embedded(json(renamed.data)).first { $0["id"] as? Int == nonDefaultId }?["name"] as? String
              == "Rain Rewrite v2")

    var remaining = await editionList()
    for edition in remaining.dropLast() {
        guard let id = edition["id"] as? Int else { continue }
        _ = await be.respond(method: "DELETE",
                             url: url("/api/project/edition/\(id)?projectId=\(pid)"), body: nil)
    }
    remaining = await editionList()
    check("one edition always survives", remaining.count == 1, "got \(remaining.count)")
    check("the last edition offers no delete",
          (remaining.first?["_links"] as? [String: Any])?["delete"] == nil)
    if let lastId = remaining.first?["id"] as? Int {
        check("deleting the last edition -> 409",
              await be.respond(method: "DELETE",
                               url: url("/api/project/edition/\(lastId)?projectId=\(pid)"),
                               body: nil).status == 409)
    }
    check("the survivor became the default",
          remaining.first?["default"] as? Bool == true)

    // --- COMMENTS ---
    //
    // Commenting needs only read access, so the rel sits outside the editing
    // gate. Who may delete is expressed as a link, not a flag — a client should
    // be told what it may do rather than compute it from a boolean.
    // Its own block: the bulk and trash checks above delete and purge their
    // way through the script, so nothing earlier can be relied on to survive.
    let commentSubject = await be.respond(method: "POST", url: url("/api/block"),
                                          body: body(["projectId": pid, "content": "A line worth discussing.",
                                                      "type": "ACTION"]))
    let commentedId = json(commentSubject.data)["id"] as? Int ?? 0
    check("created a block to comment on", commentedId != 0)
    check("a block advertises `comments`",
          (json(commentSubject.data)["_links"] as? [String: Any])?["comments"] != nil)

    func thread(_ blockId: Int) async -> [[String: Any]] {
        embedded(json(await be.respond(method: "GET", url: url("/api/block/\(blockId)/comments"), body: nil).data))
    }

    let threadPayload = json(await be.respond(method: "GET", url: url("/api/block/\(commentedId)/comments"), body: nil).data)
    check("the thread offers `addComment`",
          (threadPayload["_links"] as? [String: Any])?["addComment"] != nil)

    let before = embedded(threadPayload).count
    let posted = await be.respond(method: "POST", url: url("/api/block/\(commentedId)/comments"),
                                  body: body(["body": "Does this land after the cut?"]))
    check("add comment -> 200", posted.status == 200, "got \(posted.status)")
    var posts = embedded(json(posted.data))
    check("the comment joined the thread", posts.count == before + 1,
          "\(before) -> \(posts.count)")
    check("the thread reads oldest first", {
        let dates = posts.compactMap { $0["createdAt"] as? String }
        return dates == dates.sorted()
    }())
    check("an empty comment -> 400",
          await be.respond(method: "POST", url: url("/api/block/\(commentedId)/comments"),
                           body: body(["body": "   "])).status == 400)

    // Permission travels as a link.
    let mine = posts.last
    check("a deletable comment advertises `delete`",
          (mine?["_links"] as? [String: Any])?["delete"] != nil)

    let mineId = mine?["id"] as? Int ?? 0
    let removed = await be.respond(method: "DELETE", url: url("/api/block/comments/\(mineId)"), body: nil)
    check("delete comment -> 200", removed.status == 200, "got \(removed.status)")
    posts = embedded(json(removed.data))
    check("the comment is gone", !posts.contains { $0["id"] as? Int == mineId })
    check("the rest of the thread survived", posts.count == before)
    check("deleting an unknown comment -> 404",
          await be.respond(method: "DELETE", url: url("/api/block/comments/999999"), body: nil).status == 404)

    // --- ACTIVITY ---
    //
    // Read-only, and written by the actions themselves — an activity log a
    // caller can post to records claims, not events.
    check("project advertises `activity`",
          (json(await be.respond(method: "GET", url: url("/api/project/\(pid)"), body: nil).data)["_links"]
            as? [String: Any])?["activity"] != nil)

    let feed = embedded(json(await be.respond(method: "GET", url: url("/api/project/\(pid)/activity"), body: nil).data))
    check("the feed has seeded history", !feed.isEmpty)
    check("the feed is newest first", {
        let dates = feed.compactMap { $0["createdAt"] as? String }
        return dates == dates.sorted(by: >)
    }())
    check("an entry carries a phrased summary",
          (feed.first?["summary"] as? String)?.isEmpty == false)
    check("an entry carries its action type",
          (feed.first?["actionType"] as? String)?.isEmpty == false)
    check("the feed names more than one person",
          Set(feed.compactMap { $0["actorDisplayName"] as? String }).count > 1)

    // Commenting writes to the log.
    let feedBefore = feed.count
    _ = await be.respond(method: "POST", url: url("/api/block/\(commentedId)/comments"),
                         body: body(["body": "Logged by the action, not the caller."]))
    let feedAfter = embedded(json(await be.respond(method: "GET", url: url("/api/project/\(pid)/activity"), body: nil).data))
    check("an action writes its own log entry", feedAfter.count == feedBefore + 1,
          "\(feedBefore) -> \(feedAfter.count)")

    check("the feed honours a limit",
          embedded(json(await be.respond(method: "GET", url: url("/api/project/\(pid)/activity?limit=2"), body: nil).data)).count == 2)

    // --- INVITATIONS ---
    //
    // The client manages who was invited; it never accepts an invitation or
    // reads a screenplay by token, and it is never handed a token or an invite
    // URL to hold. These pin that, and pin the enumeration defence — inviting
    // an address that is already known must be indistinguishable from inviting
    // one that is not.
    func inviteList() async -> [[String: Any]] {
        embedded(json(await be.respond(method: "GET", url: url("/api/project/\(pid)/invitations"), body: nil).data))
    }

    let inviteRoot = json(await be.respond(method: "GET", url: url("/api/project/\(pid)/invitations"), body: nil).data)
    check("the collection offers `sendInvitation`",
          (inviteRoot["_links"] as? [String: Any])?["sendInvitation"] != nil)

    var invites = embedded(inviteRoot)
    check("seeded invitations are present", invites.count >= 2, "got \(invites.count)")
    check("collaborators and readers are distinguishable",
          invites.contains { $0["viewOnly"] as? Bool == true }
              && invites.contains { $0["viewOnly"] as? Bool == false })
    check("no invitation carries a token or a link to share",
          invites.allSatisfy { $0["token"] == nil && $0["inviteUrl"] == nil && $0["url"] == nil })

    let inviteCountBefore = invites.count
    let invited = await be.respond(method: "POST", url: url("/api/project/\(pid)/invitations"),
                                   body: body(["email": "newcomer@example.com", "viewOnly": false]))
    check("send invitation -> 200", invited.status == 200, "got \(invited.status)")
    invites = embedded(json(invited.data))
    check("the invitation was recorded", invites.count == inviteCountBefore + 1,
          "\(inviteCountBefore) -> \(invites.count)")

    // Inviting a known address answers identically — same status, same shape —
    // so nothing reveals whether that address was already there.
    let repeatInvite = await be.respond(method: "POST", url: url("/api/project/\(pid)/invitations"),
                                        body: body(["email": "newcomer@example.com", "viewOnly": false]))
    check("re-inviting a known address -> 200, not a conflict",
          repeatInvite.status == 200, "got \(repeatInvite.status)")
    check("re-inviting does not duplicate the invitation",
          embedded(json(repeatInvite.data)).count == invites.count)
    check("an empty address -> 400",
          await be.respond(method: "POST", url: url("/api/project/\(pid)/invitations"),
                           body: body(["email": "  "])).status == 400)

    // Inviting is an action, so it writes to the log.
    check("inviting writes an activity entry",
          embedded(json(await be.respond(method: "GET", url: url("/api/project/\(pid)/activity"), body: nil).data))
              .contains { ($0["actionType"] as? String) == "INVITATION_SEND" })

    let revokeTarget = invites.first { ($0["email"] as? String) == "newcomer@example.com" }
    let revokeId = revokeTarget?["id"] as? Int ?? 0
    check("an invitation advertises `revoke`",
          (revokeTarget?["_links"] as? [String: Any])?["revoke"] != nil)
    let revoked = await be.respond(method: "DELETE",
                                   url: url("/api/project/\(pid)/invitations/\(revokeId)"), body: nil)
    check("revoke -> 200", revoked.status == 200, "got \(revoked.status)")
    check("the invitation is gone",
          !embedded(json(revoked.data)).contains { $0["id"] as? Int == revokeId })
    check("revoking an unknown invitation -> 404",
          await be.respond(method: "DELETE", url: url("/api/project/\(pid)/invitations/999999"),
                           body: nil).status == 404)

    // --- DOCUMENT TRASH ---
    //
    // The third trash. Unlike an element, a restored document keeps its id —
    // the server restores it rather than re-creating it.
    let docsPayload = json(await be.respond(method: "GET", url: url("/api/document?projectId=\(pid)"), body: nil).data)
    check("document collection advertises `trash`",
          (docsPayload["_links"] as? [String: Any])?["trash"] != nil)

    let liveDocs = embedded(docsPayload)
    let doomedDoc = liveDocs.first?["id"] as? Int ?? 0
    let doomedTitle = liveDocs.first?["title"] as? String ?? ""

    _ = await be.respond(method: "DELETE", url: url("/api/document/\(doomedDoc)"), body: nil)
    var docTrash = embedded(json(await be.respond(method: "GET", url: url("/api/document/trash?projectId=\(pid)"), body: nil).data))
    check("a deleted document lands in the trash",
          docTrash.contains { $0["id"] as? Int == doomedDoc })
    check("it is gone from the live list",
          !embedded(json(await be.respond(method: "GET", url: url("/api/document?projectId=\(pid)"), body: nil).data))
              .contains { $0["id"] as? Int == doomedDoc })
    check("the trashed document says when it will be purged",
          docTrash.first?["purgesAt"] != nil)
    check("the trashed document keeps its type label",
          (docTrash.first?["documentTypeLabel"] as? String)?.isEmpty == false)

    let restoredDoc = await be.respond(method: "POST",
                                       url: url("/api/document/trash/\(doomedDoc)/restore?projectId=\(pid)"),
                                       body: nil)
    check("restore document -> 200", restoredDoc.status == 200, "got \(restoredDoc.status)")
    let docsAfter = embedded(json(await be.respond(method: "GET", url: url("/api/document?projectId=\(pid)"), body: nil).data))
    check("the document is back in the list",
          docsAfter.contains { $0["id"] as? Int == doomedDoc })
    check("a restored document keeps its id and title",
          docsAfter.first { $0["id"] as? Int == doomedDoc }?["title"] as? String == doomedTitle)
    check("restoring empties it from the trash",
          !embedded(json(restoredDoc.data)).contains { $0["id"] as? Int == doomedDoc })

    // Purging is final.
    _ = await be.respond(method: "DELETE", url: url("/api/document/\(doomedDoc)"), body: nil)
    let purgedDoc = await be.respond(method: "DELETE",
                                     url: url("/api/document/trash/\(doomedDoc)?projectId=\(pid)"),
                                     body: nil)
    check("purge document -> 200", purgedDoc.status == 200, "got \(purgedDoc.status)")
    check("the purged document is gone for good",
          !embedded(json(purgedDoc.data)).contains { $0["id"] as? Int == doomedDoc })
    check("restoring an unknown document -> 404",
          await be.respond(method: "POST", url: url("/api/document/trash/999999/restore?projectId=\(pid)"),
                           body: nil).status == 404)

    // --- BULK OPERATIONS ACROSS EDITIONS ---
    //
    // Regression. Selecting elements while reading a non-default edition and
    // applying a bulk action used to come back 403: the ownership check looked
    // only at the default edition's blocks. Every other check passed, because
    // none of them combined the two features — it took tapping through the app
    // to find. "The project" means every edition of it.
    let editionForBulk = await be.respond(method: "POST", url: url("/api/project/edition?projectId=\(pid)"),
                                          body: body(["name": "Bulk Check"]))
    if let bulkEditionId = embedded(json(editionForBulk.data))
        .first(where: { $0["name"] as? String == "Bulk Check" })?["id"] as? Int {

        // Give it something of its own to act on.
        _ = await be.respond(method: "POST", url: url("/api/block"),
                             body: body(["projectId": pid, "content": "A line in the revision.",
                                         "type": "ACTION"]))
        let editionBlocks = embedded(json(await be.respond(
            method: "GET", url: url("/api/block?projectId=\(pid)&editionId=\(bulkEditionId)"),
            body: nil).data))

        if let target = editionBlocks.first?["id"] as? Int {
            let retyped = await be.respond(method: "POST", url: url("/api/block/bulk/type"),
                                           body: body(["ids": [target], "projectId": pid,
                                                       "type": "SCENE"]))
            check("a bulk action on a non-default edition is not forbidden",
                  retyped.status == 200, "got \(retyped.status)")

            let formatted = await be.respond(method: "POST", url: url("/api/block/bulk/format"),
                                             body: body(["ids": [target], "projectId": pid,
                                                         "highlight": "yellow"]))
            check("bulk formatting reaches a non-default edition",
                  formatted.status == 200, "got \(formatted.status)")
            check("and the change actually landed on that block",
                  embedded(json(await be.respond(
                      method: "GET", url: url("/api/block?projectId=\(pid)&editionId=\(bulkEditionId)"),
                      body: nil).data))
                      .first { $0["id"] as? Int == target }?["highlight"] as? String == "YELLOW")
        }
    }

    // --- SONG EDITIONS ---
    //
    // The song counterpart of script editions. Advertised on songs only — a
    // note has no lyric blocks for an edition to scope.
    // Its own song and note: the document-trash checks above purge their way
    // through the seeded ones, so nothing earlier survives to be relied on.
    let madeSongDoc = await be.respond(method: "POST", url: url("/api/document"),
                                       body: body(["projectId": pid, "title": "Edition Check",
                                                   "documentType": "SONG", "content": "A line."]))
    let madeNoteDoc = await be.respond(method: "POST", url: url("/api/document"),
                                       body: body(["projectId": pid, "title": "A Note",
                                                   "documentType": "NOTES", "content": "Nothing."]))
    let songDoc = json(madeSongDoc.data)
    let noteDoc = json(madeNoteDoc.data)

    check("a song advertises `editions`",
          (songDoc["_links"] as? [String: Any])?["editions"] != nil)
    check("a note does not",
          (noteDoc["_links"] as? [String: Any])?["editions"] == nil)
    check("a song advertises its lyric lines",
          (songDoc["_links"] as? [String: Any])?["songBlocks"] != nil)

    // --- SONG BLOCKS ---
    //
    // A song is ordered lines, which is what makes reordering, tinting and
    // editions mean anything. The client edited songs as one lump of text
    // before, so none of this was reachable from here.
    if let lyricDocId = songDoc["id"] as? Int {
        func lyric() async -> [[String: Any]] {
            embedded(json(await be.respond(method: "GET", url: url("/api/song/block?documentId=\(lyricDocId)"), body: nil).data))
        }

        var lines = await lyric()
        check("a song's text becomes lines", !lines.isEmpty, "got \(lines.count)")
        let lineLinks = lines.first?["_links"] as? [String: Any] ?? [:]
        for rel in ["update", "delete", "createBelow", "move", "setHighlight"] {
            check("a lyric line advertises `\(rel)`", lineLinks[rel] != nil)
        }

        // Adding below is what Return does.
        let firstLineId = lines.first?["id"] as? Int ?? 0
        let countBefore = lines.count
        let below = await be.respond(method: "POST", url: url("/api/song/block/\(firstLineId)/below"),
                                     body: body(["content": "A line that came second."]))
        check("add line below -> 200", below.status == 200, "got \(below.status)")
        lines = await lyric()
        check("the new line is second", lines.count == countBefore + 1
              && lines[1]["content"] as? String == "A line that came second.",
              "got \(lines.count) lines")
        check("orders stay contiguous", lines.enumerated().allSatisfy { $1["order"] as? Int == $0 + 1 })

        // Editing a line.
        let secondId = lines[1]["id"] as? Int ?? 0
        let edited = await be.respond(method: "PUT", url: url("/api/song/block/\(secondId)"),
                                      body: body(["content": "Rewritten."]))
        check("edit line -> 200", edited.status == 200, "got \(edited.status)")
        check("the edit stuck", json(edited.data)["content"] as? String == "Rewritten.")

        // Tinting, and the lenient clear.
        _ = await be.respond(method: "POST", url: url("/api/song/block/\(secondId)/highlight"),
                             body: body(["highlight": "green"]))
        lines = await lyric()
        check("a line can be tinted",
              lines.first { $0["id"] as? Int == secondId }?["highlight"] as? String == "GREEN")
        _ = await be.respond(method: "POST", url: url("/api/song/block/\(secondId)/highlight"),
                             body: body(["highlight": "chartreuse"]))
        lines = await lyric()
        check("an unknown tint clears rather than failing",
              lines.first { $0["id"] as? Int == secondId }?["highlight"] == nil)

        // Reordering.
        _ = await be.respond(method: "POST", url: url("/api/song/block/\(secondId)/move"),
                             body: body(["position": 1]))
        lines = await lyric()
        check("a line can be moved", lines.first?["id"] as? Int == secondId)
        check("orders renumbered after a move",
              lines.enumerated().allSatisfy { $1["order"] as? Int == $0 + 1 })

        // Deleting.
        let beforeDelete = lines.count
        _ = await be.respond(method: "DELETE", url: url("/api/song/block/\(secondId)"), body: nil)
        lines = await lyric()
        check("a line can be deleted", lines.count == beforeDelete - 1)
        check("and the rest renumber",
              lines.enumerated().allSatisfy { $1["order"] as? Int == $0 + 1 })
    }

    if let songId = songDoc["id"] as? Int {
        func songEditions() async -> [[String: Any]] {
            embedded(json(await be.respond(method: "GET", url: url("/api/song/edition?documentId=\(songId)"), body: nil).data))
        }

        var songEds = await songEditions()
        check("a song starts with one edition", songEds.count == 1, "got \(songEds.count)")
        check("and it is the default", songEds.first?["default"] as? Bool == true)
        check("the only edition offers no delete",
              (songEds.first?["_links"] as? [String: Any])?["delete"] == nil)
        check("an edition points at its lyrics",
              (songEds.first?["_links"] as? [String: Any])?["songBlocks"] != nil)

        let madeSong = await be.respond(method: "POST", url: url("/api/song/edition?documentId=\(songId)"),
                                        body: body(["name": "Acoustic"]))
        check("create song edition -> 200", madeSong.status == 200, "got \(madeSong.status)")
        songEds = embedded(json(madeSong.data))
        check("the song now has two editions", songEds.count == 2, "got \(songEds.count)")
        check("both now offer delete",
              songEds.allSatisfy { ($0["_links"] as? [String: Any])?["delete"] != nil })
        check("a song edition needs a name -> 400",
              await be.respond(method: "POST", url: url("/api/song/edition?documentId=\(songId)"),
                               body: body(["name": " "])).status == 400)

        if let acousticId = songEds.first(where: { $0["name"] as? String == "Acoustic" })?["id"] as? Int {
            _ = await be.respond(method: "POST",
                                 url: url("/api/song/edition/\(acousticId)/set-default?documentId=\(songId)"),
                                 body: nil)
            songEds = await songEditions()
            check("setting a song default moves it",
                  songEds.first { $0["id"] as? Int == acousticId }?["default"] as? Bool == true)
            check("still exactly one song default",
                  songEds.filter { $0["default"] as? Bool == true }.count == 1)

            for edition in songEds where edition["id"] as? Int != acousticId {
                if let id = edition["id"] as? Int {
                    _ = await be.respond(method: "DELETE",
                                         url: url("/api/song/edition/\(id)?documentId=\(songId)"),
                                         body: nil)
                }
            }
            check("deleting the last song edition -> 409",
                  await be.respond(method: "DELETE",
                                   url: url("/api/song/edition/\(acousticId)?documentId=\(songId)"),
                                   body: nil).status == 409)
        }
    }

    // --- SONG EXPORT ---
    //
    // A song exports on its own, in the formats SongExportService offers. Like
    // script export, these sit outside the edit gate — a reader can take a copy.
    // Song-only: a note has no song layout, so it carries none of these links.
    for rel in ["exportSongTxt", "exportSongPdf", "exportSongDocx", "exportSongEpub",
                "exportSongMusicXml"] {
        check("a song advertises `\(rel)`",
              (songDoc["_links"] as? [String: Any])?[rel] != nil)
        check("a note does not advertise `\(rel)`",
              (noteDoc["_links"] as? [String: Any])?[rel] == nil)
    }
    if let href = ((songDoc["_links"] as? [String: Any])?["exportSongTxt"]
        as? [String: Any])?["href"] as? String, let exportURL = URL(string: href) {
        let exported = await be.respond(method: "GET", url: exportURL, body: nil)
        check("following a song export link returns a file",
              exported.status == 200 && !exported.data.isEmpty, "got \(exported.status)")
    }

    // --- DOCUMENT REORDER ---
    //
    // Reordering reassigns sort order to the ids supplied, so the client can
    // send just the tab it is dragging in. Advertised on the collection for an
    // editor.
    let docCollection = json(await be.respond(
        method: "GET", url: url("/api/document?projectId=\(pid)"), body: nil).data)
    check("the document collection advertises `reorder`",
          (docCollection["_links"] as? [String: Any])?["reorder"] != nil)
    if let songId = songDoc["id"] as? Int, let noteId = noteDoc["id"] as? Int {
        func documentIds() async -> [Int] {
            embedded(json(await be.respond(
                method: "GET", url: url("/api/document?projectId=\(pid)"), body: nil).data))
                .compactMap { $0["id"] as? Int }
        }
        let flipped = embedded(json(await be.respond(
            method: "POST", url: url("/api/document/reorder?projectId=\(pid)"),
            body: body(["orderedIds": [noteId, songId]])).data))
            .compactMap { $0["id"] as? Int }
        check("reorder lists the note before the song",
              (flipped.firstIndex(of: noteId) ?? 0) < (flipped.firstIndex(of: songId) ?? 0),
              "got \(flipped)")
        _ = await be.respond(method: "POST", url: url("/api/document/reorder?projectId=\(pid)"),
                             body: body(["orderedIds": [songId, noteId]]))
        let restored = await documentIds()
        check("reorder puts the song first again",
              (restored.firstIndex(of: songId) ?? 0) < (restored.firstIndex(of: noteId) ?? 0),
              "got \(restored)")
        check("reorder rejects an unknown id -> 400",
              await be.respond(method: "POST", url: url("/api/document/reorder?projectId=\(pid)"),
                               body: body(["orderedIds": [987654]])).status == 400)
    }

    // --- CAPITALIZATION PREFERENCES ---
    //
    // Per-element auto-caps, stored on the server because exports bake the case
    // in. Advertised on the root; a partial POST changes just the field sent.
    check("root advertises `capitalizationPreferences`",
          links(root)["capitalizationPreferences"] != nil)
    let caps = json(await be.respond(
        method: "GET", url: url("/api/preferences/capitalization"), body: nil).data)
    check("preferences default to all-on",
          ["scene", "character", "transition", "shot"].allSatisfy { caps[$0] as? Bool == true })
    check("preferences advertise `update`", links(caps)["update"] != nil)
    let toggled = json(await be.respond(
        method: "POST", url: url("/api/preferences/capitalization"),
        body: body(["character": false])).data)
    check("a partial post turns one element off", toggled["character"] as? Bool == false)
    check("and leaves the others on",
          ["scene", "transition", "shot"].allSatisfy { toggled[$0] as? Bool == true })
    let reread = json(await be.respond(
        method: "GET", url: url("/api/preferences/capitalization"), body: nil).data)
    check("the change persists on re-read", reread["character"] as? Bool == false)
    // Put it back so a re-run starts clean.
    _ = await be.respond(method: "POST", url: url("/api/preferences/capitalization"),
                         body: body(["character": true]))

    checkCurieTolerance()
    await checkDocumentCopyAndType(pid: pid)
    await checkCommentCounts(pid: pid)
    await checkAuditions(pid: pid)
    await checkHeadshots(pid: pid)
    await checkAccount(root: root)
    await checkUsers(root: root)
    await checkContactSuggestions(pid: pid)
    await checkBundleExports(pid: pid)
    await checkSongTrashAndHistory(pid: pid)
    await checkProjectAccess(pid: pid)
    await checkSongSelection(pid: pid)
    await checkMusicXmlRoundTrip(pid: pid)

    print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
}

/// Which elements have discussion on them, in one call. The client paints a
/// badge per element from this, so the shape is the contract: keyed by block id
/// (as strings, since they are JSON object keys) and silent about the elements
/// with nothing on them.
func checkCommentCounts(pid: Int) async {
    let collection = json(await be.respond(
        method: "GET", url: url("/api/block?projectId=\(pid)"), body: nil).data)
    check("the block collection advertises `commentCounts`",
          links(collection)["commentCounts"] != nil)
    // Follow the advertised href rather than rebuilding the path, which is the
    // whole point of the rel.
    guard let href = (links(collection)["commentCounts"] as? [String: Any])?["href"] as? String,
          let countsURL = URL(string: href),
          let blockId = embedded(collection).first?["id"] as? Int else {
        check("the commentCounts link is followable", false)
        return
    }

    func counts() async -> [String: Any] {
        json(await be.respond(method: "GET", url: countsURL, body: nil).data)["counts"]
            as? [String: Any] ?? [:]
    }

    let before = await counts()
    let started = before[String(blockId)] as? Int ?? 0
    _ = await be.respond(method: "POST", url: url("/api/block/\(blockId)/comments"),
                         body: body(["body": "One more thought."]))
    let after = await counts()
    check("a new comment raises that element's count",
          after[String(blockId)] as? Int == started + 1,
          "was \(started), now \(after[String(blockId)] as? Int ?? -1)")
    check("the map is keyed by block id as a string",
          after.keys.allSatisfy { Int($0) != nil }, "got \(after.keys.sorted())")

    // An element nobody has commented on is absent, not zero — that absence is
    // what keeps the payload small enough to fetch with the script.
    let quiet = embedded(collection).compactMap { $0["id"] as? Int }
        .first { after[String($0)] == nil }
    check("an uncommented element is absent rather than zero", quiet != nil)

    // Put the count back so a re-run starts from the same place.
    let thread = embedded(json(await be.respond(
        method: "GET", url: url("/api/block/\(blockId)/comments"), body: nil).data))
    if let mine = thread.last?["id"] as? Int {
        _ = await be.respond(method: "DELETE", url: url("/api/block/comments/\(mine)"), body: nil)
    }
    check("removing it lowers the count again",
          await counts()[String(blockId)] as? Int ?? 0 == started)
}

/// Copying a song/note and switching it between song and note. Both rels are
/// advertised on the document itself for an editor, and both are camel-cased
/// names over kebab-cased paths, so these pin the rel names rather than the
/// URLs they happen to point at.
func checkDocumentCopyAndType(pid: Int) async {
    let made = json(await be.respond(
        method: "POST", url: url("/api/document"),
        body: body(["projectId": pid, "title": "Overture",
                    "documentType": "SONG", "content": "First line.\nSecond line."])).data)
    guard let id = made["id"] as? Int else {
        check("a document to copy was created", false)
        return
    }
    check("a document advertises `duplicate`", links(made)["duplicate"] != nil)
    check("a document advertises `changeType`", links(made)["changeType"] != nil)

    // --- duplicate ---
    let copied = await be.respond(method: "POST", url: url("/api/document/\(id)/duplicate"), body: nil)
    check("duplicate -> 201", copied.status == 201, "got \(copied.status)")
    let copy = json(copied.data)
    check("the copy is titled \"… (copy)\"", copy["title"] as? String == "Overture (copy)",
          "got \(copy["title"] as? String ?? "nil")")
    check("the copy carries the content over",
          copy["content"] as? String == "First line.\nSecond line.")
    check("the copy is a new document", (copy["id"] as? Int) != id)
    check("the copy keeps the original's type", copy["documentType"] as? String == "SONG")
    let listed = embedded(json(await be.respond(
        method: "GET", url: url("/api/document?projectId=\(pid)"), body: nil).data))
        .compactMap { $0["id"] as? Int }
    check("both the original and its copy are listed",
          listed.contains(id) && listed.contains(copy["id"] as? Int ?? -1))
    check("duplicating an unknown document -> 404",
          await be.respond(method: "POST", url: url("/api/document/987654/duplicate"),
                           body: nil).status == 404)

    // --- changeType ---
    let toNote = json(await be.respond(
        method: "POST", url: url("/api/document/\(id)/change-type"),
        body: body(["type": "NOTES"])).data)
    check("change-type turns the song into a note",
          toNote["documentType"] as? String == "NOTES",
          "got \(toNote["documentType"] as? String ?? "nil")")
    check("and relabels it", toNote["documentTypeLabel"] as? String == "Notes")
    check("a note drops the song-only rels",
          links(toNote)["songBlocks"] == nil && links(toNote)["exportSongTxt"] == nil)
    let backToSong = json(await be.respond(
        method: "POST", url: url("/api/document/\(id)/change-type"),
        body: body(["type": "SONG"])).data)
    check("change-type turns it back into a song",
          backToSong["documentType"] as? String == "SONG")
    check("the song-only rels come back", links(backToSong)["songBlocks"] != nil)
    check("change-type keeps the content", backToSong["content"] as? String == "First line.\nSecond line.")
    check("change-type with no type -> 400",
          await be.respond(method: "POST", url: url("/api/document/\(id)/change-type"),
                           body: body(["type": ""])).status == 400)

    // Leave the project as it was found.
    _ = await be.respond(method: "DELETE", url: url("/api/document/\(id)"), body: nil)
    if let copyId = copy["id"] as? Int {
        _ = await be.respond(method: "DELETE", url: url("/api/document/\(copyId)"), body: nil)
    }
}

/// The two "take the whole set away" exports: a songbook of a project's songs,
/// and every project as one archive. Both hang off a collection rather than off
/// any one resource, and both disappear when there is nothing to bundle — a
/// client that advertised them anyway would offer an empty download.
func checkBundleExports(pid: Int) async {
    func documents() async -> [String: Any] {
        json(await be.respond(method: "GET", url: url("/api/document?projectId=\(pid)"), body: nil).data)
    }

    let songbookRels = ["exportSongsTxt", "exportSongsPdf", "exportSongsDocx", "exportSongsEpub",
                        "exportSongsMusicXml"]
    let collection = await documents()
    check("the document collection advertises every songbook format",
          songbookRels.allSatisfy { links(collection)[$0] != nil },
          "got \(links(collection).keys.sorted())")

    // Follow the advertised href rather than rebuilding the path.
    guard let href = (links(collection)["exportSongsTxt"] as? [String: Any])?["href"] as? String,
          let bookURL = URL(string: href) else {
        check("the songbook link is followable", false)
        return
    }
    let book = await be.respond(method: "GET", url: bookURL, body: nil)
    check("the songbook download -> 200", book.status == 200, "got \(book.status)")
    let text = String(data: book.data, encoding: .utf8) ?? ""
    let songTitles = embedded(collection)
        .filter { $0["documentType"] as? String == "SONG" }
        .compactMap { $0["title"] as? String }
    check("the songbook holds every song in the project",
          !songTitles.isEmpty && songTitles.allSatisfy(text.contains),
          "missing \(songTitles.filter { !text.contains($0) })")
    check("a PDF songbook comes back as a PDF",
          await be.respond(method: "GET",
                           url: url("/api/document/export-songs?projectId=\(pid)&format=pdf"),
                           body: nil).data.starts(with: Data("%PDF".utf8)))
    check("a songbook for an unknown project -> 400",
          await be.respond(method: "GET",
                           url: url("/api/document/export-songs?projectId=987654"),
                           body: nil).status == 400)

    // A project of notes alone has no songbook to offer.
    let notesOnly = json(await be.respond(
        method: "POST", url: url("/api/project"), body: body(["title": "Notes Only"])).data)
    if let emptyId = notesOnly["id"] as? Int {
        let empty = json(await be.respond(
            method: "GET", url: url("/api/document?projectId=\(emptyId)"), body: nil).data)
        check("a project without songs advertises no songbook",
              songbookRels.allSatisfy { links(empty)[$0] == nil })
    }

    // --- every project as one bundle ---
    let projects = json(await be.respond(method: "GET", url: url("/api/project"), body: nil).data)
    check("the project collection advertises `exportProjects`",
          links(projects)["exportProjects"] != nil)
    guard let bundleHref = (links(projects)["exportProjects"] as? [String: Any])?["href"] as? String,
          let bundleURL = URL(string: bundleHref) else {
        check("the exportProjects link is followable", false)
        return
    }
    let bundle = await be.respond(method: "GET", url: bundleURL, body: nil)
    check("the projects bundle -> 200", bundle.status == 200, "got \(bundle.status)")
    let listed = (json(bundle.data)["projects"] as? [[String: Any]]) ?? []
    check("the bundle holds every project the list showed",
          listed.count == embedded(projects).count,
          "\(listed.count) bundled vs \(embedded(projects).count) listed")

    if let emptyId = notesOnly["id"] as? Int {
        _ = await be.respond(method: "DELETE", url: url("/api/project/\(emptyId)"), body: nil)
    }
}

/// Invite autofill hangs off one rel, and the rel's spelling is the whole
/// contract: the server names it `contactSuggestions` (camel, curied to
/// `scripty:contactSuggestions`) even though the path it points at is
/// kebab-cased. The client once declared the path's spelling instead, so the
/// suggestions worked offline and silently vanished against a real deployment.
/// These checks pin the name in both spellings the client can meet.
func checkContactSuggestions(pid: Int) async {
    let projects = json(await be.respond(method: "GET", url: url("/api/project"), body: nil).data)
    guard let p = embedded(projects).first(where: { $0["id"] as? Int == pid }) else {
        check("the project is still listed", false)
        return
    }
    check("project advertises `contactSuggestions` under the server's spelling",
          links(p)[Rel.contactSuggestions.rawValue] != nil,
          "links were \(links(p).keys.sorted())")

    let curied = Data("""
    {"_links":{"scripty:contactSuggestions":{"href":"/api/project/1/contact-suggestions"}}}
    """.utf8)
    let probe = try? JSONDecoder().decode(LinkProbe.self, from: curied)
    check("a curied contactSuggestions resolves", probe?.hasLink(.contactSuggestions) == true)

    let suggestions = json(await be.respond(
        method: "GET", url: url("/api/project/\(pid)/contact-suggestions?q=ava"), body: nil).data)
    check("the link answers with a match", embedded(suggestions).count == 1)
}

/// The signed-in user's own account: the password, and the passkeys registered
/// to it. Unlike `users`, this is advertised to anyone signed in — it is your
/// own account, not an admin's view of someone else's. Registering a passkey is
/// deliberately absent (a browser-side WebAuthn ceremony), so the API offers
/// listing and revoking only.
func checkAccount(root: [String: Any]) async {
    check("root advertises `account` rel", links(root)["account"] != nil)

    let account = json(await be.respond(method: "GET", url: url("/api/account"), body: nil).data)
    check("the account names who is signed in", account["username"] as? String == "demo")
    check("the account offers `changePassword`", links(account)["changePassword"] != nil)
    check("the account offers `passkeys` where they are configured",
          links(account)["passkeys"] != nil)
    check("the account says whether passkeys are enabled",
          account["passkeysEnabled"] as? Bool == true)

    // The current password is required, and its message is worth showing.
    let wrong = await be.respond(method: "POST", url: url("/api/account/password"),
                                 body: body(["currentPassword": "nope",
                                             "newPassword": "correcthorse"]))
    check("a wrong current password -> 400", wrong.status == 400, "got \(wrong.status)")
    check("and the refusal carries a message",
          (json(wrong.data)["message"] as? String)?.isEmpty == false)
    check("a too-short new password -> 400",
          await be.respond(method: "POST", url: url("/api/account/password"),
                           body: body(["currentPassword": "demo1234",
                                       "newPassword": "short"])).status == 400)
    check("reusing the current password -> 400",
          await be.respond(method: "POST", url: url("/api/account/password"),
                           body: body(["currentPassword": "demo1234",
                                       "newPassword": "demo1234"])).status == 400)

    let changed = await be.respond(method: "POST", url: url("/api/account/password"),
                                   body: body(["currentPassword": "demo1234",
                                               "newPassword": "correcthorse"]))
    check("changing the password -> 200", changed.status == 200, "got \(changed.status)")
    // The change is real: the old one no longer works, the new one does.
    check("the old password stops working",
          await be.respond(method: "POST", url: url("/api/account/password"),
                           body: body(["currentPassword": "demo1234",
                                       "newPassword": "somethingelse"])).status == 400)
    check("the new password is the current one now",
          await be.respond(method: "POST", url: url("/api/account/password"),
                           body: body(["currentPassword": "correcthorse",
                                       "newPassword": "demo1234"])).status == 200)

    // Passkeys: listed, each revocable, and revoking answers with what is left.
    let keysDoc = json(await be.respond(method: "GET", url: url("/api/account/passkeys"), body: nil).data)
    var keys = embedded(keysDoc)
    check("the passkey collection points back at the account",
          links(keysDoc)["account"] != nil)
    check("seeded passkeys are present", keys.count >= 2, "got \(keys.count)")
    check("a passkey carries its credential id",
          keys.allSatisfy { ($0["credentialId"] as? String)?.isEmpty == false })
    check("a passkey says when it was added", keys.allSatisfy { $0["created"] != nil })
    check("a never-used passkey simply omits lastUsed",
          keys.contains { $0["lastUsed"] == nil })
    check("a passkey advertises `delete`",
          keys.allSatisfy { ($0["_links"] as? [String: Any])?["delete"] != nil })

    let victim = keys.first?["credentialId"] as? String ?? ""
    let revoked = await be.respond(method: "DELETE",
                                   url: url("/api/account/passkeys/\(victim)"), body: nil)
    check("revoke passkey -> 200", revoked.status == 200, "got \(revoked.status)")
    keys = embedded(json(revoked.data))
    check("the revoked passkey is gone",
          !keys.contains { $0["credentialId"] as? String == victim })
    check("the other passkey survived", keys.count == 1, "got \(keys.count)")
    check("revoking an unknown passkey -> 404",
          await be.respond(method: "DELETE",
                           url: url("/api/account/passkeys/not-a-real-id"),
                           body: nil).status == 404)
}

/// Auditions get their own function: `run()` had grown large enough that the
/// Swift optimizer crashed splitting the one async body.
func checkHeadshots(pid: Int) async {
    // --- HEADSHOTS ---
    //
    // The links are the whole feature: `setHeadshot` is always there, because
    // replacing a picture is the same action as adding one, while `headshot`
    // and `removeHeadshot` appear only once there is one. A client draws its
    // controls from that alone, so getting the condition backwards would offer
    // to delete a picture nobody uploaded.
    let actor = json(await be.respond(method: "POST", url: url("/api/actor"),
                                      body: body(["first": "Iris", "last": "Vance",
                                                  "projectIds": [pid]])).data)
    let actorId = actor["id"] as! Int
    check("a new actor may be given a headshot", links(actor)["setHeadshot"] != nil)
    check("and offers nothing to remove", links(actor)["removeHeadshot"] == nil)
    check("nor anything to fetch", links(actor)["headshot"] == nil)
    check("and says it has none", actor["hasHeadshot"] as? Bool == false)

    // The demo does not parse the multipart envelope; what matters here is
    // that bytes arriving change what the actor offers.
    let picture = Data("not really a jpeg, but bytes".utf8)
    let uploaded = json(await be.respond(
        method: "POST", url: url("/api/actor/\(actorId)/headshot"), body: picture).data)
    check("uploading answers with the refreshed actor", uploaded["id"] as? Int == actorId)
    check("which now says it has one", uploaded["hasHeadshot"] as? Bool == true)
    check("offers the image", links(uploaded)["headshot"] != nil)
    check("offers to remove it", links(uploaded)["removeHeadshot"] != nil)
    check("and still offers to replace it", links(uploaded)["setHeadshot"] != nil)

    let fetched = await be.respond(method: "GET", url: url("/api/actor/\(actorId)/headshot"), body: nil)
    check("the image comes back as it went in", fetched.data == picture)

    let empty = await be.respond(method: "POST", url: url("/api/actor/\(actorId)/headshot"), body: nil)
    check("an empty upload -> 400", empty.status == 400)

    let removed = json(await be.respond(
        method: "DELETE", url: url("/api/actor/\(actorId)/headshot"), body: nil).data)
    check("removing answers with the refreshed actor", removed["hasHeadshot"] as? Bool == false)
    check("and the remove link goes with it", links(removed)["removeHeadshot"] == nil)
    check("while the upload link stays", links(removed)["setHeadshot"] != nil)
    let gone = await be.respond(method: "GET", url: url("/api/actor/\(actorId)/headshot"), body: nil)
    check("the image is gone", gone.status == 404)
}

func checkAuditions(pid: Int) async {
    // --- AUDITIONS ---
    //
    // Which characters an actor auditions for, within a project. The ids ride on
    // the project-scoped actor (and only there — auditions have no meaning off a
    // project); `setAuditions` replaces the whole set. Its own actor and
    // characters, since the casting checks above deleted theirs.
    let auditionActor = json(await be.respond(method: "POST", url: url("/api/actor"),
                                              body: body(["first": "Nadia", "last": "Cole",
                                                          "email": "nadia@x.com",
                                                          "projectIds": [pid]])).data)
    let auditionActorId = auditionActor["id"] as! Int

    // A project-scoped actor carries the audition fields; an unscoped one does not.
    let scopedActors = embedded(json(await be.respond(
        method: "GET", url: url("/api/actor?projectId=\(pid)"), body: nil).data))
    let scoped = scopedActors.first { $0["id"] as? Int == auditionActorId }
    check("a project-scoped actor advertises `setAuditions`",
          (scoped?["_links"] as? [String: Any])?["setAuditions"] != nil)
    check("a project-scoped actor starts auditioning for no one",
          (scoped?["auditionCharacterIds"] as? [Int])?.isEmpty == true)
    let unscoped = embedded(json(await be.respond(method: "GET", url: url("/api/actor"), body: nil).data))
        .first { $0["id"] as? Int == auditionActorId }
    check("an unscoped actor carries no audition ids", unscoped?["auditionCharacterIds"] == nil)
    check("an unscoped actor offers no `setAuditions`",
          (unscoped?["_links"] as? [String: Any])?["setAuditions"] == nil)

    let auditionChars = embedded(json(await be.respond(
        method: "GET", url: url("/api/person?projectId=\(pid)"), body: nil).data))
    guard auditionChars.count >= 2 else {
        check("the project has characters to audition for", false)
        print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
        return
    }
    let castIdA = auditionChars[0]["id"] as! Int
    let castIdB = auditionChars[1]["id"] as! Int

    let setResponse = await be.respond(
        method: "POST", url: url("/api/actor/\(auditionActorId)/auditions?projectId=\(pid)"),
        body: body(["characterIds": [castIdA, castIdB]]))
    check("set auditions -> 200", setResponse.status == 200, "got \(setResponse.status)")
    let afterSet = Set(json(setResponse.data)["auditionCharacterIds"] as? [Int] ?? [])
    check("the response reports the auditions just set", afterSet == Set([castIdA, castIdB]),
          "got \(afterSet)")

    // The change is durable: a fresh project-scoped read shows it.
    let reReadActor = embedded(json(await be.respond(
        method: "GET", url: url("/api/actor?projectId=\(pid)"), body: nil).data))
        .first { $0["id"] as? Int == auditionActorId }
    check("auditions persist on re-read",
          Set(reReadActor?["auditionCharacterIds"] as? [Int] ?? []) == Set([castIdA, castIdB]))

    // Sending a smaller set replaces wholesale rather than adding.
    _ = await be.respond(method: "POST",
                         url: url("/api/actor/\(auditionActorId)/auditions?projectId=\(pid)"),
                         body: body(["characterIds": [castIdA]]))
    let narrowed = embedded(json(await be.respond(
        method: "GET", url: url("/api/actor?projectId=\(pid)"), body: nil).data))
        .first { $0["id"] as? Int == auditionActorId }
    check("a smaller set replaces the auditions wholesale",
          Set(narrowed?["auditionCharacterIds"] as? [Int] ?? []) == Set([castIdA]))

    // An empty list clears them.
    _ = await be.respond(method: "POST",
                         url: url("/api/actor/\(auditionActorId)/auditions?projectId=\(pid)"),
                         body: body(["characterIds": [Int]()]))
    let cleared = embedded(json(await be.respond(
        method: "GET", url: url("/api/actor?projectId=\(pid)"), body: nil).data))
        .first { $0["id"] as? Int == auditionActorId }
    check("an empty list clears the auditions",
          (cleared?["auditionCharacterIds"] as? [Int])?.isEmpty == true)

    // Deleting the actor takes their auditions with them; setting auditions
    // without a project is rejected.
    check("setting auditions without a project -> 400",
          await be.respond(method: "POST",
                           url: url("/api/actor/\(auditionActorId)/auditions"),
                           body: body(["characterIds": [castIdA]])).status == 400)
    _ = await be.respond(method: "DELETE", url: url("/api/actor/\(auditionActorId)"), body: nil)

}

func checkUsers(root: [String: Any]) async {
    // --- USERS (admin) ---
    //
    // Managing accounts is an admin task, so the root advertises `users` only to
    // one — the demo's single account stands in for that admin. What may be done
    // to an account travels as links: every account offers `update`, but the
    // signed-in admin's own account carries no `delete` (it cannot remove
    // itself), and deleting it is refused server-side too.
    check("root advertises `users` rel", links(root)["users"] != nil)

    func userList() async -> [[String: Any]] {
        embedded(json(await be.respond(method: "GET", url: url("/api/user"), body: nil).data))
    }

    let usersRoot = json(await be.respond(method: "GET", url: url("/api/user"), body: nil).data)
    check("the user collection has a self link", links(usersRoot)["self"] != nil)
    var accounts = embedded(usersRoot)
    check("seeded accounts are present", accounts.count >= 2, "got \(accounts.count)")
    check("an account reports whether it is enabled",
          accounts.allSatisfy { $0["enabled"] != nil })

    let selfAccount = accounts.first { $0["id"] as? Int == 1 }
    check("the signed-in admin offers `update`",
          (selfAccount?["_links"] as? [String: Any])?["update"] != nil)
    check("the signed-in admin offers no `delete`",
          (selfAccount?["_links"] as? [String: Any])?["delete"] == nil)
    check("another account offers `delete`",
          accounts.contains {
              ($0["id"] as? Int) != 1 && (($0["_links"] as? [String: Any])?["delete"] != nil)
          })

    let accountCountBefore = accounts.count
    let newAccount = await be.respond(method: "POST", url: url("/api/user"),
                                      body: body(["username": "gale", "password": "s3cretpw",
                                                  "firstName": "Gale", "lastName": "Ferris",
                                                  "writer": true, "viewCasting": true]))
    check("create user -> 200", newAccount.status == 200, "got \(newAccount.status)")
    let createdUser = json(newAccount.data)
    check("a created account returns an `update` link", links(createdUser)["update"] != nil)
    check("a created account keeps the roles it was given",
          createdUser["writer"] as? Bool == true && createdUser["viewCasting"] as? Bool == true)
    check("a role not granted stays off", createdUser["admin"] as? Bool == false)
    accounts = await userList()
    check("the created account joins the list", accounts.count == accountCountBefore + 1,
          "\(accountCountBefore) -> \(accounts.count)")

    check("creating without a username -> 400",
          await be.respond(method: "POST", url: url("/api/user"),
                           body: body(["password": "s3cretpw", "firstName": "N", "lastName": "N"]))
              .status == 400)
    check("creating with a short password -> 400",
          await be.respond(method: "POST", url: url("/api/user"),
                           body: body(["username": "x", "password": "short",
                                       "firstName": "N", "lastName": "N"])).status == 400)

    let createdId = createdUser["id"] as? Int ?? 0
    let edited = await be.respond(method: "PUT", url: url("/api/user/\(createdId)"),
                                  body: body(["username": "gale", "firstName": "Gale",
                                              "lastName": "Ferris", "writer": true,
                                              "director": true, "viewCasting": false]))
    check("edit user -> 200", edited.status == 200, "got \(edited.status)")
    let editedUser = json(edited.data)
    check("an edit adds the newly granted role", editedUser["director"] as? Bool == true)
    check("an edit clears a role turned off", editedUser["viewCasting"] as? Bool == false)

    let removedUser = await be.respond(method: "DELETE", url: url("/api/user/\(createdId)"), body: nil)
    check("delete user -> 200", removedUser.status == 200, "got \(removedUser.status)")
    check("the deleted account is gone",
          !(await userList()).contains { $0["id"] as? Int == createdId })
    check("an admin deleting their own account -> 400",
          await be.respond(method: "DELETE", url: url("/api/user/1"), body: nil).status == 400)

}

/// Getting a deleted lyric line back, and stepping an edit backwards.
///
/// Deleting a line has always been a soft delete, and the song editor has
/// always kept an undo stack — the API just never advertised either, so a line
/// deleted from the iPad was gone for good and one deleted from the browser was
/// not. Both hang off the line collection, which is where the client looks.
func checkSongTrashAndHistory(pid: Int) async {
    let song = json(await be.respond(
        method: "POST", url: url("/api/document"),
        body: body(["projectId": pid, "title": "Second Reprise", "documentType": "SONG",
                    "content": "First line.\nSecond line.\nThird line."])).data)
    guard let docId = song["id"] as? Int else {
        check("a song to work with", false)
        return
    }

    func lyric() async -> [String: Any] {
        json(await be.respond(method: "GET",
                              url: url("/api/song/block?documentId=\(docId)"), body: nil).data)
    }
    func follow(_ rel: String, in resource: [String: Any], method: String = "GET") async -> [String: Any] {
        guard let href = (links(resource)[rel] as? [String: Any])?["href"] as? String,
              let target = URL(string: href) else { return [:] }
        return json(await be.respond(method: method, url: target, body: nil).data)
    }

    var collection = await lyric()
    check("the lyric advertises its `trash`", links(collection)["trash"] != nil)
    check("the lyric advertises `undoRedoStatus`", links(collection)["undoRedoStatus"] != nil)

    // --- TRASH ---
    let doomed = embedded(collection).first { $0["content"] as? String == "Second line." }
    guard let doomedId = doomed?["id"] as? Int else {
        check("a line to delete", false)
        return
    }
    _ = await be.respond(method: "DELETE", url: url("/api/song/block/\(doomedId)"), body: nil)

    var trash = await follow("trash", in: collection)
    let trashed = embedded(trash).first
    check("a deleted line lands in the song's trash",
          trashed?["content"] as? String == "Second line.")
    // The whole line, not a preview: it is short, and it is what the writer is
    // deciding about.
    check("the trashed line carries its words rather than a preview",
          trashed?["preview"] == nil && trashed?["content"] != nil)
    check("a trashed line advertises `restore` and `purge`",
          (trashed?["_links"] as? [String: Any])?["restore"] != nil
          && (trashed?["_links"] as? [String: Any])?["purge"] != nil)

    trash = await follow("restore", in: trashed ?? [:], method: "POST")
    check("restoring answers with the refreshed trash", embedded(trash).isEmpty)
    collection = await lyric()
    check("the restored line is back in the lyric",
          embedded(collection).contains { $0["content"] as? String == "Second line." })
    check("and the lyric renumbers around it",
          embedded(collection).enumerated().allSatisfy { $1["order"] as? Int == $0 + 1 })

    // Purging leaves nothing to restore.
    let second = embedded(collection).first { $0["content"] as? String == "Second line." }
    _ = await be.respond(method: "DELETE",
                         url: url("/api/song/block/\(second?["id"] as? Int ?? 0)"), body: nil)
    trash = await follow("trash", in: collection)
    let toPurge = embedded(trash).first ?? [:]
    trash = await follow("purge", in: toPurge, method: "DELETE")
    check("purging empties the trash", embedded(trash).isEmpty)
    check("and the line does not come back",
          !(embedded(await lyric()).contains { $0["content"] as? String == "Second line." }))

    // --- UNDO / REDO ---
    collection = await lyric()
    var status = await follow("undoRedoStatus", in: collection)
    check("there is something to undo after those edits", status["canUndo"] as? Bool == true)
    check("and nothing to redo yet", status["canRedo"] as? Bool == false)
    check("the status carries the `undo` link", links(status)["undo"] != nil)
    check("and offers no `redo` link while the stack is empty", links(status)["redo"] == nil)

    let beforeUndo = embedded(collection).count
    let undone = await follow("undo", in: status, method: "POST")
    check("undo answers with the rewound lyric rather than a status",
          embedded(undone).count != beforeUndo || links(undone)["songBlocks"] == nil,
          "got \(embedded(undone).count) lines, was \(beforeUndo)")
    status = await follow("undoRedoStatus", in: await lyric())
    check("after an undo there is something to redo", status["canRedo"] as? Bool == true)

    let redone = await follow("redo", in: status, method: "POST")
    check("redo puts it back", embedded(redone).count == beforeUndo,
          "got \(embedded(redone).count), was \(beforeUndo)")
}

/// Who can already see a project, which is not who has been invited to it.
///
/// The client used to answer "nobody else has been invited" and let that stand
/// as the answer to "who can see this", which a role or a team quietly made
/// untrue. The rel sits outside the invitation feature flag for that reason.
func checkProjectAccess(pid: Int) async {
    let project = json(await be.respond(
        method: "GET", url: url("/api/project/\(pid)"), body: nil).data)
    check("a project advertises `access`", links(project)["access"] != nil)

    guard let href = (links(project)["access"] as? [String: Any])?["href"] as? String,
          let target = URL(string: href) else {
        check("the access link is followable", false)
        return
    }
    let list = json(await be.respond(method: "GET", url: target, body: nil).data)
    let people = embedded(list)
    check("it lists the people who can see it", !people.isEmpty)
    check("each carries a name", people.allSatisfy { ($0["displayName"] as? String)?.isEmpty == false })
    // The reason and the permission arrive rendered, so the client never
    // restates the server's access rules in Swift.
    check("each says why they are here",
          people.allSatisfy { ($0["accessLabel"] as? String)?.isEmpty == false })
    check("each says whether they can write",
          people.allSatisfy { $0["canEdit"] is Bool && $0["permissionLabel"] is String })
    check("the labels agree with the flag",
          people.allSatisfy {
              ($0["canEdit"] as? Bool == true) == ($0["permissionLabel"] as? String == "Can edit")
          })
    check("it links back to the project", links(list)["project"] != nil)

    // Names are how the client identifies a row, so a duplicate would collapse
    // two people into one in the list.
    let names = people.compactMap { $0["displayName"] as? String }
    check("names are unique enough to identify a row", Set(names).count == names.count)
}

/// Acting on several songs at once, the way the web list's checkbox column
/// does: a songbook of just the ticked songs, and a bulk delete that puts them
/// in the trash. The narrowing rides on the songbook link's own `ids`
/// parameter rather than on a second rel, so the check follows the advertised
/// href and adds ids to it exactly as the client does.
/// The one export a writer is meant to open and work on rather than read, and
/// the only one that comes home again: a song leaves as a score, is set to
/// music somewhere else, and is imported back as a song. The `importDocument`
/// rel carries it in both directions, so nothing new is advertised for the
/// return leg — which is exactly what has to be checked, since a client that
/// looked for an `importSong` rel would find none and offer nothing.
func checkMusicXmlRoundTrip(pid: Int) async {
    // Two verses, so the blank line between them has to survive too — it is
    // the shape of the song, not whitespace.
    let lyric = "Hold the line\nWait for morning\n\nNothing here is ours\nNothing here"
    guard let songId = json(await be.respond(
        method: "POST", url: url("/api/document"),
        body: body(["projectId": pid, "title": "Round Trip",
                    "documentType": "SONG", "content": lyric])).data)["id"] as? Int else {
        check("a song to export as a score", false)
        return
    }

    let song = json(await be.respond(method: "GET", url: url("/api/document/\(songId)"), body: nil).data)
    guard let href = (links(song)["exportSongMusicXml"] as? [String: Any])?["href"] as? String,
          let scoreURL = URL(string: href) else {
        check("the score link is followable", false)
        return
    }

    let downloaded = await be.respond(method: "GET", url: scoreURL, body: nil)
    let score = String(data: downloaded.data, encoding: .utf8) ?? ""
    check("following the score link returns a file", downloaded.status == 200 && !score.isEmpty,
          "got \(downloaded.status)")
    check("the file is a MusicXML score", score.contains("<score-partwise"))
    check("the score is named after the song", score.contains("<work-title>Round Trip</work-title>"))
    check("the words are laid under the staff", score.contains("<text>morning</text>"))
    // Without this a reader cannot tell where the writer's lines ended, and the
    // lyric comes back as one run-on line.
    check("the score records where the lines end", score.contains("<end-line/>"))
    check("and where the verses end", score.contains("<end-paragraph/>"))

    // --- and back in through the same import the other formats use ---
    let bd = APIClient.multipartBoundary
    let multipart = "--\(bd)\r\nContent-Disposition: form-data; name=\"projectId\"\r\n\r\n\(pid)\r\n"
        + "--\(bd)\r\nContent-Disposition: form-data; name=\"type\"\r\n\r\nSONG\r\n"
        + "--\(bd)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"round-trip.musicxml\"\r\n"
        + "Content-Type: application/vnd.recordare.musicxml+xml\r\n\r\n\(score)\r\n--\(bd)--\r\n"
    let imported = await be.respond(method: "POST", url: url("/api/document/import"),
                                    body: Data(multipart.utf8))
    check("importing a score -> 200", imported.status == 200, "got \(imported.status)")
    let reimported = json(imported.data)
    check("the score's lyric survives the round trip",
          reimported["content"] as? String == lyric,
          "got \(reimported["content"] ?? "nil")")
    // The filename would have said "round-trip"; the score itself says better.
    check("the song is named by the score, not the file",
          reimported["title"] as? String == "Round Trip",
          "got \(reimported["title"] ?? "nil")")
    check("and it comes back as a song",
          reimported["documentType"] as? String == "SONG")
}

func checkSongSelection(pid: Int) async {
    func documents() async -> [String: Any] {
        json(await be.respond(method: "GET", url: url("/api/document?projectId=\(pid)"), body: nil).data)
    }
    func makeSong(_ title: String) async -> Int? {
        json(await be.respond(method: "POST", url: url("/api/document"),
                              body: body(["projectId": pid, "title": title,
                                          "documentType": "SONG",
                                          "content": title + " lyric"])).data)["id"] as? Int
    }

    guard let keep = await makeSong("Selection Keeper"),
          let drop = await makeSong("Selection Goner") else {
        check("two songs to select between", false)
        return
    }

    let collection = await documents()
    check("the document collection advertises `bulkDelete`", links(collection)["bulkDelete"] != nil,
          "got \(links(collection).keys.sorted())")

    // --- a songbook of the selection only ---
    if let href = (links(collection)["exportSongsTxt"] as? [String: Any])?["href"] as? String,
       let narrowed = URL(string: href + "&ids=\(keep)") {
        let text = String(data: await be.respond(method: "GET", url: narrowed, body: nil).data,
                          encoding: .utf8) ?? ""
        check("a songbook of one song holds it", text.contains("Selection Keeper"))
        check("and holds nothing else", !text.contains("Selection Goner"))
    } else {
        check("the songbook link takes an ids list", false)
    }

    // --- deleting a selection ---
    guard let deleteHref = (links(collection)["bulkDelete"] as? [String: Any])?["href"] as? String,
          let deleteURL = URL(string: deleteHref) else {
        check("the bulkDelete link is followable", false)
        return
    }
    check("an empty selection -> 400",
          await be.respond(method: "POST", url: deleteURL, body: body(["ids": [Int]()])).status == 400)

    let left = json(await be.respond(method: "POST", url: deleteURL,
                                     body: body(["ids": [drop]])).data)
    let titles = embedded(left).compactMap { $0["title"] as? String }
    check("the answer is what is left of the collection",
          titles.contains("Selection Keeper") && !titles.contains("Selection Goner"),
          "got \(titles)")
    check("what is left still advertises the collection's links",
          links(left)["bulkDelete"] != nil && links(left)["reorder"] != nil)

    // Deleted, not destroyed: the trash is where the web's bulk delete puts
    // them too, and the client offers a restore from there.
    let trash = json(await be.respond(
        method: "GET", url: url("/api/document/trash?projectId=\(pid)"), body: nil).data)
    check("the deleted song is in the trash",
          embedded(trash).contains { $0["title"] as? String == "Selection Goner" })

    _ = await be.respond(method: "DELETE", url: url("/api/document/\(keep)"), body: nil)
}

await run()
exit(failures == 0 ? 0 : 1)
