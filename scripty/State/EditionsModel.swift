//
//  EditionsModel.swift
//  scripty
//
//  The named editions of one screenplay or one song, and which one the
//  writer is looking at.
//
//  The server has always taken an `editionId`; what it never offered was a way
//  to find out which ids exist. With that in place the client can do what the
//  web app does from its session — open a different draft — by naming the
//  edition on the block request instead.
//
//  Scripts and songs have the same six operations, the same default/published
//  rules, and the same picker; they differ only in where the collection link
//  lives, which rel an edition's contents hang off, and what one item is
//  called. Those three travel through the initialisers, so the two kinds
//  share every line of behaviour rather than drifting apart a fix at a time.
//

import Foundation
import Observation

@Observable
@MainActor
final class EditionsModel {
    private let app: AppModel
    /// The editions collection, from whichever resource owns it.
    private let sourceLink: HALLink?
    /// Where an edition's contents hang: `blocks` for a screenplay,
    /// `songBlocks` for a lyric.
    private let blocksRel: Rel

    /// What one item of this kind of edition is called, singular. A script
    /// edition holds elements; a song's holds lines. The picker is otherwise
    /// identical, and calling a lyric line an "element" would be the one
    /// place the sharing showed through.
    let itemNoun: String

    private(set) var editions: [ScriptEdition] = []
    private(set) var links = HALLinks()
    private(set) var isLoading = false
    private(set) var isWorking = false
    var errorMessage: String?

    /// The edition being read. Nil means "whichever the server calls default",
    /// which is what an untouched project and every older client asks for.
    var selectedId: Int?

    var canCreate: Bool { links.contains(.create) }

    /// Only worth showing a picker once there is a choice to make.
    var hasChoice: Bool { editions.count > 1 }

    var selected: ScriptEdition? {
        if let selectedId, let match = editions.first(where: { $0.id == selectedId }) {
            return match
        }
        return editions.first(where: \.isTheDefault) ?? editions.first
    }

    /// A screenplay's editions.
    convenience init(app: AppModel, project: Project) {
        self.init(app: app, sourceLink: project.link(.editions),
                  blocksRel: .blocks, itemNoun: "element")
    }

    /// A song's editions — an alternate lyric, a rewrite, a version cut for a
    /// different scene.
    convenience init(app: AppModel, document: TextDocument) {
        self.init(app: app, sourceLink: document.link(.editions),
                  blocksRel: .songBlocks, itemNoun: "line")
    }

    private init(app: AppModel, sourceLink: HALLink?, blocksRel: Rel, itemNoun: String) {
        self.app = app
        self.sourceLink = sourceLink
        self.blocksRel = blocksRel
        self.itemNoun = itemNoun
    }

    func load() async {
        guard let link = sourceLink else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let collection: HALCollection<ScriptEdition> = try await app.client.fetch(from: link)
            adopt(collection)
            errorMessage = nil
        } catch APIError.forbidden {
            // A reader who may not browse editions sees none, which is the
            // same as a project that has only one.
            editions = []
        } catch {
            // Loaded quietly on every project open, so a device with no
            // connection degrades to "no editions" without an alert over the
            // offline copy of the script — the offline banner already says
            // what is going on.
            if error.isRetryableAPIError, !app.connectivity.isOnline { return }
            report(error)
        }
    }

    // MARK: - Affordances

    func canRename(_ edition: ScriptEdition) -> Bool { edition.hasLink(.update) }
    func canDelete(_ edition: ScriptEdition) -> Bool { edition.hasLink(.delete) }
    func canSetDefault(_ edition: ScriptEdition) -> Bool { edition.hasLink(.setDefault) }
    func canSetPublished(_ edition: ScriptEdition) -> Bool { edition.hasLink(.setPublished) }

    /// The contents of an edition — what the editor loads once one is picked.
    func blocksLink(for edition: ScriptEdition) -> HALLink? { edition.link(blocksRel) }

    /// The edition with this id, if the server still lists it — how a
    /// remembered choice from a previous visit is matched back up.
    func edition(withId id: Int) -> ScriptEdition? {
        editions.first { $0.id == id }
    }

    // MARK: - Mutations

    @discardableResult
    func create(name: String, copyFrom: ScriptEdition?) async -> Bool {
        guard let link = links[.create] else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return await act(link, method: "POST",
                         body: CreateEditionCommand(name: trimmed, copyFromEditionId: copyFrom?.id))
    }

    @discardableResult
    func rename(_ edition: ScriptEdition, to name: String) async -> Bool {
        guard let link = edition.link(.update) else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return await act(link, method: "PUT", body: RenameEditionCommand(name: trimmed))
    }

    /// Deletes an edition and everything written in it. The server refuses to
    /// remove the last one and stops advertising `delete` for it, so this is
    /// never offered when it could only fail.
    @discardableResult
    func delete(_ edition: ScriptEdition) async -> Bool {
        guard let link = edition.link(.delete) else { return false }
        let removingSelection = edition.id == selected?.id
        let succeeded = await act(link, method: "DELETE")
        if succeeded && removingSelection {
            // Fall back to whatever the server now calls default rather than
            // pointing at an edition that no longer exists.
            selectedId = nil
        }
        return succeeded
    }

    @discardableResult
    func setDefault(_ edition: ScriptEdition) async -> Bool {
        guard let link = edition.link(.setDefault) else { return false }
        return await act(link, method: "POST")
    }

    @discardableResult
    func setPublished(_ edition: ScriptEdition) async -> Bool {
        guard let link = edition.link(.setPublished) else { return false }
        return await act(link, method: "POST")
    }

    // MARK: - Plumbing

    private func act(_ link: HALLink, method: String, body: (any Encodable)? = nil) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            let collection: HALCollection<ScriptEdition> = try await app.client.fetch(
                from: link, method: method, body: body)
            adopt(collection)
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    private func adopt(_ collection: HALCollection<ScriptEdition>) {
        editions = collection.items
        links = collection.links
        // Drop a selection the server no longer knows about.
        if let selectedId, !editions.contains(where: { $0.id == selectedId }) {
            self.selectedId = nil
        }
    }

    private func report(_ error: Error) {
        // Nothing cancelled is ever shown — see `isCancelledRequest`.
        guard !error.isCancelledRequest else { return }
        app.handle(error)
        errorMessage = error.localizedDescription
    }
}
