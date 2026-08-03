//
//  ShareView.swift
//  scripty
//
//  Who has access to a screenplay, and inviting more.
//
//  "People with access" comes first because it is the honest answer to the
//  question the sheet is opened with. Access follows from a role or a team as
//  much as from an invitation, so this list can hold people no invitation ever
//  named — and until it was here, an empty invitation list read as "nobody else
//  can see this", which was often untrue.
//
//  Collaborators and readers are listed apart because they are different
//  grants: a collaborator gets an account and can write, a reader gets a link
//  and can only read. Conflating them would make it easy to hand out the wrong
//  one.
//
//  There is no link to copy here. The server never returns an invite token or
//  URL, and the invitee's journey — accepting, or opening a view-only link —
//  happens in email and a browser, where it already works and where no account
//  is needed.
//

import SwiftUI

struct ShareView: View {
    @State private var model: InvitationsModel
    let projectTitle: String

    @Environment(\.dismiss) private var dismiss
    @State private var draftEmail = ""
    @State private var inviteAsReader = false
    /// The team a collaborator will join. A collaborator invitation must name
    /// one of the project's teams, so this is chosen before "Can edit" can be
    /// sent; a reader invitation ignores it.
    @State private var selectedTeamId: Int?
    @State private var pendingRevoke: Invitation?
    @State private var sentNotice: String?
    @FocusState private var emailFocused: Bool

    init(app: AppModel,
         source: HALLink?,
         contactsSource: HALLink? = nil,
         accessSource: HALLink? = nil,
         projectTitle: String) {
        _model = State(initialValue: InvitationsModel(
            app: app, source: source,
            contactsSource: contactsSource, accessSource: accessSource))
        self.projectTitle = projectTitle
    }

