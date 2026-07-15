//
//  AppModel.swift
//  scripty
//
//  Session state: credentials, the API root document, and the global
//  signed-in/out phase. A 401 from anywhere routes through handle(_:)
//  and drops the user back to the login screen.
//

import Foundation
import Observation

@Observable @MainActor
final class AppModel {
    enum Phase {
        case loading
        case signedOut
        case signedIn
    }

    private(set) var phase: Phase = .loading
    private(set) var apiRoot: APIRoot?
    private(set) var isDemo = false
    var signInError: String?

    private(set) var client = APIClient()

    /// Set via launch arguments (`-scripty.demo YES`) to boot straight into
    /// demo mode — used by scripts/demo.sh and never persisted.
    static let demoLaunchKey = "scripty.demo"

    /// Bumped whenever the session is replaced. An in-flight bootstrap that
    /// resumes against a stale token must not overwrite the newer session —
    /// otherwise `scripty://demo` on a cold launch loses a race with the
    /// stored-credential check and drops the user back at the login screen.
    private var session = 0

    /// Called once at launch: try stored credentials against the API root.
    func bootstrap() async {
        if UserDefaults.standard.bool(forKey: Self.demoLaunchKey) {
            await enterDemo()
            return
        }
        guard let stored = KeychainStore.load() else {
            phase = .signedOut
            return
        }
        let token = session
        client.credentials = stored
        do {
            let root = try await client.fetch(APIRoot.self, from: client.rootLink)
            guard token == session else { return }
            apiRoot = root
            phase = .signedIn
        } catch APIError.unauthorized {
            guard token == session else { return }
            client.credentials = nil
            KeychainStore.delete()
            phase = .signedOut
        } catch {
            guard token == session else { return }
            client.credentials = nil
            signInError = error.localizedDescription
            phase = .signedOut
        }
    }

    func signIn(username: String, password: String) async {
        let credentials = Credentials(username: username, password: password)
        client.credentials = credentials
        do {
            apiRoot = try await client.fetch(APIRoot.self, from: client.rootLink)
            try? KeychainStore.save(credentials)
            signInError = nil
            phase = .signedIn
        } catch APIError.unauthorized {
            client.credentials = nil
            signInError = "Incorrect username or password."
        } catch {
            client.credentials = nil
            signInError = error.localizedDescription
        }
    }

    /// Signs in with a passkey: runs the WebAuthn assertion, exchanges it for a
    /// bearer token, and persists that token as the session credential.
    func signInWithPasskey() async {
        do {
            let credentials = try await PasskeyService().signIn()
            client.credentials = credentials
            apiRoot = try await client.fetch(APIRoot.self, from: client.rootLink)
            try? KeychainStore.save(credentials)
            signInError = nil
            phase = .signedIn
        } catch PasskeyService.PasskeyError.cancelled {
            // User backed out of the system sheet — leave the login screen as-is.
        } catch {
            client.credentials = nil
            signInError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    /// Registers a new passkey for the signed-in account. Throws on failure so
    /// the caller can surface it inline; cancellation is reported as such.
    func registerPasskey(label: String) async throws {
        guard let credentials = client.credentials, !isDemo else {
            throw PasskeyService.PasskeyError.notAuthenticated
        }
        try await PasskeyService().register(label: label, authorization: credentials)
    }

    /// The client's passkey-list endpoint. Not a HAL rel — built from the base
    /// URL — so it degrades to an empty list against servers without it.
    var passkeysLink: HALLink {
        HALLink(href: client.baseURL.appendingPathComponent("api/passkeys").absoluteString)
    }

    /// Removes a registered passkey via Spring Security's WebAuthn delete filter.
    func deletePasskey(_ passkey: Passkey) async throws {
        let link = HALLink(href: client.baseURL
            .appendingPathComponent("webauthn/register/\(passkey.id)").absoluteString)
        _ = try await client.data(for: link, method: "DELETE")
    }

    /// Enters the offline demo: a fresh in-memory backend seeded with a
    /// sample screenplay. Stored real credentials are left untouched.
    ///
    /// Re-entering while already in the demo is a no-op, so opening
    /// `scripty://demo` again doesn't throw away the edits being demoed.
    func enterDemo() async {
        guard !isDemo else { return }
        session += 1
        let demoClient = APIClient(baseURL: DemoBackend.baseURL, demo: DemoBackend())
        do {
            apiRoot = try await demoClient.fetch(APIRoot.self, from: demoClient.rootLink)
            client = demoClient
            isDemo = true
            signInError = nil
            phase = .signedIn
        } catch {
            signInError = error.localizedDescription
            phase = .signedOut
        }
    }

    func signOut() {
        session += 1
        if isDemo {
            isDemo = false
            client = APIClient()
        } else {
            KeychainStore.delete()
            client.credentials = nil
        }
        apiRoot = nil
        signInError = nil
        phase = .signedOut
    }

    /// Global error routing: revoked credentials end the session.
    func handle(_ error: Error) {
        if case APIError.unauthorized = error {
            signOut()
            signInError = "Your session ended. Please sign in again."
        }
    }
}
