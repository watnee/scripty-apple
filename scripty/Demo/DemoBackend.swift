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
    private var undoStacks: [Int: [[DemoBlock]]] = [:]
    private var redoStacks: [Int: [[DemoBlock]]] = [:]
    private var defaultProjectId: Int?
    private var nextProjectId = 1
    private var nextBlockId = 1
    private var nextPersonId = 1
    private var nextDocumentId = 1
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
        default:
            return notFound()
        }
    }

    private func routeProject(method: String, path: [String],
                              query: [String: String],
                              fields: [String: Any],
                              body: Data?) -> (Int, Data) {
        if method == "POST", path.first == "import" {
            return demoImport(body: body)
        }
        switch (method, path.count) {
        case ("GET", 0):
            return ok(["_embedded": ["projectResourceList": projects.map(projectJSON)],
                       "_links": ["self": link("/api/project"),
                                  "importProject": link("/api/project/import")]])
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
            if let title = fields["title"] as? String {
                projects[index].title = title
                projects[index].lastEdited = .now
            }
            return ok(projectJSON(projects[index]))
        case ("DELETE", nil):
            let removed = projects.remove(at: index)
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
        case ("POST", "toggleDefault"):
            defaultProjectId = (defaultProjectId == id) ? nil : id
            return ok(["_embedded": ["projectResourceList": projects.map(projectJSON)],
                       "_links": ["self": link("/api/project"),
                                  "importProject": link("/api/project/import")]])
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
            var links: [String: Any] = ["self": link("/api/block?projectId=\(projectId)")]
            // An untouched script advertises only the seed affordance.
            if items.isEmpty, blocks[projectId] != nil {
                links["createInitial"] = link("/api/block/initial?projectId=\(projectId)")
            }
            return ok(["_embedded": ["blockResourceList": items], "_links": links])
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
            return ok(["_embedded": ["textDocumentResourceList": items],
                       "_links": ["self": link(selfHref),
                                  "project": link("/api/project/\(projectId)"),
                                  "importDocument": link("/api/document/import")]])
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
            documents[projectId]?.remove(at: index)
            return ok([:])
        case ("POST", "insert"):
            return insertDocument(document: documents[projectId]![index],
                                  afterBlockId: fields["afterBlockId"] as? Int,
                                  asType: fields["asType"] as? String)
        case ("POST", "share-email"):
            let email = (fields["email"] as? String) ?? ""
            if email.isBlank { return badRequest("email") }
            return ok(["shared": true,
                       "title": documents[projectId]![index].title,
                       "email": email])
        default:
            return notFound()
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
        ]
        if isSong {
            links["shareEmail"] = link("/api/document/\(document.id)/share-email")
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
                "createBelow": link("/api/block/\(block.id)/below"),
                "setType": link("/api/block/\(block.id)/type"),
                "move": link("/api/block/\(block.id)/move"),
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
