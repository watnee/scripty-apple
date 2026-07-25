//
//  UserProfileView.swift
//  scripty
//
//  One account's profile: its identity, its roles, and — the reason this
//  screen exists — the breakdown of which projects it can reach and why.
//  Mirrors the web admin profile page (`user/show.html`): the list shows who
//  someone is, this shows what they can get to.
//
//  The access breakdown is computed by the server and carried only on the
//  single-user resource, so it is fetched from the account's `self` link when
//  the screen appears; identity and roles come from the list item already in
//  hand, so the screen is useful immediately while the projects load.
//

import SwiftUI

struct UserProfileView: View {
    let user: User
    /// Shared with the list, so a fetch reports through the same error channel.
    let model: UsersModel

    /// The full resource, once fetched — the only source of `projectAccess`.
    @State private var detail: User?
    @State private var isLoading = false

    /// The privileged roles that grant access to every project, matching the
    /// server's `hasPrivilegedProjectRole`. Shown as a note, the way the web
    /// profile does, so an all-projects reason is explained rather than implied.
    private var isPrivileged: Bool {
        [user.admin, user.director, user.producer, user.writer, user.actor,
         user.crew, user.directorOfPhotography, user.castingDirector]
            .contains(true)
    }

    private var access: [UserProjectAccess]? { detail?.projectAccess }

    var body: some View {
        List {
            Section("Identity") {
                LabeledContent("Name", value: user.displayName)
                if let username = user.username, !username.isEmpty {
                    LabeledContent("Username", value: "@\(username)")
                }
                if let team = user.team, !team.isEmpty {
                    LabeledContent("Team", value: team)
                }
                if user.enabled == false {
                    LabeledContent("Status") {
                        Text("Disabled").foregroundStyle(.orange)
                    }
                }
            }

            Section("Roles") {
                Text(user.roleSummary)
                    .foregroundStyle(.secondary)
            }

            accessSection
        }
        .navigationTitle(user.displayName)
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            isLoading = true
            detail = await model.detail(for: user)
            isLoading = false
        }
    }

    @ViewBuilder
    private var accessSection: some View {
        Section {
            if user.enabled == false {
                Text("Account is disabled — no project access.")
                    .foregroundStyle(.secondary)
            } else if let access {
                if access.isEmpty {
                    Text("No projects accessible.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(access) { project in
                        projectRow(project)
                    }
                }
            } else if isLoading {
                HStack {
                    ProgressView()
                    Text("Loading projects…").foregroundStyle(.secondary)
                }
            } else {
                // The fetch failed; the error surfaced through the model. Say so
                // plainly rather than leaving an empty section that reads as
                // "no access".
                Text("Couldn't load project access.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Projects")
        } footer: {
            if user.enabled != false && isPrivileged {
                Text("A privileged role grants access to every project.")
            }
        }
    }

    private func projectRow(_ project: UserProjectAccess) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.projectName ?? "Untitled")
                if let reason = project.accessReason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            permissionChip(project)
        }
    }

    /// The view-only / can-edit chip, coloured like the web's
    /// `access-permission-chip--edit` / `--view`. The label is the server's own
    /// wording, so the client never has to decide what "edit" means.
    private func permissionChip(_ project: UserProjectAccess) -> some View {
        let canEdit = project.canEdit == true
        return Text(project.permissionLabel ?? (canEdit ? "Can edit" : "View only"))
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background((canEdit ? Color.green : Color.secondary).opacity(0.18),
                        in: Capsule())
            .foregroundStyle(canEdit ? Color.green : Color.secondary)
    }
}
