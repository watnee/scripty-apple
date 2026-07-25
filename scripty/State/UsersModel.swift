//
//  UsersModel.swift
//  scripty
//
//  The set of accounts on the server: list them, make one, edit roles or
//  identity, and remove one.
//
//  Gated entirely on the `users` rel the API root advertises, which the server
//  only offers to an admin. A deployment or an account without that rel sees no
//  user-management UI at all, rather than a screen that 403s. Mirrors TeamsModel
//  — the other admin-only top-level collection.
//

import Foundation
import Observation

@Observable
@MainActor
final class UsersModel {
    private let app: AppModel
    /// The root's `users` link — both the list to read and, by POST, where a new
    /// account is created. The collection advertises no separate `create` rel, so
    /// its own address is the create target.
    private let source: HALLink

    private(set) var users: [User] = []
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
            let collection: HALCollection<User> = try await app.client.fetch(from: source)
            users = collection.items.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            links = collection.links
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    /// The full profile for one account, fetched from its `self` link. The list
    /// items carry identity and roles but not the per-project access breakdown —
    /// the server computes that only on the single-user resource — so the
    /// profile screen loads it on demand. Returns nil (and reports) on failure;
    /// the caller falls back to the list item it already has.
    func detail(for user: User) async -> User? {
        guard let link = user.link(.selfRel) else { return nil }
        do {
            let full: User = try await app.client.fetch(from: link)
            errorMessage = nil
            return full
        } catch {
            report(error)
            return nil
        }
    }

    @discardableResult
    func create(_ command: CreateUserCommand) async -> Bool {
        await perform {
            let _: User = try await self.app.client.fetch(
                from: self.source, method: "POST", body: command)
        }
    }

    @discardableResult
    func update(_ user: User, with command: EditUserCommand) async -> Bool {
        guard let link = user.link(.update) else { return false }
        return await perform {
            let _: User = try await self.app.client.fetch(
                from: link, method: "PUT", body: command)
        }
    }

    @discardableResult
    func delete(_ user: User) async -> Bool {
        guard let link = user.link(.delete) else { return false }
        return await perform {
            // Delete answers with the account it removed, not a collection; the
            // reload below is what refreshes the list.
            _ = try await self.app.client.data(for: link, method: "DELETE")
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
        app.handle(error)
        errorMessage = error.localizedDescription
    }
}
