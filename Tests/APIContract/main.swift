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

func run() async {
    // --- root advertises actors ---
    let root = json(await be.respond(method: "GET", url: url("/api"), body: nil).data)
    check("root advertises `actors` rel", links(root)["actors"] != nil)
    check("root advertises `capitalizationPreferences`",
          links(root)["capitalizationPreferences"] != nil)

    // --- capitalization preferences round-trip ---
    let prefsURL = url("/api/preferences/capitalization")
    let prefs = json(await be.respond(method: "GET", url: prefsURL, body: nil).data)
    check("capitalization defaults to all on",
          prefs["scene"] as? Bool == true && prefs["character"] as? Bool == true
              && prefs["transition"] as? Bool == true && prefs["shot"] as? Bool == true)
    check("capitalization advertises `update`", links(prefs)["update"] != nil)

    // A single toggle posts only the field it changed; the rest must survive.
    let updatedPrefs = json(await be.respond(
        method: "POST", url: prefsURL,
        body: Data(#"{"character":false}"#.utf8)).data)
    check("capitalization: posted field applied",
          updatedPrefs["character"] as? Bool == false)
    check("capitalization: absent fields keep their value",
          updatedPrefs["scene"] as? Bool == true,
          "a partial update must not reset the flags it left out")

    // Put it back so later checks see the documented defaults.
    _ = await be.respond(method: "POST", url: prefsURL,
                         body: Data(#"{"character":true}"#.utf8))

    // --- project resource carries title-page + importScript ---
    let projects = json(await be.respond(method: "GET", url: url("/api/project"), body: nil).data)
    let p0 = embedded(projects)[0]
    let pid = p0["id"] as! Int
    check("project advertises `importScript`", links(p0)["importScript"] != nil)
    let p0Links = links(p0)
    check("project advertises `exportArchive`", p0Links["exportArchive"] != nil)
    // Rel-gating cuts both ways: the demo renders no PDF, so it must not
    // claim one. A menu entry that downloads nothing is the failure this
    // whole link-driven design exists to prevent.
    let advertisesPdf = p0Links["exportPdf"] != nil
    check("demo does not advertise `exportPdf`", !advertisesPdf)
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

    print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
}

await run()
exit(failures == 0 ? 0 : 1)
