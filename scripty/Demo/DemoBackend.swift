//
//  DemoBackend.swift
//  scripty
//
//  An in-process, in-memory stand-in for the Scripty API, used by demo
//  mode. It speaks the same HAL dialect as the real server — the rest of
//  the app follows `_links` exactly as it would against production, so
//  every rel-gated affordance (edit, delete, undo, export…) works offline
//  against the sample screenplay seeded below.
//

import Foundation

actor DemoBackend {
    /// Never contacted; only anchors the absolute hrefs demo links carry.
    static let baseURL = URL(string: "https://demo.scripty.local")!

    // MARK: - Store

    private struct DemoProject {
        var id: Int
        var title: String
        var writers: String?
        var lastEdited: Date
    }

    private struct DemoBlock {
        var id: Int
        var order: Int
        var content: String
        var type: String
        var personId: Int?
        var bookmarked = false
        var pinned = false
        var tags: String?
    }

    private struct DemoPerson {
        var id: Int
        var name: String
        var fullName: String
    }

    private var projects: [DemoProject] = []
    private var blocks: [Int: [DemoBlock]] = [:]      // keyed by project id
    private var people: [Int: [DemoPerson]] = [:]     // keyed by project id
    private var undoStacks: [Int: [[DemoBlock]]] = [:]
    private var redoStacks: [Int: [[DemoBlock]]] = [:]
    private var nextProjectId = 1
    private var nextBlockId = 1
    private var nextPersonId = 1
    private var seeded = false

    // MARK: - Router

    func respond(method: String, url: URL, body: Data?) -> (status: Int, data: Data) {
        if !seeded {
            seeded = true
            seed()
        }
        let path = url.pathComponents.filter { $0 != "/" }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .reduce(into: [String: String]()) { $0[$1.name] = $1.value } ?? [:]
        let fields = body
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        switch (method, path.first, path.dropFirst().first) {
        case ("GET", "api", nil):
            return ok(rootJSON())

        case (_, "api", "project"):
            return routeProject(method: method, path: Array(path.dropFirst(2)),
                                query: query, fields: fields)
        case (_, "api", "block"):
            return routeBlock(method: method, path: Array(path.dropFirst(2)),
                              query: query, fields: fields)
        case (_, "api", "person"):
            return routePerson(method: method, path: Array(path.dropFirst(2)),
                               query: query, fields: fields)
        default:
            return notFound()
        }
    }

    private func routeProject(method: String, path: [String],
                              query: [String: String],
                              fields: [String: Any]) -> (Int, Data) {
        switch (method, path.count) {
        case ("GET", 0):
            return ok(["_embedded": ["projectResourceList": projects.map(projectJSON)],
                       "_links": ["self": link("/api/project")]])
        case ("POST", 0):
            guard let title = fields["title"] as? String else { return badRequest("title") }
            let project = DemoProject(id: nextProjectId, title: title, lastEdited: .now)
            nextProjectId += 1
            projects.append(project)
            blocks[project.id] = []
            people[project.id] = []
            return ok(projectJSON(project))
        default:
            break
        }

        guard let id = path.first.flatMap(Int.init),
              let index = projects.firstIndex(where: { $0.id == id }) else { return notFound() }

        switch (method, path.dropFirst().first) {
        case ("GET", nil):
            return ok(projectJSON(projects[index]))
        case ("PUT", nil):
            if let title = fields["title"] as? String {
                projects[index].title = title
                projects[index].lastEdited = .now
            }
            return ok(projectJSON(projects[index]))
        case ("DELETE", nil):
            let removed = projects.remove(at: index)
            blocks[removed.id] = nil
            people[removed.id] = nil
            return ok([:])
        case ("GET", "undo-redo-status"):
            return ok(undoRedoJSON(projectId: id, success: nil))
        case ("POST", "undo"):
            return applyHistory(projectId: id, undoing: true)
        case ("POST", "redo"):
            return applyHistory(projectId: id, undoing: false)
        case ("GET", "sync-status"):
            let revision = Int64(projects[index].lastEdited.timeIntervalSince1970 * 1000)
            let since = query["since"].flatMap(Int64.init) ?? 0
            return ok(["exists": true,
                       "revision": revision,
                       "changed": since != 0 && since != revision,
                       "title": projects[index].title,
                       "_links": ["self": link("/api/project/\(id)/sync-status")]])
        case ("GET", "export"):
            return (200, Data(fountainExport(projects[index]).utf8))
        default:
            return notFound()
        }
    }

    private func routeBlock(method: String, path: [String],
                            query: [String: String],
                            fields: [String: Any]) -> (Int, Data) {
        switch (method, path.count) {
        case ("GET", 0):
            guard let projectId = query["projectId"].flatMap(Int.init) else {
                return badRequest("projectId")
            }
            let items = (blocks[projectId] ?? [])
                .sorted { $0.order < $1.order }
                .map { blockJSON($0, projectId: projectId) }
            return ok(["_embedded": ["blockResourceList": items],
                       "_links": ["self": link("/api/block?projectId=\(projectId)")]])
        case ("POST", 0):
            guard let projectId = fields["projectId"] as? Int,
                  blocks[projectId] != nil,
                  let content = fields["content"] as? String else {
                return badRequest("projectId")
            }
            snapshot(projectId)
            let block = DemoBlock(id: nextBlockId,
                                  order: (blocks[projectId]?.map(\.order).max() ?? 0) + 1,
                                  content: content,
                                  type: fields["type"] as? String ?? "ACTION",
                                  personId: fields["personId"] as? Int)
            nextBlockId += 1
            blocks[projectId]?.append(block)
            touch(projectId)
            return ok(blockJSON(block, projectId: projectId))
        default:
            break
        }

        guard let id = path.first.flatMap(Int.init),
              let (projectId, index) = locateBlock(id) else { return notFound() }

        switch (method, path.dropFirst().first) {
        case ("PUT", nil):
            snapshot(projectId)
            if let content = fields["content"] as? String {
                blocks[projectId]?[index].content = content
            }
            blocks[projectId]?[index].personId = fields["personId"] as? Int
            blocks[projectId]?[index].tags = fields["tags"] as? String
            touch(projectId)
            return ok(blockJSON(blocks[projectId]![index], projectId: projectId))
        case ("DELETE", nil):
            snapshot(projectId)
            blocks[projectId]?.remove(at: index)
            touch(projectId)
            return ok([:])
        case ("POST", "bookmark"):
            blocks[projectId]?[index].bookmarked.toggle()
            return ok(blockJSON(blocks[projectId]![index], projectId: projectId))
        case ("POST", "pinned"):
            blocks[projectId]?[index].pinned.toggle()
            return ok(blockJSON(blocks[projectId]![index], projectId: projectId))
        default:
            return notFound()
        }
    }

    private func routePerson(method: String, path: [String],
                             query: [String: String],
                             fields: [String: Any]) -> (Int, Data) {
        switch (method, path.count) {
        case ("GET", 0):
            guard let projectId = query["projectId"].flatMap(Int.init) else {
                return badRequest("projectId")
            }
            let items = (people[projectId] ?? []).map { personJSON($0, projectId: projectId) }
            return ok(["_embedded": ["personResourceList": items],
                       "_links": ["self": link("/api/person?projectId=\(projectId)")]])
        case ("POST", 0):
            guard let projectId = fields["projectId"] as? Int,
                  people[projectId] != nil,
                  let name = fields["name"] as? String else {
                return badRequest("projectId")
            }
            let person = DemoPerson(id: nextPersonId, name: name,
                                    fullName: fields["fullName"] as? String ?? name)
            nextPersonId += 1
            people[projectId]?.append(person)
            touch(projectId)
            return ok(personJSON(person, projectId: projectId))
        default:
            break
        }

        guard let id = path.first.flatMap(Int.init),
              let (projectId, index) = locatePerson(id) else { return notFound() }

        switch method {
        case "PUT":
            if let name = fields["name"] as? String {
                people[projectId]?[index].name = name
            }
            if let fullName = fields["fullName"] as? String {
                people[projectId]?[index].fullName = fullName
            }
            touch(projectId)
            return ok(personJSON(people[projectId]![index], projectId: projectId))
        case "DELETE":
            people[projectId]?.remove(at: index)
            touch(projectId)
            return ok([:])
        default:
            return notFound()
        }
    }

    // MARK: - Undo / redo

    /// History is snapshot-based: good enough for a demo, invisible to the UI.
    private func snapshot(_ projectId: Int) {
        undoStacks[projectId, default: []].append(blocks[projectId] ?? [])
        if undoStacks[projectId]!.count > 50 {
            undoStacks[projectId]!.removeFirst()
        }
        redoStacks[projectId] = []
    }

    private func applyHistory(projectId: Int, undoing: Bool) -> (Int, Data) {
        let popped = undoing
            ? undoStacks[projectId]?.popLast()
            : redoStacks[projectId]?.popLast()
        guard let state = popped else {
            return ok(undoRedoJSON(projectId: projectId, success: false))
        }
        let current = blocks[projectId] ?? []
        if undoing {
            redoStacks[projectId, default: []].append(current)
        } else {
            undoStacks[projectId, default: []].append(current)
        }
        blocks[projectId] = state
        touch(projectId)
        return ok(undoRedoJSON(projectId: projectId, success: true))
    }

    private func undoRedoJSON(projectId: Int, success: Bool?) -> [String: Any] {
        let canUndo = !(undoStacks[projectId] ?? []).isEmpty
        let canRedo = !(redoStacks[projectId] ?? []).isEmpty
        var links: [String: Any] = ["self": link("/api/project/\(projectId)/undo-redo-status")]
        if canUndo { links["undo"] = link("/api/project/\(projectId)/undo") }
        if canRedo { links["redo"] = link("/api/project/\(projectId)/redo") }
        var json: [String: Any] = ["canUndo": canUndo, "canRedo": canRedo, "_links": links]
        if let success { json["success"] = success }
        return json
    }

    // MARK: - Resource JSON

    private func rootJSON() -> [String: Any] {
        ["_links": ["self": link("/api"),
                    "projects": link("/api/project")]]
    }

    private func projectJSON(_ project: DemoProject) -> [String: Any] {
        var json: [String: Any] = [
            "id": project.id,
            "title": project.title,
            "lastEdited": iso.string(from: project.lastEdited),
            "teams": ["Demo"],
            "_links": [
                "self": link("/api/project/\(project.id)"),
                "update": link("/api/project/\(project.id)"),
                "delete": link("/api/project/\(project.id)"),
                "blocks": link("/api/block?projectId=\(project.id)"),
                "characters": link("/api/person?projectId=\(project.id)"),
                "undoRedoStatus": link("/api/project/\(project.id)/undo-redo-status"),
                "syncStatus": link("/api/project/\(project.id)/sync-status"),
                "export": link("/api/project/\(project.id)/export/fountain"),
            ],
        ]
        if let writers = project.writers { json["writers"] = writers }
        return json
    }

    private func blockJSON(_ block: DemoBlock, projectId: Int) -> [String: Any] {
        var json: [String: Any] = [
            "id": block.id,
            "projectId": projectId,
            "order": block.order,
            "content": block.content,
            "type": block.type,
            "bookmarked": block.bookmarked,
            "pinned": block.pinned,
            "scene": block.type == "SCENE",
            "_links": [
                "self": link("/api/block/\(block.id)"),
                "update": link("/api/block/\(block.id)"),
                "delete": link("/api/block/\(block.id)"),
                "toggleBookmark": link("/api/block/\(block.id)/bookmark"),
                "togglePinned": link("/api/block/\(block.id)/pinned"),
            ],
        ]
        if let personId = block.personId {
            json["personId"] = personId
            if let person = people[projectId]?.first(where: { $0.id == personId }) {
                json["personName"] = person.name
            }
        }
        if let tags = block.tags { json["tags"] = tags }
        return json
    }

    private func personJSON(_ person: DemoPerson, projectId: Int) -> [String: Any] {
        [
            "id": person.id,
            "name": person.name,
            "fullName": person.fullName,
            "projectId": projectId,
            "_links": [
                "self": link("/api/person/\(person.id)"),
                "update": link("/api/person/\(person.id)"),
                "delete": link("/api/person/\(person.id)"),
            ],
        ]
    }

    // MARK: - Export

    private func fountainExport(_ project: DemoProject) -> String {
        var lines = ["Title: \(project.title)", ""]
        for block in (blocks[project.id] ?? []).sorted(by: { $0.order < $1.order }) {
            switch block.type {
            case "SCENE", "TRANSITION":
                lines.append(block.content.uppercased())
                lines.append("")
            case "CHARACTER", "DUAL_DIALOGUE":
                lines.append(block.content.uppercased())
            case "PARENTHETICAL", "DIALOGUE":
                lines.append(block.content)
            default:
                lines.append(block.content)
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private let iso = ISO8601DateFormatter()

    private func locateBlock(_ id: Int) -> (projectId: Int, index: Int)? {
        for (projectId, list) in blocks {
            if let index = list.firstIndex(where: { $0.id == id }) {
                return (projectId, index)
            }
        }
        return nil
    }

    private func locatePerson(_ id: Int) -> (projectId: Int, index: Int)? {
        for (projectId, list) in people {
            if let index = list.firstIndex(where: { $0.id == id }) {
                return (projectId, index)
            }
        }
        return nil
    }

    private func touch(_ projectId: Int) {
        if let index = projects.firstIndex(where: { $0.id == projectId }) {
            projects[index].lastEdited = .now
        }
    }

    private func link(_ path: String) -> [String: String] {
        ["href": Self.baseURL.absoluteString + path]
    }

    private func ok(_ object: [String: Any]) -> (Int, Data) {
        ((try? JSONSerialization.data(withJSONObject: object)).map { (200, $0) }
            ?? (500, Data("{}".utf8)))
    }

    private func notFound() -> (Int, Data) {
        (404, Data("{}".utf8))
    }

    private func badRequest(_ field: String) -> (Int, Data) {
        let body = (try? JSONSerialization.data(withJSONObject: [field: "is required"]))
            ?? Data("{}".utf8)
        return (400, body)
    }

    // MARK: - Sample content

    private func seed() {
        let maya = addPerson(name: "MAYA", fullName: "Maya Okafor")
        let dev = addPerson(name: "DEV", fullName: "Dev Ramaswamy")

        let lastTake = addProject(title: "The Last Take",
                                  writers: "Demo Screenwriter",
                                  editedMinutesAgo: 12,
                                  people: [maya, dev])
        seedBlocks(project: lastTake, entries: [
            ("SCENE", "INT. SOUNDSTAGE 7 - NIGHT", nil, true),
            ("ACTION", "The crew of a no-budget indie huddles around a single flickering work light. MAYA (30s, running on cold coffee and spite) stares at a playback monitor.", nil, false),
            ("CHARACTER", "MAYA", maya.id, false),
            ("DIALOGUE", "That was perfect. Why does nobody trust me when I say it was perfect?", maya.id, false),
            ("CHARACTER", "DEV", dev.id, false),
            ("PARENTHETICAL", "(without looking up)", dev.id, false),
            ("DIALOGUE", "Because you said that about the take where the boom fell on me.", dev.id, false),
            ("CHARACTER", "MAYA", maya.id, false),
            ("DIALOGUE", "The boom added realism.", maya.id, false),
            ("ACTION", "The work light sputters. Everyone looks up. It dies with a sad little pop.", nil, false),
            ("CHARACTER", "DEV", dev.id, false),
            ("DIALOGUE", "We have four minutes of battery and one working light, Maya.", dev.id, false),
            ("CHARACTER", "MAYA", maya.id, false),
            ("PARENTHETICAL", "(standing)", maya.id, false),
            ("DIALOGUE", "Then we shoot the ending first. Right now. One take.", maya.id, false),
            ("TRANSITION", "SMASH CUT TO:", nil, false),
            ("SCENE", "EXT. STUDIO PARKING LOT - NIGHT", nil, false),
            ("ACTION", "Rain. Of course it's raining. Maya and Dev sprint across the lot, the camera cradled between them like a newborn.", nil, false),
            ("CHARACTER", "DEV", dev.id, false),
            ("DIALOGUE", "For the record, this is insane.", dev.id, false),
            ("CHARACTER", "MAYA", maya.id, false),
            ("DIALOGUE", "For the record, it's going to be beautiful.", maya.id, false),
            ("ACTION", "Maya skids to a stop and frames the shot with her hands: the night guard asleep in his booth, lit gold by a humming vending machine.", nil, false),
            ("CHARACTER", "MAYA", maya.id, false),
            ("PARENTHETICAL", "(whispering)", maya.id, false),
            ("DIALOGUE", "There it is. Roll.", maya.id, false),
            ("ACTION", "Dev rolls. Somewhere, thunder. The little red record light burns like a tiny sun.", nil, false),
            ("CHARACTER", "DEV", dev.id, false),
            ("PARENTHETICAL", "(quietly)", dev.id, false),
            ("DIALOGUE", "...Yeah, okay. It's beautiful.", dev.id, false),
            ("TRANSITION", "FADE OUT.", nil, false),
        ])

        let juniper = addPerson(name: "JUNIPER", fullName: "Juniper Vale")
        let dustAndNeon = addProject(title: "Dust & Neon",
                                     writers: "Demo Screenwriter",
                                     editedMinutesAgo: 60 * 26,
                                     people: [juniper])
        seedBlocks(project: dustAndNeon, entries: [
            ("SCENE", "EXT. FRONTIER TOWN OF LAST CHANCE - DUSK", nil, false),
            ("ACTION", "Two moons rise over a dirt main street lined with holographic saloon signs. A rider approaches, boots dusty, jacket flickering with dead pixels.", nil, false),
            ("CHARACTER", "JUNIPER", juniper.id, false),
            ("DIALOGUE", "They said this town was empty. They said a lot of things.", juniper.id, false),
            ("SYNOPSIS", "Juniper discovers the town isn't abandoned - it's hiding.", nil, false),
        ])
        _ = (lastTake, dustAndNeon)
    }

    private func addProject(title: String, writers: String?,
                            editedMinutesAgo: Double,
                            people members: [DemoPerson]) -> DemoProject {
        let project = DemoProject(id: nextProjectId, title: title, writers: writers,
                                  lastEdited: Date(timeIntervalSinceNow: -editedMinutesAgo * 60))
        nextProjectId += 1
        projects.append(project)
        blocks[project.id] = []
        people[project.id] = members
        return project
    }

    private func addPerson(name: String, fullName: String) -> DemoPerson {
        let person = DemoPerson(id: nextPersonId, name: name, fullName: fullName)
        nextPersonId += 1
        return person
    }

    private func seedBlocks(project: DemoProject,
                            entries: [(type: String, content: String, personId: Int?, pinned: Bool)]) {
        for (index, entry) in entries.enumerated() {
            let block = DemoBlock(id: nextBlockId,
                                  order: index + 1,
                                  content: entry.content,
                                  type: entry.type,
                                  personId: entry.personId,
                                  pinned: entry.pinned)
            nextBlockId += 1
            blocks[project.id]?.append(block)
        }
    }
}
