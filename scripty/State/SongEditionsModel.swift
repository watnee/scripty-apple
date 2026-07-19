//
//  SongEditionsModel.swift
//  scripty
//
//  The named editions of one song — an alternate lyric, a rewrite, a version
//  cut for a different scene.
//
//  The same shape as the script's editions, keyed on a document instead of a
//  project. Now that a song is edited as lines rather than as one lump of text,
//  switching editions genuinely changes what is on screen; before this there
//  was nothing for it to switch between.
//

import Foundation
import Observation

@Observable
@MainActor
final class SongEditionsModel {
    private let app: AppModel
    private let document: TextDocument

    private(set) var editions: [ScriptEdition] = []
    private(set) var links = HALLinks()
    private(set) var isLoading = false
    private(set) var isWorking = false
    var errorMessage: String?

    var selectedId: Int?

    var canCreate: Bool { links.contains(.create) }

    let itemNoun = "line"
    var hasChoice: Bool { editions.count > 1 }

    var selected: ScriptEdition? {
        if let selectedId, let match = editions.first(where: { $0.id == selectedId }) {
            return match
        }
        return editions.first(where: \.isTheDefault) ?? editions.first
    }

    init(app: AppModel, document: TextDocument) {
        self.app = app
        self.document = document
    }

    func load() async {
        guard let link = document.link(.editions) else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let collection: HALCollection<ScriptEdition> = try await app.client.fetch(from: link)
            adopt(collection)
            errorMessage = nil
        } catch APIError.forbidden {
            editions = []
        } catch {
            report(error)
        }
    }

    // MARK: - Affordances

    func canRename(_ edition: ScriptEdition) -> Bool { edition.hasLink(.update) }
    func canDelete(_ edition: ScriptEdition) -> Bool { edition.hasLink(.delete) }
    func canSetDefault(_ edition: ScriptEdition) -> Bool { edition.hasLink(.setDefault) }
    func canSetPublished(_ edition: ScriptEdition) -> Bool { edition.hasLink(.setPublished) }

    /// The lyric of an edition — what the editor loads once one is picked.
    func blocksLink(for edition: ScriptEdition) -> HALLink? { edition.link(.songBlocks) }

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

    @discardableResult
    func delete(_ edition: ScriptEdition) async -> Bool {
        guard let link = edition.link(.delete) else { return false }
        let removingSelection = edition.id == selected?.id
        let succeeded = await act(link, method: "DELETE")
        if succeeded && removingSelection { selectedId = nil }
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
        if let selectedId, !editions.contains(where: { $0.id == selectedId }) {
            self.selectedId = nil
        }
    }

    private func report(_ error: Error) {
        app.handle(error)
        errorMessage = error.localizedDescription
    }
}
