//
//  ActivityModel.swift
//  scripty
//
//  A project's activity log. Read-only — there is nothing to mutate, because
//  entries are written by the services that perform the actions.
//

import Foundation
import Observation

@Observable
@MainActor
final class ActivityModel {
    private let app: AppModel
    private let source: HALLink

    private(set) var entries: [ProjectActivity] = []
    private(set) var isLoading = false
    var errorMessage: String?

    init(app: AppModel, source: HALLink) {
        self.app = app
        self.source = source
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let collection: HALCollection<ProjectActivity> = try await app.client.fetch(from: source)
            // Most recent first: activity is read from now backwards.
            entries = collection.items.sorted {
                ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
            }
            errorMessage = nil
        } catch {
            app.handle(error)
            errorMessage = error.localizedDescription
        }
    }
}
