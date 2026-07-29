//
//  AccountModel.swift
//  scripty
//
//  The signed-in user's own account: change the password, and see or revoke the
//  passkeys registered to it.
//
//  Gated on the `account` rel the API root advertises to anyone signed in. The
//  passkey half is gated separately on the `passkeys` link, which the server
//  offers only where the deployment has passkeys configured — so a build without
//  them shows the password form alone rather than an empty list that can only
//  404.
//
//  Registering a passkey is split in two: the platform ceremony lives in
//  PasskeyRegistrationFlow (AuthenticationServices must not leak into this
//  file, which Tests/run.sh compiles bare), and this model holds the link
//  gating and the verify call.
//

import Foundation
import Observation

@Observable
@MainActor
final class AccountModel {
    private let app: AppModel
    private let source: HALLink

    private(set) var account: Account?
    private(set) var passkeys: [Passkey] = []
    private(set) var isLoading = false
    private(set) var isWorking = false

    /// Set after a successful password change, so the form can say so rather
    /// than just clearing itself.
    var didChangePassword = false
    var errorMessage: String?

    init(app: AppModel, source: HALLink) {
        self.app = app
        self.source = source
    }

    var canChangePassword: Bool { account?.canChangePassword == true }
    /// Passkeys are offered only where the server advertised them.
    var passkeysLink: HALLink? { account?.link(.passkeys) }
    var showsPasskeys: Bool { passkeysLink != nil }

    /// Where registering a new passkey begins, when the collection advertised
    /// it. The demo backend deliberately does not: the platform ceremony can
    /// only succeed against a domain this app is associated with.
    private(set) var registerPasskeyLink: HALLink?
    var canAddPasskey: Bool { registerPasskeyLink != nil }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            account = try await app.client.fetch(from: source)
            errorMessage = nil
        } catch {
            report(error)
            return
        }
        await loadPasskeys()
    }

    func loadPasskeys() async {
        guard let link = passkeysLink else {
            passkeys = []
            registerPasskeyLink = nil
            return
        }
        do {
            let collection: HALCollection<Passkey> = try await app.client.fetch(from: link)
            adopt(collection)
        } catch APIError.notFound {
            // A deployment without passkeys configured: hide the section rather
            // than showing an error nobody can act on.
            passkeys = []
            registerPasskeyLink = nil
        } catch {
            report(error)
        }
    }

    /// The verify half of registering a passkey; PasskeyRegistrationFlow ran
    /// the platform ceremony that produced the command. Answers with the
    /// refreshed collection, like revoking does.
    @discardableResult
    func completePasskeyRegistration(verify: HALLink,
                                     command: RegisterPasskeyCommand) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            let collection: HALCollection<Passkey> = try await app.client.fetch(
                from: verify, method: "POST", body: command)
            adopt(collection)
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Changes the password. The server rejects a wrong current password, one
    /// that is too weak, or one that matches the old — each with a message worth
    /// showing verbatim, so the error text is surfaced rather than a status.
    @discardableResult
    func changePassword(current: String, new: String) async -> Bool {
        guard let link = account?.link(.changePassword), !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            account = try await app.client.fetch(
                from: link, method: "POST",
                body: ChangePasswordCommand(currentPassword: current, newPassword: new))
            didChangePassword = true
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    @discardableResult
    func deletePasskey(_ passkey: Passkey) async -> Bool {
        guard let link = passkey.link(.delete), !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            let collection: HALCollection<Passkey> = try await app.client.fetch(
                from: link, method: "DELETE")
            adopt(collection)
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Every answer that carries the collection updates both the list and the
    /// registration affordance in one place.
    private func adopt(_ collection: HALCollection<Passkey>) {
        passkeys = collection.items.sorted {
            // Newest first; an undated one sorts last rather than crashing
            // the comparison.
            ($0.created ?? .distantPast) > ($1.created ?? .distantPast)
        }
        registerPasskeyLink = collection.links[.registerPasskey]
    }

    private func report(_ error: Error) {
        // Nothing cancelled is ever shown — see `isCancelledRequest`.
        guard !error.isCancelledRequest else { return }
        app.handle(error)
        errorMessage = error.localizedDescription
    }
}
