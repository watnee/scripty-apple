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

    print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
}

await run()
exit(failures == 0 ? 0 : 1)
