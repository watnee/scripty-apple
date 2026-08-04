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

    /// Something worth telling the writer about the last crossing between this
    /// device and an account. Nil for the ordinary case, which is silence: a
    /// screenplay carried over without incident is not news.
    var syncNotice: SyncNotice?

    /// One thing to say about a sync, and the identity a sheet or an alert
    /// needs to tell one from the next.
    struct SyncNotice: Identifiable {
        let id: Int
        let message: String
    }

    private var nextNoticeId = 0

    /// Which screenplay here is which screenplay in an account.
    ///
    /// The record that makes a screenplay written without an account go on being
    /// the same screenplay after signing in, out, and in again — see
    /// `ProjectLinks` and `syncLinkedProjects`.
    let projectLinks = ProjectLinkStore()

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
    var workspaceScope: String { draftScope ?? Self.localWorkspaceScope }

    /// What the local workspace is called in a record that names one. Spelled
    /// once because the crossing between sessions has to name the *other* side's
    /// scope while still standing in this one.
    static let localWorkspaceScope = "local"

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
            // A launch that comes up signed in can still owe the account words:
            // an upload that failed at the last sign-in, or a server that could
            // not take one yet. Nothing happens where there is nothing owed.
            catchUpLinkedProjects()
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
        // Straight over, and before anything is on screen for the new session:
        // the writer was in a screenplay a moment ago, and this account has that
        // screenplay. Landing them on the project list instead would be the app
        // forgetting where they were in the middle of a step they took to keep
        // their work.
        carryOpenProject(from: Self.localWorkspaceScope, to: workspaceScope) {
            projectLinks.remoteId(forLocal: $0, in: workspaceScope)
        }
        phase = .signedIn
        loadEditorPreferences()
        // Only work this account has never been given. A screenplay it already
        // holds is not a thing to copy — it is the same screenplay, and it is
        // caught up below without asking.
        let offerable = written.filter {
            projectLinks.remoteId(forLocal: $0.id, in: workspaceScope) == nil
        }
        if let guestBackend, !offerable.isEmpty {
            nextOfferId += 1
            pendingGuestWorkOffer = GuestWorkOffer(
                id: nextOfferId,
                backend: guestBackend,
                projects: offerable.map {
                    GuestWorkOffer.Item(id: $0.id, title: $0.title, elements: $0.blockCount,
                                        alreadyKept: $0.alreadyKept
                                            || projectLinks.isLinkedAnywhere(local: $0.id))
                })
        }
        // Last: the sheet coming down is what `RootView` presents the offer on.
        isPresentingSignIn = false
        catchUpLinkedProjects()
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
        let backend = persisted ? localWorkspaceBackend() : DemoBackend(store: nil)
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
    ///
    /// A screenplay the two of them share is brought down first, so what the
    /// writer finds on the other side of this is what they were just looking at
    /// rather than the words as they stood whenever the copies last met. That is
    /// the whole difference between a copy and the same screenplay, and it is
    /// done here — while there is still a session to ask.
    ///
    /// Offline it simply does not happen: the local copy is left exactly as it
    /// was, which is stale but whole, and the next sign-in works out what to do
    /// about it.
    func signOutToLocal() async {
        let scope = workspaceScope
        // Read before the session goes, written before the local one is on
        // screen: `ContentView` reopens what this names as soon as it has a
        // list, so a record arriving after that would be a step late.
        carryOpenProject(from: scope, to: Self.localWorkspaceScope) {
            projectLinks.localId(forRemote: $0, in: scope)
        }
        let mirrors = await gatherMirrorsBeforeLeaving()
        endSession()
        // Into the workspace before it is opened, not after: a screenplay
        // brought down once the local session is already on screen would appear
        // to change under the writer, and the script view has no reason to look
        // again.
        await applyMirrors(mirrors, in: scope)
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

    /// Copies chosen screenplays from the guest session into the account that
    /// has just signed in, as one `.scripty.json` bundle through the very
    /// import the projects list already offers. Nothing about the archive is
    /// special-cased: the guest backend writes the same document the server's
    /// own export writes, and the server reads it the same way.
    ///
    /// Not a move, and no longer a fork either: what is on the device stays on
    /// the device, and a link is written down saying which screenplay in the
    /// account each local one has become. From here on the two are one
    /// screenplay kept in two places — see `syncLinkedProjects`.
    ///
    /// One project per upload rather than one bundle for all of them, which is
    /// the only change the link needed: an import answers with the screenplay it
    /// made, and a bundle of four answers with one of them. Without knowing
    /// which is which there is nothing to link.
    ///
    /// Answers an error message, or nil when it landed.
    func uploadGuestWork(_ offer: GuestWorkOffer, ids: [Int]) async -> String? {
        guard !ids.isEmpty else { return nil }
        guard let projectsLink = apiRoot?.link(.projects) else {
            return "This account can't take new screenplays."
        }
        do {
            let collection: HALCollection<Project> = try await client.fetch(from: projectsLink)
            guard let importLink = collection.links[.importProject] else {
                return "This account can't take new screenplays."
            }
            var kept: [Int] = []
            var failure: String?
            for id in ids {
                let (status, bundle) = await offer.backend.demoProjectsBundle(ids: [id])
                guard status == 200, !bundle.isEmpty else {
                    failure = "That work could not be read back."
                    break
                }
                do {
                    let created: Project = try await client.upload(
                        to: importLink,
                        fileName: "Scripty.scripty.json",
                        fileData: bundle,
                        mimeType: "application/json")
                    projectLinks.record(ProjectLink(localId: id, scope: workspaceScope,
                                                    remoteId: created.id,
                                                    syncedRemoteEdited: created.lastEdited))
                    kept.append(id)
                } catch {
                    guard !error.isCancelledRequest else { break }
                    handle(error)
                    failure = error.localizedDescription
                    break
                }
            }
            // Only what was taken, and only now. The local copies stay where
            // they are — signing out later must not take the writer's
            // screenplay away with the session — so all this records is that
            // the account has them, which is what keeps the next sign-in from
            // offering the same work twice.
            if !kept.isEmpty {
                await offer.backend.markHandedOff(projectIds: kept)
                // The screenplay they were in when they reached for Sign In is
                // now one of the account's. Point the record at it, so the list
                // reloading behind this sheet puts them back in it rather than
                // beside it — `ContentView.openKeptProject` acts on this.
                carryOpenProject(from: Self.localWorkspaceScope, to: workspaceScope) {
                    kept.contains($0) ? projectLinks.remoteId(forLocal: $0, in: workspaceScope) : nil
                }
                guestWorkImports += 1
            }
            return failure
        } catch {
            // A cancelled upload is the writer leaving, not a failure — see
            // `isCancelledRequest`.
            guard !error.isCancelledRequest else { return nil }
            handle(error)
            return error.localizedDescription
        }
    }

    // MARK: - One screenplay, on the device and in the account

    /// The local workspace's backend, kept for as long as the app runs.
    ///
    /// One instance, whichever session is in front. Two of them on the same file
    /// would each hold a whole copy of the workspace in memory and write it out
    /// whole, so the second to save would quietly undo the first — and a signed-
    /// in session now writes here too, catching the device's copy up with the
    /// account's.
    private var localWorkspace: DemoBackend?

    private func localWorkspaceBackend() -> DemoBackend {
        if let localWorkspace { return localWorkspace }
        let backend = DemoBackend(store: LocalWorkspaceStore())
        localWorkspace = backend
        return backend
    }

    /// Catches an account up with a linked screenplay written on this device
    /// while signed out. Runs by itself on the way in, and says nothing when
    /// there is nothing to carry.
    private func catchUpLinkedProjects() {
        guard !isDemo, !projectLinks.links(in: workspaceScope).isEmpty else { return }
        linkSyncTask = Task { await syncLinkedProjects() }
    }

    /// The crossing on the way in, while it is still going. Held so the
    /// crossing on the way *out* can wait for it: bringing the account's copy
    /// down over words that are still on their way up would undo them.
    private var linkSyncTask: Task<Void, Never>?

    /// Everything needed to leave: whatever the way-in crossing is still doing,
    /// then the account's copy of each linked screenplay.
    ///
    /// Bounded, because a writer who taps Sign Out has asked to leave, not to
    /// wait on a network. Past the deadline the work is cancelled and whatever
    /// arrived in time is used; a screenplay left behind is stale but whole, and
    /// the next sign-in works out what to do about it.
    private func gatherMirrorsBeforeLeaving(
        within seconds: Double = 8) async -> [LinkedArchive] {
        let work = Task { [self] () -> [LinkedArchive] in
            await linkSyncTask?.value
            return await archivesOfLinkedProjects()
        }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(seconds))
            work.cancel()
        }
        let mirrors = await work.value
        deadline.cancel()
        return mirrors
    }

    /// The crossing on the way in: words written on this device while signed out
    /// go into the account's copy of the same screenplay, rather than becoming a
    /// second screenplay beside it.
    ///
    /// The three cases, in the order they are decided:
    ///
    /// - The account no longer has it, or this device no longer does. The link
    ///   is a statement about two things, and with one of them gone it is only
    ///   a way to be wrong later. Forgotten; nothing else moves.
    /// - Nothing was written here since the two last met. Then this crossing has
    ///   nothing to carry, and all that is recorded is where the account's copy
    ///   has got to.
    /// - Something was written here. It goes up, into that same screenplay,
    ///   unless the account's copy has moved on too — two writers on the same
    ///   screenplay is the one case where neither copy can be thrown away, so
    ///   the local one is kept as a second screenplay and the writer is told.
    func syncLinkedProjects() async {
        guard !isDemo, let projectsLink = apiRoot?.link(.projects) else { return }
        let scope = workspaceScope
        let links = projectLinks.links(in: scope)
        guard !links.isEmpty else { return }
        let backend = localWorkspaceBackend()
        guard let collection: HALCollection<Project> =
                try? await client.fetch(from: projectsLink) else { return }
        let remotes = Dictionary(collection.items.map { ($0.id, $0) }) { first, _ in first }

        var updated = false
        var copied: [String] = []
        var stranded: [String] = []
        for link in links {
            let localExists = await backend.projectExists(link.localId)
            let localHasWork = localExists
                ? await backend.hasUnsentWork(projectId: link.localId)
                : false
            let remote = remotes[link.remoteId]
            switch LinkSync.decide(link, localExists: localExists, remote: remote,
                                   localHasWork: localHasWork) {
            case .forget:
                projectLinks.forget(local: link.localId, in: scope)
                // A screenplay the account has deleted is one this device may
                // now be the only copy of. It goes back on the list of work to
                // offer, unless some other account still holds a copy.
                if localExists, !projectLinks.isLinkedAnywhere(local: link.localId) {
                    await backend.forgetHandOff(projectIds: [link.localId])
                }
            case .nothingToSend:
                guard let remote else { break }
                projectLinks.record(ProjectLink(localId: link.localId, scope: scope,
                                                remoteId: link.remoteId,
                                                syncedRemoteEdited: remote.lastEdited))
            case .keepBoth:
                if let copy = await keepAsNewProject(link.localId, backend: backend) {
                    copied.append(copy.displayTitle)
                    updated = true
                } else if let remote {
                    stranded.append(remote.displayTitle)
                }
            case .send:
                guard let remote else { break }
                switch await push(link.localId, into: remote, backend: backend, scope: scope) {
                case .sent: updated = true
                case .unsupported: stranded.append(remote.displayTitle)
                case .failed: break
                }
            }
        }
        if updated { guestWorkImports += 1 }
        report(copied: copied, stranded: stranded)
    }

    /// What to do about one linked screenplay on the way in.
    ///
    /// A rule rather than a run of conditions inside the loop, because it is the
    /// part of this that can lose someone's writing if it is wrong, and it can
    /// be read — and checked — without a session, a network or a backend.
    enum LinkSync: Equatable {
        /// One of the two copies is gone. The link is a statement about both of
        /// them, so it is only a way to be wrong later.
        case forget
        /// Nothing has been written on this device since the two last met, so
        /// there is nothing to carry.
        case nothingToSend
        /// Words here that the account has not got, and a copy in the account
        /// that nobody else has touched: they go into it.
        case send
        /// Both copies have been written in. Neither can be thrown away, so the
        /// device's becomes a screenplay of its own in the account.
        case keepBoth

        static func decide(_ link: ProjectLink, localExists: Bool,
                           remote: Project?, localHasWork: Bool) -> LinkSync {
            guard localExists, let remote else { return .forget }
            guard localHasWork else { return .nothingToSend }
            return hasMovedSinceSync(remote, link) ? .keepBoth : .send
        }

        /// Whether the account's copy has been written in somewhere else since
        /// the two were last in step.
        ///
        /// Anything unknown — a link recorded before this was, a project the
        /// server gives no date for — counts as "it has". The cost of being
        /// wrong that way is a second screenplay; the cost of being wrong the
        /// other way is somebody's writing.
        static func hasMovedSinceSync(_ remote: Project, _ link: ProjectLink) -> Bool {
            guard let known = link.syncedRemoteEdited, let now = remote.lastEdited else { return true }
            // A second's tolerance: the two ends of this round trip spell dates
            // to different precision, and a screenplay is not re-uploaded over a
            // rounding difference.
            return abs(now.timeIntervalSince(known)) > 1
        }
    }

    private enum PushOutcome {
        case sent
        /// The server has no `replaceFromArchive` — an older deployment. Nothing
        /// is uploaded, and nothing is lost: the words stay on the device, still
        /// flagged as unsent, and the next sign-in tries again.
        case unsupported
        case failed
    }

    /// Sends this device's copy of a screenplay into the account's copy of it.
    private func push(_ localId: Int, into remote: Project,
                      backend: DemoBackend, scope: String) async -> PushOutcome {
        guard let replaceLink = remote.links?[.replaceFromArchive] else { return .unsupported }
        let (status, bundle) = await backend.demoProjectsBundle(ids: [localId])
        guard status == 200, !bundle.isEmpty else { return .failed }
        do {
            let replaced: Project = try await client.upload(
                to: replaceLink,
                fileName: "Scripty.scripty.json",
                fileData: bundle,
                mimeType: "application/json")
            await backend.markHandedOff(projectIds: [localId])
            projectLinks.record(ProjectLink(localId: localId, scope: scope,
                                            remoteId: replaced.id,
                                            syncedRemoteEdited: replaced.lastEdited))
            return .sent
        } catch {
            guard !error.isCancelledRequest else { return .failed }
            handle(error)
            return .failed
        }
    }

    /// Files this device's copy as a screenplay of its own in the account, and
    /// points the link at it. The way out of a conflict: both versions kept,
    /// which is what this app does everywhere else two copies disagree.
    private func keepAsNewProject(_ localId: Int, backend: DemoBackend) async -> Project? {
        guard let projectsLink = apiRoot?.link(.projects) else { return nil }
        let (status, bundle) = await backend.demoProjectsBundle(ids: [localId])
        guard status == 200, !bundle.isEmpty else { return nil }
        do {
            let collection: HALCollection<Project> = try await client.fetch(from: projectsLink)
            guard let importLink = collection.links[.importProject] else { return nil }
            let created: Project = try await client.upload(
                to: importLink,
                fileName: "Scripty.scripty.json",
                fileData: bundle,
                mimeType: "application/json")
            await backend.markHandedOff(projectIds: [localId])
            projectLinks.record(ProjectLink(localId: localId, scope: workspaceScope,
                                            remoteId: created.id,
                                            syncedRemoteEdited: created.lastEdited))
            return created
        } catch {
            guard !error.isCancelledRequest else { return nil }
            handle(error)
            return nil
        }
    }

    /// The account's copy of every linked screenplay, as archives, fetched while
    /// there is still a session to fetch them with. For the crossing on the way
    /// out — see `signOutToLocal`.
    private func archivesOfLinkedProjects() async -> [LinkedArchive] {
        guard !isDemo, let projectsLink = apiRoot?.link(.projects) else { return [] }
        let links = projectLinks.links(in: workspaceScope)
        guard !links.isEmpty else { return [] }
        guard let collection: HALCollection<Project> =
                try? await client.fetch(from: projectsLink) else { return [] }
        let remotes = Dictionary(collection.items.map { ($0.id, $0) }) { first, _ in first }

        var mirrors: [LinkedArchive] = []
        for link in links {
            guard let remote = remotes[link.remoteId],
                  let archiveLink = remote.links?[.exportArchive],
                  let data = try? await client.data(for: archiveLink) else { continue }
            mirrors.append(LinkedArchive(localId: link.localId, data: data,
                                         edited: remote.lastEdited))
        }
        return mirrors
    }

    /// The account's copy of one linked screenplay, in hand and on its way to
    /// the device.
    struct LinkedArchive: Sendable {
        let localId: Int
        let data: Data
        /// What the account said `lastEdited` was, so the record of where the
        /// two last met is written from the same answer the file came from.
        let edited: Date?
    }

    /// Writes those archives into the device's own copies, so the local session
    /// opens on the screenplay as the account has it.
    ///
    /// A copy with words of its own is left alone. That only happens when the
    /// crossing on the way *in* could not be made — an older server, a failed
    /// upload — and in that case the device's words are the ones that exist
    /// nowhere else.
    private func applyMirrors(_ mirrors: [LinkedArchive], in scope: String) async {
        guard !mirrors.isEmpty else { return }
        let backend = localWorkspaceBackend()
        for mirror in mirrors {
            guard await !backend.hasUnsentWork(projectId: mirror.localId) else { continue }
            guard await backend.mirrorProject(mirror.localId, fromArchive: mirror.data),
                  let link = projectLinks.link(local: mirror.localId, in: scope) else { continue }
            projectLinks.record(ProjectLink(localId: link.localId, scope: scope,
                                            remoteId: link.remoteId,
                                            syncedRemoteEdited: mirror.edited))
        }
    }

    /// Moves the "which screenplay was open" record across a crossing, so the
    /// writer comes out of it in the screenplay they went into it in — and, when
    /// they were inside one, in the song or note they were writing.
    ///
    /// Two records, because they answer different questions: one is which script
    /// the window is showing, the other is what was open above it. The screen a
    /// writer reaches for Sign In from is very often a lyric editor, and landing
    /// them on the screenplay it belongs to would be the app forgetting where
    /// they were in the middle of a step they took to keep that lyric.
    ///
    /// Nothing is written when the two sides have no such screenplay in common:
    /// the record left behind belongs to a workspace this is not, and reads as
    /// no record at all from here.
    private func carryOpenProject(from: String, to: String,
                                  translating translate: (Int) -> Int?) {
        let lastOpened = LastOpenedProject()
        guard let there = lastOpened.projectId(in: from), let here = translate(there) else { return }
        lastOpened.remember(here, in: to)
        OpenEditorState.shared.carry(from: from, to: to, translating: translate)
    }

    private func report(copied: [String], stranded: [String]) {
        var lines: [String] = []
        if !copied.isEmpty {
            lines.append(
                copied.count == 1
                    ? "“\(copied[0])” had also been changed in your account, so what you wrote "
                        + "on this device was kept as a separate screenplay. Both versions are here."
                    : "\(copied.count) screenplays had also been changed in your account, so what "
                        + "you wrote on this device was kept separately. Both versions are here.")
        }
        if !stranded.isEmpty {
            lines.append(
                stranded.count == 1
                    ? "“\(stranded[0])” could not be updated in your account just now. What you "
                        + "wrote is still on this device, and will go up next time you sign in."
                    : "\(stranded.count) screenplays could not be updated in your account just "
                        + "now. What you wrote is still on this device, and will go up next time "
                        + "you sign in.")
        }
        guard !lines.isEmpty else { return }
        nextNoticeId += 1
        syncNotice = SyncNotice(id: nextNoticeId, message: lines.joined(separator: "\n\n"))
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
        /// True when this account — or another one — has been given a copy of
        /// this screenplay before, and it has been written in on the device
        /// since. Keeping it again adds a second screenplay rather than
        /// updating the first, so it is offered unticked and labelled.
        let alreadyKept: Bool
    }
}
