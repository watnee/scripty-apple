//
//  UsersView.swift
//  scripty
//
//  The admin-only user directory, reached from the user menu's "Users" item.
//  Read-only: it follows the `users` link the account resource advertises and
//  lists who's on the server, matching the web /user/list page.
//

import SwiftUI

struct UsersView: View {
    let app: AppModel
    let link: HALLink

    @Environment(\.dismiss) private var dismiss
    @State private var users: [User] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List(users) { user in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(user.displayName)
                            .font(.headline)
                        if user.enabled == false {
                            Text("Disabled")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let username = user.username, username != user.displayName {
                        Text(username)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if !user.roleLabels.isEmpty {
                        Text(user.roleLabels.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            .overlay {
                if isLoading {
                    ProgressView()
                } else if let errorMessage {
                    ContentUnavailableView("Couldn't Load Users",
                                           systemImage: "person.2.slash",
                                           description: Text(errorMessage))
                } else if users.isEmpty {
                    ContentUnavailableView("No Users", systemImage: "person.2")
                }
            }
            .navigationTitle("Users")
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
            let collection: HALCollection<User> = try await app.client.fetch(from: link)
            users = collection.items.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            errorMessage = nil
        } catch {
            app.handle(error)
            errorMessage = error.localizedDescription
        }
    }
}
