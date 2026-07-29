//
//  InvitationsModel.swift
//  scripty
//
//  Who can see a screenplay: the people who already can, and the people who
//  have been invited to.
//
//  The invitation surface is gated on a link the project advertises, which the
//  server only offers when its `api-invitations` flag is on. So a deployment
//  that has not enabled invitations over the API shows nothing of it at all,
//  rather than a button that fails.
//
//  The access list is not behind that flag, and is deliberately loaded even
//  when invitations are off — a role or a team grants access with no invitation
//  involved, so "nobody has been invited" was never the same answer as "nobody
//  else can see this".
//

import Foundation
import Observation

@Observable
@MainActor
final class InvitationsModel {
    private let app: AppModel
    /// The project's `invitations` link. Nil where the deployment has not
    /// turned the API's invitation surface on — the access list still loads.
    private let source: HALLink?
    /// The project's `contact-suggestions` link, when it advertised one. Nil
    /// simply means no autofill — the invite field still works by hand.
    private let contactsSource: HALLink?
    /// The project's `access` link.
    private let accessSource: HALLink?

    private(set) var invitations: [Invitation] = []
    private(set) var people: [ProjectAccessUser] = []
    /// The teams a collaborator can be invited into — the project's own. Empty
    /// where the project has no teams, which is a real state: a collaborator
    /// cannot be invited until the project is assigned one.
    private(set) var inviteTeams: [InviteTeam] = []
    private(set) var links = HALLinks()
    private(set) var isLoading = false
    private(set) var isWorking = false
    var errorMessage: String?

    private(set) var suggestions: [ContactSuggestion] = []
    private var suggestTask: Task<Void, Never>?

    var canInvite: Bool { links.contains(.sendInvitation) }
    var canSuggest: Bool { contactsSource != nil }
    var knowsWhoHasAccess: Bool { accessSource != nil }

    /// A collaborator can only be invited if the project has a team to invite
    /// them into. The server enforces this; the client hides the "Can edit"
    /// path rather than offering an invitation it knows will be rejected.
    var canInviteCollaborator: Bool { !inviteTeams.isEmpty }

    var collaborators: [Invitation] { invitations.filter { !$0.isViewOnly } }
    var readers: [Invitation] { invitations.filter(\.isViewOnly) }

    init(app: AppModel,
         source: HALLink?,
         contactsSource: HALLink? = nil,
         accessSource: HALLink? = nil) {
        self.app = app
        self.source = source
        self.contactsSource = contactsSource
        self.accessSource = accessSource
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        if let source {
            do {
                let collection: HALCollection<Invitation> = try await app.client.fetch(from: source)
                adopt(collection)
                errorMessage = nil
            } catch {
                report(error)
            }
        }
        await loadInviteTeams()
        await loadAccess()
    }

    /// The teams a collaborator may be invited into, advertised on the
    /// invitation collection. Quiet on failure like the access list: an empty
    /// list simply hides the collaborator path, the same as a project with no
    /// teams, rather than raising an alert over the invite form.
    private func loadInviteTeams() async {
        guard let link = links[.inviteTeams] else {
            inviteTeams = []
            return
        }
        if let collection: HALCollection<InviteTeam> = try? await app.client.fetch(from: link) {
            inviteTeams = collection.items
        }
    }

    /// Quiet on failure. This list is context beside the invitations, and an
    /// alert about it would sit on top of the thing the writer came here to do.
    private func loadAccess() async {
        guard let accessSource else { return }
        if let collection: HALCollection<ProjectAccessUser> =
            try? await app.client.fetch(from: accessSource) {
            people = collection.items
        }
    }

    /// Invites an address. Answers the same whether or not that address already
    /// has an account — the server will not say, so the client cannot either.
    ///
    /// A collaborator invitation must name one of the project's teams; a reader
    /// invitation takes none. Passing a `teamId` the project does not own is the
    /// server's to reject, so this sends what the caller chose from `inviteTeams`.
    @discardableResult
    func invite(_ email: String, viewOnly: Bool, teamId: Int? = nil) async -> Bool {
        guard let link = links[.sendInvitation] else { return false }
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return await act(link, method: "POST",
                         body: SendInvitationCommand(email: trimmed,
                                                     teamId: viewOnly ? nil : teamId,
                                                     viewOnly: viewOnly))
    }

    /// Looks up contacts matching what has been typed so far, debounced so a
    /// fast typist does not fire a request per keystroke. An empty query clears
    /// the list rather than asking the server for everyone.
    func suggestContacts(matching query: String) {
        suggestTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let contactsSource, trimmed.count >= 2 else {
            suggestions = []
            return
        }
        suggestTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let link = contactsSource.addingQuery(["q": trimmed])
            do {
                let collection: HALCollection<ContactSuggestion> = try await app.client.fetch(from: link)
                guard !Task.isCancelled else { return }
                suggestions = collection.items
            } catch {
                // Autofill is a convenience; a failed lookup just offers nothing
                // rather than interrupting the writer with an error.
                suggestions = []
            }
        }
    }

    func clearSuggestions() {
        suggestTask?.cancel()
        suggestions = []
    }

    @discardableResult
    func revoke(_ invitation: Invitation) async -> Bool {
        guard let link = invitation.link(.revoke) else { return false }
        return await act(link, method: "DELETE")
    }

    private func act(_ link: HALLink, method: String, body: (any Encodable)? = nil) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            let collection: HALCollection<Invitation> = try await app.client.fetch(
                from: link, method: method, body: body)
            adopt(collection)
            errorMessage = nil
            return true
        } catch APIError.server(let status) where status == 429 {
            // Sending is rate limited per user; say so plainly rather than
            // reporting it as a failure the writer can retry immediately.
            errorMessage = "Too many invitations sent recently. Try again later."
            return false
        } catch {
            report(error)
            return false
        }
    }

    private func adopt(_ collection: HALCollection<Invitation>) {
        invitations = collection.items
        links = collection.links
    }

    private func report(_ error: Error) {
        // Nothing cancelled is ever shown — see `isCancelledRequest`.
        guard !error.isCancelledRequest else { return }
        app.handle(error)
        errorMessage = error.localizedDescription
    }
}
