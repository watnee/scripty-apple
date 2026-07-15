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
    private(set) var account: Account?
    private(set) var isDemo = false
    var signInError: String?

    private(set) var client = APIClient()

    /// Set via launch arguments (`-scripty.demo YES`) to boot straight into
    /// demo mode — used by scripts/demo.sh and never persisted.
    static let demoLaunchKey = "scripty.demo"

    /// The user menu's appearance preference (Light/Dark/System), persisted
    /// locally. Applied app-wide from `RootView` via `preferredColorScheme`.
    static let themeKey = "scripty.theme"
    var theme: ThemeSetting = ThemeSetting(
        rawValue: UserDefaults.standard.string(forKey: "scripty.theme") ?? "") ?? .system {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey) }
    }

    /// Admin affordances are rel-gated: the account resource carries the
    /// `users`/`teams` links only for admins (older servers omit the account
    /// resource entirely, leaving these hidden).
    var isAdmin: Bool { account?.hasLink(.users) == true }

    /// Name for the user-menu header: the account's display name if the server
    /// provides one, else the signed-in username, else a neutral fallback.
    var accountDisplayName: String {
        if let account { return account.displayName }
        if isDemo { return "Demo" }
        return client.credentials?.username ?? "Account"
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
            await loadAccount(token: token)
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
        let token = session
        do {
            apiRoot = try await client.fetch(APIRoot.self, from: client.rootLink)
            try? KeychainStore.save(credentials)
            signInError = nil
            phase = .signedIn
            await loadAccount(token: token)
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
        let token = session
        let demoClient = APIClient(baseURL: DemoBackend.baseURL, demo: DemoBackend())
        do {
            apiRoot = try await demoClient.fetch(APIRoot.self, from: demoClient.rootLink)
            client = demoClient
            isDemo = true
            signInError = nil
            phase = .signedIn
            await loadAccount(token: token)
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
        account = nil
        signInError = nil
        phase = .signedOut
    }

    /// Loads the signed-in user's account resource (`/api/account`) to drive the
    /// user menu — display name, and the rel-gated Users/Teams/change-password
    /// affordances. Best-effort: a server that predates the account resource
    /// simply leaves `account` nil, so the menu falls back to the username and
    /// hides admin items.
    private func loadAccount(token: Int) async {
        guard let link = apiRoot?.link(.account) else {
            account = nil
            return
        }
        do {
            let loaded = try await client.fetch(Account.self, from: link)
            guard token == session else { return }
            account = loaded
        } catch {
            guard token == session else { return }
            account = nil
        }
    }

    /// Changes the signed-in user's password via `PUT /api/account/password`.
    /// On success the stored Basic-auth credentials are rotated to the new
    /// password so the session keeps working; validation failures propagate to
    /// the caller for display. Only available when the account advertises the
    /// `changePassword` rel.
    func changePassword(current: String, new: String) async throws {
        guard let link = account?.link(.changePassword) else {
            throw APIError.notFound
        }
        try await client.data(
            for: link, method: "PUT",
            body: ChangePasswordCommand(currentPassword: current, newPassword: new))
        if var credentials = client.credentials {
            credentials.password = new
            client.credentials = credentials
            try? KeychainStore.save(credentials)
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
