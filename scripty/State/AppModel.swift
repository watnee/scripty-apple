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

    /// Whether this session is the local one, answered in-process by
    /// `DemoBackend` rather than by a server.
    ///
    /// It is what a launch with no stored credentials lands in: the app opens
    /// on a workspace instead of a login wall, and signing in is something the
    /// writer does when they want their work kept — see `enterDemo()`. The name
    /// is unchanged because the session is unchanged; what moved is when it
    /// happens, and it is still exactly what `scripty://demo` opens.
    private(set) var isDemo = false

    /// Whether this local session is the throwaway kind: the screenshot runs,
    /// entered by `-scripty.demo YES` and nothing else.
    ///
    /// The distinction `isDemo` no longer draws. A signed-out device's
    /// workspace is kept on disk and its ids mean the same thing next launch,
    /// so everything that remembers a place — the project reopened at launch,
    /// the screen above it, the Home Screen menu, the widgets — works there
    /// exactly as it does in an account. None of that holds for a session that
    /// is reseeded every run: its project 1 is a different screenplay each
    /// time, and letting it write those records would mean a screenshot pass
    /// costing the writer their place.
    ///
    /// So: `isDemo` asks "is there an account behind this?", which is what the
    /// cloud badges and the sign-in offer want. This asks "will any of it be
    /// here tomorrow?", which is what anything *recording* something wants.
    private(set) var isEphemeralDemo = false

    /// Whether the sign-in screen is being shown over the app.
    ///
    /// The signed-out *phase* is now the narrow case — a session the server
    /// revoked — so a guest asking to sign in gets a sheet over their own
    /// workspace instead, and cancelling leaves everything they wrote in place.
    var isPresentingSignIn = false

    /// Work written without an account, waiting to be offered to the account
    /// that just signed in.
    ///
    /// Parked rather than presented: the sign-in sheet is on its way out at
    /// exactly this moment, and a sheet raised while another is being dismissed
    /// is dropped without a word. `RootView` picks this up once that one has
    /// gone, and clears it.
    var pendingGuestWorkOffer: GuestWorkOffer?

    /// Bumped when guest work has been copied into the account, so the project
    /// list knows to reload — the upload happens after the list has already
    /// loaded for the new session.
    private(set) var guestWorkImports = 0

    var signInError: String?

    /// The token from a recovery email's link, when one has opened the app.
    ///
    /// Held here rather than passed down because of when it arrives: tapping
    /// the link may well be what launched the app, so it lands before there is
    /// anything on screen to hand it to — and it can land on a device that is
    /// still signed in. `RootView` picks it up in any phase and clears it once
    /// the sheet is done with it.
    var passwordResetToken: String?

    /// The song or note a Home Screen widget row was tapped for, waiting for a
    /// project list to open it against.
    ///
    /// Here for the same reason the reset token is: the tap is often what
    /// launched the app, so it arrives before the sidebar exists — and on a
    /// cold launch the session has not even been established yet. `ContentView`
    /// picks it up once there is a list to answer it with, and clears it.
    var pendingWidgetDestination: WidgetDestination?

    /// The flagged element a Bookmarks widget row was tapped for, waiting for a
    /// project list to open it against.
    ///
    /// Separate from `pendingWidgetDestination` rather than folded into it: that
    /// one names a song or note and ends at a sheet, this one names an element
    /// and ends at a scroll, and a type that could be either would only push the
    /// question of which one down to `ContentView`.
    var pendingBookmarkDestination: BookmarkDestination?

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

    /// Point a client's fail-fast gate at the monitor. Applied to every real
    /// client this model creates; the demo client is left unwired, since the
    /// demo answers in-process and works with no connection at all.
    @discardableResult
    private func wireOfflineCheck(_ target: APIClient? = nil) -> APIClient {
        let target = target ?? client
        target.offlineCheck = { [weak connectivity] in
            !(connectivity?.isOnline ?? true)
        }
        return target
    }

    /// Where the offline copies of this account's documents live. Nil exactly
    /// when `draftScope` is nil (a local session), and scoped the same way, so
    /// cached scripts can never leak between accounts or servers.
    var offlineStore: OfflineStore? {
        draftScope.map { OfflineStore(scope: $0) }
    }

    /// Set via launch arguments (`-scripty.demo YES`) to boot straight into a
    /// throwaway local session — used by scripts/demo.sh and never persisted.
    ///
    /// The backend behind it is the same one a signed-out device writes in;
    /// what this flag picks is the *ephemeral* variant, seeded fresh every
    /// launch and never written to disk. That is what makes it a demo: the
    /// screenshot runs need the same app every time, and one that remembered
    /// yesterday's fiddling would be no use to them. Nothing in the interface
    /// reaches this and no URL opens it.
    static let demoLaunchKey = "scripty.demo"

    /// Whose unsaved drafts the disk store holds: server + account, so drafts
    /// can never leak between accounts or servers.
    ///
    /// Nil in a local session, and deliberately so even now that one survives a
    /// relaunch. Everything downstream of this — `UnsavedDraftStore`,
    /// `OfflineBlockQueue`, `OfflineStore` — exists because a save can fail or
    /// a read can find no network, and neither can happen against a backend in
    /// this process: a local write is answered and on disk before the call
    /// returns. A store here would be a second copy of `LocalWorkspaceStore`
    /// that never held anything.
    ///
    /// The debounce window is covered without it. `flushPendingCommits()` runs
    /// the outstanding saves on the way to the background, and locally each one
    /// lands in the workspace file synchronously — which is as far as a
    /// signed-in session gets too.
    var draftScope: String? {
        guard !isDemo, let username = client.credentials?.username else { return nil }
        let host = client.baseURL.host ?? client.baseURL.absoluteString
        return host + "|" + username.lowercased()
    }

    /// Which set of screenplays a device-wide record is about.
    ///
    /// The records that remember a *place* — `LastOpenedProject`,
    /// `OpenEditorState` — are one per device rather than one per account,
    /// because they are the app window's state and not the writer's. That works
    /// only as long as a stored id is either found in the list that comes back
    /// or is not; it breaks the moment two workspaces number their screenplays
    /// the same way, which a local session and a fresh account both do, from 1.
    /// Signing in after writing without an account would then reopen whichever
    /// of the account's screenplays happened to share a number with the local
    /// one — the right kind of thing, from the wrong place.
    ///
    /// So each record carries this, and one written elsewhere reads as no
    /// record. `draftScope` already spells an account uniquely (server plus
    /// user); the local session has exactly one workspace per device and needs
    /// no more than a name. It contains no `|`, which every account scope does,
    /// so the two can never collide.
    var workspaceScope: String { draftScope ?? "local" }

    /// Counts the offers made, so each gets an identity of its own.
    private var nextOfferId = 0

    /// Bumped whenever the session is replaced. An in-flight bootstrap that
    /// resumes against a stale token must not overwrite the newer session —
    /// otherwise a passkey sign-in that lands while the stored-credential check
    /// is still in flight is overwritten by it, dropping the user back at the
    /// login screen.
    private var session = 0

    /// Called once at launch: try stored credentials against the API root.
    ///
    /// A device with no stored credentials is not sent to a login screen. It
    /// opens the local session instead, so the app can be used — and written in
    /// — without an account; signing in is offered from inside it, and is what
    /// gives the writing somewhere to live. Credentials the *server* refuses
    /// still land on the login screen: that writer has an account, and the only
    /// useful thing to say is that it needs signing into again.
    func bootstrap() async {
        if UserDefaults.standard.bool(forKey: Self.demoLaunchKey) {
            await enterDemo(persisted: false)
            return
        }
        guard let stored = KeychainStore.load() else {
            await enterDemo()
            return
        }
        let token = session
        client.credentials = stored
        // Let the system report the path once before the first request, so an
        // offline cold launch goes straight to the cached copy instead of
        // spending a doomed round trip on the way there.
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
            // A cancelled launch has not failed, it has been abandoned — by a
            // sign-out, or by the spinner this runs from going away. Deciding
            // anything on it would throw away credentials the server never
            // refused and land the writer on the login screen.
            guard !error.isCancelledRequest else { return }
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
        let attempt = signingInClient(with: credentials)
        do {
            let data = try await attempt.data(for: attempt.rootLink)
            let root = try attempt.decode(APIRoot.self, from: data)
            await adopt(root, rootData: data, from: attempt, credentials: credentials)
        } catch APIError.unauthorized {
            abandon(attempt)
            signInError = "Incorrect username or password."
        } catch {
            abandon(attempt)
            guard !error.isCancelledRequest else { return }
            signInError = error.localizedDescription
        }
    }

    /// The client everything to do with signing in talks to.
    ///
    /// In a guest session the installed client is answered in-process by the
    /// demo backend, which has no accounts, no passkeys and no password to
    /// recover — asking it anything about signing in gets the demo's answer to
    /// a question about the writer's real account. So the sign-in screen, the
    /// passkey ceremonies and the attempt itself use this one instead: a real
    /// client, kept *beside* the guest session rather than replacing it, so an
    /// attempt that fails leaves the writer exactly where they were, in the
    /// workspace they have been writing in. Only success installs it (`adopt`).
    var signInClient: APIClient {
        guard isDemo else { return client }
        if let guestSignInClient { return guestSignInClient }
        let fresh = wireOfflineCheck(APIClient())
        guestSignInClient = fresh
        return fresh
    }

    private var guestSignInClient: APIClient?

    private func signingInClient(with credentials: Credentials) -> APIClient {
        let attempt = signInClient
        attempt.credentials = credentials
        return attempt
    }

    /// Takes on a session the server has just accepted, whatever proved it.
    ///
    /// The client is installed here rather than before the request, so a guest
    /// session survives a failed attempt untouched. When the writer came from
    /// one, what they wrote there is offered to the account they have just
    /// reached — the backend is held open past the swap for exactly that.
    private func adopt(_ root: APIRoot, rootData: Data, from attempt: APIClient,
                       credentials: Credentials) async {
        // Asked first, and awaited before anything else moves: taking the sheet
        // down is what makes the offer presentable, so the offer has to exist
        // by then. Everything below this line is synchronous for that reason.
        let guestBackend = isDemo ? client.demoBackend : nil
        let written = await guestBackend?.guestWork() ?? []

        session += 1
        client = attempt
        guestSignInClient = nil
        isDemo = false
        isEphemeralDemo = false
        apiRoot = root
        isOfflineSession = false
        offlineStore?.save(rootData, .root)
        // A keychain that won't hold the credentials doesn't stop this session,
        // but it does mean the next cold launch lands back signed out — better
        // to say so now than to look like a bug then.
        do {
            try KeychainStore.save(credentials)
            isSessionPersisted = true
        } catch {
            isSessionPersisted = false
        }
        signInError = nil
        phase = .signedIn
        loadEditorPreferences()
        if let guestBackend, !written.isEmpty {
            nextOfferId += 1
            pendingGuestWorkOffer = GuestWorkOffer(
                id: nextOfferId,
                backend: guestBackend,
                projects: written.map {
                    GuestWorkOffer.Item(id: $0.id, title: $0.title, elements: $0.blockCount)
                })
        }
        // Last: the sheet coming down is what `RootView` presents the offer on.
        isPresentingSignIn = false
    }

    /// Gives up on a sign-in attempt: the refused credentials come off the
    /// client that carried them, and nothing else moves. A guest's own client
    /// was never replaced, so there is nothing to put back — the workspace on
    /// screen has not noticed any of this.
    private func abandon(_ attempt: APIClient) {
        attempt.credentials = nil
    }

    /// Completes a passkey sign-in: adopt the bearer token the server minted
    /// (a passkey leaves this client with no password for Basic), fetch the
    /// root with it, and persist like any other session.
    ///
    /// The ceremony itself lives in PasskeySignInFlow — AuthenticationServices
    /// must not leak into this file, which Tests/run.sh compiles bare.
    @discardableResult
    func adoptPasskeySession(username: String, token: String, revokeHref: String?) async -> Bool {
        let credentials = Credentials(username: username, token: token, revokeHref: revokeHref)
        let attempt = signingInClient(with: credentials)
        do {
            let data = try await attempt.data(for: attempt.rootLink)
            let root = try attempt.decode(APIRoot.self, from: data)
            await adopt(root, rootData: data, from: attempt, credentials: credentials)
            return true
        } catch {
            abandon(attempt)
            guard !error.isCancelledRequest else { return false }
            signInError = error.localizedDescription
            return false
        }
    }

    /// Waits until the launch has decided whether there is a session, and says
    /// what it decided.
    ///
    /// Only App Intents call this. Everything else on screen is inside
    /// `RootView`, which shows a spinner for `.loading` and so never has to ask
    /// — but an intent can be dispatched into a process that has only just
    /// started, before `bootstrap()` has finished or, on the very first frame,
    /// before `RootView` has even begun it. Acting on `.loading` would read as
    /// "you are signed out" to a writer who is not.
    ///
    /// A polling loop rather than a continuation: `phase` is set from five
    /// places, and a waiter list would be a sixth thing that has to be kept
    /// honest by every one of them. The cost is a handful of wake-ups on a
    /// path taken a few times a day.
    ///
    /// The deadline is what stops Siri spinning forever behind a launch that
    /// never lands — a request sitting in `waitsForConnectivity`, say. Timing
    /// out answers `.loading`, which the caller reports as "try again".
    func awaitReady(timeout: Duration = .seconds(15)) async -> Phase {
        let deadline = ContinuousClock.now + timeout
        while phase == .loading, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return phase
    }

    /// Enters the local session: the workspace this device last wrote, or a
    /// sample screenplay on one that never has. Stored real credentials are
    /// left untouched.
    ///
    /// This is what a launch with no account lands in, as well as what
    /// `scripty://demo` and the Try Scripty script open. Everything here is
    /// writable and none of it leaves the device — but it does now outlive the
    /// app being quit, so a writer without an account has somewhere to keep
    /// working rather than a session that expires when they put the phone down.
    /// Signing in still offers to take it with them.
    ///
    /// `persisted: false` is the demo proper — the screenshot runs, which want
    /// the same app every time and would be worse than useless if they showed
    /// yesterday's fiddling.
    ///
    /// Re-entering while already in it is a no-op, so opening `scripty://demo`
    /// again doesn't throw away the edits being demoed.
    func enterDemo(persisted: Bool = true) async {
        guard !isDemo else { return }
        session += 1
        let backend = DemoBackend(store: persisted ? LocalWorkspaceStore() : nil)
        let demoClient = APIClient(baseURL: DemoBackend.baseURL, demo: backend)
        do {
            apiRoot = try await demoClient.fetch(APIRoot.self, from: demoClient.rootLink)
            client = demoClient
            isDemo = true
            isEphemeralDemo = !persisted
            signInError = nil
            phase = .signedIn
            loadEditorPreferences()
        } catch {
            guard !error.isCancelledRequest else { return }
            signInError = error.localizedDescription
            phase = .signedOut
        }
    }

    /// Ends the session and shows the sign-in screen. For the session that
    /// ended without being asked to — credentials the server revoked — where
    /// the only useful thing to say is that signing in again is needed.
    func signOut() {
        endSession()
        phase = .signedOut
    }

    /// Ends the session and goes back to the local one, which is where a device
    /// with no account belongs: signing out is not a reason to be shut out of
    /// the app. What was written in the account stays in the account, and the
    /// local session comes back to whatever *it* was last left holding —
    /// including anything a previous sign-in was offered and declined.
    func signOutToLocal() async {
        endSession()
        await enterDemo()
    }

    private func endSession() {
        session += 1
        if isDemo {
            isDemo = false
            isEphemeralDemo = false
            client = APIClient()
            wireOfflineCheck()
        } else {
            revokeTokenIfAny()
            KeychainStore.delete()
            client.credentials = nil
        }
        guestSignInClient = nil
        pendingGuestWorkOffer = nil
        apiRoot = nil
        signInError = nil
        isOfflineSession = false
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

    // MARK: - Keeping what was written without an account

    /// Copies chosen screenplays out of the guest session and into the account
    /// that has just signed in, as one `.scripty.json` bundle through the very
    /// import the projects list already offers. Nothing about the archive is
    /// special-cased: the guest backend writes the same document the server's
    /// own export writes, and the server reads it the same way.
    ///
    /// Answers an error message, or nil when it landed.
    func uploadGuestWork(_ offer: GuestWorkOffer, ids: [Int]) async -> String? {
        guard !ids.isEmpty else { return nil }
        guard let projectsLink = apiRoot?.link(.projects) else {
            return "This account can't take new screenplays."
        }
        let (status, bundle) = await offer.backend.demoProjectsBundle(ids: ids)
        guard status == 200, !bundle.isEmpty else {
            return "That work could not be read back."
        }
        do {
            let collection: HALCollection<Project> = try await client.fetch(from: projectsLink)
            guard let importLink = collection.links[.importProject] else {
                return "This account can't take new screenplays."
            }
            _ = try await client.upload(to: importLink,
                                        fileName: "Scripty.scripty.json",
                                        fileData: bundle,
                                        mimeType: "application/json")
            // Only now, and only what was taken: the local workspace outlives
            // this session, so a screenplay left in it after the account has a
            // copy would come back as a stale second one at the next sign-out.
            // Anything the writer left unticked stays put.
            await offer.backend.handOff(projectIds: ids)
            guestWorkImports += 1
            return nil
        } catch {
            // A cancelled upload is the writer leaving, not a failure — see
            // `isCancelledRequest`.
            guard !error.isCancelledRequest else { return nil }
            handle(error)
            return error.localizedDescription
        }
    }
}

/// The screenplays written without an account, offered to the account that has
/// just signed in.
///
/// Holds the guest backend itself, not a copy of the work: the bundle is built
/// only if the writer says yes, and until then the session it came from is
/// still the one that could answer any question about it.
struct GuestWorkOffer: Identifiable {
    /// One per offer, so a second sign-in in the same run presents a new sheet
    /// rather than reusing the last one's identity.
    let id: Int
    let backend: DemoBackend
    let projects: [Item]

    struct Item: Identifiable, Hashable {
        let id: Int
        let title: String
        let elements: Int
    }
}
