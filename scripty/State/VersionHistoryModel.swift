//
//  VersionHistoryModel.swift
//  scripty
//
//  Saved snapshots: list them, name a new one, restore an old one, delete the
//  ones that stopped mattering.
//
//  The server has offered all of this over REST since before the iPad client
//  existed; nothing here needed a new endpoint. Restoring answers with the
//  refreshed history, and the caller reloads the content itself — a restore
//  rewrites what is on screen out from under the reader.
//
//  Scripts and songs both keep a history, and the two work identically: the
//  model is handed the `versions` link its owner advertised and never learns
//  which kind of thing it is a history of.
//

import Foundation
import Observation

@Observable
@MainActor
final class VersionHistoryModel {
    private let app: AppModel
    /// The `versions` link its owner advertised — a project's, or a song's.
    private let source: HALLink

    private(set) var versions: [ProjectVersion] = []
    private(set) var links = HALLinks()
    private(set) var isLoading = false
    /// Set while a restore or delete is in flight, so the list can refuse a
    /// second tap rather than racing itself.
    private(set) var isWorking = false
    var errorMessage: String?

    var canCreate: Bool { links.contains(.create) }

    /// Snapshots the writer named deliberately. Kept apart from the automatic
    /// ones so they stay findable — the autosaves outnumber them heavily.
    var namedVersions: [ProjectVersion] { versions.filter { !$0.isAutoSave } }

    var autoSaves: [ProjectVersion] { versions.filter(\.isAutoSave) }

    init(app: AppModel, source: HALLink) {
        self.app = app
        self.source = source
    }

    // MARK: - Loading

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let collection: HALCollection<ProjectVersion> = try await app.client.fetch(from: source)
            // Newest first: a version history is read from the present backwards.
            versions = collection.items.sorted {
                ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
            }
            links = collection.links
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    // MARK: - Mutations

    /// Save the script as it stands now under an optional name.
    @discardableResult
    func createVersion(label: String?) async -> Bool {
        guard let link = links[.create] else { return false }
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        return await perform {
            let _: ProjectVersion = try await self.app.client.fetch(
                from: link, method: "POST",
                body: CreateVersionCommand(label: (trimmed?.isEmpty ?? true) ? nil : trimmed))
        }
    }

    /// Roll the script back to a snapshot. The server answers with the
    /// refreshed history — restoring itself records a new snapshot first, so
    /// the state being replaced is never lost.
    @discardableResult
    func restore(_ version: ProjectVersion) async -> Bool {
        guard let link = version.link(.restore) else { return false }
        return await perform {
            let collection: HALCollection<ProjectVersion> = try await self.app.client.fetch(
                from: link, method: "POST")
            self.adopt(collection)
        }
    }

    @discardableResult
    func delete(_ version: ProjectVersion) async -> Bool {
        guard let link = version.link(.delete) else { return false }
        return await perform {
            let collection: HALCollection<ProjectVersion> = try await self.app.client.fetch(
                from: link, method: "DELETE")
            self.adopt(collection)
        }
    }

    func canRestore(_ version: ProjectVersion) -> Bool { version.hasLink(.restore) }
    func canDelete(_ version: ProjectVersion) -> Bool { version.hasLink(.delete) }

    // MARK: - Plumbing

    private func adopt(_ collection: HALCollection<ProjectVersion>) {
        versions = collection.items.sorted {
            ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
        }
        links = collection.links
    }

    /// Runs a mutation and reloads, so the list reflects whatever the server
    /// decided — a create may have been coalesced, a restore adds a snapshot
    /// of its own.
    private func perform(_ work: () async throws -> Void) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            try await work()
            await load()
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    private func report(_ error: Error) {
        // Nothing cancelled is ever shown — see `isCancelledRequest`.
        guard !error.isCancelledRequest else { return }
        app.handle(error)
        errorMessage = error.localizedDescription
    }
}
