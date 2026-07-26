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

    /// Whether this device currently has a route to the network. Injectable
    /// so tests can drive transitions by hand.
    let connectivity: ConnectivityMonitor

    /// True when this session was signed in from the offline copy of the API
    /// root rather than the server — the connection was down at launch. The
    /// next reconnect replaces the copy with the real thing.
    private(set) var isOfflineSession = false

    /// Nil means the real system monitor; tests pass a hand-driven one.
    /// (Constructed in the body: a default argument is evaluated outside the
    /// actor, where the monitor's initializer may not run.)
    init(connectivity: ConnectivityMonitor? = nil) {
        self.connectivity = connectivity ?? ConnectivityMonitor()
        wireOfflineCheck()
        self.connectivity.onOnline = { [weak self] in
            guard let self else { return }
            Task { await self.refreshAfterReconnect() }
        }
    }

    /// Point the client's fail-fast gate at the monitor. Applied to every
    /// real client this model creates; the demo client is left unwired, since
    /// the demo answers in-process and works with no connection at all.
    private func wireOfflineCheck() {
        client.offlineCheck = { [weak connectivity] in
            !(connectivity?.isOnline ?? true)
        }
    }

    /// Where the offline copies of this account's documents live. Nil exactly
    /// when `draftScope` is nil (signed out, demo), and scoped the same way,
    /// so cached scripts can never leak between accounts or servers.
    var offlineStore: OfflineStore? {
        draftScope.map { OfflineStore(scope: $0) }
    }

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
        // Let the system report the path once before the first request, so an
        // offline cold launch goes straight to the cached copy instead of
        // sitting in the connectivity wait it is guaranteed to lose.
        await connectivity.waitForFirstVerdict()
        do {
            let data = try await client.data(for: client.rootLink)
            let root = try client.decode(APIRoot.self, from: data)
            guard token == session else { return }
            apiRoot = root
            isOfflineSession = false
            phase = .signedIn
            offlineStore?.save(data, .root)
            loadEditorPreferences()
        } catch APIError.unauthorized {
            guard token == session else { return }
            client.credentials = nil
            KeychainStore.delete()
            phase = .signedOut
        } catch {
            guard token == session else { return }
            // A launch the network failed — not one the server refused — can
            // still open from the copy of the API root saved last session, so
            // the writer's cached scripts stay readable on a plane. The
            // credentials stay set: the reconnect path re-fetches with them.
            if error.isRetryableAPIError,
               let snapshot = offlineStore?.load(.root),
               let root = try? client.decode(APIRoot.self, from: snapshot.data) {
                apiRoot = root
                isOfflineSession = true
                phase = .signedIn
                return
            }
            client.credentials = nil
            signInError = error.localizedDescription
            phase = .signedOut
        }
    }

    /// The connection is back. A session that opened from the offline copy
    /// trades it for the real root — quietly, keeping the cached one if the
    /// fetch fails again (the monitor can be ahead of an actual route).
    private func refreshAfterReconnect() async {
        guard isOfflineSession else { return }
        let token = session
        do {
            let data = try await client.data(for: client.rootLink)
            let root = try client.decode(APIRoot.self, from: data)
            guard token == session, isOfflineSession else { return }
            apiRoot = root
            isOfflineSession = false
            offlineStore?.save(data, .root)
            loadEditorPreferences()
        } catch {
            // Still unreachable; the next transition tries again.
        }
    }

    func signIn(username: String, password: String) async {
        let credentials = Credentials(username: username, password: password)
        client.credentials = credentials
        do {
            let data = try await client.data(for: client.rootLink)
            apiRoot = try client.decode(APIRoot.self, from: data)
            isOfflineSession = false
            offlineStore?.save(data, .root)
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

    /// Completes a passkey sign-in: adopt the bearer token the server minted
    /// (a passkey leaves this client with no password for Basic), fetch the
    /// root with it, and persist like any other session.
    ///
    /// The ceremony itself lives in PasskeySignInFlow — AuthenticationServices
    /// must not leak into this file, which Tests/run.sh compiles bare.
    @discardableResult
    func adoptPasskeySession(username: String, token: String, revokeHref: String?) async -> Bool {
        session += 1
        let credentials = Credentials(username: username, token: token, revokeHref: revokeHref)
        client.credentials = credentials
        do {
            let data = try await client.data(for: client.rootLink)
            apiRoot = try client.decode(APIRoot.self, from: data)
            isOfflineSession = false
            offlineStore?.save(data, .root)
            do {
                try KeychainStore.save(credentials)
                isSessionPersisted = true
            } catch {
                isSessionPersisted = false
            }
            signInError = nil
            phase = .signedIn
            loadEditorPreferences()
            return true
        } catch {
            client.credentials = nil
            signInError = error.localizedDescription
            return false
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
            wireOfflineCheck()
        } else {
            revokeTokenIfAny()
            KeychainStore.delete()
            client.credentials = nil
        }
        apiRoot = nil
        signInError = nil
        isOfflineSession = false
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

    /// A passkey session's bearer token should not outlive the sign-out.
    /// Fire-and-forget on a client of its own: sign-out is synchronous and
    /// must not wait on the network, and the main client's credentials are
    /// about to be cleared out from under any shared request.
    private func revokeTokenIfAny() {
        guard let credentials = client.credentials, credentials.token != nil,
              let href = credentials.revokeHref else { return }
        let revokeClient = APIClient(baseURL: client.baseURL, credentials: credentials)
        Task {
            try? await revokeClient.data(for: HALLink(href: href), method: "DELETE")
        }
    }

    /// Global error routing: revoked credentials end the session.
    func handle(_ error: Error) {
        if case APIError.unauthorized = error {
            signOut()
            signInError = "Your session ended. Please sign in again."
        }
    }
}
