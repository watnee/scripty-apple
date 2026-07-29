//
//  TitlePageModel.swift
//  scripty
//
//  Editable front matter for one project — the iPad counterpart of the web
//  app's Title Page screen. The fields start from whatever the project
//  resource carried and are saved back through its `update` link.
//

import Foundation
import Observation

@Observable @MainActor
final class TitlePageModel {
    private let app: AppModel

    /// The project as the server last described it. Replaced by the resource
    /// returned from a successful save.
    private(set) var project: Project

    /// The project's own name — what the projects list calls it, and what the
    /// title page falls back to when no screenplay title is set. Editable here
    /// because this is the screen the screenplay's names live on; until now it
    /// could only be changed by swiping the row in the sidebar, which is a
    /// journey from inside the script it names.
    var projectName: String
    var screenplayTitle: String
    var writers: String
    var contactInfo: String
    var screenplayVersion: String

    private(set) var isSaving = false
    var errorMessage: String?

    /// Draft colours in production order — the web form's `<datalist>`.
    static let versionSuggestions = [
        "White Draft", "Blue Revision", "Pink Revision", "Yellow Revision",
        "Green Revision", "Goldenrod Revision", "Buff Revision",
        "Salmon Revision", "Cherry Revision",
        "Second Blue Revision", "Second Pink Revision",
    ]

    init(app: AppModel, project: Project) {
        self.app = app
        self.project = project
        projectName = project.title ?? ""
        screenplayTitle = project.screenplayTitle ?? ""
        writers = project.writers ?? ""
        contactInfo = project.contactInfo ?? ""
        screenplayVersion = project.screenplayVersion ?? ""
    }

    /// No `update` link means this reader may look but not save.
    var canEdit: Bool { project.hasLink(.update) }

    var hasChanges: Bool {
        trimmed(projectName) != (project.title ?? "")
            || trimmed(screenplayTitle) != (project.screenplayTitle ?? "")
            || trimmed(writers) != (project.writers ?? "")
            || trimmed(contactInfo) != (project.contactInfo ?? "")
            || trimmed(screenplayVersion) != (project.screenplayVersion ?? "")
    }

    /// The server will not take a blank project name, so an emptied field stops
    /// the save here rather than at the round trip. A project the server never
    /// named is the exception: there is nothing to erase, and the save keeps
    /// sending what it always sent.
    var canSave: Bool {
        !trimmed(projectName).isEmpty || (project.title ?? "").isEmpty
    }

    // MARK: - Preview (mirrors the web page's live preview rules)

    /// The screenplay title, falling back to the project name and then to a
    /// placeholder — always uppercased, as a title page is set.
    var previewTitle: String {
        let entered = trimmed(screenplayTitle)
        if !entered.isEmpty { return entered.uppercased() }
        let fallback = (project.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "UNTITLED SCREENPLAY" : fallback.uppercased()
    }

    /// nil hides the "written by" line entirely, as the web preview does.
    var previewWriters: String? {
        let value = trimmed(writers)
        return value.isEmpty ? nil : value
    }

    var previewVersion: String? {
        let value = trimmed(screenplayVersion)
        return value.isEmpty ? nil : value
    }

    var previewContact: String? {
        let value = trimmed(contactInfo)
        return value.isEmpty ? nil : value
    }

    // MARK: - Saving

    /// PUT the title-page fields through the project's `update` link. The
    /// project's own name rides along as `title`; a field left blank on a
    /// project the server never named falls back to what this command sent
    /// before rather than to a blank the server would refuse.
    @discardableResult
    func save() async -> Bool {
        guard let link = project.link(.update), !isSaving, canSave else { return false }
        isSaving = true
        defer { isSaving = false }
        let name = trimmed(projectName)
        do {
            let updated: Project = try await app.client.fetch(
                from: link, method: "PUT",
                body: EditProjectCommand(title: name.isEmpty
                                            ? (project.title ?? project.displayTitle)
                                            : name,
                                         screenplayTitle: trimmed(screenplayTitle),
                                         writers: trimmed(writers),
                                         contactInfo: trimmed(contactInfo),
                                         screenplayVersion: trimmed(screenplayVersion)))
            apply(updated)
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Re-seeds the fields from a server response so the form and the preview
    /// show exactly what was stored.
    private func apply(_ updated: Project) {
        project = updated
        projectName = updated.title ?? ""
        screenplayTitle = updated.screenplayTitle ?? ""
        writers = updated.writers ?? ""
        contactInfo = updated.contactInfo ?? ""
        screenplayVersion = updated.screenplayVersion ?? ""
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func report(_ error: Error) {
        app.handle(error)
        errorMessage = error.localizedDescription
    }
}
