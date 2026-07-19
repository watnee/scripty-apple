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

    print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
}

await run()
exit(failures == 0 ? 0 : 1)
