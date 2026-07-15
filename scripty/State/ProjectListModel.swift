//
//  ProjectListModel.swift
//  scripty
//

import Foundation
import Observation

@Observable @MainActor
final class ProjectListModel {
    private let app: AppModel

    private(set) var projects: [Project] = []
    private(set) var collectionLinks = HALLinks()
    private(set) var isLoading = false
    var errorMessage: String?

    init(app: AppModel) {
        self.app = app
    }

    func refresh() async {
        guard let link = app.apiRoot?.link(.projects) else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let collection: HALCollection<Project> = try await app.client.fetch(from: link)
            projects = collection.items.sorted {
                ($0.lastEdited ?? .distantPast) > ($1.lastEdited ?? .distantPast)
            }
            collectionLinks = collection.links
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    /// POST to the projects collection (its self link, falling back to the
    /// root rel). Returns the created project on success.
    @discardableResult
    func createProject(title: String) async -> Project? {
        guard let link = collectionLinks[.selfRel] ?? app.apiRoot?.link(.projects) else { return nil }
        do {
            let created: Project = try await app.client.fetch(
                from: link, method: "POST",
                body: CreateProjectCommand(title: title))
            await refresh()
            errorMessage = nil
            return created
        } catch {
            report(error)
            return nil
        }
    }

    var canImport: Bool { collectionLinks[.importProject] != nil }

    /// Import a project from a .scripty.json archive (the web list's Import
    /// button). Returns the created project on success.
    @discardableResult
    func importProject(data: Data, filename: String) async -> Project? {
        guard let link = collectionLinks[.importProject] else { return nil }
        do {
            let created: Project = try await app.client.upload(
                to: link, fileData: data, filename: filename)
            await refresh()
            errorMessage = nil
            return created
        } catch {
            report(error)
            return nil
        }
    }

    @discardableResult
    func rename(_ project: Project, to title: String) async -> Bool {
        guard let link = project.link(.update) else { return false }
        do {
            let _: Project = try await app.client.fetch(
                from: link, method: "PUT",
                body: EditProjectCommand(title: title))
            await refresh()
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Toggle this project as the user's default (the web list's star). The
    /// server returns the refreshed collection with updated `default` flags.
    func toggleDefault(_ project: Project) async {
        guard let link = project.link(.toggleDefault) else { return }
        do {
            let collection: HALCollection<Project> = try await app.client.fetch(from: link, method: "POST")
            projects = collection.items.sorted {
                ($0.lastEdited ?? .distantPast) > ($1.lastEdited ?? .distantPast)
            }
            collectionLinks = collection.links
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    func delete(_ project: Project) async {
        guard let link = project.link(.delete) else { return }
        do {
            try await app.client.data(for: link, method: "DELETE")
            projects.removeAll { $0.id == project.id }
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        app.handle(error)
        errorMessage = error.localizedDescription
    }
}
