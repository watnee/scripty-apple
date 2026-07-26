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

    /// Set when the list on screen is the offline copy rather than the
    /// server's answer, with when that copy was saved — the sidebar's footer
    /// says so, since an out-of-date list should not look current.
    private(set) var offlineCopySavedAt: Date?
    var isShowingOfflineCopy: Bool { offlineCopySavedAt != nil }

    init(app: AppModel) {
        self.app = app
    }

    func refresh() async {
        guard let link = app.apiRoot?.link(.projects) else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await app.client.data(for: link)
            let collection: HALCollection<Project> = try app.client.decode(from: data)
            adopt(collection)
            offlineCopySavedAt = nil
            errorMessage = nil
            app.offlineStore?.save(data, .projects)
        } catch {
            // A list the network failed to fetch falls back to the copy saved
            // last time it loaded — an old list of the writer's own projects
            // beats an empty sidebar and an alert.
            if error.isRetryableAPIError,
               let snapshot = app.offlineStore?.load(.projects),
               let collection: HALCollection<Project> = try? app.client.decode(from: snapshot.data) {
                adopt(collection)
                offlineCopySavedAt = snapshot.savedAt
                errorMessage = nil
            } else {
                report(error)
            }
        }
    }

    private func adopt(_ collection: HALCollection<Project>) {
        projects = collection.items.sorted {
            ($0.lastEdited ?? .distantPast) > ($1.lastEdited ?? .distantPast)
        }
        collectionLinks = collection.links
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
                to: link, fileName: filename, fileData: data, mimeType: "application/json")
            await refresh()
            errorMessage = nil
            return created
        } catch {
            report(error)
            return nil
        }
    }

    /// Whether the whole list can be taken away as one archive — advertised on
    /// the collection only when it holds a project.
    var canExportAll: Bool { collectionLinks[.exportProjects] != nil }

    /// Downloads projects as one `.scripty.json` bundle — the file
    /// `importProject` reads back — and writes it where the share sheet can
    /// pick it up.
    ///
    /// An empty `ids` means every project the signed-in user can see, which is
    /// what the endpoint already does when asked for none. Narrowing to a
    /// selection needs no second rel: the archive endpoint reads an `ids` list
    /// and the web's own export ticks append to the very same href, so the
    /// choice rides as a query on the advertised link — the same move the
    /// songbook export makes.
    func exportProjects(ids: [Int] = [], named baseName: String = "Scripty Projects") async -> URL? {
        guard let base = collectionLinks[.exportProjects] else { return nil }
        let link = ids.isEmpty
            ? base
            : base.addingQuery(["ids": ids.map(String.init).joined(separator: ",")])
        do {
            let data = try await app.client.data(for: link)
            let safeName = baseName
                .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
                .joined()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent((safeName.isEmpty ? "Projects" : safeName) + ".scripty.json")
            try data.write(to: url, options: .atomic)
            errorMessage = nil
            return url
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

    /// Every team the project could belong to, each flagged whether it does
    /// now — the production page's team checkboxes. Nil when the caller cannot
    /// manage teams (no `projectTeams` link), which is how the row decides
    /// whether to offer the action at all.
    func loadProjectTeams(_ project: Project) async -> [ProjectTeamOption]? {
        guard let link = project.link(.projectTeams) else { return nil }
        do {
            let collection: HALCollection<ProjectTeamOption> = try await app.client.fetch(from: link)
            errorMessage = nil
            // Explicit parameter types force the `sorted(by:)` overload; the bare
            // `$0`/`$1` form fails to type-check in this async @MainActor context
            // on the Xcode 26 toolchain (see CastingModel.loadAssignableProjects).
            return collection.items.sorted { (lhs: ProjectTeamOption, rhs: ProjectTeamOption) in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        } catch {
            report(error)
            return nil
        }
    }

    /// Reassigns the project to exactly `teamIds`. The write rides on `update`
    /// (the same PUT a rename uses), so the current title has to travel with it
    /// — the server requires a non-blank title, and omitting the title-page
    /// fields leaves the front matter untouched. Refreshes so the row's team
    /// badge reflects the new set.
    @discardableResult
    func updateProjectTeams(_ project: Project, teamIds: [Int]) async -> Bool {
        guard let link = project.link(.update) else { return false }
        do {
            let _: Project = try await app.client.fetch(
                from: link, method: "PUT",
                body: EditProjectCommand(title: project.title ?? project.displayTitle,
                                         teamIds: teamIds))
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
