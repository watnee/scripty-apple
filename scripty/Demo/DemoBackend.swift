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
        var screenplayTitle: String?
        var contactInfo: String?
        var screenplayVersion: String?
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
        var textAlign: String?
        var font: String?
        var highlight: String?
        var textBold: Bool?
        var textItalic: Bool?
        var textUnderline: Bool?
    }

    private struct DemoPerson {
        var id: Int
        var name: String
        var fullName: String
        var actorId: Int?
    }

    /// Actors live outside any one project — the same person can be cast in
    /// several — so they are stored flat and filtered by `projectIds`.
    private struct DemoActor {
        var id: Int
        var first: String
        var last: String
        /// The bytes of whatever was uploaded, held so the demo can serve them
        /// back — the point of the feature is seeing the picture appear.
        /// Defaulted so the seed and the create route need not mention it.
        var headshot: Data? = nil
        var phone: String?
        var email: String?
        var projectIds: [Int]
    }

    private struct DemoDocument {
        var id: Int
        var projectId: Int
        var title: String
        var documentType: String   // "SONG" or "NOTES"
        var content: String
        var sortOrder: Int
        var createdAt: Date
        var updatedAt: Date
    }

    private var projects: [DemoProject] = []
    private var blocks: [Int: [DemoBlock]] = [:]      // keyed by project id
    private var people: [Int: [DemoPerson]] = [:]     // keyed by project id
    private var documents: [Int: [DemoDocument]] = [:] // keyed by project id
    private var actors: [DemoActor] = []
    private var undoStacks: [Int: [[DemoBlock]]] = [:]
    private var versions: [Int: [DemoVersion]] = [:]
    private var nextVersionId = 1
    private var comments: [DemoComment] = []
    private var nextCommentId = 1
    private var songBlocks: [Int: [DemoSongBlock]] = [:]
    private var nextSongBlockId = 1
    private var songEditions: [DemoSongEdition] = []
    private var nextSongEditionId = 1
    // Trash and history are per song version, as on the server: undoing in one
    // version must not reach into another's lines.
    private var deletedSongBlocks: [Int: [DeletedDemoSongBlock]] = [:]
    private var nextDeletedSongBlockId = 1
    private var songUndoStacks: [Int: [[DemoSongBlock]]] = [:]
    private var songRedoStacks: [Int: [[DemoSongBlock]]] = [:]
    private var deletedDocuments: [Int: [DeletedDemoDocument]] = [:]
    private var invitations: [DemoInvitation] = []
    private var nextInvitationId = 1
    private var activity: [DemoActivity] = []
    private var nextActivityId = 1
    private var editions: [DemoEdition] = []
    private var editionBlocks: [Int: [DemoBlock]] = [:]
    private var nextEditionId = 1
    private var trashedProjects: [TrashedDemoProject] = []
    private var deletedBlocks: [Int: [DeletedDemoBlock]] = [:]
    private var nextDeletedBlockId = 1
    private var redoStacks: [Int: [[DemoBlock]]] = [:]
    private var defaultProjectId: Int?
    private var nextProjectId = 1
    private var nextBlockId = 1
    private var nextPersonId = 1
    private var nextDocumentId = 1
    private var nextActorId = 1
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
                                query: query, fields: fields, body: body)
        case (_, "api", "block"):
            return routeBlock(method: method, path: Array(path.dropFirst(2)),
                              query: query, fields: fields)
        case (_, "api", "person"):
            return routePerson(method: method, path: Array(path.dropFirst(2)),
                               query: query, fields: fields)
        case (_, "api", "document"):
            return routeDocument(method: method, path: Array(path.dropFirst(2)),
                                 query: query, fields: fields, body: body)
        case (_, "api", "song"):
            switch path.dropFirst(2).first {
            case "edition":
                return routeSongEdition(method: method, path: Array(path.dropFirst(3)),
                                        query: query, fields: fields)
            case "block":
                return routeSongBlock(method: method, path: Array(path.dropFirst(3)),
                                      query: query, fields: fields)
            case "version":
                return routeSongVersion(method: method, path: Array(path.dropFirst(3)),
                                        query: query, fields: fields)
            default:
                return notFound()
            }
        case (_, "api", "actor"):
            return routeActor(method: method, path: Array(path.dropFirst(2)),
                              query: query, fields: fields, body: body)
        case (_, "api", "team"):
            return routeTeam(method: method, path: Array(path.dropFirst(2)),
                             query: query, fields: fields)
        case (_, "api", "user"):
            return routeUser(method: method, path: Array(path.dropFirst(2)),
                             query: query, fields: fields)
        case (_, "api", "account"):
            return routeAccount(method: method, path: Array(path.dropFirst(2)),
                                fields: fields)
        case (_, "api", "preferences"):
            return routePreferences(method: method, path: Array(path.dropFirst(2)),
                                    fields: fields)
        default:
            return notFound()
        }
    }

    // MARK: - Account (own password and passkeys)

    private struct DemoPasskey {
        var credentialId: String
        var label: String
        var created: Date
        var lastUsed: Date?
    }

    /// The demo account's password. Changing it is checked against this, so the
    /// "current password is wrong" path is reachable offline.
    private lazy var accountPassword = "demo1234"

    /// Seeded so the list is not empty; one never used, to show that state.
    private lazy var passkeyStore: [DemoPasskey] = [
        DemoPasskey(credentialId: "ZGVtby1pcGhvbmU",
                    label: "iPhone",
                    created: Date(timeIntervalSinceNow: -60 * 60 * 24 * 30),
                    lastUsed: Date(timeIntervalSinceNow: -60 * 60 * 24 * 2)),
        DemoPasskey(credentialId: "ZGVtby1sYXB0b3A",
                    label: "MacBook Pro",
                    created: Date(timeIntervalSinceNow: -60 * 60 * 24 * 5),
                    lastUsed: nil),
    ]

    private func routeAccount(method: String, path: [String],
                              fields: [String: Any]) -> (Int, Data) {
        switch (method, path.first) {
        case ("GET", nil):
            return ok(accountJSON())
        case ("POST", "password"):
            guard let current = fields["currentPassword"] as? String,
                  current == accountPassword else {
                return (400, (try? JSONSerialization.data(
                    withJSONObject: ["message": "Current password is incorrect."]))
                    ?? Data("{}".utf8))
            }
            guard let new = fields["newPassword"] as? String, new.count >= 8 else {
                return (400, (try? JSONSerialization.data(
                    withJSONObject: ["message": "New password is too weak: use at least 8 characters."]))
                    ?? Data("{}".utf8))
            }
            guard new != accountPassword else {
                return (400, (try? JSONSerialization.data(
                    withJSONObject: ["message": "New password must be different from the current password."]))
                    ?? Data("{}".utf8))
            }
            accountPassword = new
            return ok(accountJSON())
        case ("GET", "passkeys"):
            return ok(passkeyCollectionJSON())
        case ("DELETE", "passkeys"):
            guard let credentialId = path.dropFirst().first,
                  let index = passkeyStore.firstIndex(where: { $0.credentialId == credentialId })
            else {
                return notFound()
            }
            passkeyStore.remove(at: index)
            return ok(passkeyCollectionJSON())
        default:
            return notFound()
        }
    }

    private func accountJSON() -> [String: Any] {
        [
            "username": "demo",
            "firstName": "Demo",
            "lastName": "Admin",
            "passwordChangeRequired": false,
            "passkeysEnabled": true,
            "_links": [
                "self": link("/api/account"),
                "changePassword": link("/api/account/password"),
                "passkeys": link("/api/account/passkeys"),
            ],
        ]
    }

    private func passkeyCollectionJSON() -> [String: Any] {
        [
            "_embedded": ["passkeyResourceList": passkeyStore.map(passkeyJSON)],
            "_links": [
                "self": link("/api/account/passkeys"),
                "account": link("/api/account"),
            ],
        ]
    }

    private func passkeyJSON(_ passkey: DemoPasskey) -> [String: Any] {
        var json: [String: Any] = [
            "credentialId": passkey.credentialId,
            "label": passkey.label,
            "created": iso.string(from: passkey.created),
            "_links": [
                "delete": link("/api/account/passkeys/\(passkey.credentialId)"),
                "passkeys": link("/api/account/passkeys"),
            ],
        ]
        if let lastUsed = passkey.lastUsed {
            json["lastUsed"] = iso.string(from: lastUsed)
        }
        return json
    }

    // MARK: - Editor preferences

    /// Auto-capitalization is per element and stored on the server; the demo
    /// keeps the same four flags in memory so the toggles persist for the
    /// session and a re-read reflects what was set.
    private var capitalization: [String: Bool] = [
        "scene": true, "character": true, "transition": true, "shot": true,
    ]

    private func routePreferences(method: String, path: [String],
                                  fields: [String: Any]) -> (Int, Data) {
        guard path.first == "capitalization" else { return notFound() }
        switch method {
        case "GET":
            return ok(capitalizationJSON())
        case "POST":
            // Partial: only the posted fields change, matching the server so a
            // single toggle need not resend the others.
            for key in ["scene", "character", "transition", "shot"] {
                if let value = fields[key] as? Bool { capitalization[key] = value }
            }
            return ok(capitalizationJSON())
        default:
            return notFound()
        }
    }

    private func capitalizationJSON() -> [String: Any] {
        var json: [String: Any] = capitalization
        json["_links"] = [
            "self": link("/api/preferences/capitalization"),
            "update": link("/api/preferences/capitalization"),
        ]
        return json
    }

    private func routeProject(method: String, path: [String],
                              query: [String: String],
                              fields: [String: Any],
                              body: Data?) -> (Int, Data) {
        if method == "POST", path.first == "import" {
            return demoImport(body: body)
        }
        // `/api/project/version…` is a sibling of the project resources, not a
        // project id, so it has to be picked off before the numeric lookup.
        if path.first == "version" {
            return routeVersion(method: method, path: Array(path.dropFirst()),
                                query: query, fields: fields)
        }
        if path.first == "trash" {
            return routeProjectTrash(method: method, path: Array(path.dropFirst()))
        }
        if path.first == "edition" {
            return routeEdition(method: method, path: Array(path.dropFirst()),
                                query: query, fields: fields)
        }
        // The whole list as one bundle — a sibling of the project resources,
        // not a project id.
        if method == "GET", path.first == "export-projects" {
            return demoProjectsBundle()
        }
        switch (method, path.count) {
        case ("GET", 0):
            return projectCollection()
        case ("POST", 0):
            guard let title = fields["title"] as? String else { return badRequest("title") }
            let project = DemoProject(id: nextProjectId, title: title, lastEdited: .now)
            nextProjectId += 1
            projects.append(project)
            blocks[project.id] = []
            people[project.id] = []
            documents[project.id] = []
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
            // Title-page fields follow the same absent-means-unchanged rule as
            // blocks, so renaming a project never blanks its front matter.
            if let title = fields["title"] as? String { projects[index].title = title }
            if let value = fields["screenplayTitle"] as? String { projects[index].screenplayTitle = value }
            if let value = fields["writers"] as? String { projects[index].writers = value }
            if let value = fields["contactInfo"] as? String { projects[index].contactInfo = value }
            if let value = fields["screenplayVersion"] as? String { projects[index].screenplayVersion = value }
            projects[index].lastEdited = .now
            return ok(projectJSON(projects[index]))
        case ("POST", "import-script"):
            return demoImportScript(projectId: id, body: body)
        case ("DELETE", nil):
            // A soft delete, as on the server: everything belonging to the
            // project is kept aside so a restore can bring it back whole.
            let removed = projects.remove(at: index)
            trashedProjects.append(TrashedDemoProject(
                project: removed,
                deletedAt: Date(),
                blocks: blocks[removed.id] ?? [],
                people: people[removed.id] ?? [],
                documents: documents[removed.id] ?? []))
            blocks[removed.id] = nil
            people[removed.id] = nil
            documents[removed.id] = nil
            return ok([:])
        case ("GET", "undo-redo-status"):
            return ok(undoRedoJSON(projectId: id, success: nil))
        case ("POST", "undo"):
            return applyHistory(projectId: id, undoing: true)
        case ("POST", "redo"):
            return applyHistory(projectId: id, undoing: false)
        case (_, "invitations"):
            return routeInvitations(method: method, projectId: id,
                                    path: Array(path.dropFirst(2)), fields: fields)
        case ("GET", "activity"):
            let limit = query["limit"].flatMap(Int.init) ?? 30
            return activityCollection(id, limit: min(max(limit, 1), 100))
        case ("GET", "sync-status"):
            let revision = Int64(projects[index].lastEdited.timeIntervalSince1970 * 1000)
            let since = query["since"].flatMap(Int64.init) ?? 0
            return ok(["exists": true,
                       "revision": revision,
                       "changed": since != 0 && since != revision,
                       "title": projects[index].title,
                       "_links": ["self": link("/api/project/\(id)/sync-status")]])
        case ("GET", "export"):
            // The format is the next path segment; every rel points here. The
            // demo returns a plausible file per format so the export and print
            // flows can be exercised offline, not just the fountain one.
            let format = path.dropFirst(2).first ?? "fountain"
            return demoExport(projects[index], format: format)
        case ("GET", "contact-suggestions"):
            return contactSuggestions(matching: query["q"] ?? "")
        case ("GET", "access"):
            return projectAccess(id)
        case ("POST", "toggleDefault"):
            defaultProjectId = (defaultProjectId == id) ? nil : id
            return projectCollection()
        default:
            return notFound()
        }
    }

    /// Accepts a multipart project-archive upload and seeds a project from its
    /// title. The demo is lenient — it only reads the archive's project title.
    private func demoImport(body: Data?) -> (Int, Data) {
        guard let body, let text = String(data: body, encoding: .utf8),
              let headerEnd = text.range(of: "\r\n\r\n") else {
            return badRequest("file")
        }
        var payload = String(text[headerEnd.upperBound...])
        if let closing = payload.range(of: "\r\n--\(APIClient.multipartBoundary)--") {
            payload = String(payload[..<closing.lowerBound])
        }
        guard let jsonData = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return badRequest("file")
        }
        let info = object["project"] as? [String: Any]
        let title = (info?["title"] as? String) ?? (object["title"] as? String) ?? "Imported Project"
        let project = DemoProject(id: nextProjectId, title: title, lastEdited: .now)
        nextProjectId += 1
        projects.append(project)
        blocks[project.id] = []
        people[project.id] = []
        return ok(projectJSON(project))
    }

    /// Replaces a project's script from an uploaded file. The demo parses only
    /// plain Fountain — enough to prove the round trip — and rejects anything
    /// it cannot read as text, the way the server rejects an unparseable file.
    private func demoImportScript(projectId: Int, body: Data?) -> (Int, Data) {
        guard let index = projects.firstIndex(where: { $0.id == projectId }),
              let parsed = parseMultipart(body),
              let fileData = parsed.fileData,
              let text = String(data: fileData, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return badRequest("file")
        }
        snapshot(projectId)
        var imported: [DemoBlock] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            imported.append(DemoBlock(id: nextBlockId,
                                      order: imported.count + 1,
                                      content: trimmed,
                                      type: importedType(for: trimmed),
                                      personId: nil))
            nextBlockId += 1
        }
        guard !imported.isEmpty else { return badRequest("file") }
        blocks[projectId] = imported
        touch(projectId)
        return ok(projectJSON(projects[index]))
    }

    /// A deliberately small subset of the Fountain heuristics the real importer
    /// applies — the client-side detector in FountainDetect.swift is the one
    /// that matters for editing.
    private func importedType(for line: String) -> String {
        let upper = line.uppercased()
        if upper.hasPrefix("INT.") || upper.hasPrefix("EXT.") || upper.hasPrefix("INT/EXT") {
            return "SCENE"
        }
        // `... TO:` is the general form; the terminal transitions have no colon
        // and would otherwise read as action, since they end in a period and so
        // fail the character-cue test too.
        if upper.hasSuffix("TO:") { return "TRANSITION" }
        if ["FADE OUT.", "FADE TO BLACK.", "FADE IN:", "THE END."].contains(upper) {
            return "TRANSITION"
        }
        if line.hasPrefix("(") && line.hasSuffix(")") { return "PARENTHETICAL" }
        if line == upper && line.count <= 60 && !line.hasSuffix(".") {
            return "CHARACTER"
        }
        return "ACTION"
    }

    // MARK: - Actors (casting)

    /// Which characters an actor auditions for, keyed projectId → actorId → the
    /// set of character ids. Only meaningful in a project scope, mirroring the
    /// server's per-project audition table.
    private var auditions: [Int: [Int: Set<Int>]] = [:]

    private func routeActor(method: String, path: [String],
                            query: [String: String],
                            fields: [String: Any],
                            body: Data?) -> (Int, Data) {
        switch (method, path.count) {
        case ("GET", 0):
            let projectId = query["projectId"].flatMap(Int.init)
            let visible = projectId.map { id in
                actors.filter { $0.projectIds.contains(id) }
            } ?? actors
            let selfHref = projectId.map { "/api/actor?projectId=\($0)" } ?? "/api/actor"
            return ok(["_embedded": ["actorResourceList":
                        visible.map { actorJSON($0, projectId: projectId) }],
                       "_links": ["self": link(selfHref)]])
        case ("POST", 0):
            guard let first = fields["first"] as? String, !first.isEmpty else {
                return badRequest("first")
            }
            let actor = DemoActor(id: nextActorId,
                                  first: first,
                                  last: fields["last"] as? String ?? "",
                                  phone: fields["phone"] as? String,
                                  email: fields["email"] as? String,
                                  projectIds: fields["projectIds"] as? [Int] ?? [])
            nextActorId += 1
            actors.append(actor)
            return ok(actorJSON(actor))
        default:
            break
        }

        guard let id = path.first.flatMap(Int.init),
              let index = actors.firstIndex(where: { $0.id == id }) else { return notFound() }

        switch (method, path.dropFirst().first) {
        case ("GET", nil):
            return ok(actorJSON(actors[index]))
        case ("PUT", nil):
            if let value = fields["first"] as? String { actors[index].first = value }
            if let value = fields["last"] as? String { actors[index].last = value }
            if let value = fields["phone"] as? String { actors[index].phone = value }
            if let value = fields["email"] as? String { actors[index].email = value }
            if let value = fields["projectIds"] as? [Int] { actors[index].projectIds = value }
            return ok(actorJSON(actors[index]))
        case ("POST", "auditions"):
            // Replace the actor's auditions for one project, wholesale. Per
            // project, so a projectId is required; an empty list clears them.
            guard let projectId = query["projectId"].flatMap(Int.init),
                  actors[index].projectIds.contains(projectId) else {
                return badRequest("projectId")
            }
            let characterIds = fields["characterIds"] as? [Int] ?? []
            // Keep only ids that are real characters in the project.
            let valid = Set((people[projectId] ?? []).map(\.id))
            auditions[projectId, default: [:]][id] = Set(characterIds).intersection(valid)
            return ok(actorJSON(actors[index], projectId: projectId))
        case ("POST", "headshot"):
            // Multipart, like the server. The demo does not parse the envelope
            // — it only has to remember that a picture arrived, and how big it
            // was, for the links to change.
            guard let body, !body.isEmpty else { return badRequest("headshot") }
            actors[index].headshot = body
            return ok(actorJSON(actors[index]))
        case ("DELETE", "headshot"):
            actors[index].headshot = nil
            return ok(actorJSON(actors[index]))
        case ("GET", "headshot"):
            guard let data = actors[index].headshot else { return notFound() }
            return (200, data)
        case ("DELETE", nil):
            let removed = actors.remove(at: index)
            // Anyone cast as this actor becomes uncast rather than dangling, and
            // their auditions go with them.
            for (projectId, list) in people {
                for (i, person) in list.enumerated() where person.actorId == removed.id {
                    people[projectId]?[i].actorId = nil
                }
            }
            for projectId in auditions.keys {
                auditions[projectId]?[removed.id] = nil
            }
            return ok([:])
        default:
            return notFound()
        }
    }

    private func actorJSON(_ actor: DemoActor, projectId: Int? = nil) -> [String: Any] {
        var links: [String: Any] = [
            "self": link("/api/actor/\(actor.id)"),
            "actors": link("/api/actor"),
            "update": link("/api/actor/\(actor.id)"),
            "delete": link("/api/actor/\(actor.id)"),
            // Always on offer: replacing a headshot is the same action as
            // adding one.
            "setHeadshot": link("/api/actor/\(actor.id)/headshot"),
        ]
        // Reading and removing one are offered only where there is a headshot,
        // so a client can draw its controls from the links alone.
        if actor.headshot != nil {
            links["headshot"] = link("/api/actor/\(actor.id)/headshot")
            links["removeHeadshot"] = link("/api/actor/\(actor.id)/headshot")
        }
        var json: [String: Any] = [
            "id": actor.id,
            "first": actor.first,
            "last": actor.last,
            "hasHeadshot": actor.headshot != nil,
            "projectIds": actor.projectIds,
        ]
        // Auditions ride along only on a project-scoped actor — the same as the
        // server, which omits them (null) otherwise.
        if let projectId {
            let ids = (auditions[projectId]?[actor.id] ?? []).sorted()
            json["auditionCharacterIds"] = ids
            links["setAuditions"] = link("/api/actor/\(actor.id)/auditions?projectId=\(projectId)")
        }
        json["_links"] = links
        if let phone = actor.phone { json["phone"] = phone }
        if let email = actor.email { json["email"] = email }
        return json
    }

    private func routeBlock(method: String, path: [String],
                            query: [String: String],
                            fields: [String: Any]) -> (Int, Data) {
        switch (method, path.count) {
        case ("GET", 0):
            guard let projectId = query["projectId"].flatMap(Int.init) else {
                return badRequest("projectId")
            }
            // Naming an edition switches which script is being read. The
            // default edition's blocks are the project's own, so an unnamed
            // request behaves exactly as it always did.
            if let editionId = query["editionId"].flatMap(Int.init) {
                guard let edition = editions.first(where: {
                    $0.id == editionId && $0.projectId == projectId
                }) else { return notFound() }
                if !edition.isDefault {
                    return blockCollection(projectId, editionId: editionId)
                }
            }
            return blockCollection(projectId)
        case ("POST", 1) where path.first == "initial":
            guard let projectId = query["projectId"].flatMap(Int.init),
                  blocks[projectId] != nil else { return badRequest("projectId") }
            guard blocks[projectId]?.isEmpty ?? true else { return (409, Data("{}".utf8)) }
            snapshot(projectId)
            let block = DemoBlock(id: nextBlockId, order: 1, content: "", type: "ACTION", personId: nil)
            nextBlockId += 1
            blocks[projectId] = [block]
            touch(projectId)
            return ok(blockJSON(block, projectId: projectId))
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
        case ("POST", 2) where path.first == "bulk":
            return routeBulkBlocks(operation: path[1], fields: fields)
        default:
            break
        }

        // `/api/block/trash…`, `/api/block/comments/{id}` and
        // `/api/block/comment-counts` are siblings of the block resources, not
        // block ids, so they are picked off before the numeric lookup.
        if path.first == "trash" {
            return routeBlockTrash(method: method, path: Array(path.dropFirst()), query: query)
        }
        if path.first == "comment-counts", method == "GET" {
            guard let projectId = query["projectId"].flatMap(Int.init),
                  blocks[projectId] != nil else { return badRequest("projectId") }
            return commentCounts(projectId)
        }
        if path.first == "comments", path.count == 2, method == "DELETE",
           let commentId = Int(path[1]) {
            return routeDeleteComment(commentId)
        }

        guard let id = path.first.flatMap(Int.init),
              let (projectId, index) = locateBlock(id) else { return notFound() }

        switch (method, path.dropFirst().first) {
        case ("PUT", nil):
            snapshot(projectId)
            // Absent means "leave alone", never "clear" — the editor's debounced
            // content auto-save omits every field but `content`, and must not
            // wipe the speaker, tags or formatting on its way past.
            if let content = fields["content"] as? String {
                blocks[projectId]?[index].content = content
            }
            if let personId = fields["personId"] as? Int {
                blocks[projectId]?[index].personId = personId
            }
            if let tags = fields["tags"] as? String {
                blocks[projectId]?[index].tags = tags
            }
            if let align = fields["textAlign"] as? String {
                guard let canonical = canonicalAlign(align) else {
                    return badRequest("textAlign")
                }
                blocks[projectId]?[index].textAlign = canonical
            }
            if let font = fields["font"] as? String {
                guard let canonical = canonicalFont(font) else {
                    return badRequest("font")
                }
                blocks[projectId]?[index].font = canonical
            }
            if let bold = fields["textBold"] as? Bool {
                blocks[projectId]?[index].textBold = bold
            }
            if let italic = fields["textItalic"] as? Bool {
                blocks[projectId]?[index].textItalic = italic
            }
            if let underline = fields["textUnderline"] as? Bool {
                blocks[projectId]?[index].textUnderline = underline
            }
            touch(projectId)
            return ok(blockJSON(blocks[projectId]![index], projectId: projectId))
        case ("POST", "move"):
            guard let position = fields["position"] as? Int else {
                return badRequest("position")
            }
            snapshot(projectId)
            var list = (blocks[projectId] ?? []).sorted { $0.order < $1.order }
            guard let from = list.firstIndex(where: { $0.id == id }) else { return notFound() }
            // `position` is an absolute 1-based order; clamp so a stale client
            // index can't throw.
            let to = min(max(position - 1, 0), list.count - 1)
            let moved = list.remove(at: from)
            list.insert(moved, at: to)
            for i in list.indices { list[i].order = i + 1 }
            blocks[projectId] = list
            touch(projectId)
            let items = list.map { blockJSON($0, projectId: projectId) }
            return ok(["_embedded": ["blockResourceList": items],
                       "_links": ["self": link("/api/block?projectId=\(projectId)")]])
        case ("DELETE", nil):
            snapshot(projectId)
            if let removed = blocks[projectId]?.remove(at: index) {
                trashBlock(removed, projectId: projectId)
            }
            touch(projectId)
            return ok([:])
        case (_, "comments"):
            return routeComments(method: method, blockId: id, fields: fields)
        case ("POST", "bookmark"):
            blocks[projectId]?[index].bookmarked.toggle()
            return ok(blockJSON(blocks[projectId]![index], projectId: projectId))
        case ("POST", "pinned"):
            blocks[projectId]?[index].pinned.toggle()
            return ok(blockJSON(blocks[projectId]![index], projectId: projectId))
        case ("POST", "below"):
            snapshot(projectId)
            var list = blocks[projectId] ?? []
            let inserted = DemoBlock(id: nextBlockId,
                                     order: 0,
                                     content: fields["content"] as? String ?? "",
                                     type: (fields["type"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "ACTION",
                                     personId: fields["personId"] as? Int)
            nextBlockId += 1
            list.insert(inserted, at: index + 1)
            for i in list.indices { list[i].order = i + 1 }   // renumber to keep a clean sequence
            blocks[projectId] = list
            touch(projectId)
            return ok(blockJSON(list[index + 1], projectId: projectId))
        case ("POST", "type"):
            guard let type = fields["type"] as? String, !type.isEmpty else {
                return badRequest("type")
            }
            snapshot(projectId)
            var updated = blocks[projectId]![index]
            updated.type = type
            if let content = fields["content"] as? String { updated.content = content }
            if let personId = fields["personId"] as? Int { updated.personId = personId }
            if let tags = fields["tags"] as? String { updated.tags = tags }
            blocks[projectId]![index] = updated
            touch(projectId)
            return ok(blockJSON(updated, projectId: projectId))
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
            // Mirrors the server: an omitted actorId clears the casting, so
            // every character PUT must state the casting it means to keep.
            people[projectId]?[index].actorId = fields["actorId"] as? Int
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

    // MARK: - Documents (songs & notes)

    private func routeDocument(method: String, path: [String],
                               query: [String: String],
                               fields: [String: Any],
                               body: Data?) -> (Int, Data) {
        // Collection: list / create.
        switch (method, path.first) {
        case ("GET", nil):
            guard let projectId = query["projectId"].flatMap(Int.init),
                  documents[projectId] != nil else { return badRequest("projectId") }
            let type = normalizeDocumentType(query["type"])
            let items = (documents[projectId] ?? [])
                .filter { type == nil || $0.documentType == type }
                .sorted { $0.sortOrder < $1.sortOrder }
                .map { documentJSON($0, includeContent: false) }
            var selfHref = "/api/document?projectId=\(projectId)"
            if let type { selfHref += "&type=\(type)" }
            var links = documentCollectionLinks(projectId: projectId)
            links["self"] = link(selfHref)
            return ok(["_embedded": ["textDocumentResourceList": items], "_links": links])
        case ("POST", nil):
            guard let projectId = fields["projectId"] as? Int,
                  documents[projectId] != nil,
                  let title = fields["title"] as? String, !title.isBlank else {
                return badRequest("title")
            }
            let type = normalizeDocumentType(fields["documentType"] as? String) ?? "SONG"
            let document = addDocument(projectId: projectId, title: title, type: type,
                                       content: fields["content"] as? String ?? "")
            return ok(documentJSON(document, includeContent: true))
        case ("POST", "import"):
            return importDocument(body: body)
        default:
            break
        }

        // `/api/document/trash…` is a sibling of the document resources, not a
        // document id, so it is picked off before the numeric lookup.
        if path.first == "trash" {
            return routeDocumentTrash(method: method, path: Array(path.dropFirst()), query: query)
        }

        // `/api/document/reorder` is likewise a sibling, not an id.
        if method == "POST", path.first == "reorder" {
            return reorderDocuments(query: query, fields: fields)
        }

        // …as is the songbook, which exports the collection rather than any one
        // document in it. An `ids` list narrows it to a selection, the way the
        // web's export menu does when songs are checked.
        if method == "GET", path.first == "export-songs" {
            guard let projectId = query["projectId"].flatMap(Int.init),
                  documents[projectId] != nil else { return badRequest("projectId") }
            return demoSongbookExport(projectId: projectId, format: query["format"] ?? "txt",
                                      ids: idList(query["ids"]))
        }

        // …and so is the bulk delete, which trashes a selection of songs.
        if method == "POST", path.first == "bulk", path.dropFirst().first == "delete" {
            return bulkDeleteDocuments(query: query, fields: fields)
        }

        guard let id = path.first.flatMap(Int.init),
              let (projectId, index) = locateDocument(id) else { return notFound() }

        switch (method, path.dropFirst().first) {
        case ("GET", nil):
            return ok(documentJSON(documents[projectId]![index], includeContent: true))
        case ("PUT", nil):
            if let title = fields["title"] as? String, !title.isBlank {
                documents[projectId]?[index].title = title
            }
            documents[projectId]?[index].content = fields["content"] as? String ?? ""
            documents[projectId]?[index].updatedAt = .now
            return ok(documentJSON(documents[projectId]![index], includeContent: true))
        case ("DELETE", nil):
            // A soft delete, as on the server: the document is kept aside so a
            // restore can bring it back whole.
            if let removed = documents[projectId]?.remove(at: index) {
                deletedDocuments[projectId, default: []].append(
                    DeletedDemoDocument(document: removed, deletedAt: Date()))
            }
            return ok([:])
        case ("POST", "insert"):
            return insertDocument(document: documents[projectId]![index],
                                  afterBlockId: fields["afterBlockId"] as? Int,
                                  asType: fields["asType"] as? String)
        case ("POST", "duplicate"):
            // Content only, as on the server: a song's lyric blocks and
            // editions are not carried over to the copy.
            let source = documents[projectId]![index]
            let copy = addDocument(projectId: projectId, title: copyTitle(source.title),
                                   type: source.documentType, content: source.content)
            return created(documentJSON(copy, includeContent: true))
        case ("POST", "change-type"):
            // A blank type is the only rejection; the server maps any other
            // unrecognized value onto SONG rather than failing.
            guard let type = normalizeDocumentType(fields["type"] as? String) else {
                return badRequest("type")
            }
            documents[projectId]?[index].documentType = type
            documents[projectId]?[index].updatedAt = .now
            return ok(documentJSON(documents[projectId]![index], includeContent: true))
        case ("POST", "share-email"):
            let email = (fields["email"] as? String) ?? ""
            if email.isBlank { return badRequest("email") }
            return ok(["shared": true,
                       "title": documents[projectId]![index].title,
                       "email": email])
        case ("GET", "export-song"):
            return demoSongExport(documents[projectId]![index], format: query["format"] ?? "txt")
        default:
            return notFound()
        }
    }

    /// Reassigns sort order to the supplied sequence, exactly as the server
    /// does — ids from another project or unknown ids reject the whole request.
    private func reorderDocuments(query: [String: String], fields: [String: Any]) -> (Int, Data) {
        guard let projectId = query["projectId"].flatMap(Int.init),
              documents[projectId] != nil else { return badRequest("projectId") }
        let orderedIds = (fields["orderedIds"] as? [Any])?.compactMap { $0 as? Int } ?? []
        guard !orderedIds.isEmpty else { return badRequest("orderedIds") }
        let existing = Set((documents[projectId] ?? []).map(\.id))
        guard orderedIds.allSatisfy(existing.contains) else {
            return badRequest("orderedIds")
        }
        for (position, id) in orderedIds.enumerated() {
            if let index = documents[projectId]?.firstIndex(where: { $0.id == id }) {
                documents[projectId]?[index].sortOrder = position
            }
        }
        let items = (documents[projectId] ?? [])
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { documentJSON($0, includeContent: false) }
        // The reorder answer replaces the client's held collection links, so it
        // carries the same set the listing did — otherwise every other
        // affordance would disappear after a drag.
        return ok(["_embedded": ["textDocumentResourceList": items],
                   "_links": documentCollectionLinks(projectId: projectId)])
    }

    /// Trashes several songs at once, skipping anything that is not a song of
    /// this project — a mixed selection takes the songs and leaves the notes,
    /// as the server's own bulk delete does. Answers with what is left.
    private func bulkDeleteDocuments(query: [String: String], fields: [String: Any]) -> (Int, Data) {
        guard let projectId = query["projectId"].flatMap(Int.init),
              documents[projectId] != nil else { return badRequest("projectId") }
        let ids = (fields["ids"] as? [Any])?.compactMap { $0 as? Int } ?? []
        guard !ids.isEmpty else { return badRequest("ids") }
        var deleted = 0
        for id in Set(ids) {
            guard let index = documents[projectId]?.firstIndex(where: {
                $0.id == id && $0.documentType == "SONG"
            }) else { continue }
            if let removed = documents[projectId]?.remove(at: index) {
                deletedDocuments[projectId, default: []].append(
                    DeletedDemoDocument(document: removed, deletedAt: Date()))
                deleted += 1
            }
        }
        guard deleted > 0 else { return badRequest("ids") }
        let items = (documents[projectId] ?? [])
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { documentJSON($0, includeContent: false) }
        return ok(["_embedded": ["textDocumentResourceList": items],
                   "_links": documentCollectionLinks(projectId: projectId)])
    }

    /// The ids of a comma-separated query value, as Spring reads a `List<Integer>`
    /// parameter.
    private func idList(_ value: String?) -> [Int] {
        (value ?? "").split(separator: ",").compactMap { Int($0) }
    }

    /// The links a project's document collection carries. The songbook exports
    /// appear only where there is a song to put in the book, matching the
    /// server, and sit outside the edit gate because exporting is a read.
    private func documentCollectionLinks(projectId: Int) -> [String: Any] {
        var links: [String: Any] = [
            "self": link("/api/document?projectId=\(projectId)"),
            "project": link("/api/project/\(projectId)"),
            "importDocument": link("/api/document/import"),
            "reorder": link("/api/document/reorder?projectId=\(projectId)"),
            "trash": link("/api/document/trash?projectId=\(projectId)"),
        ]
        if (documents[projectId] ?? []).contains(where: { $0.documentType == "SONG" }) {
            for (rel, format) in [("exportSongsTxt", "txt"), ("exportSongsPdf", "pdf"),
                                  ("exportSongsDocx", "docx"), ("exportSongsEpub", "epub"),
                                  ("exportSongsMusicXml", "musicxml")] {
                links[rel] = link("/api/document/export-songs?projectId=\(projectId)&format=\(format)")
            }
            // Deleting a selection is songs-only and an edit, so it rides with
            // the songbook's condition but inside the edit gate — which the
            // demo is always on the right side of.
            links["bulkDelete"] = link("/api/document/bulk/delete?projectId=\(projectId)")
        }
        return links
    }

    /// A song exported on its own. The demo serves the format it can actually
    /// produce — a PDF shell or the lyric text — so the export rel resolves
    /// offline; the point is the round trip, not a faithful renderer.
    private func demoSongExport(_ document: DemoDocument, format: String) -> (Int, Data) {
        switch format {
        case "pdf":
            return (200, minimalPDF(title: document.title))
        default:
            let header = document.title.isEmpty ? "" : document.title + "\n\n"
            return (200, Data((header + document.content).utf8))
        }
    }

    /// Every song in a project, one after another — the songbook the web's
    /// Export menu downloads. Same shortcut as the single-song export: the
    /// point is that the rel resolves and a file comes back. A non-empty `ids`
    /// list narrows the book to those songs, keeping the project's order.
    private func demoSongbookExport(projectId: Int, format: String, ids: [Int] = []) -> (Int, Data) {
        let chosen = Set(ids)
        let songs = (documents[projectId] ?? [])
            .filter { $0.documentType == "SONG" && (chosen.isEmpty || chosen.contains($0.id)) }
            .sorted { $0.sortOrder < $1.sortOrder }
        let title = projects.first { $0.id == projectId }?.title ?? "Songs"
        switch format {
        case "pdf":
            return (200, minimalPDF(title: title))
        default:
            let book = songs
                .map { ($0.title.isEmpty ? "" : $0.title + "\n\n") + $0.content }
                .joined(separator: "\n\n\n")
            return (200, Data(book.utf8))
        }
    }

    private func insertDocument(document: DemoDocument, afterBlockId: Int?,
                                asType: String?) -> (Int, Data) {
        let projectId = document.projectId
        let type = asType ?? (document.documentType == "SONG" ? "LYRICS" : "ACTION")
        let lines = document.content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else {
            return ok(["inserted": 0, "projectId": projectId, "firstBlockId": NSNull()])
        }
        snapshot(projectId)
        var current = blocks[projectId] ?? []
        // Determine insertion order: after the given block, else append.
        var order: Int
        if let afterBlockId, let anchor = current.first(where: { $0.id == afterBlockId }) {
            order = anchor.order
        } else {
            order = current.map(\.order).max() ?? 0
        }
        var firstId: Int?
        for line in lines {
            order += 1
            let block = DemoBlock(id: nextBlockId, order: order, content: line, type: type)
            if firstId == nil { firstId = block.id }
            nextBlockId += 1
            current.append(block)
        }
        blocks[projectId] = current.sorted { $0.order < $1.order }
        touch(projectId)
        return ok(["inserted": lines.count,
                   "projectId": projectId,
                   "firstBlockId": firstId ?? NSNull()])
    }

    /// Minimal multipart parse: pulls the `type` field and the uploaded file's
    /// name + text. Binary formats can't be extracted offline, so their text
    /// is best-effort UTF-8 (the real backend handles docx/pdf/fdx).
    private func importDocument(body: Data?) -> (Int, Data) {
        guard let parsed = parseMultipart(body) else { return badRequest("file") }
        guard let projectId = parsed.fields["projectId"].flatMap(Int.init),
              documents[projectId] != nil else { return badRequest("projectId") }
        let type = normalizeDocumentType(parsed.fields["type"]) ?? "SONG"
        let rawName = parsed.fileName ?? "Imported"
        let title = (rawName as NSString).deletingPathExtension
        let content = String(data: parsed.fileData ?? Data(), encoding: .utf8) ?? ""
        let document = addDocument(projectId: projectId,
                                   title: title.isEmpty ? "Imported" : title,
                                   type: type, content: content)
        return ok(documentJSON(document, includeContent: true))
    }

    @discardableResult
    private func addDocument(projectId: Int, title: String, type: String,
                             content: String) -> DemoDocument {
        let order = (documents[projectId] ?? []).map(\.sortOrder).max().map { $0 + 1 } ?? 0
        let document = DemoDocument(id: nextDocumentId, projectId: projectId, title: title,
                                    documentType: type, content: content, sortOrder: order,
                                    createdAt: .now, updatedAt: .now)
        nextDocumentId += 1
        documents[projectId, default: []].append(document)
        return document
    }

    private func documentJSON(_ document: DemoDocument, includeContent: Bool) -> [String: Any] {
        let isSong = document.documentType == "SONG"
        var links: [String: Any] = [
            "self": link("/api/document/\(document.id)"),
            "documents": link("/api/document?projectId=\(document.projectId)"),
            "project": link("/api/project/\(document.projectId)"),
            "update": link("/api/document/\(document.id)"),
            "delete": link("/api/document/\(document.id)"),
            "insert": link("/api/document/\(document.id)/insert"),
            // Both are editor affordances on the document itself; the demo user
            // always has edit rights, so they are unconditional here.
            "duplicate": link("/api/document/\(document.id)/duplicate"),
            "changeType": link("/api/document/\(document.id)/change-type"),
        ]
        if isSong {
            links["shareEmail"] = link("/api/document/\(document.id)/share-email")
            // Songs are lyric blocks on the server, so only they have editions
            // to scope. A note is plain text with nothing to vary.
            links["editions"] = link("/api/song/edition?documentId=\(document.id)")
            links["songBlocks"] = link("/api/song/block?documentId=\(document.id)")
            // A song exports on its own; a note has no song layout, so these are
            // song-only, matching the server.
            links["exportSongTxt"] = link("/api/document/\(document.id)/export-song?format=txt")
            links["exportSongPdf"] = link("/api/document/\(document.id)/export-song?format=pdf")
            links["exportSongDocx"] = link("/api/document/\(document.id)/export-song?format=docx")
            links["exportSongEpub"] = link("/api/document/\(document.id)/export-song?format=epub")
            // A score rather than a document to read, and the format the song
            // importer reads back.
            links["exportSongMusicXml"] = link("/api/document/\(document.id)/export-song?format=musicxml")
        }
        var json: [String: Any] = [
            "id": document.id,
            "projectId": document.projectId,
            "title": document.title,
            "documentType": document.documentType,
            "documentTypeLabel": isSong ? "Song" : "Notes",
            "preview": documentPreview(document.content),
            "sortOrder": document.sortOrder,
            "createdAt": iso.string(from: document.createdAt),
            "updatedAt": iso.string(from: document.updatedAt),
            "_links": links,
        ]
        if includeContent {
            json["content"] = document.content
        }
        return json
    }

    private func documentPreview(_ content: String) -> String {
        let flattened = content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return flattened.count > 90 ? String(flattened.prefix(90)) + "…" : flattened
    }

    /// The title the server gives a duplicate: the original with " (copy)"
    /// appended, trimmed to fit the column if that would overflow it.
    private func copyTitle(_ title: String) -> String {
        let suffix = " (copy)"
        var base = title.isBlank ? "Untitled" : title.trimmingCharacters(in: .whitespaces)
        if base.count + suffix.count > 200 {
            base = String(base.prefix(200 - suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return base + suffix
    }

    private func normalizeDocumentType(_ type: String?) -> String? {
        guard let type, !type.isBlank else { return nil }
        switch type.uppercased() {
        case "NOTES", "NOTE", "DRAFT", "DRAFTS", "OTHER":
            return "NOTES"
        default:
            return "SONG"
        }
    }

    private func locateDocument(_ id: Int) -> (projectId: Int, index: Int)? {
        for (projectId, list) in documents {
            if let index = list.firstIndex(where: { $0.id == id }) {
                return (projectId, index)
            }
        }
        return nil
    }

    /// Parses the fixed-boundary multipart body produced by `APIClient.upload`.
    private func parseMultipart(_ body: Data?) -> (fields: [String: String], fileName: String?, fileData: Data?)? {
        guard let body else { return nil }
        let boundary = "--" + APIClient.multipartBoundary
        guard let boundaryData = boundary.data(using: .utf8),
              let crlfcrlf = "\r\n\r\n".data(using: .utf8),
              let crlf = "\r\n".data(using: .utf8) else { return nil }

        var fields: [String: String] = [:]
        var fileName: String?
        var fileData: Data?

        var searchStart = body.startIndex
        var parts: [Data] = []
        // Split on the boundary marker.
        var ranges: [Range<Data.Index>] = []
        while let range = body.range(of: boundaryData, in: searchStart..<body.endIndex) {
            ranges.append(range)
            searchStart = range.upperBound
        }
        for i in 0..<ranges.count {
            let start = ranges[i].upperBound
            let end = (i + 1 < ranges.count) ? ranges[i + 1].lowerBound : body.endIndex
            if start < end { parts.append(body.subdata(in: start..<end)) }
        }

        for part in parts {
            guard let headerEnd = part.range(of: crlfcrlf) else { continue }
            let headerData = part.subdata(in: part.startIndex..<headerEnd.lowerBound)
            guard let header = String(data: headerData, encoding: .utf8) else { continue }
            var contentStart = headerEnd.upperBound
            var contentEnd = part.endIndex
            // Strip the trailing CRLF before the next boundary.
            if let trailing = part.range(of: crlf, options: .backwards, in: contentStart..<part.endIndex) {
                contentEnd = trailing.lowerBound
            }
            if contentStart > contentEnd { contentStart = contentEnd }
            let content = part.subdata(in: contentStart..<contentEnd)

            if let name = value(in: header, for: "name") {
                if let file = value(in: header, for: "filename") {
                    fileName = file
                    fileData = content
                } else {
                    fields[name] = String(data: content, encoding: .utf8)
                }
            }
        }
        return (fields, fileName, fileData)
    }

    /// Extracts a `key="value"` token from a Content-Disposition header line.
    private func value(in header: String, for key: String) -> String? {
        guard let keyRange = header.range(of: "\(key)=\"") else { return nil }
        let rest = header[keyRange.upperBound...]
        guard let endQuote = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<endQuote])
    }

    // MARK: - Undo / redo

    /// History is snapshot-based: good enough for a demo, invisible to the UI.
    // MARK: - Invitations

    /// Someone invited to a screenplay. The demo enables this surface where a
    /// real deployment keeps it behind a flag, because nothing here leaves the
    /// process: no mail is sent and no account can be created.
    private struct DemoInvitation {
        var id: Int
        var projectId: Int
        var email: String
        var viewOnly: Bool
        var status: String
    }

    private func routeInvitations(method: String, projectId: Int, path: [String],
                                  fields: [String: Any]) -> (Int, Data) {
        guard projects.contains(where: { $0.id == projectId }) else { return notFound() }

        switch (method, path.count) {
        case ("GET", 0):
            return invitationCollection(projectId)

        case ("POST", 0):
            guard let email = (fields["email"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else {
                return badRequest("email")
            }
            // Answers the same whether or not the address is already known, so
            // the client cannot learn who has an account. The real service
            // returns null in that case for the same reason.
            let known = invitations.contains {
                $0.projectId == projectId && $0.email.caseInsensitiveCompare(email) == .orderedSame
            }
            if !known {
                invitations.append(DemoInvitation(
                    id: nextInvitationId,
                    projectId: projectId,
                    email: email,
                    viewOnly: fields["viewOnly"] as? Bool ?? false,
                    status: "Pending"))
                nextInvitationId += 1
            }
            recordActivity(projectId, type: "INVITATION_SEND",
                           summary: "Invited \(email)")
            return invitationCollection(projectId)

        default:
            break
        }

        guard let id = path.first.flatMap(Int.init),
              let index = invitations.firstIndex(where: {
                  $0.id == id && $0.projectId == projectId
              }), method == "DELETE" else { return notFound() }

        let removed = invitations.remove(at: index)
        recordActivity(projectId, type: "INVITATION_REVOKE",
                       summary: "Revoked the invitation for \(removed.email)")
        return invitationCollection(projectId)
    }

    private func invitationCollection(_ projectId: Int) -> (Int, Data) {
        let items = invitations
            .filter { $0.projectId == projectId }
            .map { invitation -> [String: Any] in
                [
                    "id": invitation.id,
                    "email": invitation.email,
                    "statusLabel": invitation.status,
                    "viewOnly": invitation.viewOnly,
                    "_links": [
                        "revoke": link("/api/project/\(projectId)/invitations/\(invitation.id)"),
                        "invitations": link("/api/project/\(projectId)/invitations"),
                    ],
                ]
            }
        return ok([
            "_embedded": ["invitationResourceList": items],
            "_links": [
                "self": link("/api/project/\(projectId)/invitations"),
                "sendInvitation": link("/api/project/\(projectId)/invitations"),
                "project": link("/api/project/\(projectId)"),
            ],
        ])
    }

    // MARK: - Activity

    /// One entry in a project's activity log. Written by the demo's own
    /// mutations, never by a caller — the log records what happened, not what
    /// someone claimed happened.
    private struct DemoActivity {
        var id: Int
        var projectId: Int
        var actor: String
        var actionType: String
        var summary: String
        var createdAt: Date
    }

    private func recordActivity(_ projectId: Int, type: String, summary: String,
                                actor: String = "You", minutesAgo: Int = 0) {
        activity.append(DemoActivity(
            id: nextActivityId,
            projectId: projectId,
            actor: actor,
            actionType: type,
            summary: summary,
            createdAt: Date(timeIntervalSinceNow: -Double(minutesAgo) * 60)))
        nextActivityId += 1
    }

    private func activityCollection(_ projectId: Int, limit: Int) -> (Int, Data) {
        let items = activity
            .filter { $0.projectId == projectId }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map { entry -> [String: Any] in
                [
                    "id": entry.id,
                    "actorDisplayName": entry.actor,
                    "actionType": entry.actionType,
                    "summary": entry.summary,
                    "createdAt": iso.string(from: entry.createdAt),
                ]
            }
        return ok([
            "_embedded": ["projectActivityResourceList": Array(items)],
            "_links": [
                "self": link("/api/project/\(projectId)/activity"),
                "project": link("/api/project/\(projectId)"),
            ],
        ])
    }

    // MARK: - Comments

    private struct DemoComment {
        var id: Int
        var blockId: Int
        var authorName: String
        var body: String
        var createdAt: Date
        /// Whether the demo's single user wrote it. Only their own comments —
        /// and any comment on a script they can edit — offer a delete link.
        var mine: Bool
    }

    private func routeComments(method: String, blockId: Int,
                               fields: [String: Any]) -> (Int, Data) {
        switch method {
        case "GET":
            return commentCollection(blockId)
        case "POST":
            guard let body = (fields["body"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else {
                return badRequest("body")
            }
            comments.append(DemoComment(id: nextCommentId, blockId: blockId,
                                        authorName: "You", body: body,
                                        createdAt: Date(), mine: true))
            nextCommentId += 1
            // The log is written by the action, not by the caller.
            if let (projectId, _) = locateBlock(blockId) {
                recordActivity(projectId, type: "COMMENT_ADD",
                               summary: "Commented on an element")
            }
            return commentCollection(blockId)
        default:
            return notFound()
        }
    }

    private func routeDeleteComment(_ commentId: Int) -> (Int, Data) {
        guard let index = comments.firstIndex(where: { $0.id == commentId }) else {
            return notFound()
        }
        let blockId = comments[index].blockId
        comments.remove(at: index)
        return commentCollection(blockId)
    }

    private func commentCollection(_ blockId: Int) -> (Int, Data) {
        let items = comments
            .filter { $0.blockId == blockId }
            .sorted { $0.createdAt < $1.createdAt }
            .map { comment -> [String: Any] in
                var links: [String: Any] = [
                    "comments": link("/api/block/\(blockId)/comments"),
                ]
                // The demo user can edit the script, so every comment here is
                // deletable — but the link is still what says so.
                links["delete"] = link("/api/block/comments/\(comment.id)")
                return [
                    "id": comment.id,
                    "blockId": blockId,
                    "authorName": comment.authorName,
                    "body": comment.body,
                    "createdAt": iso.string(from: comment.createdAt),
                    "_links": links,
                ]
            }
        return ok([
            "_embedded": ["blockCommentResourceList": items],
            "_links": [
                "self": link("/api/block/\(blockId)/comments"),
                "addComment": link("/api/block/\(blockId)/comments"),
                "block": link("/api/block/\(blockId)"),
            ],
        ])
    }

    /// Comments per element for a whole project, keyed by block id. Elements
    /// with none are left out entirely rather than sent as zero — that absence
    /// is the contract, since it is what keeps the payload small enough to
    /// fetch alongside the script.
    private func commentCounts(_ projectId: Int) -> (Int, Data) {
        var counts: [String: Int] = [:]
        for comment in comments where ownsBlock(comment.blockId, projectId: projectId) {
            counts[String(comment.blockId), default: 0] += 1
        }
        return ok([
            "counts": counts,
            "_links": [
                "self": link("/api/block/comment-counts?projectId=\(projectId)"),
                "blocks": link("/api/block?projectId=\(projectId)"),
            ],
        ])
    }

    // MARK: - Editions

    /// A named variant of a script. Blocks belong to an edition; the demo keys
    /// them by edition id so switching genuinely shows different text.
    private struct DemoEdition {
        var id: Int
        var projectId: Int
        var name: String
        var isDefault: Bool
        var isPublished: Bool
        var lastEdited: Date
    }

    private func routeEdition(method: String, path: [String],
                              query: [String: String],
                              fields: [String: Any]) -> (Int, Data) {
        guard let projectId = query["projectId"].flatMap(Int.init),
              blocks[projectId] != nil else { return badRequest("projectId") }

        switch (method, path.count) {
        case ("GET", 0):
            return editionCollection(projectId)

        case ("POST", 0):
            guard let name = (fields["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return badRequest("name")
            }
            let source = fields["copyFromEditionId"] as? Int
            if let source, !editions.contains(where: { $0.id == source && $0.projectId == projectId }) {
                return badRequest("copyFromEditionId")
            }
            let edition = DemoEdition(id: nextEditionId, projectId: projectId, name: name,
                                      isDefault: false, isPublished: false, lastEdited: Date())
            nextEditionId += 1
            editions.append(edition)
            // A new edition starts as a copy of its source, or empty.
            if let source {
                editionBlocks[edition.id] = (editionBlocks[source] ?? []).map { block in
                    var copy = block
                    copy.id = nextBlockId
                    nextBlockId += 1
                    return copy
                }
            } else {
                editionBlocks[edition.id] = []
            }
            return editionCollection(projectId)

        default:
            break
        }

        guard let editionId = path.first.flatMap(Int.init),
              let index = editions.firstIndex(where: { $0.id == editionId && $0.projectId == projectId })
        else { return notFound() }

        switch (method, path.dropFirst().first) {
        case ("PUT", nil):
            guard let name = (fields["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return badRequest("name")
            }
            editions[index].name = name
            return editionCollection(projectId)

        case ("DELETE", nil):
            // A project always keeps somewhere to write.
            guard editions.filter({ $0.projectId == projectId }).count > 1 else {
                return (409, Data(#"{"edition":"That edition cannot be deleted."}"#.utf8))
            }
            let removed = editions.remove(at: index)
            editionBlocks[removed.id] = nil
            // Something has to be the default once the default is gone.
            if removed.isDefault,
               let next = editions.firstIndex(where: { $0.projectId == projectId }) {
                editions[next].isDefault = true
                blocks[projectId] = editionBlocks[editions[next].id] ?? []
            }
            return editionCollection(projectId)

        case ("POST", "set-default"):
            for i in editions.indices where editions[i].projectId == projectId {
                editions[i].isDefault = (editions[i].id == editionId)
            }
            return editionCollection(projectId)

        case ("POST", "set-published"):
            for i in editions.indices where editions[i].projectId == projectId {
                editions[i].isPublished = (editions[i].id == editionId)
            }
            return editionCollection(projectId)

        default:
            return notFound()
        }
    }

    private func editionCollection(_ projectId: Int) -> (Int, Data) {
        let mine = editions.filter { $0.projectId == projectId }
        let items = mine.map { edition -> [String: Any] in
            var links: [String: Any] = [
                "blocks": link("/api/block?projectId=\(projectId)&editionId=\(edition.id)"),
                "editions": link("/api/project/edition?projectId=\(projectId)"),
                "update": link("/api/project/edition/\(edition.id)?projectId=\(projectId)"),
            ]
            // The last edition offers no delete, so the client never shows an
            // action that could only fail.
            if mine.count > 1 {
                links["delete"] = link("/api/project/edition/\(edition.id)?projectId=\(projectId)")
            }
            if !edition.isDefault {
                links["setDefault"] = link("/api/project/edition/\(edition.id)/set-default?projectId=\(projectId)")
            }
            if !edition.isPublished {
                links["setPublished"] = link("/api/project/edition/\(edition.id)/set-published?projectId=\(projectId)")
            }
            return [
                "id": edition.id,
                "name": edition.name,
                "default": edition.isDefault,
                "published": edition.isPublished,
                "lastEdited": iso.string(from: edition.lastEdited),
                "blockCount": (editionBlocks[edition.id] ?? []).count,
                "_links": links,
            ]
        }
        return ok([
            "_embedded": ["scriptEditionResourceList": items],
            "_links": [
                "self": link("/api/project/edition?projectId=\(projectId)"),
                "create": link("/api/project/edition?projectId=\(projectId)"),
                "project": link("/api/project/\(projectId)"),
            ],
        ])
    }

    // MARK: - Song blocks

    /// One lyric line. Keyed by edition, since that is what an edition scopes.
    private struct DemoSongBlock {
        var id: Int
        var order: Int
        var content: String
        var highlight: String?
    }

    /// Splits a song's seeded text into lines the first time its lyric is
    /// asked for. The demo stores songs as text for the list preview; the real
    /// server has had them as blocks all along.
    private func ensureSongBlocks(_ documentId: Int, editionId: Int) {
        guard songBlocks[editionId] == nil else { return }
        guard let (projectId, index) = locateDocument(documentId) else {
            songBlocks[editionId] = []
            return
        }
        let lines = documents[projectId]![index].content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        songBlocks[editionId] = lines.enumerated().map { offset, text in
            let block = DemoSongBlock(id: nextSongBlockId, order: offset + 1, content: text)
            nextSongBlockId += 1
            return block
        }
    }

    /// The edition whose lyric a request means: the one named, else the default.
    private func resolveSongEdition(_ documentId: Int, editionId: Int?) -> Int? {
        ensureSongEditions(documentId)
        if let editionId {
            return songEditions.first { $0.id == editionId && $0.documentId == documentId }?.id
        }
        return songEditions.first { $0.documentId == documentId && $0.isDefault }?.id
    }

    private func routeSongBlock(method: String, path: [String],
                                query: [String: String],
                                fields: [String: Any]) -> (Int, Data) {
        // `trash`, `undo`, `redo` and `undo-redo-status` are siblings of the
        // line resources rather than line ids, so they are picked off before
        // the numeric lookup below — the same shape /api/block uses.
        if path.first == "trash" {
            return routeSongBlockTrash(method: method,
                                       path: Array(path.dropFirst()), query: query)
        }
        if let step = path.first, ["undo", "redo", "undo-redo-status"].contains(step) {
            guard let documentId = query["documentId"].flatMap(Int.init),
                  locateDocument(documentId) != nil,
                  let editionId = resolveSongEdition(documentId,
                                                     editionId: query["editionId"].flatMap(Int.init))
            else { return badRequest("documentId") }
            ensureSongBlocks(documentId, editionId: editionId)
            if step == "undo-redo-status" {
                guard method == "GET" else { return notFound() }
                return ok(songUndoRedoJSON(documentId: documentId, editionId: editionId))
            }
            guard method == "POST" else { return notFound() }
            return applySongHistory(documentId: documentId,
                                    editionId: editionId, undoing: step == "undo")
        }

        switch (method, path.count) {
        case ("GET", 0), ("POST", 0):
            guard let documentId = query["documentId"].flatMap(Int.init),
                  locateDocument(documentId) != nil,
                  let editionId = resolveSongEdition(documentId,
                                                     editionId: query["editionId"].flatMap(Int.init))
            else { return badRequest("documentId") }
            ensureSongBlocks(documentId, editionId: editionId)

            if method == "GET" {
                return songBlockCollection(documentId, editionId: editionId)
            }
            snapshotSong(editionId)
            let block = DemoSongBlock(
                id: nextSongBlockId,
                order: (songBlocks[editionId] ?? []).map(\.order).max().map { $0 + 1 } ?? 1,
                content: fields["content"] as? String ?? "")
            nextSongBlockId += 1
            songBlocks[editionId]?.append(block)
            syncSongText(documentId, editionId: editionId)
            return ok(songBlockJSON(block, documentId: documentId, editionId: editionId))
        default:
            break
        }

        guard let id = path.first.flatMap(Int.init),
              let editionId = songBlocks.first(where: { $0.value.contains { $0.id == id } })?.key,
              let index = songBlocks[editionId]?.firstIndex(where: { $0.id == id }),
              let documentId = songEditions.first(where: { $0.id == editionId })?.documentId
        else { return notFound() }

        switch (method, path.dropFirst().first) {
        case ("PUT", nil):
            snapshotSong(editionId)
            songBlocks[editionId]?[index].content = fields["content"] as? String ?? ""
            syncSongText(documentId, editionId: editionId)
            return ok(songBlockJSON(songBlocks[editionId]![index],
                                    documentId: documentId, editionId: editionId))

        case ("DELETE", nil):
            snapshotSong(editionId)
            trashSongBlock(songBlocks[editionId]![index], editionId: editionId)
            songBlocks[editionId]?.remove(at: index)
            renumberSongBlocks(editionId)
            syncSongText(documentId, editionId: editionId)
            return songBlockCollection(documentId, editionId: editionId)

        case ("POST", "below"):
            snapshotSong(editionId)
            var list = songBlocks[editionId] ?? []
            // Order is assigned by renumbering below, from where it lands in
            // the array; anything set here would only be overwritten.
            let block = DemoSongBlock(id: nextSongBlockId,
                                      order: 0,
                                      content: fields["content"] as? String ?? "")
            nextSongBlockId += 1
            list.insert(block, at: index + 1)
            songBlocks[editionId] = list
            renumberSongBlocks(editionId)
            syncSongText(documentId, editionId: editionId)
            return ok(songBlockJSON(block, documentId: documentId, editionId: editionId))

        case ("POST", "move"):
            guard let position = fields["position"] as? Int else { return badRequest("position") }
            snapshotSong(editionId)
            var list = (songBlocks[editionId] ?? []).sorted { $0.order < $1.order }
            let target = min(max(position - 1, 0), list.count - 1)
            let moved = list.remove(at: index)
            list.insert(moved, at: target)
            songBlocks[editionId] = list
            renumberSongBlocks(editionId)
            syncSongText(documentId, editionId: editionId)
            return songBlockCollection(documentId, editionId: editionId)

        case ("POST", "highlight"):
            snapshotSong(editionId)
            let known = ["YELLOW", "GREEN", "BLUE", "RED", "GRAY"]
            let raw = (fields["highlight"] as? String)?
                .trimmingCharacters(in: .whitespaces).uppercased()
            // An unknown or blank tint clears, as on the server.
            songBlocks[editionId]?[index].highlight =
                (raw.map { known.contains($0) ? $0 : nil } ?? nil)
            return ok(songBlockJSON(songBlocks[editionId]![index],
                                    documentId: documentId, editionId: editionId))

        default:
            return notFound()
        }
    }

    /// Renumbers from the array's current arrangement, deliberately without
    /// sorting first. After an insert or a move the position in the array is
    /// the truth and the stored `order` values are stale — sorting by them
    /// would put the line straight back where it came from, which is exactly
    /// what the first version of this did.
    private func renumberSongBlocks(_ editionId: Int) {
        guard var list = songBlocks[editionId] else { return }
        for index in list.indices { list[index].order = index + 1 }
        songBlocks[editionId] = list
    }

    /// Keeps the document's text in step with its default edition's lines, so
    /// the songs list preview does not go stale while the lyric is edited.
    private func syncSongText(_ documentId: Int, editionId: Int) {
        guard songEditions.first(where: { $0.id == editionId })?.isDefault == true,
              let (projectId, index) = locateDocument(documentId) else { return }
        documents[projectId]?[index].content = (songBlocks[editionId] ?? [])
            .sorted { $0.order < $1.order }
            .map(\.content)
            .joined(separator: "\n")
        documents[projectId]?[index].updatedAt = .now
        if let position = songEditions.firstIndex(where: { $0.id == editionId }) {
            songEditions[position].blockCount = (songBlocks[editionId] ?? []).count
            songEditions[position].lastEdited = .now
        }
    }

    private func songBlockCollection(_ documentId: Int, editionId: Int) -> (Int, Data) {
        let items = (songBlocks[editionId] ?? [])
            .sorted { $0.order < $1.order }
            .map { songBlockJSON($0, documentId: documentId, editionId: editionId) }
        return ok([
            "_embedded": ["songBlockResourceList": items],
            "_links": [
                "self": link("/api/song/block?documentId=\(documentId)&editionId=\(editionId)"),
                "create": link("/api/song/block?documentId=\(documentId)&editionId=\(editionId)"),
                "song": link("/api/document/\(documentId)"),
                "versions": link("/api/song/version?documentId=\(documentId)"),
                "trash": link("/api/song/block/trash?documentId=\(documentId)&editionId=\(editionId)"),
                "undoRedoStatus": link(
                    "/api/song/block/undo-redo-status?documentId=\(documentId)&editionId=\(editionId)"),
            ],
        ])
    }

    // MARK: - Deleted lines, and stepping back

    /// A deleted lyric line. Like a screenplay element it comes back as a new
    /// line rather than the original id, which is what the server does too.
    private struct DeletedDemoSongBlock {
        var id: Int
        var block: DemoSongBlock
        var deletedAt: Date
    }

    private func trashSongBlock(_ block: DemoSongBlock, editionId: Int) {
        deletedSongBlocks[editionId, default: []].append(
            DeletedDemoSongBlock(id: nextDeletedSongBlockId, block: block, deletedAt: Date()))
        nextDeletedSongBlockId += 1
    }

    private func routeSongBlockTrash(method: String, path: [String],
                                     query: [String: String]) -> (Int, Data) {
        guard let documentId = query["documentId"].flatMap(Int.init),
              locateDocument(documentId) != nil,
              let editionId = resolveSongEdition(documentId,
                                                 editionId: query["editionId"].flatMap(Int.init))
        else { return badRequest("documentId") }

        if method == "GET", path.isEmpty {
            return songTrashCollection(documentId, editionId: editionId)
        }

        guard let deletedId = path.first.flatMap(Int.init),
              let index = deletedSongBlocks[editionId]?.firstIndex(where: { $0.id == deletedId })
        else { return notFound() }

        switch (method, path.dropFirst().first) {
        case ("POST", "restore"):
            let record = deletedSongBlocks[editionId]!.remove(at: index)
            snapshotSong(editionId)
            var restored = record.block
            restored.id = nextSongBlockId
            nextSongBlockId += 1
            var list = (songBlocks[editionId] ?? []).sorted { $0.order < $1.order }
            // Back where it was, clamped in case the lyric has since shrunk.
            let target = min(max(restored.order - 1, 0), list.count)
            list.insert(restored, at: target)
            songBlocks[editionId] = list
            renumberSongBlocks(editionId)
            syncSongText(documentId, editionId: editionId)
            return songTrashCollection(documentId, editionId: editionId)

        case ("DELETE", nil):
            deletedSongBlocks[editionId]?.remove(at: index)
            return songTrashCollection(documentId, editionId: editionId)

        default:
            return notFound()
        }
    }

    private func songTrashCollection(_ documentId: Int, editionId: Int) -> (Int, Data) {
        let base = "/api/song/block/trash?documentId=\(documentId)&editionId=\(editionId)"
        let items = (deletedSongBlocks[editionId] ?? [])
            .sorted { $0.deletedAt > $1.deletedAt }
            .map { record -> [String: Any] in
                let content = record.block.content.trimmingCharacters(in: .whitespacesAndNewlines)
                var json: [String: Any] = [
                    "id": record.id,
                    "content": record.block.content,
                    "blank": content.isEmpty,
                    "deletedAt": iso.string(from: record.deletedAt),
                    "purgeAt": iso.string(from: record.deletedAt.addingTimeInterval(
                        Double(Self.trashRetentionDays) * 86_400)),
                    "_links": [
                        "restore": link("/api/song/block/trash/\(record.id)/restore"
                                        + "?documentId=\(documentId)&editionId=\(editionId)"),
                        "purge": link("/api/song/block/trash/\(record.id)"
                                      + "?documentId=\(documentId)&editionId=\(editionId)"),
                        "trash": link(base),
                    ],
                ]
                if let highlight = record.block.highlight { json["highlight"] = highlight }
                return json
            }
        return ok([
            "_embedded": ["deletedSongBlockResourceList": items],
            "_links": [
                "self": link(base),
                "songBlocks": link("/api/song/block?documentId=\(documentId)&editionId=\(editionId)"),
                "song": link("/api/document/\(documentId)"),
            ],
        ])
    }

    private func snapshotSong(_ editionId: Int) {
        songUndoStacks[editionId, default: []].append(songBlocks[editionId] ?? [])
        if songUndoStacks[editionId]!.count > 50 {
            songUndoStacks[editionId]!.removeFirst()
        }
        songRedoStacks[editionId] = []
    }

    private func applySongHistory(documentId: Int, editionId: Int, undoing: Bool) -> (Int, Data) {
        let popped = undoing
            ? songUndoStacks[editionId]?.popLast()
            : songRedoStacks[editionId]?.popLast()
        // An empty stack is not an error on the server either: the lyric comes
        // back unchanged and the status link is where a client learns why.
        if let state = popped {
            let current = songBlocks[editionId] ?? []
            if undoing {
                songRedoStacks[editionId, default: []].append(current)
            } else {
                songUndoStacks[editionId, default: []].append(current)
            }
            songBlocks[editionId] = state
            syncSongText(documentId, editionId: editionId)
        }
        return songBlockCollection(documentId, editionId: editionId)
    }

    private func songUndoRedoJSON(documentId: Int, editionId: Int) -> [String: Any] {
        let canUndo = !(songUndoStacks[editionId] ?? []).isEmpty
        let canRedo = !(songRedoStacks[editionId] ?? []).isEmpty
        let suffix = "documentId=\(documentId)&editionId=\(editionId)"
        var links: [String: Any] = [
            "self": link("/api/song/block/undo-redo-status?" + suffix),
            "songBlocks": link("/api/song/block?" + suffix),
            "song": link("/api/document/\(documentId)"),
        ]
        if canUndo { links["undo"] = link("/api/song/block/undo?" + suffix) }
        if canRedo { links["redo"] = link("/api/song/block/redo?" + suffix) }
        return ["canUndo": canUndo, "canRedo": canRedo, "_links": links]
    }

    private func songBlockJSON(_ block: DemoSongBlock,
                               documentId: Int, editionId: Int) -> [String: Any] {
        var json: [String: Any] = [
            "id": block.id,
            "documentId": documentId,
            "order": block.order,
            "content": block.content,
            "_links": [
                "self": link("/api/song/block/\(block.id)"),
                "update": link("/api/song/block/\(block.id)"),
                "delete": link("/api/song/block/\(block.id)"),
                "createBelow": link("/api/song/block/\(block.id)/below"),
                "move": link("/api/song/block/\(block.id)/move"),
                "setHighlight": link("/api/song/block/\(block.id)/highlight"),
                "songBlocks": link("/api/song/block?documentId=\(documentId)&editionId=\(editionId)"),
                "song": link("/api/document/\(documentId)"),
            ],
        ]
        if let highlight = block.highlight { json["highlight"] = highlight }
        return json
    }

    // MARK: - Song editions

    /// A named edition of a song. Songs are lyric blocks on the server, so an
    /// edition scopes those; the demo tracks the count rather than the lines,
    /// since this client edits a song as plain text and never reads its blocks.
    private struct DemoSongEdition {
        var id: Int
        var documentId: Int
        var name: String
        var isDefault: Bool
        var isPublished: Bool
        var lastEdited: Date
        var blockCount: Int
    }

    /// Every song has at least one edition, created on first sight rather than
    /// up front — the server's ensureDefaultEdition does the same.
    private func ensureSongEditions(_ documentId: Int) {
        guard !songEditions.contains(where: { $0.documentId == documentId }) else { return }
        songEditions.append(DemoSongEdition(
            id: nextSongEditionId, documentId: documentId, name: "Original",
            isDefault: true, isPublished: true, lastEdited: Date(), blockCount: 0))
        nextSongEditionId += 1
    }

    private func routeSongEdition(method: String, path: [String],
                                  query: [String: String],
                                  fields: [String: Any]) -> (Int, Data) {
        guard let documentId = query["documentId"].flatMap(Int.init),
              locateDocument(documentId) != nil else { return badRequest("documentId") }
        ensureSongEditions(documentId)

        switch (method, path.count) {
        case ("GET", 0):
            return songEditionCollection(documentId)

        case ("POST", 0):
            guard let name = (fields["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return badRequest("name")
            }
            let source = fields["copyFromEditionId"] as? Int
            if let source,
               !songEditions.contains(where: { $0.id == source && $0.documentId == documentId }) {
                return badRequest("copyFromEditionId")
            }
            let copied = source.flatMap { id in
                songEditions.first { $0.id == id }?.blockCount
            } ?? 0
            songEditions.append(DemoSongEdition(
                id: nextSongEditionId, documentId: documentId, name: name,
                isDefault: false, isPublished: false, lastEdited: Date(), blockCount: copied))
            nextSongEditionId += 1
            return songEditionCollection(documentId)

        default:
            break
        }

        guard let editionId = path.first.flatMap(Int.init),
              let index = songEditions.firstIndex(where: {
                  $0.id == editionId && $0.documentId == documentId
              }) else { return notFound() }

        switch (method, path.dropFirst().first) {
        case ("PUT", nil):
            guard let name = (fields["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return badRequest("name")
            }
            songEditions[index].name = name
            return songEditionCollection(documentId)

        case ("DELETE", nil):
            // A song always keeps somewhere to write.
            guard songEditions.filter({ $0.documentId == documentId }).count > 1 else {
                return (409, Data(#"{"edition":"That edition cannot be deleted."}"#.utf8))
            }
            let removed = songEditions.remove(at: index)
            if removed.isDefault,
               let next = songEditions.firstIndex(where: { $0.documentId == documentId }) {
                songEditions[next].isDefault = true
            }
            return songEditionCollection(documentId)

        case ("POST", "set-default"):
            for i in songEditions.indices where songEditions[i].documentId == documentId {
                songEditions[i].isDefault = (songEditions[i].id == editionId)
            }
            return songEditionCollection(documentId)

        case ("POST", "set-published"):
            for i in songEditions.indices where songEditions[i].documentId == documentId {
                songEditions[i].isPublished = (songEditions[i].id == editionId)
            }
            return songEditionCollection(documentId)

        default:
            return notFound()
        }
    }

    private func songEditionCollection(_ documentId: Int) -> (Int, Data) {
        let mine = songEditions.filter { $0.documentId == documentId }
        let items = mine.map { edition -> [String: Any] in
            var links: [String: Any] = [
                "songBlocks": link("/api/song/block?documentId=\(documentId)&editionId=\(edition.id)"),
                "editions": link("/api/song/edition?documentId=\(documentId)"),
                "update": link("/api/song/edition/\(edition.id)?documentId=\(documentId)"),
            ]
            if mine.count > 1 {
                links["delete"] = link("/api/song/edition/\(edition.id)?documentId=\(documentId)")
            }
            if !edition.isDefault {
                links["setDefault"] = link("/api/song/edition/\(edition.id)/set-default?documentId=\(documentId)")
            }
            if !edition.isPublished {
                links["setPublished"] = link("/api/song/edition/\(edition.id)/set-published?documentId=\(documentId)")
            }
            return [
                "id": edition.id,
                "name": edition.name,
                "default": edition.isDefault,
                "published": edition.isPublished,
                "lastEdited": iso.string(from: edition.lastEdited),
                "blockCount": edition.blockCount,
                "_links": links,
            ]
        }
        return ok([
            "_embedded": ["songEditionResourceList": items],
            "_links": [
                "self": link("/api/song/edition?documentId=\(documentId)"),
                "create": link("/api/song/edition?documentId=\(documentId)"),
                "document": link("/api/document/\(documentId)"),
            ],
        ])
    }

    // MARK: - Trash

    /// A deleted screenplay, kept whole so a restore returns everything.
    private struct TrashedDemoProject {
        var project: DemoProject
        var deletedAt: Date
        var blocks: [DemoBlock]
        var people: [DemoPerson]
        var documents: [DemoDocument]
    }

    /// A deleted element. Restoring makes a *new* element at the old position —
    /// the original id does not come back, matching the server.
    private struct DeletedDemoBlock {
        var id: Int
        var block: DemoBlock
        var deletedAt: Date
    }

    /// A deleted song or note. Unlike an element, it keeps its id: the server
    /// restores the document itself rather than re-creating it.
    private struct DeletedDemoDocument {
        var document: DemoDocument
        var deletedAt: Date
    }

    private func routeDocumentTrash(method: String, path: [String],
                                    query: [String: String]) -> (Int, Data) {
        guard let projectId = query["projectId"].flatMap(Int.init),
              documents[projectId] != nil else { return badRequest("projectId") }

        if method == "GET", path.isEmpty {
            return documentTrashCollection(projectId)
        }

        guard let documentId = path.first.flatMap(Int.init),
              let index = deletedDocuments[projectId]?.firstIndex(where: {
                  $0.document.id == documentId
              }) else { return notFound() }

        switch (method, path.dropFirst().first) {
        case ("POST", "restore"):
            let record = deletedDocuments[projectId]!.remove(at: index)
            documents[projectId]?.append(record.document)
            documents[projectId]?.sort { $0.sortOrder < $1.sortOrder }
            return documentTrashCollection(projectId)

        case ("DELETE", nil):
            deletedDocuments[projectId]?.remove(at: index)
            return documentTrashCollection(projectId)

        default:
            return notFound()
        }
    }

    private func documentTrashCollection(_ projectId: Int) -> (Int, Data) {
        let items = (deletedDocuments[projectId] ?? [])
            .sorted { $0.deletedAt > $1.deletedAt }
            .map { record -> [String: Any] in
                let id = record.document.id
                var json: [String: Any] = [
                    "id": id,
                    "title": record.document.title,
                    "documentType": record.document.documentType,
                    "documentTypeLabel": record.document.documentType == "SONG" ? "Song" : "Note",
                    "deletedAt": iso.string(from: record.deletedAt),
                    "purgesAt": iso.string(from: record.deletedAt.addingTimeInterval(
                        Double(Self.trashRetentionDays) * 86_400)),
                    "_links": [
                        "restore": link("/api/document/trash/\(id)/restore?projectId=\(projectId)"),
                        "purge": link("/api/document/trash/\(id)?projectId=\(projectId)"),
                        "trash": link("/api/document/trash?projectId=\(projectId)"),
                    ],
                ]
                let preview = record.document.content
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !preview.isEmpty { json["preview"] = String(preview.prefix(120)) }
                return json
            }
        return ok([
            "_embedded": ["deletedDocumentResourceList": items],
            "_links": [
                "self": link("/api/document/trash?projectId=\(projectId)"),
                "documents": link("/api/document?projectId=\(projectId)"),
                "project": link("/api/project/\(projectId)"),
            ],
        ])
    }

    /// Elements are recoverable for thirty days, as on the server.
    private static let trashRetentionDays = 30

    private func trashBlock(_ block: DemoBlock, projectId: Int) {
        deletedBlocks[projectId, default: []].append(
            DeletedDemoBlock(id: nextDeletedBlockId, block: block, deletedAt: Date()))
        nextDeletedBlockId += 1
    }

    private func routeBlockTrash(method: String, path: [String],
                                 query: [String: String]) -> (Int, Data) {
        guard let projectId = query["projectId"].flatMap(Int.init),
              blocks[projectId] != nil else { return badRequest("projectId") }

        if method == "GET", path.isEmpty {
            return blockTrashCollection(projectId)
        }

        guard let deletedId = path.first.flatMap(Int.init),
              let index = deletedBlocks[projectId]?.firstIndex(where: { $0.id == deletedId })
        else { return notFound() }

        switch (method, path.dropFirst().first) {
        case ("POST", "restore"):
            let record = deletedBlocks[projectId]!.remove(at: index)
            snapshot(projectId)
            var restored = record.block
            restored.id = nextBlockId
            nextBlockId += 1
            var list = blocks[projectId] ?? []
            // Back at the position it held, clamped in case the script shrank.
            let target = min(max(restored.order - 1, 0), list.count)
            list.insert(restored, at: target)
            for i in list.indices { list[i].order = i + 1 }
            blocks[projectId] = list
            touch(projectId)
            return blockTrashCollection(projectId)

        case ("DELETE", nil):
            deletedBlocks[projectId]?.remove(at: index)
            return blockTrashCollection(projectId)

        default:
            return notFound()
        }
    }

    private func blockTrashCollection(_ projectId: Int) -> (Int, Data) {
        let items = (deletedBlocks[projectId] ?? [])
            .sorted { $0.deletedAt > $1.deletedAt }
            .map { record -> [String: Any] in
                let content = record.block.content.trimmingCharacters(in: .whitespacesAndNewlines)
                var json: [String: Any] = [
                    "id": record.id,
                    "empty": content.isEmpty,
                    "typeLabel": record.block.type.capitalized,
                    "deletedAt": iso.string(from: record.deletedAt),
                    "purgeAt": iso.string(from: record.deletedAt.addingTimeInterval(
                        Double(Self.trashRetentionDays) * 86_400)),
                    "deletedByName": "You",
                    "_links": [
                        "restore": link("/api/block/trash/\(record.id)/restore?projectId=\(projectId)"),
                        "purge": link("/api/block/trash/\(record.id)?projectId=\(projectId)"),
                        "trash": link("/api/block/trash?projectId=\(projectId)"),
                    ],
                ]
                if !content.isEmpty { json["preview"] = String(content.prefix(120)) }
                return json
            }
        return ok([
            "_embedded": ["deletedBlockResourceList": items],
            "_links": [
                "self": link("/api/block/trash?projectId=\(projectId)"),
                "blocks": link("/api/block?projectId=\(projectId)"),
                "project": link("/api/project/\(projectId)"),
            ],
        ])
    }

    private func routeProjectTrash(method: String, path: [String]) -> (Int, Data) {
        if path.isEmpty {
            switch method {
            case "GET":
                return projectTrashCollection()
            case "DELETE":
                trashedProjects.removeAll()
                return projectTrashCollection()
            default:
                return notFound()
            }
        }

        guard let projectId = path.first.flatMap(Int.init),
              let index = trashedProjects.firstIndex(where: { $0.project.id == projectId })
        else { return notFound() }

        switch (method, path.dropFirst().first) {
        case ("POST", "restore"):
            let record = trashedProjects.remove(at: index)
            projects.append(record.project)
            projects.sort { $0.id < $1.id }
            blocks[record.project.id] = record.blocks
            people[record.project.id] = record.people
            documents[record.project.id] = record.documents
            return projectTrashCollection()

        case ("DELETE", nil):
            trashedProjects.remove(at: index)
            return projectTrashCollection()

        default:
            return notFound()
        }
    }

    private func projectTrashCollection() -> (Int, Data) {
        let items = trashedProjects
            .sorted { $0.deletedAt > $1.deletedAt }
            .map { record -> [String: Any] in
                [
                    "id": record.project.id,
                    "title": record.project.title,
                    "deletedAt": iso.string(from: record.deletedAt),
                    "_links": [
                        "restore": link("/api/project/trash/\(record.project.id)/restore"),
                        "purge": link("/api/project/trash/\(record.project.id)"),
                        "trash": link("/api/project/trash"),
                    ],
                ]
            }
        var links: [String: Any] = [
            "self": link("/api/project/trash"),
            "projects": link("/api/project"),
        ]
        if !items.isEmpty {
            links["emptyTrash"] = link("/api/project/trash")
        }
        return ok(["_embedded": ["trashedProjectResourceList": items], "_links": links])
    }

    private func projectCollection() -> (Int, Data) {
        var links: [String: Any] = [
            "self": link("/api/project"),
            "importProject": link("/api/project/import"),
            "trash": link("/api/project/trash"),
        ]
        // Nothing to bundle from an empty list, so the rel goes away with the
        // last project — the same rule the server applies.
        if !projects.isEmpty {
            links["exportProjects"] = link("/api/project/export-projects")
        }
        return ok(["_embedded": ["projectResourceList": projects.map(projectJSON)],
                   "_links": links])
    }

    // MARK: - Version history

    /// A saved snapshot. Holds the blocks themselves, so restoring is just
    /// putting them back.
    private struct DemoVersion {
        var id: Int
        var label: String?
        var createdAt: Date
        var autoSave: Bool
        var blocks: [DemoBlock]
        var sceneCount: Int
        var blockCount: Int
    }

    private func routeVersion(method: String, path: [String],
                              query: [String: String],
                              fields: [String: Any]) -> (Int, Data) {
        switch (method, path.count) {
        case ("GET", 0):
            guard let projectId = query["projectId"].flatMap(Int.init),
                  blocks[projectId] != nil else { return badRequest("projectId") }
            return versionCollection(projectId)

        case ("POST", 0):
            guard let projectId = query["projectId"].flatMap(Int.init),
                  blocks[projectId] != nil else { return badRequest("projectId") }
            let label = (fields["label"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let version = recordVersion(projectId,
                                        label: (label?.isEmpty ?? true) ? "Version" : label,
                                        autoSave: false)
            return ok(versionJSON(version, projectId: projectId))

        default:
            break
        }

        guard let versionId = path.first.flatMap(Int.init),
              let projectId = query["projectId"].flatMap(Int.init),
              let index = versions[projectId]?.firstIndex(where: { $0.id == versionId })
        else { return notFound() }

        switch (method, path.dropFirst().first) {
        case ("GET", nil):
            return ok(versionJSON(versions[projectId]![index], projectId: projectId))

        case ("POST", "restore"):
            // Restoring snapshots the current state first, so nothing is lost
            // by rolling back — the same promise the server makes.
            _ = recordVersion(projectId, label: "Before restore", autoSave: true)
            blocks[projectId] = versions[projectId]![index].blocks
            snapshot(projectId)
            touch(projectId)
            return versionCollection(projectId)

        case ("DELETE", nil):
            versions[projectId]?.remove(at: index)
            return versionCollection(projectId)

        default:
            return notFound()
        }
    }

    @discardableResult
    private func recordVersion(_ projectId: Int, label: String?, autoSave: Bool) -> DemoVersion {
        let current = blocks[projectId] ?? []
        let version = DemoVersion(
            id: nextVersionId,
            label: label,
            createdAt: Date(),
            autoSave: autoSave,
            blocks: current,
            sceneCount: current.filter { $0.type == "SCENE" }.count,
            blockCount: current.count)
        nextVersionId += 1
        versions[projectId, default: []].append(version)
        return version
    }

    private func versionCollection(_ projectId: Int) -> (Int, Data) {
        let items = (versions[projectId] ?? [])
            .sorted { $0.createdAt > $1.createdAt }
            .map { versionJSON($0, projectId: projectId) }
        return ok([
            "_embedded": ["projectVersionResourceList": items],
            "_links": [
                "self": link("/api/project/version?projectId=\(projectId)"),
                "create": link("/api/project/version?projectId=\(projectId)"),
                "project": link("/api/project/\(projectId)"),
            ],
        ])
    }

    private func versionJSON(_ version: DemoVersion, projectId: Int) -> [String: Any] {
        var json: [String: Any] = [
            "id": version.id,
            "createdAt": iso.string(from: version.createdAt),
            "autoSave": version.autoSave,
            "sceneCount": version.sceneCount,
            "blockCount": version.blockCount,
            "characterCount": (people[projectId] ?? []).count,
            "_links": [
                "self": link("/api/project/version/\(version.id)?projectId=\(projectId)"),
                "versions": link("/api/project/version?projectId=\(projectId)"),
                "restore": link("/api/project/version/\(version.id)/restore?projectId=\(projectId)"),
                "delete": link("/api/project/version/\(version.id)?projectId=\(projectId)"),
                "project": link("/api/project/\(projectId)"),
            ],
        ]
        if let label = version.label { json["label"] = label }
        return json
    }

    // MARK: - Song versions

    /// A song's snapshot history, kept per document. Mirrors the project one but
    /// counts lyric lines instead of scenes, which is what the shared history
    /// view shows for a song.
    private struct DemoSongVersion {
        var id: Int
        var label: String?
        var title: String
        var createdAt: Date
        var autoSave: Bool
        var lines: [DemoSongBlock]
    }

    private var songVersions: [Int: [DemoSongVersion]] = [:]

    private func routeSongVersion(method: String, path: [String],
                                  query: [String: String],
                                  fields: [String: Any]) -> (Int, Data) {
        guard let documentId = query["documentId"].flatMap(Int.init) else {
            return badRequest("documentId")
        }
        switch (method, path.count) {
        case ("GET", 0):
            return songVersionCollection(documentId)
        case ("POST", 0):
            let label = (fields["label"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            recordSongVersion(documentId,
                              label: (label?.isEmpty ?? true) ? "Version" : label,
                              autoSave: false)
            return songVersionCollection(documentId)
        default:
            break
        }

        guard let versionId = path.first.flatMap(Int.init),
              let index = songVersions[documentId]?.firstIndex(where: { $0.id == versionId })
        else { return notFound() }

        switch (method, path.dropFirst().first) {
        case ("POST", "restore"):
            recordSongVersion(documentId, label: "Before restore", autoSave: true)
            if let editionId = defaultSongEditionId(for: documentId) {
                songBlocks[editionId] = songVersions[documentId]![index].lines
            }
            return songVersionCollection(documentId)
        case ("DELETE", nil):
            songVersions[documentId]?.remove(at: index)
            return songVersionCollection(documentId)
        default:
            return notFound()
        }
    }

    /// The edition whose lines a song version snapshots — the default one, which
    /// is what a single-edition song always resolves to.
    private func defaultSongEditionId(for documentId: Int) -> Int? {
        songEditions.first { $0.documentId == documentId }?.id
    }

    private func recordSongVersion(_ documentId: Int, label: String?, autoSave: Bool) {
        let lines = defaultSongEditionId(for: documentId).flatMap { songBlocks[$0] } ?? []
        let title = documents.values.flatMap { $0 }
            .first { $0.id == documentId }?.title ?? "Song"
        let version = DemoSongVersion(
            id: nextVersionId, label: label, title: title,
            createdAt: Date(), autoSave: autoSave, lines: lines)
        nextVersionId += 1
        songVersions[documentId, default: []].append(version)
    }

    private func songVersionCollection(_ documentId: Int) -> (Int, Data) {
        let items = (songVersions[documentId] ?? [])
            .sorted { $0.createdAt > $1.createdAt }
            .map { songVersionJSON($0, documentId: documentId) }
        return ok([
            "_embedded": ["songVersionResourceList": items],
            "_links": [
                "self": link("/api/song/version?documentId=\(documentId)"),
                "create": link("/api/song/version?documentId=\(documentId)"),
                "song": link("/api/document/\(documentId)"),
            ],
        ])
    }

    private func songVersionJSON(_ version: DemoSongVersion, documentId: Int) -> [String: Any] {
        var json: [String: Any] = [
            "id": version.id,
            "title": version.title,
            "createdAt": iso.string(from: version.createdAt),
            "autoSave": version.autoSave,
            "lineCount": version.lines.count,
            "_links": [
                "self": link("/api/song/version/\(version.id)?documentId=\(documentId)"),
                "versions": link("/api/song/version?documentId=\(documentId)"),
                "restore": link("/api/song/version/\(version.id)/restore?documentId=\(documentId)"),
                "delete": link("/api/song/version/\(version.id)?documentId=\(documentId)"),
                "song": link("/api/document/\(documentId)"),
            ],
        ]
        if let label = version.label { json["label"] = label }
        return json
    }

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

    // MARK: - Teams

    private struct DemoTeam {
        var id: Int
        var name: String
    }

    /// Seeded with the team every demo project already shows a badge for, so the
    /// list is not empty on first open.
    private lazy var teamsStore: [DemoTeam] = [DemoTeam(id: 1, name: "Demo")]
    private lazy var nextTeamId = 2

    private func routeTeam(method: String, path: [String],
                           query: [String: String],
                           fields: [String: Any]) -> (Int, Data) {
        switch (method, path.count) {
        case ("GET", 0):
            return teamCollection()
        case ("POST", 0):
            guard let name = (fields["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return badRequest("name")
            }
            let team = DemoTeam(id: nextTeamId, name: name)
            nextTeamId += 1
            teamsStore.append(team)
            return ok(teamJSON(team))
        default:
            break
        }

        guard let id = path.first.flatMap(Int.init),
              let index = teamsStore.firstIndex(where: { $0.id == id }) else { return notFound() }

        switch (method, path.dropFirst().first) {
        case ("GET", nil):
            return ok(teamJSON(teamsStore[index]))
        case ("PUT", nil):
            guard let name = (fields["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return badRequest("name")
            }
            teamsStore[index].name = name
            return ok(teamJSON(teamsStore[index]))
        case ("PUT", "productions"):
            // The demo does not re-badge its projects, so this just acknowledges
            // the assignment; the point offline is that the flow completes.
            return ok(teamJSON(teamsStore[index]))
        case ("DELETE", nil):
            let removed = teamsStore.remove(at: index)
            return ok(teamJSON(removed))
        default:
            return notFound()
        }
    }

    private func teamCollection() -> (Int, Data) {
        let items = teamsStore
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { teamJSON($0) }
        return ok([
            "_embedded": ["teamResourceList": items],
            "_links": ["self": link("/api/team")],
        ])
    }

    private func teamJSON(_ team: DemoTeam) -> [String: Any] {
        [
            "id": team.id,
            "name": team.name,
            "_links": [
                "self": link("/api/team/\(team.id)"),
                "teams": link("/api/team"),
                "update": link("/api/team/\(team.id)"),
                "assignProductions": link("/api/team/\(team.id)/productions"),
                "delete": link("/api/team/\(team.id)"),
            ],
        ]
    }

    // MARK: - Users (admin)

    private struct DemoUser {
        var id: Int
        var username: String
        var firstName: String
        var lastName: String
        var team: String?
        var admin: Bool
        var director: Bool
        var producer: Bool
        var writer: Bool
        var actor: Bool
        var crew: Bool
        var directorOfPhotography: Bool
        var castingDirector: Bool
        var viewCasting: Bool
        var developer: Bool
        var enabled: Bool
    }

    /// Seeded with the demo's own admin plus a couple of ordinary accounts, so
    /// the list is not empty and the different role summaries are visible. The
    /// admin (id 1) stands in for the signed-in user, so — like the server — it
    /// carries no `delete` link: an admin cannot remove their own account.
    private lazy var usersStore: [DemoUser] = [
        DemoUser(id: 1, username: "demo", firstName: "Demo", lastName: "Admin",
                 team: "Demo", admin: true, director: false, producer: false,
                 writer: false, actor: false, crew: false,
                 directorOfPhotography: false, castingDirector: false,
                 viewCasting: false, developer: false, enabled: true),
        DemoUser(id: 2, username: "wes", firstName: "Wes", lastName: "Halloran",
                 team: "Demo", admin: false, director: true, producer: false,
                 writer: true, actor: false, crew: false,
                 directorOfPhotography: false, castingDirector: false,
                 viewCasting: true, developer: false, enabled: true),
        DemoUser(id: 3, username: "rin", firstName: "Rin", lastName: "Kobayashi",
                 team: "Demo", admin: false, director: false, producer: false,
                 writer: false, actor: true, crew: false,
                 directorOfPhotography: false, castingDirector: false,
                 viewCasting: false, developer: false, enabled: false),
    ]
    private lazy var nextUserId = 4

    private func routeUser(method: String, path: [String],
                           query: [String: String],
                           fields: [String: Any]) -> (Int, Data) {
        switch (method, path.count) {
        case ("GET", 0):
            return userCollection()
        case ("POST", 0):
            guard let username = (fields["username"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty else {
                return badRequest("username")
            }
            guard let password = fields["password"] as? String, password.count >= 8 else {
                return badRequest("password")
            }
            var user = DemoUser(id: nextUserId, username: username,
                                firstName: fields["firstName"] as? String ?? "",
                                lastName: fields["lastName"] as? String ?? "",
                                team: (fields["team"] as? String),
                                admin: false, director: false, producer: false,
                                writer: false, actor: false, crew: false,
                                directorOfPhotography: false, castingDirector: false,
                                viewCasting: false, developer: false, enabled: true)
            applyRoles(&user, from: fields)
            nextUserId += 1
            usersStore.append(user)
            return ok(userJSON(user))
        default:
            break
        }

        guard let id = path.first.flatMap(Int.init),
              let index = usersStore.firstIndex(where: { $0.id == id }) else { return notFound() }

        switch (method, path.dropFirst().first) {
        case ("GET", nil):
            return ok(userJSON(usersStore[index]))
        case ("PUT", nil):
            if let value = (fields["username"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                usersStore[index].username = value
            }
            if let value = fields["firstName"] as? String { usersStore[index].firstName = value }
            if let value = fields["lastName"] as? String { usersStore[index].lastName = value }
            if fields.keys.contains("team") { usersStore[index].team = fields["team"] as? String }
            applyRoles(&usersStore[index], from: fields)
            return ok(userJSON(usersStore[index]))
        case ("DELETE", nil):
            // The signed-in admin (id 1) cannot delete their own account, matching
            // the server's guard.
            guard id != 1 else {
                return (400, (try? JSONSerialization.data(
                    withJSONObject: ["message": "You cannot delete your own account."]))
                    ?? Data("{}".utf8))
            }
            let removed = usersStore.remove(at: index)
            return ok(userJSON(removed))
        default:
            return notFound()
        }
    }

    private func applyRoles(_ user: inout DemoUser, from fields: [String: Any]) {
        if let value = fields["admin"] as? Bool { user.admin = value }
        if let value = fields["director"] as? Bool { user.director = value }
        if let value = fields["producer"] as? Bool { user.producer = value }
        if let value = fields["writer"] as? Bool { user.writer = value }
        if let value = fields["actor"] as? Bool { user.actor = value }
        if let value = fields["crew"] as? Bool { user.crew = value }
        if let value = fields["directorOfPhotography"] as? Bool { user.directorOfPhotography = value }
        if let value = fields["castingDirector"] as? Bool { user.castingDirector = value }
        if let value = fields["viewCasting"] as? Bool { user.viewCasting = value }
        if let value = fields["developer"] as? Bool { user.developer = value }
    }

    private func userCollection() -> (Int, Data) {
        let items = usersStore
            .sorted { ($0.firstName + $0.lastName)
                .localizedCaseInsensitiveCompare($1.firstName + $1.lastName) == .orderedAscending }
            .map { userJSON($0) }
        return ok([
            "_embedded": ["userResourceList": items],
            "_links": ["self": link("/api/user")],
        ])
    }

    private func userJSON(_ user: DemoUser) -> [String: Any] {
        var links: [String: Any] = [
            "self": link("/api/user/\(user.id)"),
            "users": link("/api/user"),
            "update": link("/api/user/\(user.id)"),
        ]
        // The signed-in admin's own account carries no delete link.
        if user.id != 1 {
            links["delete"] = link("/api/user/\(user.id)")
        }
        var json: [String: Any] = [
            "id": user.id,
            "username": user.username,
            "firstName": user.firstName,
            "lastName": user.lastName,
            "admin": user.admin,
            "director": user.director,
            "producer": user.producer,
            "writer": user.writer,
            "actor": user.actor,
            "crew": user.crew,
            "directorOfPhotography": user.directorOfPhotography,
            "castingDirector": user.castingDirector,
            "viewCasting": user.viewCasting,
            "developer": user.developer,
            "enabled": user.enabled,
            "_links": links,
        ]
        if let team = user.team { json["team"] = team }
        return json
    }

    private func rootJSON() -> [String: Any] {
        // `teams` and `users` are advertised here as they are on the server for a
        // user allowed to manage them; the demo's single account stands in for
        // that admin.
        //
        // Password recovery is deliberately absent, and is the one rel the real
        // server has that this does not. It rides on the 401 challenge rather
        // than on any document — and the demo never challenges anyone, because
        // there is no sign-in to fail. There is nothing here to recover from.
        ["_links": ["self": link("/api"),
                    "projects": link("/api/project"),
                    "actors": link("/api/actor"),
                    "capitalizationPreferences": link("/api/preferences/capitalization"),
                    // Your own account: offered to anyone signed in, unlike the
                    // admin-only `users` and `teams`.
                    "account": link("/api/account"),
                    "teams": link("/api/team"),
                    "users": link("/api/user")]]
    }

    /// Who can already see a project. Built from the same accounts the Users
    /// view lists, so the two agree — and, like the server, it is the roles and
    /// the team that put someone here, not an invitation. A disabled account is
    /// left out: it cannot sign in, so it cannot be reading anything.
    private func projectAccess(_ projectId: Int) -> (Int, Data) {
        let people = usersStore
            .filter(\.enabled)
            .map { user -> (name: String, why: String, canEdit: Bool) in
                let name = "\(user.firstName) \(user.lastName)"
                let canEdit = user.admin || user.writer
                let why: String
                if user.admin {
                    why = "Admin"
                } else if user.writer {
                    why = "Writer"
                } else if user.director {
                    why = "Director"
                } else if let team = user.team {
                    why = "On the \(team) team"
                } else {
                    why = "Has access"
                }
                return (name, why, canEdit)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { person -> [String: Any] in
                [
                    "displayName": person.name,
                    "accessLabel": person.why,
                    "canEdit": person.canEdit,
                    "permissionLabel": person.canEdit ? "Can edit" : "View only",
                ]
            }
        return ok([
            "_embedded": ["projectAccessUserResourceList": people],
            "_links": [
                "self": link("/api/project/\(projectId)/access"),
                "project": link("/api/project/\(projectId)"),
            ],
        ])
    }

    private func projectJSON(_ project: DemoProject) -> [String: Any] {
        var json: [String: Any] = [
            "id": project.id,
            "title": project.title,
            "lastEdited": iso.string(from: project.lastEdited),
            "teams": ["Demo"],
            "default": project.id == defaultProjectId,
            "_links": [
                "self": link("/api/project/\(project.id)"),
                "update": link("/api/project/\(project.id)"),
                "delete": link("/api/project/\(project.id)"),
                "toggleDefault": link("/api/project/\(project.id)/toggleDefault"),
                "blocks": link("/api/block?projectId=\(project.id)"),
                "characters": link("/api/person?projectId=\(project.id)"),
                "documents": link("/api/document?projectId=\(project.id)"),
                "undoRedoStatus": link("/api/project/\(project.id)/undo-redo-status"),
                "syncStatus": link("/api/project/\(project.id)/sync-status"),
                "export": link("/api/project/\(project.id)/export/fountain"),
                "exportPdf": link("/api/project/\(project.id)/export/pdf"),
                "exportDocx": link("/api/project/\(project.id)/export/docx"),
                "exportFdx": link("/api/project/\(project.id)/export/fdx"),
                "exportEpub": link("/api/project/\(project.id)/export/epub"),
                "exportArchive": link("/api/project/\(project.id)/export/scripty"),
                "actors": link("/api/actor?projectId=\(project.id)"),
                "importScript": link("/api/project/\(project.id)/import-script"),
                "versions": link("/api/project/version?projectId=\(project.id)"),
                "editions": link("/api/project/edition?projectId=\(project.id)"),
                "activity": link("/api/project/\(project.id)/activity"),
                "invitations": link("/api/project/\(project.id)/invitations"),
                "access": link("/api/project/\(project.id)/access"),
                "contactSuggestions": link("/api/project/\(project.id)/contact-suggestions"),
            ],
        ]
        if let writers = project.writers { json["writers"] = writers }
        if let value = project.screenplayTitle { json["screenplayTitle"] = value }
        if let value = project.contactInfo { json["contactInfo"] = value }
        if let value = project.screenplayVersion { json["screenplayVersion"] = value }
        return json
    }

    /// The block collection, with the affordances the real server advertises:
    /// only an untouched script offers `createInitial`, and only a script with
    /// something in it offers the bulk operations.
    private func blockCollection(_ projectId: Int, editionId: Int? = nil) -> (Int, Data) {
        let source = editionId.flatMap { editionBlocks[$0] } ?? blocks[projectId] ?? []
        let items = source
            .sorted { $0.order < $1.order }
            .map { blockJSON($0, projectId: projectId) }
        let selfHref = editionId.map { "/api/block?projectId=\(projectId)&editionId=\($0)" }
            ?? "/api/block?projectId=\(projectId)"
        var links: [String: Any] = ["self": link(selfHref)]
        if items.isEmpty, blocks[projectId] != nil {
            links["createInitial"] = link("/api/block/initial?projectId=\(projectId)")
        }
        if !items.isEmpty {
            links["bulkSetType"] = link("/api/block/bulk/type")
            links["bulkAddTags"] = link("/api/block/bulk/tags")
            links["bulkFormat"] = link("/api/block/bulk/format")
            links["bulkDelete"] = link("/api/block/bulk/delete")
            links["bulkReplace"] = link("/api/block/bulk/replace")
            // Like the bulk operations, this needs a script to act on — but
            // unlike them it is offered to readers too on the real server,
            // which the demo's always-an-editor user cannot show.
            links["commentCounts"] = link("/api/block/comment-counts?projectId=\(projectId)")
        }
        // Offered even for an empty script — that is exactly when everything
        // has just been deleted.
        links["trash"] = link("/api/block/trash?projectId=\(projectId)")
        return ok(["_embedded": ["blockResourceList": items], "_links": links])
    }

    /// Handles the five bulk operations. Each mutates a set of blocks under a
    /// single snapshot — one undo step for the batch, as on the server — and
    /// answers with the refreshed collection.
    private func routeBulkBlocks(operation: String, fields: [String: Any]) -> (Int, Data) {
        guard let ids = fields["ids"] as? [Int], !ids.isEmpty else {
            return badRequest("ids")
        }
        guard let projectId = fields["projectId"] as? Int, blocks[projectId] != nil else {
            return badRequest("projectId")
        }
        // A caller may not reach outside the project it named — but "the
        // project" means every edition of it, not just the default one. The
        // first version of this checked only the default edition's blocks, so
        // selecting elements while reading a revision and applying any bulk
        // action came back 403. The real server checks the blocks belong to
        // the project, which is edition-independent; this now matches.
        guard ids.allSatisfy({ ownsBlock($0, projectId: projectId) }) else {
            return (403, Data("{}".utf8))
        }

        snapshot(projectId)
        let targets = Set(ids)

        switch operation {
        case "type":
            guard let type = fields["type"] as? String, !type.isEmpty else {
                return badRequest("type")
            }
            mutate(projectId, where: targets) { $0.type = type }

        case "tags":
            guard let tags = fields["tags"] as? String, !tags.isEmpty else {
                return badRequest("tags")
            }
            let incoming = tags.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            mutate(projectId, where: targets) { block in
                var existing = (block.tags ?? "").split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                // Additive and case-insensitive, and the stored casing wins.
                for tag in incoming
                where !existing.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                    existing.append(tag)
                }
                block.tags = existing.isEmpty ? nil : existing.joined(separator: ", ")
            }

        case "delete":
            // Removes from wherever they live and renumbers that list, so a
            // bulk delete works while reading a revision, not only the default.
            for removed in (blocks[projectId] ?? []) where targets.contains(removed.id) {
                trashBlock(removed, projectId: projectId)
            }
            blocks[projectId]?.removeAll { targets.contains($0.id) }
            renumber(&blocks[projectId])
            for edition in editions where edition.projectId == projectId {
                for removed in (editionBlocks[edition.id] ?? []) where targets.contains(removed.id) {
                    trashBlock(removed, projectId: projectId)
                }
                editionBlocks[edition.id]?.removeAll { targets.contains($0.id) }
                renumber(&editionBlocks[edition.id])
            }

        case "format":
            if let align = fields["align"] as? String {
                guard let canonical = canonicalAlign(align) else { return badRequest("align") }
                mutate(projectId, where: targets) { $0.textAlign = canonical }
            }
            if let font = fields["font"] as? String {
                guard let canonical = canonicalFont(font) else { return badRequest("font") }
                mutate(projectId, where: targets) { $0.font = canonical }
            }
            if let style = fields["style"] as? String {
                switch style.uppercased() {
                case "BOLD":
                    mutate(projectId, where: targets) { $0.textBold = !($0.textBold ?? false) }
                case "ITALIC":
                    mutate(projectId, where: targets) { $0.textItalic = !($0.textItalic ?? false) }
                case "UNDERLINE":
                    mutate(projectId, where: targets) { $0.textUnderline = !($0.textUnderline ?? false) }
                default:
                    return badRequest("style")
                }
            }
            if fields["clearHighlight"] as? Bool == true {
                mutate(projectId, where: targets) { $0.highlight = nil }
            } else if let highlight = fields["highlight"] as? String {
                // An unrecognised tint clears rather than failing, as on the server.
                let known = ["YELLOW", "GREEN", "BLUE", "RED", "GRAY"]
                let key = highlight.trimmingCharacters(in: .whitespaces).uppercased()
                mutate(projectId, where: targets) { $0.highlight = known.contains(key) ? key : nil }
            }

        case "replace":
            guard let find = fields["find"] as? String, !find.isEmpty else {
                return badRequest("find")
            }
            let replacement = fields["replace"] as? String ?? ""
            let matchCase = fields["matchCase"] as? Bool ?? false
            let wholeWord = fields["wholeWord"] as? Bool ?? false
            let includeCues = fields["includeCharacterCues"] as? Bool ?? false
            mutate(projectId, where: targets) { block in
                // Cue content mirrors the person record, so it is left alone
                // unless the caller opted in.
                if !includeCues, block.type == "CHARACTER" || block.type == "DUAL_DIALOGUE" {
                    return
                }
                block.content = Self.literalReplace(
                    in: block.content, find: find, with: replacement,
                    matchCase: matchCase, wholeWord: wholeWord)
            }

        default:
            return notFound()
        }

        touch(projectId)
        return blockCollection(projectId)
    }

    /// Restores contiguous 1-based ordering after a removal.
    private func renumber(_ list: inout [DemoBlock]?) {
        guard var blocks = list else { return }
        blocks.sort { $0.order < $1.order }
        for index in blocks.indices { blocks[index].order = index + 1 }
        list = blocks
    }

    /// True when the block belongs to this project, in any of its editions.
    private func ownsBlock(_ id: Int, projectId: Int) -> Bool {
        if (blocks[projectId] ?? []).contains(where: { $0.id == id }) {
            return true
        }
        return editions
            .filter { $0.projectId == projectId }
            .contains { (editionBlocks[$0.id] ?? []).contains(where: { $0.id == id }) }
    }

    /// Applies a change wherever the blocks actually live — the project's own
    /// list, and every edition's — so a bulk action works the same whichever
    /// edition the writer is reading.
    private func mutate(_ projectId: Int,
                        where ids: Set<Int>,
                        _ change: (inout DemoBlock) -> Void) {
        if var list = blocks[projectId] {
            for index in list.indices where ids.contains(list[index].id) {
                change(&list[index])
            }
            blocks[projectId] = list
        }
        for edition in editions where edition.projectId == projectId {
            guard var list = editionBlocks[edition.id] else { continue }
            for index in list.indices where ids.contains(list[index].id) {
                change(&list[index])
            }
            editionBlocks[edition.id] = list
        }
    }

    /// Literal find-and-replace — `find` is never treated as a pattern and the
    /// replacement is inserted verbatim, matching the server's use of
    /// `Pattern.quote` and `Matcher.quoteReplacement`.
    private static func literalReplace(in text: String,
                                       find: String,
                                       with replacement: String,
                                       matchCase: Bool,
                                       wholeWord: Bool) -> String {
        guard !find.isEmpty else { return text }
        var pattern = NSRegularExpression.escapedPattern(for: find)
        if wholeWord { pattern = "\\b\(pattern)\\b" }
        let options: NSRegularExpression.Options = matchCase ? [] : [.caseInsensitive]
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        let template = NSRegularExpression.escapedTemplate(for: replacement)
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template)
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
                "createBelow": link("/api/block/\(block.id)/below"),
                "setType": link("/api/block/\(block.id)/type"),
                "move": link("/api/block/\(block.id)/move"),
                // Commenting needs only read access, so this is offered
                // alongside the editing links rather than gated with them.
                "comments": link("/api/block/\(block.id)/comments"),
            ],
        ]
        if let personId = block.personId {
            json["personId"] = personId
            if let person = people[projectId]?.first(where: { $0.id == personId }) {
                json["personName"] = person.name
            }
        }
        if let tags = block.tags { json["tags"] = tags }
        if let value = block.textAlign { json["textAlign"] = value }
        if let value = block.font { json["font"] = value }
        if let value = block.highlight { json["highlight"] = value }
        if let value = block.textBold { json["textBold"] = value }
        if let value = block.textItalic { json["textItalic"] = value }
        if let value = block.textUnderline { json["textUnderline"] = value }
        return json
    }

    private func personJSON(_ person: DemoPerson, projectId: Int) -> [String: Any] {
        var json: [String: Any] = [
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
        if let actorId = person.actorId {
            json["actorId"] = actorId
            if let actor = actors.first(where: { $0.id == actorId }) {
                json["actorName"] = [actor.first, actor.last]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
        }
        return json
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

    /// A file for each export format the demo advertises.
    ///
    /// The demo has no real PDF/DOCX/EPUB engines, so it returns the fountain
    /// text for the text-shaped formats and a genuine one-page PDF for `pdf` —
    /// the latter so the print flow, which hands its bytes to the system print
    /// panel, has something valid to render offline.
    private func demoExport(_ project: DemoProject, format: String) -> (Int, Data) {
        switch format {
        case "pdf":
            return (200, minimalPDF(title: project.title))
        case "scripty", "json":
            let archive: [String: Any] = [
                "project": ["title": project.title],
                "blocks": (blocks[project.id] ?? [])
                    .sorted { $0.order < $1.order }
                    .map { ["type": $0.type, "content": $0.content] },
            ]
            let data = (try? JSONSerialization.data(withJSONObject: archive, options: [.prettyPrinted]))
                ?? Data()
            return (200, data)
        default:
            // fountain, docx, fdx, epub — the demo serves the plain text it can
            // actually produce; the point offline is that the rel resolves.
            return (200, Data(fountainExport(project).utf8))
        }
    }

    /// Every project as one archive, in the shape a single project's
    /// `exportArchive` uses — a bundle is the same document with a list at the
    /// top, so what goes out here is what `importProject` could read back.
    private func demoProjectsBundle() -> (Int, Data) {
        let bundle: [String: Any] = [
            "projects": projects.map { project in
                ["project": ["title": project.title],
                 "blocks": (blocks[project.id] ?? [])
                     .sorted { $0.order < $1.order }
                     .map { ["type": $0.type, "content": $0.content] }]
            },
        ]
        let data = (try? JSONSerialization.data(withJSONObject: bundle, options: [.prettyPrinted])) ?? Data()
        return (200, data)
    }

    /// The smallest well-formed PDF: one blank US-Letter page. Enough for the
    /// print panel to open on a real document rather than reject empty bytes.
    private func minimalPDF(title: String) -> Data {
        let objects = [
            "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
            "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
            "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\n",
        ]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for object in objects {
            offsets.append(pdf.utf8.count)
            pdf += object
        }
        let xrefStart = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            pdf += String(format: "%010d 00000 n \n", offset)
        }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\n"
        pdf += "startxref\n\(xrefStart)\n%%EOF"
        return Data(pdf.utf8)
    }

    /// A couple of stand-in contacts, filtered by what has been typed. Enough to
    /// show the invite autofill working offline without inventing a directory.
    private func contactSuggestions(matching query: String) -> (Int, Data) {
        let all: [(name: String, email: String, source: String)] = [
            ("Ava Collaborator", "ava@example.com", "Collaborator"),
            ("Sam Reader", "sam@example.com", "Reader"),
            ("Casting Office", "casting@example.com", "Cast"),
        ]
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matches = q.isEmpty ? [] : all.filter {
            $0.name.lowercased().contains(q) || $0.email.lowercased().contains(q)
        }
        let items = matches.map { ["name": $0.name, "email": $0.email, "sourceLabel": $0.source] }
        return ok(["_embedded": ["contactSuggestionViewModelList": items],
                   "_links": ["self": link("/api/project/contact-suggestions")]])
    }

    // MARK: - Helpers

    private let iso = ISO8601DateFormatter()

    /// The real server accepts either the display spelling or its own canonical
    /// form and always reads back the canonical one. The demo mirrors that, so
    /// a client that round-trips a value here behaves the same in production.
    private func canonicalAlign(_ value: String) -> String? {
        switch value.uppercased() {
        case "LEFT": return "LEFT"
        case "CENTER": return "CENTER"
        case "RIGHT": return "RIGHT"
        default: return nil
        }
    }

    private func canonicalFont(_ value: String) -> String? {
        switch value.uppercased().replacingOccurrences(of: " ", with: "_") {
        case "COURIER_PRIME": return "COURIER_PRIME"
        case "ARIAL": return "ARIAL"
        case "TIMES_NEW_ROMAN": return "TIMES_NEW_ROMAN"
        default: return nil
        }
    }

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

    /// 201 with the new resource, for the routes the server answers that way.
    private func created(_ object: [String: Any]) -> (Int, Data) {
        ((try? JSONSerialization.data(withJSONObject: object)).map { (201, $0) }
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
        var maya = addPerson(name: "MAYA", fullName: "Maya Okafor")
        let dev = addPerson(name: "DEV", fullName: "Dev Ramaswamy")

        // One character arrives already cast and one still open, so the casting
        // screen shows both states without the user having to set them up.
        let rosa = addActor(first: "Rosa", last: "Delgado",
                            email: "rosa@example.com", phone: "555-0142",
                            projectIds: [1])
        addActor(first: "Theo", last: "Nakamura",
                 email: "theo@example.com", phone: nil, projectIds: [1])
        addActor(first: "Priya", last: "Anand",
                 email: "priya@example.com", phone: nil, projectIds: [2])
        maya.actorId = rosa.id

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

        // Arrive with a bookmark and a tag already set, so those affordances
        // are visible in the script without the user having to add them first.
        flag(project: lastTake, order: 17, bookmarked: true, tags: "vfx, rain")
        flag(project: dustAndNeon, order: 1, bookmarked: true)

        // A song and a note per project so the Songs & Notes screen isn't empty.
        addDocument(projectId: lastTake.id, title: "One More Take", type: "SONG", content: """
        Roll the film, we're running out of night
        One more take before we lose the light
        The reel keeps spinning, so do I
        One more take, one more try
        """)
        addDocument(projectId: lastTake.id, title: "Production Notes", type: "NOTES", content: """
        Reshoot the parking-lot ending if the rain rig is available.
        Ask props for a second vending machine practical light.
        Dev's boom mic still rattles on wide shots — tape it.
        """)
        addDocument(projectId: dustAndNeon.id, title: "Ballad of Last Chance", type: "SONG", content: """
        Two moons over a one-horse town
        Neon buzzing as the sun goes down
        I rode in chasing an empty street
        Found a town with a heartbeat
        """)

        // A little history to arrive with, so version history is not an empty
        // screen. Backdated, and one named against two automatic saves, which
        // is the ratio the real thing produces.
        seedVersion(lastTake.id, label: "First pass", autoSave: false, minutesAgo: 180)
        seedVersion(lastTake.id, label: nil, autoSave: true, minutesAgo: 95)
        seedVersion(lastTake.id, label: "Before the rain rewrite", autoSave: false, minutesAgo: 40)
        seedVersion(lastTake.id, label: nil, autoSave: true, minutesAgo: 12)
        seedVersion(dustAndNeon.id, label: nil, autoSave: true, minutesAgo: 1_500)

        // Every project has a default edition; the first one also has a
        // revision, so the picker has something to choose between and switching
        // shows genuinely different text.
        seedEdition(lastTake.id, name: "Shooting Draft", isDefault: true, isPublished: true)
        let revision = seedEdition(lastTake.id, name: "Rain Rewrite",
                                   isDefault: false, isPublished: false)
        editionBlocks[revision] = (blocks[lastTake.id] ?? []).prefix(12).map { block in
            var copy = block
            copy.id = nextBlockId
            nextBlockId += 1
            if copy.type == "ACTION", copy.content.contains("rain") || copy.content.contains("Rain") {
                copy.content = "The rain arrives early, and everything changes."
            }
            return copy
        }
        seedEdition(dustAndNeon.id, name: "First Draft", isDefault: true, isPublished: true)

        // A little history, so the activity screen shows a record rather than
        // an empty state. Backdated and attributed to more than one person,
        // since a log with a single name in it teaches nothing.
        recordActivity(lastTake.id, type: "PROJECT_CREATE",
                       summary: "Created the screenplay", minutesAgo: 4_320)
        recordActivity(lastTake.id, type: "SCRIPT_IMPORT",
                       summary: "Imported the first draft from Final Draft", minutesAgo: 4_200)
        recordActivity(lastTake.id, type: "ACTOR_CAST",
                       summary: "Cast Rosa Delgado as MAYA",
                       actor: "Priya Anand", minutesAgo: 1_460)
        recordActivity(lastTake.id, type: "VERSION_SAVE",
                       summary: "Saved the version “Before the rain rewrite”", minutesAgo: 40)
        recordActivity(lastTake.id, type: "COMMENT_ADD",
                       summary: "Commented on an action line",
                       actor: "Rosa Delgado", minutesAgo: 220)
        recordActivity(dustAndNeon.id, type: "PROJECT_CREATE",
                       summary: "Created the screenplay", minutesAgo: 1_500)

        // A short thread already in place, so the comments screen shows a
        // conversation rather than an empty state.
        if let commented = (blocks[lastTake.id] ?? []).first(where: { $0.type == "ACTION" }) {
            seedComment(commented.id, author: "Rosa Delgado",
                        body: "Can we lose the second half of this? It plays long.",
                        minutesAgo: 220, mine: false)
            seedComment(commented.id, author: "You",
                        body: "Agreed — trimming after the table read.",
                        minutesAgo: 55, mine: true)
        }

        // One of each kind of access, so the share screen shows the distinction
        // between a collaborator and a reader rather than describing it.
        invitations.append(DemoInvitation(id: nextInvitationId, projectId: lastTake.id,
                                          email: "rosa@example.com", viewOnly: false,
                                          status: "Pending"))
        nextInvitationId += 1
        invitations.append(DemoInvitation(id: nextInvitationId, projectId: lastTake.id,
                                          email: "financier@example.com", viewOnly: true,
                                          status: "Active"))
        nextInvitationId += 1
    }

    private func seedComment(_ blockId: Int, author: String, body: String,
                             minutesAgo: Int, mine: Bool) {
        comments.append(DemoComment(
            id: nextCommentId,
            blockId: blockId,
            authorName: author,
            body: body,
            createdAt: Date(timeIntervalSinceNow: -Double(minutesAgo) * 60),
            mine: mine))
        nextCommentId += 1
    }

    @discardableResult
    private func seedEdition(_ projectId: Int, name: String,
                             isDefault: Bool, isPublished: Bool) -> Int {
        let edition = DemoEdition(id: nextEditionId, projectId: projectId, name: name,
                                  isDefault: isDefault, isPublished: isPublished,
                                  lastEdited: Date())
        nextEditionId += 1
        editions.append(edition)
        // The default edition reads the project's own blocks, so an unnamed
        // request behaves exactly as it did before editions existed.
        editionBlocks[edition.id] = isDefault ? (blocks[projectId] ?? []) : []
        return edition.id
    }

    private func seedVersion(_ projectId: Int, label: String?, autoSave: Bool, minutesAgo: Int) {
        var version = recordVersion(projectId, label: label, autoSave: autoSave)
        version.createdAt = Date(timeIntervalSinceNow: -Double(minutesAgo) * 60)
        if let index = versions[projectId]?.firstIndex(where: { $0.id == version.id }) {
            versions[projectId]?[index] = version
        }
    }

    private func flag(project: DemoProject, order: Int,
                      bookmarked: Bool = false, tags: String? = nil) {
        guard let index = blocks[project.id]?.firstIndex(where: { $0.order == order }) else { return }
        blocks[project.id]?[index].bookmarked = bookmarked
        blocks[project.id]?[index].tags = tags
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
        documents[project.id] = []
        return project
    }

    private func addPerson(name: String, fullName: String) -> DemoPerson {
        let person = DemoPerson(id: nextPersonId, name: name, fullName: fullName)
        nextPersonId += 1
        return person
    }

    @discardableResult
    private func addActor(first: String, last: String, email: String?,
                          phone: String?, projectIds: [Int]) -> DemoActor {
        let actor = DemoActor(id: nextActorId, first: first, last: last,
                              phone: phone, email: email, projectIds: projectIds)
        nextActorId += 1
        actors.append(actor)
        return actor
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

private extension String {
    nonisolated var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
