//
//  TeamsView.swift
//  scripty
//
//  The admin-only team list, reached from the user menu's "Teams" item.
//  Read-only: follows the `teams` link the account resource advertises,
//  mirroring the web /team/list page.
//

import SwiftUI

struct TeamsView: View {
    let app: AppModel
    let link: HALLink

    @Environment(\.dismiss) private var dismiss
    @State private var teams: [Team] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List(teams) { team in
                Text(team.displayName)
                    .font(.body)
            }
            .overlay {
                if isLoading {
                    ProgressView()
                } else if let errorMessage {
                    ContentUnavailableView("Couldn't Load Teams",
                                           systemImage: "person.3.sequence",
                                           description: Text(errorMessage))
                } else if teams.isEmpty {
                    ContentUnavailableView("No Teams", systemImage: "person.3")
                }
            }
            .navigationTitle("Teams")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let collection: HALCollection<Team> = try await app.client.fetch(from: link)
            teams = collection.items.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            errorMessage = nil
        } catch {
            app.handle(error)
            errorMessage = error.localizedDescription
        }
    }
}