    var body: some View {
        NavigationStack {
            Form {
                if model.canInvite {
                    inviteSection
                }

                if !model.people.isEmpty {
                    Section {
                        ForEach(model.people) { person in
                            accessRow(person)
                        }
                    } header: {
                        Text("People with Access")
                    } footer: {
                        // The reasons are the server's, rendered per person, so
                        // nothing here restates the access rules in Swift.
                        Text("Includes anyone whose role or team lets them open "
                             + "“\(projectTitle)”, invited or not.")
                    }
                }

                if !model.collaborators.isEmpty {
                    Section("Collaborators") {
                        ForEach(model.collaborators) { row($0) }
                    }
                }

                if !model.readers.isEmpty {
                    Section {
                        ForEach(model.readers) { row($0) }
                    } header: {
                        Text("View-Only Readers")
                    } footer: {
                        Text("Readers open the screenplay from a link in their email. "
                             + "They cannot edit it.")
                    }
                }

                // Only when there is genuinely nothing to report. Saying nobody
                // has been invited while the access list is showing five people
                // would be answering a question nobody asked.
                if model.collaborators.isEmpty && model.readers.isEmpty
                    && model.people.isEmpty && !model.isLoading {
                    Section {
                        Text("Nobody else can see “\(projectTitle)”.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Share")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await model.load()
                syncSelectedTeam()
            }
            .refreshable {
                await model.load()
                syncSelectedTeam()
            }
            .onChange(of: model.inviteTeams) { _, _ in syncSelectedTeam() }
            .alert("Remove Access", isPresented: revokeBinding) {
                Button("Cancel", role: .cancel) { pendingRevoke = nil }
                Button("Remove", role: .destructive) {
                    let invitation = pendingRevoke
                    pendingRevoke = nil
                    Task {
                        guard let invitation else { return }
                        await model.revoke(invitation)
                    }
                }
            } message: {
                Text("Revoke the invitation for \(pendingRevoke?.displayEmail ?? "")?")
            }
            .alert("Error", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    private var inviteSection: some View {
        Section {
            TextField("Email address", text: $draftEmail)
                .textContentType(.emailAddress)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                #if !os(macOS)
                .keyboardType(.emailAddress)
                #endif
                .focused($emailFocused)
                .onChange(of: draftEmail) { _, text in
                    if model.canSuggest { model.suggestContacts(matching: text) }
                }

            // Names the project already knows, filled in on a tap. Only shown
            // while the field has focus, so a chosen address is not second-
            // guessed by the list reappearing under it.
            if emailFocused {
                ForEach(model.suggestions) { suggestion in
                    Button {
                        pick(suggestion)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.displayName)
                                .foregroundStyle(.primary)
                            HStack(spacing: 6) {
                                Text(suggestion.email)
                                if let source = suggestion.sourceLabel, !source.isEmpty {
                                    Text("· \(source)")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Picker("Access", selection: $inviteAsReader) {
                Text("Can edit").tag(false)
                Text("Can read").tag(true)
            }
            .pickerStyle(.segmented)

            // A collaborator joins a team, and only the project's own teams are
            // valid. Shown only for "Can edit"; a reader has no team.
            if !inviteAsReader {
                if model.canInviteCollaborator {
                    Picker("Team", selection: $selectedTeamId) {
                        ForEach(model.inviteTeams) { team in
                            Text(team.displayName).tag(Optional(team.id))
                        }
                    }
                } else {
                    // Nothing to join. The web offers no editor invite here
                    // either — the same wall, said plainly rather than as a
                    // rejected send.
                    Text("Assign this project to a team before inviting an editor. "
                         + "You can still invite someone to read.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                send()
            } label: {
                if model.isWorking {
                    ProgressView()
                } else {
                    Text("Send Invitation")
                }
            }
            .disabled(!canSend)
        } header: {
            Text("Invite")
        } footer: {
            // The server will not say whether an address is already registered,
            // so neither does this — the confirmation is deliberately the same
            // either way.
            Text(sentNotice
                 ?? "They will get an email. Scripty does not say whether an address "
                 + "already has an account.")
        }
    }

    /// One person who can already see the screenplay. Nothing to swipe: access
    /// that comes from a role or a team is not revoked from here, and offering
    /// a Remove that quietly did nothing would be worse than offering none.
    private func accessRow(_ person: ProjectAccessUser) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                if let why = person.accessLabel, !why.isEmpty {
                    Text(why)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(person.permission)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quaternary.opacity(0.5), in: Capsule())
                .foregroundStyle(person.writes ? .primary : .secondary)
        }
    }

    private func row(_ invitation: Invitation) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(invitation.displayEmail)
            HStack(spacing: 6) {
                if let status = invitation.statusLabel, !status.isEmpty {
                    Text(status)
                }
                if let team = invitation.teamName, !team.isEmpty {
                    Text("· \(team)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .swipeActions(edge: .trailing) {
            if invitation.canRevoke {
                Button(role: .destructive) {
                    pendingRevoke = invitation
                } label: {
                    Label("Remove", systemImage: "person.badge.minus")
                }
            }
        }
    }

    /// Fills the field from a suggestion and puts the list away, leaving the
    /// send to a deliberate second tap.
    private func pick(_ suggestion: ContactSuggestion) {
        draftEmail = suggestion.email
        model.clearSuggestions()
        emailFocused = false
    }

    /// A reader needs only an address; a collaborator also needs a team, and
    /// there is no team to pick until the project has one.
    private var canSend: Bool {
        guard !model.isWorking else { return false }
        guard !draftEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if inviteAsReader { return true }
        return model.canInviteCollaborator && selectedTeamId != nil
    }

    private func send() {
        let email = draftEmail
        let asReader = inviteAsReader
        let teamId = selectedTeamId
        draftEmail = ""
        emailFocused = false
        model.clearSuggestions()
        Task {
            if await model.invite(email, viewOnly: asReader, teamId: teamId) {
                sentNotice = "Invitation sent to \(email)."
            } else if draftEmail.isEmpty {
                // The field was cleared optimistically, so the address has to
                // come back when the invitation doesn't go — retyping it is
                // the only other way to try again. Left alone if they have
                // started on a different address in the meantime.
                draftEmail = email
            }
        }
    }

    /// Keep a team chosen whenever there is one to choose: default to the first
    /// as soon as the list arrives, and never leave a stale id once the list
    /// changes underneath it.
    private func syncSelectedTeam() {
        if let current = selectedTeamId,
           model.inviteTeams.contains(where: { $0.id == current }) {
            return
        }
        selectedTeamId = model.inviteTeams.first?.id
    }

    private var revokeBinding: Binding<Bool> {
        Binding(get: { pendingRevoke != nil },
                set: { if !$0 { pendingRevoke = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }
}
