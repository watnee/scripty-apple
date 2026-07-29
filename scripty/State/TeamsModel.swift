//
//  TeamsModel.swift
//  scripty
//
//  The set of production teams: list them, make one, rename or remove one, and
//  say which productions each covers.
//
//  Gated entirely on the `teams` rel the API root advertises, which the server
//  only offers to a user allowed to manage them. A deployment or an account
//  without that rel sees no teams UI at all, rather than a screen that 403s.
//

import Foundation
import Observation

@Observable
@MainActor
final class TeamsModel {
    private let app: AppModel
    /// The root's `teams` link — both the list to read and, by POST, where a
    /// new team is created. The collection advertises no separate `create`
    /// rel, so its own address is the create target.
    private let source: HALLink

    private(set) var teams: [Team] = []
    private(set) var links = HALLinks()
    private(set) var isLoading = false
    private(set) var isWorking = false
    var errorMessage: String?

    init(app: AppModel, source: HALLink) {
        self.app = app
        self.source = source
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let collection: HALCollection<Team> = try await app.client.fetch(from: source)
            teams = collection.items.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            links = collection.links
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    @discardableResult
    func create(name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return await perform {
            let _: Team = try await self.app.client.fetch(
                from: self.source, method: "POST", body: TeamCommand(name: trimmed))
        }
    }

    @discardableResult
    func rename(_ team: Team, to name: String) async -> Bool {
        guard let link = team.link(.update) else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return await perform {
            let _: Team = try await self.app.client.fetch(
                from: link, method: "PUT", body: TeamCommand(name: trimmed))
        }
    }

    @discardableResult
    func delete(_ team: Team) async -> Bool {
        guard let link = team.link(.delete) else { return false }
        return await perform {
            // Delete answers with the team it removed, not a collection; the
            // reload below is what refreshes the list.
            _ = try await self.app.client.data(for: link, method: "DELETE")
        }
    }

    /// Sets the productions a team covers, wholesale. The list is sent even when
    /// empty, because the server treats an omitted list as "leave alone" and an
    /// empty one as "assign nothing".
    @discardableResult
    func assignProductions(_ team: Team, projectIds: [Int]) async -> Bool {
        guard let link = team.link(.assignProductions) else { return false }
        return await perform {
            let _: Team = try await self.app.client.fetch(
                from: link, method: "PUT",
                body: AssignProductionsCommand(projectIds: projectIds))
        }
    }

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
