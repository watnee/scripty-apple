//
//  ScriptImportModel.swift
//  scripty
//
//  Uploads a screenplay file into an existing project. The server parses it
//  and REPLACES every block in the project, so the UI confirms first (the
//  web app's import button asks the same question before submitting).
//

import Foundation
import Observation

@Observable @MainActor
final class ScriptImportModel {
    private let app: AppModel

    /// The project as the server last described it; replaced by the resource
    /// returned from a successful import.
    private(set) var project: Project

    private(set) var isImporting = false
    var errorMessage: String?

    init(app: AppModel, project: Project) {
        self.app = app
        self.project = project
    }

    /// The whole affordance is gated on the link: no `importScript`, no button.
    var canImport: Bool { project.hasLink(.importScript) }

    /// POST the file as multipart/form-data. On success the caller must reload
    /// the script — every block in the project has just been replaced.
    @discardableResult
    func importScript(fileName: String, data: Data,
                      mimeType: String = "application/octet-stream") async -> Project? {
        guard let link = project.link(.importScript), !isImporting else { return nil }
        isImporting = true
        defer { isImporting = false }
        do {
            let updated: Project = try await app.client.upload(
                to: link, fileName: fileName, fileData: data, mimeType: mimeType)
            project = updated
            errorMessage = nil
            return updated
        } catch {
            report(error)
            return nil
        }
    }

    private func report(_ error: Error) {
        // Nothing cancelled is ever shown — see `isCancelledRequest`.
        guard !error.isCancelledRequest else { return }
        app.handle(error)
        errorMessage = error.localizedDescription
    }
}
