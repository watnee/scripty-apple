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
//  Registering a new passkey is not here: it is a WebAuthn ceremony the browser
//  and the server's filters run between them, so the API offers listing and
//  revoking only.
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
            return
        }
        do {
            let collection: HALCollection<Passkey> = try await app.client.fetch(from: link)
            passkeys = collection.items.sorted {
                // Newest first; an undated one sorts last rather than crashing
                // the comparison.
                ($0.created ?? .distantPast) > ($1.created ?? .distantPast)
            }
        } catch APIError.notFound {
            // A deployment without passkeys configured: hide the section rather
            // than showing an error nobody can act on.
            passkeys = []
        } catch {
            report(error)
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
            passkeys = collection.items.sorted {
                ($0.created ?? .distantPast) > ($1.created ?? .distantPast)
            }
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    private func report(_ error: Error) {
        app.handle(error)
        errorMessage = error.localizedDescription
    }
}
