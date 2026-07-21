//
//  CastingModel.swift
//  scripty
//
//  State for the casting side of one project: the actors who can be cast,
//  and their headshots. Listing actors needs the casting permission — the
//  server answers 403 without it and the whole section quietly disappears,
//  the same way characters do in ScriptModel.
//

import Foundation
import Observation

@Observable @MainActor
final class CastingModel {
    let app: AppModel
    let project: Project

    private(set) var actors: [ScriptyActor] = []
    private(set) var actorsLinks = HALLinks()
    private(set) var isLoading = false

    /// False once the server has told us casting is off-limits (403) or never
    /// advertised the collection at all. Views hide the section rather than
    /// showing an error the user can do nothing about.
    private(set) var isAvailable = true

    /// Whether we have ever completed a load — lets the list distinguish
    /// "empty" from "not fetched yet".
    private(set) var hasLoaded = false

    var errorMessage: String?

    /// Headshot bytes keyed by actor id. A nil value is a negative result we
    /// remember so a missing image isn't re-fetched on every row redraw.
    private var headshotCache: [Int: Data?] = [:]
    private var headshotTasks: [Int: Task<Void, Never>] = [:]

    init(app: AppModel, project: Project) {
        self.app = app
        self.project = project
    }

    /// The project-scoped actor collection: the root's `actors` link narrowed
    /// with `?projectId=`. A project may also advertise the link directly.
    private var collectionLink: HALLink? {
        if let link = actorsLinks[.selfRel] { return link }
        if let link = project.link(.actors) { return link }
        return app.apiRoot?.link(.actors)?
            .addingQuery(["projectId": String(project.id)])
    }

    /// True when the API root advertised actors at all — the cheap, pre-fetch
    /// gate the Characters screen uses to decide whether to offer casting.
    var isAdvertised: Bool {
        project.hasLink(.actors) || app.apiRoot?.hasLink(.actors) == true
    }

    // MARK: - Loading

    func load() async {
        guard isAdvertised, let link = collectionLink else {
            isAvailable = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let collection: HALCollection<ScriptyActor> = try await app.client.fetch(from: link)
            actors = collection.items.sorted { $0.sortKey < $1.sortKey }
            actorsLinks = collection.links
            isAvailable = true
            hasLoaded = true
            errorMessage = nil
        } catch APIError.forbidden {
            // No casting permission: degrade by hiding the section.
            isAvailable = false
            actors = []
        } catch APIError.notFound {
            // Server build without the casting endpoints.
            isAvailable = false
            actors = []
        } catch {
            report(error)
        }
    }

    /// Loads once — for `.task` on views that may re-appear.
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load()
    }

    func actor(id: Int?) -> ScriptyActor? {
        guard let id else { return nil }
        return actors.first { $0.id == id }
    }

    // MARK: - Mutations (all gated by link presence)

    /// The collection advertises a POST target only for users who may add
    /// actors, so its presence doubles as the "can create" gate.
    var canCreate: Bool { isAvailable && collectionLink != nil }

    @discardableResult
    func createActor(first: String, last: String, phone: String?, email: String?) async -> Bool {
        guard let link = collectionLink else { return false }
        do {
            let _: ScriptyActor = try await app.client.fetch(
                from: link, method: "POST",
                body: CreateActorCommand(first: first, last: last, phone: phone,
                                         email: email, projectIds: [project.id]))
            await load()
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    @discardableResult
    func updateActor(_ actor: ScriptyActor, first: String, last: String,
                     phone: String?, email: String?) async -> Bool {
        guard let link = actor.link(.update) else { return false }
        do {
            let _: ScriptyActor = try await app.client.fetch(
                from: link, method: "PUT",
                body: EditActorCommand(first: first, last: last, phone: phone,
                                       email: email,
                                       projectIds: actor.projectIds ?? [project.id]))
            headshotCache[actor.id] = nil
            await load()
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Replaces the set of characters an actor auditions for in this project.
    /// The server answers with the refreshed project-scoped actor, so the row's
    /// audition ids update without a full reload. Gated on the `setAuditions`
    /// link the server advertises only to a caster.
    @discardableResult
    func setAuditions(_ actor: ScriptyActor, characterIds: [Int]) async -> Bool {
        guard let link = actor.link(.setAuditions) else { return false }
        do {
            let updated: ScriptyActor = try await app.client.fetch(
                from: link, method: "POST",
                body: SetAuditionsCommand(characterIds: characterIds))
            if let index = actors.firstIndex(where: { $0.id == actor.id }) {
                actors[index] = updated
            }
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    func deleteActor(_ actor: ScriptyActor) async {
        guard let link = actor.link(.delete) else { return }
        do {
            try await app.client.data(for: link, method: "DELETE")
            actors.removeAll { $0.id == actor.id }
            headshotCache.removeValue(forKey: actor.id)
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    // MARK: - Headshots

    /// Cached headshot bytes, or nil if this actor has none (or it hasn't been
    /// fetched yet — call `loadHeadshot` to start that).
    func headshotData(for actor: ScriptyActor) -> Data? {
        headshotCache[actor.id] ?? nil
    }

    /// Fetches the headshot through the authenticated client. The `headshot`
    /// link is only advertised when the actor actually has one, and it returns
    /// image bytes rather than JSON — so this uses the raw-data path the
    /// exports use.
    func loadHeadshot(for actor: ScriptyActor) async {
        guard headshotCache[actor.id] == nil, let link = actor.link(.headshot) else { return }
        if let existing = headshotTasks[actor.id] {
            await existing.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await self.app.client.data(for: link)
                let image: Data? = data.isEmpty ? nil : data
                self.headshotCache[actor.id] = image
            } catch {
                // A missing or forbidden headshot is not worth an alert; remember
                // the miss so the row settles on its placeholder.
                let miss: Data? = nil
                self.headshotCache[actor.id] = miss
            }
            self.headshotTasks[actor.id] = nil
        }
        headshotTasks[actor.id] = task
        await task.value
    }

    private func report(_ error: Error) {
        app.handle(error)
        errorMessage = error.localizedDescription
    }
}

private extension ScriptyActor {
    /// Sort by surname then given name, case-insensitively, so the list reads
    /// the way a cast sheet does.
    var sortKey: String {
        [last, first].compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }
}
