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

    /// False when the keychain refused to hold this session's credentials, so
    /// signing in again will be needed after the app is quit.
    private(set) var isSessionPersisted = true

    private(set) var client = APIClient()

    /// Set via launch arguments (`-scripty.demo YES`) to boot straight into
    /// demo mode — used by scripts/demo.sh and never persisted.
    static let demoLaunchKey = "scripty.demo"

    /// Whose unsaved drafts the disk store holds: server + account, so drafts
    /// can never leak between accounts or servers. Nil while signed out and in
    /// demo — the demo's blocks don't survive a relaunch, so a persisted draft
    /// would point at ids that no longer exist.
    var draftScope: String? {
        guard !isDemo, let username = client.credentials?.username else { return nil }
        let host = client.baseURL.host ?? client.baseURL.absoluteString
        return host + "|" + username.lowercased()
    }

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
            loadEditorPreferences()
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
            // A keychain that won't hold the credentials doesn't stop this
            // session, but it does mean the next cold launch lands back on
            // this screen — better to say so now than to look like a bug then.
            do {
                try KeychainStore.save(credentials)
                isSessionPersisted = true
            } catch {
                isSessionPersisted = false
            }
            signInError = nil
            phase = .signedIn
            loadEditorPreferences()
        } catch APIError.unauthorized {
            client.credentials = nil
            signInError = "Incorrect username or password."
        } catch {
            client.credentials = nil
            signInError = error.localizedDescription
        }
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
            loadEditorPreferences()
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
        CapitalizationSettings.shared.reset()
    }

    /// Loads the server-stored editor preferences once signed in, if the root
    /// advertises them. Fire-and-forget: the editor already shows the cached (or
    /// default) value, so nothing waits on this, and a failure is silent.
    private func loadEditorPreferences() {
        guard let link = apiRoot?.link(.capitalizationPreferences) else {
            CapitalizationSettings.shared.reset()
            return
        }
        let loadClient = client
        Task { await CapitalizationSettings.shared.load(using: loadClient, from: link) }
    }

    /// Global error routing: revoked credentials end the session.
    func handle(_ error: Error) {
        if case APIError.unauthorized = error {
            signOut()
            signInError = "Your session ended. Please sign in again."
        }
    }
}
