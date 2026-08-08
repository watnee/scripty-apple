//
//  DemoBackend.swift
//  scripty
//
//  An in-process, in-memory stand-in for the Scripty API, used by demo
//  mode. It speaks the same HAL dialect as the real server — the rest of
//  the app follows `_links` exactly as it would against production, so
//  every rel-gated affordance (edit, delete, undo, export…) works offline
//  against the sample screenplay seeded below.
//

import Foundation

actor DemoBackend {
    /// Never contacted; only anchors the absolute hrefs demo links carry.
    static let baseURL = URL(string: "https://demo.scripty.local")!

    // MARK: - Store

    private struct DemoProject: Codable {
        var id: Int
        var title: String
        var writers: String?
        var lastEdited: Date
        var screenplayTitle: String?
        var contactInfo: String?
        var screenplayVersion: String?
        /// The teams the project belongs to, by id. Seeded to the one "Demo"
        /// team every project already showed a badge for.
        var teamIds: [Int] = [1]
        /// Set once the project has been put aside. Unlike a trashed project,
        /// which moves to `trashedProjects` wholesale, an archived one stays
        /// right here: it is still readable by id and still goes into a bundle
        /// export, and only the collection filters it out — exactly the split
        /// the server draws with `archived_at` beside `deleted_at`.
        var archivedAt: Date?
    }

    private struct DemoBlock: Codable {
        var id: Int
        var order: Int
        var content: String
        var type: String
        var personId: Int?
        var bookmarked = false
        var pinned = false
        var tags: String?
        var textAlign: String?
        var font: String?
        var highlight: String?
        var textBold: Bool?
        var textItalic: Bool?
        var textUnderline: Bool?
    }

    private struct DemoPerson: Codable {
        var id: Int
        var name: String
        var fullName: String
        var actorId: Int?
    }

    /// Actors live outside any one project — the same person can be cast in
    /// several — so they are stored flat and filtered by `projectIds`.
    private struct DemoActor: Codable {
        var id: Int
        var first: String
        var last: String
        /// The bytes of whatever was uploaded, held so the demo can serve them
        /// back — the point of the feature is seeing the picture appear.
        /// Defaulted so the seed and the create route need not mention it.
        var headshot: Data? = nil
        var phone: String?
        var email: String?
        var projectIds: [Int]
    }

    private struct DemoDocument: Codable {
        var id: Int
        var projectId: Int
        var title: String
        var documentType: String   // "SONG" or "NOTES"
        var content: String
        var sortOrder: Int
        var createdAt: Date
        var updatedAt: Date
        /// What this song or note *is*, as against where it happens to be kept.
        ///
        /// The id names a row in this workspace and an account numbers its own
        /// documents from 1 as well, so the two can never recognise each other
        /// by it. This they can: it is minted here, travels in the archive, and
        /// is what the account matches on when the same song comes back — which
        /// is the whole of how a lyric written signed out stays one lyric across
        /// signing in, out, and in again. The server's column of the same name
        /// (V58) is the other end of it.
        ///
        /// Optional because workspaces were already on disk before it existed: a
        /// synthesised decoder reads a missing key as a failed decode, and a
        /// failed decode is read as no workspace at all. `uidOf` fills one in
        /// the first time it is asked for.
        var uid: String? = nil
        /// The folder this is filed under, or nil for an unfiled one.
        ///
        /// Optional for the same reason `uid` is: a synthesised decoder reads a
        /// missing key as a failed decode, and a failed decode is read as no
        /// workspace at all — so a workspace written before folders existed
        /// must still open, with every document unfiled, which is exactly what
        /// was true then.
        var folderId: Int? = nil
    }

    /// A folder, in the demo's own shape. Flat, per project, per list — the
    /// same three rules the server's table is built on.
    private struct DemoFolder: Codable {
        var id: Int
        var projectId: Int
        /// "SONG" or "NOTES": which list this folder belongs to.
        var documentType: String
        var name: String
        var createdAt: Date
        var updatedAt: Date
    }

    private var projects: [DemoProject] = []
    private var blocks: [Int: [DemoBlock]] = [:]      // keyed by project id
    private var people: [Int: [DemoPerson]] = [:]     // keyed by project id
    private var documents: [Int: [DemoDocument]] = [:] // keyed by project id
    private var folders: [DemoFolder] = []
    private var nextFolderId = 1
    private var actors: [DemoActor] = []
    private var undoStacks: [Int: [[DemoBlock]]] = [:]
    private var versions: [Int: [DemoVersion]] = [:]
    private var nextVersionId = 1
    private var comments: [DemoComment] = []
    private var nextCommentId = 1
    private var songBlocks: [Int: [DemoSongBlock]] = [:]
    private var nextSongBlockId = 1
    private var songEditions: [DemoSongEdition] = []
    private var nextSongEditionId = 1
    // Trash and history are per song version, as on the server: undoing in one
    // version must not reach into another's lines.
    private var deletedSongBlocks: [Int: [DeletedDemoSongBlock]] = [:]
    private var nextDeletedSongBlockId = 1
    private var songUndoStacks: [Int: [[DemoSongBlock]]] = [:]
    private var songRedoStacks: [Int: [[DemoSongBlock]]] = [:]
    private var deletedDocuments: [Int: [DeletedDemoDocument]] = [:]
    /// Documents put aside on purpose. Kept apart from `deletedDocuments`
    /// because nothing here is on a clock and nothing is ever purged from it.
    private var archivedDocuments: [Int: [ArchivedDemoDocument]] = [:]
    private var invitations: [DemoInvitation] = []
    private var nextInvitationId = 1
    private var activity: [DemoActivity] = []
    private var nextActivityId = 1
    private var editions: [DemoEdition] = []
    private var editionBlocks: [Int: [DemoBlock]] = [:]
    private var nextEditionId = 1
    private var trashedProjects: [TrashedDemoProject] = []
    private var deletedBlocks: [Int: [DeletedDemoBlock]] = [:]
    private var nextDeletedBlockId = 1
    private var redoStacks: [Int: [[DemoBlock]]] = [:]
    private var defaultProjectId: Int?
    private var nextProjectId = 1
    private var nextBlockId = 1
    private var nextPersonId = 1
    private var nextDocumentId = 1
    private var nextActorId = 1
    private var seeded = false

    /// The projects this session actually wrote — created here, or a sample one
    /// the writer has since changed. It is what "your work" means when a guest
    /// signs in and is asked whether to keep it: a sample screenplay nobody
    /// touched is not work, and offering to upload it would put a copy of the
    /// demo into every new account.
    ///
    /// Filled from `touch(_:)` and from project creation, which between them are
    /// every route that moves a project's `lastEdited` — the same "this changed"
    /// the sidebar already sorts on.
    private var writtenProjectIds: Set<Int> = []

    /// The projects an account has already been given a copy of.
    ///
    /// The copy here is not taken away when that happens — signing out is not a
    /// reason to be shut out of your own screenplay, so the local one stays and
    /// stays writable, and the two go their own way from that moment. What this
    /// remembers is that they *have* a shared origin, which is the one thing the
    /// next sign-in needs to know: it must not offer this again as though it
    /// were new, or a writer who signs in twice ends up with the same screenplay
    /// in their account twice.
    ///
    /// Writing in it again does put it back on the offer — the local copy has
    /// moved on and there is no way to send those words anywhere else — but the
    /// sheet says plainly that keeping it adds a second copy, and leaves it
    /// unticked.
    private var handedOffProjectIds: Set<Int> = []

    // MARK: - Persistence

    /// Where this workspace is kept between launches, or nil for a session that
    /// is meant to evaporate.
    ///
    /// Nil is the demo proper — `-scripty.demo YES`, which `scripts/demo.sh`
    /// and the screenshot runs use. That mode exists to show the same app every
    /// time, and a demo that remembered yesterday's fiddling would stop being a
    /// demo. A device with no account is the other caller, and everything it
    /// writes here is the writer's only copy, so it gets a store.
    private let store: LocalWorkspaceStore?

    /// Every store in the actor, in one document.
    ///
    /// Flat and exhaustive on purpose. These stores point at each other by id,
    /// so a snapshot missing one of them is not a smaller workspace but an
    /// inconsistent one — a project whose blocks are gone, or a `nextBlockId`
    /// that hands out an id something already answers to. Anything added to the
    /// actor's state belongs here too; `Tests/LocalWorkspace` round-trips a
    /// mutated backend to catch the ones that are forgotten.
    private struct Snapshot: Codable {
        var projects: [DemoProject]
        var blocks: [Int: [DemoBlock]]
        var people: [Int: [DemoPerson]]
        var documents: [Int: [DemoDocument]]
        /// Optional for the reason `handedOffProjectIds` is: added after
        /// devices were already keeping workspaces, and a missing key would
        /// otherwise fail the whole decode and open the device on the sample
        /// screenplay with its own writing gone. Absent means "no folders yet".
        var folders: [DemoFolder]?
        var nextFolderId: Int?
        var actors: [DemoActor]
        var undoStacks: [Int: [[DemoBlock]]]
        var redoStacks: [Int: [[DemoBlock]]]
        var versions: [Int: [DemoVersion]]
        var nextVersionId: Int
        var comments: [DemoComment]
        var nextCommentId: Int
        var songBlocks: [Int: [DemoSongBlock]]
        var nextSongBlockId: Int
        var songEditions: [DemoSongEdition]
        var nextSongEditionId: Int
        var deletedSongBlocks: [Int: [DeletedDemoSongBlock]]
        var nextDeletedSongBlockId: Int
        var songUndoStacks: [Int: [[DemoSongBlock]]]
        var songRedoStacks: [Int: [[DemoSongBlock]]]
        var songVersions: [Int: [DemoSongVersion]]
        var deletedDocuments: [Int: [DeletedDemoDocument]]
        var archivedDocuments: [Int: [ArchivedDemoDocument]]
        var invitations: [DemoInvitation]
        var nextInvitationId: Int
        var activity: [DemoActivity]
        var nextActivityId: Int
        var editions: [DemoEdition]
        var editionBlocks: [Int: [DemoBlock]]
        var nextEditionId: Int
        var trashedProjects: [TrashedDemoProject]
        var deletedBlocks: [Int: [DeletedDemoBlock]]
        var nextDeletedBlockId: Int
        var defaultProjectId: Int?
        var nextProjectId: Int
        var nextBlockId: Int
        var nextPersonId: Int
        var nextDocumentId: Int
        var nextActorId: Int
        var writtenProjectIds: Set<Int>
        /// Optional, unlike everything above it, because it was added after
        /// devices were already keeping workspaces on disk. A synthesised
        /// decoder treats a missing key as a failure even where the property has
        /// a default, and a snapshot that fails to decode is read as no snapshot
        /// at all — so a non-optional field here would have opened every
        /// existing signed-out device on the sample screenplay, with its own
        /// writing gone. Absent means "nothing has been handed off yet", which
        /// is what was true before this existed.
        var handedOffProjectIds: Set<Int>?
        var capitalization: [String: Bool]
        var auditions: [Int: [Int: Set<Int>]]
        var teamsStore: [DemoTeam]
        var nextTeamId: Int
        var usersStore: [DemoUser]
        var nextUserId: Int
        var accountPassword: String
        var passkeyStore: [DemoPasskey]
        /// A song's recordings, described. Optional for the reason
        /// `handedOffProjectIds` above is: a workspace written before this
        /// existed has no such key, and a synthesised decoder reads a missing
        /// non-optional as a failure — which would be read in turn as "no
        /// workspace" and open the device on the sample screenplay with the
        /// writer's own work gone.
        ///
        /// The bytes are not here. They go to files beside this one — see
        /// `songAudioData` — because this document is rewritten after every
        /// change, and re-encoding four takes to base64 on each keystroke is
        /// not a thing to do to a phone.
        var songAudio: [Int: [DemoSongAudio]]?
        var nextSongAudioId: Int?
    }

    init(store: LocalWorkspaceStore? = nil) {
        self.store = store
    }

    /// The stored workspace, restored whole — or nil, which means seed.
    ///
    /// Read on the first request rather than in `init`, both because an actor's
    /// initialiser cannot reach its own isolated state to fill it and because
    /// this is where the seed already happens: the two are the same decision.
    ///
    /// A copy that no longer decodes — the app updated and a field moved — is
    /// treated as no copy, so that device opens on the sample screenplay rather
    /// than on an empty list it cannot explain. That is a real loss, which is
    /// why the format is one private struct in one file: the shape should move
    /// rarely, and never by accident.
    private func restoreStoredWorkspace() -> Bool {
        guard let data = store?.load(),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return false
        }
        restore(snapshot)
        // A workspace written before songs and notes had durable names. Given
        // them here and written straight back, so the name a song is carried
        // under is the same one every time it is carried.
        if nameDocumentsWithoutUids() { persist() }
        return true
    }

    private func capture() -> Snapshot {
        Snapshot(projects: projects,
                 blocks: blocks,
                 people: people,
                 documents: documents,
                 folders: folders,
                 nextFolderId: nextFolderId,
                 actors: actors,
                 undoStacks: undoStacks,
                 redoStacks: redoStacks,
                 versions: versions,
                 nextVersionId: nextVersionId,
                 comments: comments,
                 nextCommentId: nextCommentId,
                 songBlocks: songBlocks,
                 nextSongBlockId: nextSongBlockId,
                 songEditions: songEditions,
                 nextSongEditionId: nextSongEditionId,
                 deletedSongBlocks: deletedSongBlocks,
                 nextDeletedSongBlockId: nextDeletedSongBlockId,
                 songUndoStacks: songUndoStacks,
                 songRedoStacks: songRedoStacks,
                 songVersions: songVersions,
                 deletedDocuments: deletedDocuments,
                 archivedDocuments: archivedDocuments,
                 invitations: invitations,
                 nextInvitationId: nextInvitationId,
                 activity: activity,
                 nextActivityId: nextActivityId,
                 editions: editions,
                 editionBlocks: editionBlocks,
                 nextEditionId: nextEditionId,
                 trashedProjects: trashedProjects,
                 deletedBlocks: deletedBlocks,
                 nextDeletedBlockId: nextDeletedBlockId,
                 defaultProjectId: defaultProjectId,
                 nextProjectId: nextProjectId,
                 nextBlockId: nextBlockId,
                 nextPersonId: nextPersonId,
                 nextDocumentId: nextDocumentId,
                 nextActorId: nextActorId,
                 writtenProjectIds: writtenProjectIds,
                 handedOffProjectIds: handedOffProjectIds,
                 capitalization: capitalization,
                 auditions: auditions,
                 teamsStore: teamsStore,
                 nextTeamId: nextTeamId,
                 usersStore: usersStore,
                 nextUserId: nextUserId,
                 accountPassword: accountPassword,
                 passkeyStore: passkeyStore,
                 songAudio: songAudio,
                 nextSongAudioId: nextSongAudioId)
    }

    private func restore(_ snapshot: Snapshot) {
        projects = snapshot.projects
        blocks = snapshot.blocks
        people = snapshot.people
        documents = snapshot.documents
        folders = snapshot.folders ?? []
        // Past every id already in use, so a workspace stored before this
        // existed cannot hand out an id one of its own folders answers to.
        nextFolderId = snapshot.nextFolderId ?? ((folders.map(\.id).max() ?? 0) + 1)
        actors = snapshot.actors
        undoStacks = snapshot.undoStacks
        redoStacks = snapshot.redoStacks
        versions = snapshot.versions
        nextVersionId = snapshot.nextVersionId
        comments = snapshot.comments
        nextCommentId = snapshot.nextCommentId
        songBlocks = snapshot.songBlocks
        nextSongBlockId = snapshot.nextSongBlockId
        songEditions = snapshot.songEditions
        nextSongEditionId = snapshot.nextSongEditionId
        deletedSongBlocks = snapshot.deletedSongBlocks
        nextDeletedSongBlockId = snapshot.nextDeletedSongBlockId
        songUndoStacks = snapshot.songUndoStacks
        songRedoStacks = snapshot.songRedoStacks
        songVersions = snapshot.songVersions
        deletedDocuments = snapshot.deletedDocuments
        archivedDocuments = snapshot.archivedDocuments
        invitations = snapshot.invitations
        nextInvitationId = snapshot.nextInvitationId
        activity = snapshot.activity
        nextActivityId = snapshot.nextActivityId
        editions = snapshot.editions
        editionBlocks = snapshot.editionBlocks
        nextEditionId = snapshot.nextEditionId
        trashedProjects = snapshot.trashedProjects
        deletedBlocks = snapshot.deletedBlocks
        nextDeletedBlockId = snapshot.nextDeletedBlockId
        defaultProjectId = snapshot.defaultProjectId
        nextProjectId = snapshot.nextProjectId
        nextBlockId = snapshot.nextBlockId
        nextPersonId = snapshot.nextPersonId
        nextDocumentId = snapshot.nextDocumentId
        nextActorId = snapshot.nextActorId
        writtenProjectIds = snapshot.writtenProjectIds
        handedOffProjectIds = snapshot.handedOffProjectIds ?? []
        capitalization = snapshot.capitalization
        auditions = snapshot.auditions
        teamsStore = snapshot.teamsStore
        nextTeamId = snapshot.nextTeamId
        usersStore = snapshot.usersStore
        nextUserId = snapshot.nextUserId
        accountPassword = snapshot.accountPassword
        passkeyStore = snapshot.passkeyStore
        // Absent in a workspace written before songs could hold a recording,
        // which means none of them do.
        songAudio = snapshot.songAudio ?? [:]
        nextSongAudioId = snapshot.nextSongAudioId ?? 1
    }

    /// Written out synchronously, on the request that changed something.
    ///
    /// The client already debounces its saves, so this runs about once per
    /// pause in the typing rather than once per keystroke, and one atomic write
    /// of a screenplay-sized document is cheaper than the round trip it is
    /// standing in for. Deferring it would buy little and cost the last edit
    /// every time the app is killed from the switcher.
    private func persist() {
        guard let store, let data = try? JSONEncoder().encode(capture()) else { return }
        store.save(data)
    }

    /// Notes that an account has just taken a copy of these screenplays.
    ///
    /// Nothing is removed. This used to delete the local copy outright, on the
    /// reasoning that the account was now the screenplay's home and a copy left
    /// behind would come back at the next sign-out as a stale second one. What
    /// that missed is where it left the writer: signing out took the screenplay
    /// with it, so the price of ever attaching an account was losing the work on
    /// the device the moment you left it. A signed-out device is a place people
    /// write, not a waiting room.
    ///
    /// So both copies live, and they diverge — the local one keeps the words it
    /// had when it was handed over, and nothing said to the account afterwards
    /// reaches it. All that is recorded here is that it went, so the next
    /// sign-in doesn't offer it again as though it were new. See
    /// `handedOffProjectIds`.
    func markHandedOff(projectIds ids: [Int]) {
        for id in ids {
            handedOffProjectIds.insert(id)
            // Off the offer list until it is written in again: as it stands the
            // account has exactly these words already.
            writtenProjectIds.remove(id)
        }
        persist()
    }

    /// Un-notes it: no account has this screenplay after all.
    ///
    /// For the one case that can say so — an account that was given a copy and
    /// has since deleted it. What is left here is then the only copy there is,
    /// and it goes back to being work worth offering rather than a screenplay
    /// wearing "already kept" for the rest of its life.
    func forgetHandOff(projectIds ids: [Int]) {
        for id in ids where projects.contains(where: { $0.id == id }) {
            handedOffProjectIds.remove(id)
            writtenProjectIds.insert(id)
        }
        persist()
    }

    /// Whether this screenplay holds words the account has not been given.
    ///
    /// The same flag the sign-in offer is built from, asked one project at a
    /// time — which is what a linked screenplay needs: a device that has not
    /// been written in since the two were last in step has nothing to send, and
    /// the crossing should cost the writer nothing and say nothing.
    func hasUnsentWork(projectId: Int) -> Bool {
        writtenProjectIds.contains(projectId)
    }

    func projectExists(_ id: Int) -> Bool {
        projects.contains { $0.id == id }
    }

    /// Makes this device's copy of a screenplay match the account's, from the
    /// archive the account just handed over.
    ///
    /// The other half of `hasUnsentWork`: this is the crossing in the other
    /// direction, run as the writer signs out, so what they wrote in the account
    /// is what they find in front of them a moment later rather than the words
    /// as they stood whenever the two last met.
    ///
    /// The screenplay keeps its local id, so the sidebar's selection, the
    /// remembered place and the widgets all still name it. Afterwards the device
    /// has nothing the account has not got, which is exactly what
    /// `hasUnsentWork` should then say.
    @discardableResult
    func mirrorProject(_ id: Int, fromArchive data: Data) -> Bool {
        guard projects.contains(where: { $0.id == id }),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let archive = (object["projects"] as? [[String: Any]])?.first ?? object
        // A file that describes no project at all would empty the screenplay and
        // call it success. Refuse it: an unreadable answer is a reason to leave
        // the copy on the device alone, not to clear it.
        guard archive["project"] != nil || archive["blocks"] != nil || archive["documents"] != nil else {
            return false
        }
        replaceProject(id, fromArchive: archive)
        writtenProjectIds.remove(id)
        handedOffProjectIds.insert(id)
        persist()
        return true
    }

    // MARK: - Router

    func respond(method: String, url: URL, body: Data?) -> (status: Int, data: Data) {
        // What this session opens on: whatever was left here last time, or the
        // sample screenplay on a device that has never written one. The seed is
        // then this device's workspace rather than a fixture regenerated each
        // launch, so it is written out straight away — before anything can be
        // built on the ids it just handed out.
        if !seeded {
            seeded = true
            if !restoreStoredWorkspace() {
                seed()
                persist()
            }
        }
        let result = route(method: method, url: url, body: body)
        // Everything that changes the store arrives as a write. A GET can only
        // read, so the common case — a script being scrolled — costs nothing.
        if method != "GET" { persist() }
        return result
    }

    private func route(method: String, url: URL, body: Data?) -> (status: Int, data: Data) {
        let path = url.pathComponents.filter { $0 != "/" }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .reduce(into: [String: String]()) { $0[$1.name] = $1.value } ?? [:]
        let fields = body
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        switch (method, path.first, path.dropFirst().first) {
        case ("GET", "api", nil):
            return ok(rootJSON())

        case (_, "api", "project"):
            return routeProject(method: method, path: Array(path.dropFirst(2)),
                                query: query, fields: fields, body: body)
        case (_, "api", "block"):
            return routeBlock(method: method, path: Array(path.dropFirst(2)),
                              query: query, fields: fields)
        case (_, "api", "person"):
            return routePerson(method: method, path: Array(path.dropFirst(2)),
                               query: query, fields: fields)
        case (_, "api", "document"):
            return routeDocument(method: method, path: Array(path.dropFirst(2)),
                                 query: query, fields: fields, body: body)
        case (_, "api", "song"):
            switch path.dropFirst(2).first {
            case "edition":
                return routeSongEdition(method: method, path: Array(path.dropFirst(3)),
                                        query: query, fields: fields)
            case "block":
                return routeSongBlock(method: method, path: Array(path.dropFirst(3)),
                                      query: query, fields: fields)
            case "version":
                return routeSongVersion(method: method, path: Array(path.dropFirst(3)),
                                        query: query, fields: fields)
            case "audio":
                return routeSongAudio(method: method, path: Array(path.dropFirst(3)),
                                      query: query, fields: fields, body: body)
            default:
                return notFound()
            }
        case (_, "api", "actor"):
            return routeActor(method: method, path: Array(path.dropFirst(2)),
                              query: query, fields: fields, body: body)
        case (_, "api", "team"):
            return routeTeam(method: method, path: Array(path.dropFirst(2)),
                             query: query, fields: fields)
        case (_, "api", "user"):
            return routeUser(method: method, path: Array(path.dropFirst(2)),
                             query: query, fields: fields)
        case (_, "api", "account"):
            return routeAccount(method: method, path: Array(path.dropFirst(2)),
                                fields: fields)
        case (_, "api", "preferences"):
            return routePreferences(method: method, path: Array(path.dropFirst(2)),
                                    fields: fields)
        default:
            return notFound()
        }
    }

    // MARK: - Account (own password and passkeys)

    private struct DemoPasskey: Codable {
        var credentialId: String
        var label: String
        var created: Date
        var lastUsed: Date?
    }

    /// The demo account's password. Changing it is checked against this, so the
    /// "current password is wrong" path is reachable offline.
    private lazy var accountPassword = "demo1234"

    /// Seeded so the list is not empty; one never used, to show that state.
    private lazy var passkeyStore: [DemoPasskey] = [
        DemoPasskey(credentialId: "ZGVtby1pcGhvbmU",
                    label: "iPhone",
                    created: Date(timeIntervalSinceNow: -60 * 60 * 24 * 30),
                    lastUsed: Date(timeIntervalSinceNow: -60 * 60 * 24 * 2)),
        DemoPasskey(credentialId: "ZGVtby1sYXB0b3A",
                    label: "MacBook Pro",
                    created: Date(timeIntervalSinceNow: -60 * 60 * 24 * 5),
                    lastUsed: nil),
    ]

    private func routeAccount(method: String, path: [String],
                              fields: [String: Any]) -> (Int, Data) {
        switch (method, path.first) {
        case ("GET", nil):
            return ok(accountJSON())
        case ("POST", "password"):
            guard let current = fields["currentPassword"] as? String,
                  current == accountPassword else {
                return (400, (try? JSONSerialization.data(
                    withJSONObject: ["message": "Current password is incorrect."]))
                    ?? Data("{}".utf8))
            }
            guard let new = fields["newPassword"] as? String, new.count >= 8 else {
                return (400, (try? JSONSerialization.data(
                    withJSONObject: ["message": "New password is too weak: use at least 8 characters."]))
                    ?? Data("{}".utf8))
            }
            guard new != accountPassword else {
                return (400, (try? JSONSerialization.data(
                    withJSONObject: ["message": "New password must be different from the current password."]))
                    ?? Data("{}".utf8))
            }
            accountPassword = new
            return ok(accountJSON())
        case ("GET", "passkeys"):
            return ok(passkeyCollectionJSON())
        case ("DELETE", "passkeys"):
            guard let credentialId = path.dropFirst().first,
                  let index = passkeyStore.firstIndex(where: { $0.credentialId == credentialId })
            else {
                return notFound()
            }
            passkeyStore.remove(at: index)
            return ok(passkeyCollectionJSON())
        default:
            return notFound()
        }
    }

    private func accountJSON() -> [String: Any] {
        [
            "username": "demo",
            "firstName": "Demo",
            "lastName": "Admin",
            "passwordChangeRequired": false,
            "passkeysEnabled": true,
            "_links": [
                "self": link("/api/account"),
                "changePassword": link("/api/account/password"),
                "passkeys": link("/api/account/passkeys"),
            ],
        ]
    }

    private func passkeyCollectionJSON() -> [String: Any] {
        [
            "_embedded": ["passkeyResourceList": passkeyStore.map(passkeyJSON)],
            "_links": [
                "self": link("/api/account/passkeys"),
                "account": link("/api/account"),
            ],
        ]
    }

    private func passkeyJSON(_ passkey: DemoPasskey) -> [String: Any] {
        var json: [String: Any] = [
            "credentialId": passkey.credentialId,
            "label": passkey.label,
            "created": iso.string(from: passkey.created),
            "_links": [
                "delete": link("/api/account/passkeys/\(passkey.credentialId)"),
                "passkeys": link("/api/account/passkeys"),
            ],
        ]
        if let lastUsed = passkey.lastUsed {
            json["lastUsed"] = iso.string(from: lastUsed)
        }
        return json
    }

    // MARK: - Editor preferences

    /// Auto-capitalization is per element and stored on the server; the demo
    /// keeps the same four flags in memory so the toggles persist for the
    /// session and a re-read reflects what was set.
    private var capitalization: [String: Bool] = [
        "scene": true, "character": true, "transition": true, "shot": true,
    ]

    private func routePreferences(method: String, path: [String],
                                  fields: [String: Any]) -> (Int, Data) {
        guard path.first == "capitalization" else { return notFound() }
        switch method {
        case "GET":
            return ok(capitalizationJSON())
        case "POST":
            // Partial: only the posted fields change, matching the server so a
            // single toggle need not resend the others.
            for key in ["scene", "character", "transition", "shot"] {
                if let value = fields[key] as? Bool { capitalization[key] = value }
            }
            return ok(capitalizationJSON())
        default:
            return notFound()
        }
    }

    private func capitalizationJSON() -> [String: Any] {
        var json: [String: Any] = capitalization
        json["_links"] = [
            "self": link("/api/preferences/capitalization"),
            "update": link("/api/preferences/capitalization"),
        ]
        return json
    }

    private func routeProject(method: String, path: [String],
                              query: [String: String],
                              fields: [String: Any],
                              body: Data?) -> (Int, Data) {
        if method == "POST", path.first == "import" {
            return demoImport(body: body)
        }
        // `/api/project/version…` is a sibling of the project resources, not a
        // project id, so it has to be picked off before the numeric lookup.
        if path.first == "version" {
            return routeVersion(method: method, path: Array(path.dropFirst()),
                                query: query, fields: fields)
        }
        if path.first == "trash" {
            return routeProjectTrash(method: method, path: Array(path.dropFirst()))
        }
        // …and `/api/project/archive…` is a sibling of both.
        if path.first == "archive" {
            return routeProjectArchive(method: method, path: Array(path.dropFirst()),
                                       fields: fields)
        }
        if path.first == "edition" {
            return routeEdition(method: method, path: Array(path.dropFirst()),
                                query: query, fields: fields)
        }
        // The whole list as one bundle — a sibling of the project resources,
        // not a project id.
        if method == "GET", path.first == "export-projects" {
            // `ids` narrows the bundle to a selection, exactly as the real
            // endpoint does; absent means every project.
            return demoProjectsBundle(ids: idList(query["ids"]))
        }
        switch (method, path.count) {
        case ("GET", 0):
            return projectCollection()
        case ("POST", 0):
            guard let title = fields["title"] as? String else { return badRequest("title") }
            var project = DemoProject(id: nextProjectId, title: title, lastEdited: .now)
            // The create form may name teams; absent means the seeded default,
            // matching the badge a new demo project already showed.
            if let teamIds = intList(fields["teamIds"]) { project.teamIds = teamIds }
            nextProjectId += 1
            writtenProjectIds.insert(project.id)
            projects.append(project)
            blocks[project.id] = []
            people[project.id] = []
            documents[project.id] = []
            return ok(projectJSON(project))
        default:
            break
        }

        guard let id = path.first.flatMap(Int.init),
              let index = projects.firstIndex(where: { $0.id == id }) else { return notFound() }

        switch (method, path.dropFirst().first) {
        case ("GET", nil):
            return ok(projectJSON(projects[index]))
        case ("PUT", nil):
            // Title-page fields follow the same absent-means-unchanged rule as
            // blocks, so renaming a project never blanks its front matter.
            if let title = fields["title"] as? String { projects[index].title = title }
            if let value = fields["screenplayTitle"] as? String { projects[index].screenplayTitle = value }
            if let value = fields["writers"] as? String { projects[index].writers = value }
            if let value = fields["contactInfo"] as? String { projects[index].contactInfo = value }
            if let value = fields["screenplayVersion"] as? String { projects[index].screenplayVersion = value }
            // Absent leaves the assignment alone (a plain rename); present
            // replaces it wholesale, an empty list clearing every team.
            if let teamIds = intList(fields["teamIds"]) { projects[index].teamIds = teamIds }
            projects[index].lastEdited = .now
            writtenProjectIds.insert(projects[index].id)
            return ok(projectJSON(projects[index]))
        case ("POST", "archive"):
            guard projects[index].archivedAt == nil else { return badRequest("id") }
            projects[index].archivedAt = Date()
            // As deleting does: a default nobody can find in the list would
            // land them on it at every launch.
            if defaultProjectId == id { defaultProjectId = nil }
            return projectCollection()
        case ("POST", "import-script"):
            return demoImportScript(projectId: id, body: body)
        case ("POST", "replace-from-archive"):
            guard let archive = singleArchive(in: body) else { return badRequest("file") }
            replaceProject(id, fromArchive: archive)
            guard let replaced = projects.first(where: { $0.id == id }) else { return notFound() }
            writtenProjectIds.insert(id)
            return ok(projectJSON(replaced))
        case ("DELETE", nil):
            // A soft delete, as on the server: everything belonging to the
            // project is kept aside so a restore can bring it back whole.
            let removed = projects.remove(at: index)
            trashedProjects.append(TrashedDemoProject(
                project: removed,
                deletedAt: Date(),
                blocks: blocks[removed.id] ?? [],
                people: people[removed.id] ?? [],
                documents: documents[removed.id] ?? []))
            blocks[removed.id] = nil
            people[removed.id] = nil
            documents[removed.id] = nil
            return ok([:])
        case ("GET", "undo-redo-status"):
            return ok(undoRedoJSON(projectId: id, success: nil))
        case ("POST", "undo"):
            return applyHistory(projectId: id, undoing: true)
        case ("POST", "redo"):
            return applyHistory(projectId: id, undoing: false)
        case (_, "invitations"):
            return routeInvitations(method: method, projectId: id,
                                    path: Array(path.dropFirst(2)), fields: fields)
        case ("GET", "activity"):
            let limit = query["limit"].flatMap(Int.init) ?? 30
            return activityCollection(id, limit: min(max(limit, 1), 100))
        case ("GET", "sync-status"):
            let revision = Int64(projects[index].lastEdited.timeIntervalSince1970 * 1000)
            let since = query["since"].flatMap(Int64.init) ?? 0
            return ok(["exists": true,
                       "revision": revision,
                       "changed": since != 0 && since != revision,
                       "title": projects[index].title,
                       "_links": ["self": link("/api/project/\(id)/sync-status")]])
        case ("GET", "export"):
            // The format is the next path segment; every rel points here. The
            // demo returns a plausible file per format so the export and print
            // flows can be exercised offline, not just the fountain one.
            let format = path.dropFirst(2).first ?? "fountain"
            return demoExport(projects[index], format: format)
        case ("GET", "contact-suggestions"):
            return contactSuggestions(matching: query["q"] ?? "")
        case ("GET", "access"):
            return projectAccess(id)
        case ("GET", "teams"):
            return projectTeamsCollection(projects[index])
        case ("POST", "toggleDefault"):
            defaultProjectId = (defaultProjectId == id) ? nil : id
            return projectCollection()
        default:
            return notFound()
        }
    }

    /// Accepts a multipart `.scripty.json` upload and builds the projects it
    /// describes — a bundle's whole list, or the single archive a one-project
    /// export writes. The answer is the first project created, which is what
    /// the importing screen decodes.
    ///
    /// It reads what `demoProjectsBundle` writes, so a project exported here
    /// comes back whole: title page, characters, songs and notes, and every
    /// element with the character it belongs to. Editions are not part of the
    /// file (see `projectArchive`), so everything lands in one script, exactly
    /// as it does when the server reads the same document.
    private func demoImport(body: Data?) -> (Int, Data) {
        guard let object = archiveDocument(in: body) else { return badRequest("file") }
        let archives = (object["projects"] as? [[String: Any]]) ?? [object]
        let created = archives.map(importArchive)
        guard let first = created.first else { return badRequest("file") }
        return ok(projectJSON(first))
    }

    /// The archive document out of a multipart upload, or nil for anything that
    /// is not one.
    private func archiveDocument(in body: Data?) -> [String: Any]? {
        guard let body, let text = String(data: body, encoding: .utf8),
              let headerEnd = text.range(of: "\r\n\r\n") else { return nil }
        var payload = String(text[headerEnd.upperBound...])
        if let closing = payload.range(of: "\r\n--\(APIClient.multipartBoundary)--") {
            payload = String(payload[..<closing.lowerBound])
        }
        guard let jsonData = payload.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
    }

    /// The one project an upload is about, for the routes that act on a project
    /// that already exists: a single-project file, or a bundle's first.
    private func singleArchive(in body: Data?) -> [String: Any]? {
        guard let object = archiveDocument(in: body) else { return nil }
        if let bundled = object["projects"] as? [[String: Any]] { return bundled.first }
        return object
    }

    /// One archive document, turned back into a project.
    private func importArchive(_ archive: [String: Any]) -> DemoProject {
        let project = DemoProject(id: nextProjectId, title: "Imported Project", lastEdited: .now)
        nextProjectId += 1
        projects.append(project)
        blocks[project.id] = []
        people[project.id] = []
        documents[project.id] = []
        writtenProjectIds.insert(project.id)
        applyArchive(archive, to: project.id)
        return projects.first { $0.id == project.id } ?? project
    }

    /// Reads an archive into a project that already exists, in place of what is
    /// in it now — the client side of `replaceFromArchive`.
    ///
    /// The screenplay keeps its id, so everything pointing at it still points at
    /// it. So does each song and note the file names: those are matched by uid
    /// and written where they stand, which is what makes a lyric survive the
    /// crossing as the same lyric — same id, same lines, same place in the
    /// widgets and the reopen record — instead of as a copy of itself under a
    /// new number.
    ///
    /// What the file does *not* name goes where the server sends it: the script
    /// onto the undo stack and into the version history, the leftover songs and
    /// notes into the document trash, so a replace nobody meant is not the end
    /// of the words it replaced.
    private func replaceProject(_ projectId: Int, fromArchive archive: [String: Any]) {
        guard projects.contains(where: { $0.id == projectId }) else { return }
        snapshot(projectId)
        // As the server does before the same write: the script being replaced
        // goes into the version history, which is where a writer would go
        // looking for it.
        recordVersion(projectId, label: nil, autoSave: true)

        // Everything the file could be talking about, taken out of both stores
        // and offered to it. Archived documents are in here as well as listed
        // ones: an archive carries both, so leaving the put-aside ones out would
        // mean every crossing added a second copy of each of them.
        let here = (documents[projectId] ?? []) + (archivedDocuments[projectId] ?? []).map(\.document)
        var claimable: [String: DemoDocument] = [:]
        for document in here {
            guard let uid = document.uid, !uid.isEmpty else { continue }
            claimable[uid] = document
        }
        // A document with no uid at all — written before they existed and never
        // restored since — can be claimed by nothing, so it is not offered and
        // is dealt with below as a leftover. That is what this did for
        // everything before uids, and it is still whole and recoverable.
        let unnamed = here.filter { $0.uid?.isEmpty ?? true }

        blocks[projectId] = []
        people[projectId] = []
        documents[projectId] = []
        archivedDocuments[projectId] = []

        let leftovers = applyArchive(archive, to: projectId, claimable: claimable) + unnamed
        for document in leftovers {
            deletedDocuments[projectId, default: []].append(
                DeletedDemoDocument(document: document, deletedAt: Date()))
        }
    }

    /// Puts a document back into the store the archive says it belongs in.
    private func place(_ document: DemoDocument, archived: Bool, in projectId: Int) {
        if archived {
            archivedDocuments[projectId, default: []].append(
                ArchivedDemoDocument(document: document, archivedAt: Date()))
        } else {
            documents[projectId, default: []].append(document)
        }
    }

    /// Makes a song's lines say what its text now says.
    ///
    /// Needed only where an archive was read into a song that already existed:
    /// lines are seeded from the text once, on a song that has none, so without
    /// this the lyric on screen would go on showing what it said before the file
    /// arrived while the text underneath it said something else. The lines it
    /// replaces go on the song's undo stack, so an unwanted crossing is one
    /// ⌘Z away.
    private func reseedSongLines(_ documentId: Int) {
        guard let editionId = resolveSongEdition(documentId, editionId: nil) else { return }
        ensureSongBlocks(documentId, editionId: editionId)
        snapshotSong(editionId)
        songBlocks[editionId] = nil
        ensureSongBlocks(documentId, editionId: editionId)
        syncSongText(documentId, editionId: editionId)
    }

    /// Everything an archive says a project holds, written into one that is
    /// ready for it.
    ///
    /// Shared by importing a file into a project made a moment ago and by
    /// reading one back into a project that has just been emptied — what is
    /// different about those two happened before this ran.
    ///
    /// `claimable` is the songs and notes already here that the file might be
    /// describing, by uid; empty when this is an import, since a project made a
    /// moment ago has none. Answers the ones it did not claim, which is what the
    /// caller trashes.
    @discardableResult
    private func applyArchive(_ archive: [String: Any], to projectId: Int,
                              claimable: [String: DemoDocument] = [:]) -> [DemoDocument] {
        guard let index = projects.firstIndex(where: { $0.id == projectId }) else {
            return Array(claimable.values)
        }
        let info = archive["project"] as? [String: Any]
        projects[index].title = (info?["title"] as? String)
            ?? (archive["title"] as? String) ?? projects[index].title
        projects[index].screenplayTitle = info?["screenplayTitle"] as? String
        projects[index].writers = info?["writers"] as? String
        projects[index].contactInfo = info?["contactInfo"] as? String
        projects[index].screenplayVersion = info?["screenplayVersion"] as? String
        projects[index].lastEdited = .now

        // The file's own keys only wire its parts together; every id here is
        // freshly minted, exactly as the server's importer does it.
        var peopleByKey: [Int: Int] = [:]
        for entry in archive["characters"] as? [[String: Any]] ?? [] {
            guard let name = entry["name"] as? String else { continue }
            let person = addPerson(name: name, fullName: entry["fullName"] as? String ?? name)
            people[projectId, default: []].append(person)
            if let key = entry["key"] as? Int { peopleByKey[key] = person.id }
        }

        var unclaimed = claimable
        // Every name this project will answer to once this is done. A second
        // entry naming one of them is not that song — it is a file describing
        // the same song twice — and must not be given its name.
        var spokenFor = Set(claimable.keys)
        for entry in archive["documents"] as? [[String: Any]] ?? [] {
            guard let title = entry["title"] as? String else { continue }
            let type = normalizeDocumentType(entry["documentType"] as? String) ?? "NOTES"
            let content = entry["content"] as? String ?? ""
            // A song put aside stays put aside: it goes to the archive rather
            // than turning up in the list as if it had been brought back.
            let isArchived = entry["archived"] as? Bool == true
            let uid = (entry["uid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // The folder the file names, made here if this project has not got
            // one of that name in that list. Nil where the file names none,
            // which also clears the folder off a document being written into:
            // the file is the whole truth about where its songs sit.
            let folderId = folderNamed(entry["folder"] as? String, type: type, in: projectId)

            if let uid, var claimed = unclaimed.removeValue(forKey: uid) {
                // The file is talking about a song this project already has, so
                // it is written where it stands — same id, same lyric lines,
                // same everything pointing at it.
                let lyricChanged = type == "SONG" && claimed.content != content
                claimed.title = title
                claimed.documentType = type
                claimed.content = content
                claimed.sortOrder = entry["sortOrder"] as? Int ?? claimed.sortOrder
                claimed.folderId = folderId
                claimed.updatedAt = .now
                place(claimed, archived: isArchived, in: projectId)
                if lyricChanged { reseedSongLines(claimed.id) }
                continue
            }

            let document = addDocument(projectId: projectId, title: title, type: type,
                                       content: content,
                                       // Keep the file's name for it where nothing here
                                       // answers to that name yet: that is how a song
                                       // written in one place goes on being the same song
                                       // in the other. Otherwise it starts afresh.
                                       uid: uid.flatMap { spokenFor.insert($0).inserted ? $0 : nil })
            if let folderId,
               let at = documents[projectId]?.firstIndex(where: { $0.id == document.id }) {
                documents[projectId]?[at].folderId = folderId
            }
            if isArchived,
               let position = documents[projectId]?.firstIndex(where: { $0.id == document.id }),
               let removed = documents[projectId]?.remove(at: position) {
                archivedDocuments[projectId, default: []].append(
                    ArchivedDemoDocument(document: removed, archivedAt: Date()))
            }
        }

        let entries = (archive["blocks"] as? [[String: Any]] ?? [])
            .sorted { ($0["order"] as? Int ?? .max) < ($1["order"] as? Int ?? .max) }
        for (offset, entry) in entries.enumerated() {
            var block = DemoBlock(id: nextBlockId,
                                  order: offset + 1,
                                  content: entry["content"] as? String ?? "",
                                  type: entry["type"] as? String ?? "ACTION",
                                  personId: (entry["characterKey"] as? Int).flatMap { peopleByKey[$0] })
            block.bookmarked = entry["bookmarked"] as? Bool ?? false
            block.pinned = entry["pinned"] as? Bool ?? false
            block.tags = entry["tags"] as? String
            block.textAlign = (entry["textAlign"] as? String).flatMap(canonicalAlign)
            block.font = (entry["font"] as? String).flatMap(canonicalFont)
            block.highlight = entry["highlight"] as? String
            block.textBold = entry["textBold"] as? Bool
            block.textItalic = entry["textItalic"] as? Bool
            block.textUnderline = entry["textUnderline"] as? Bool
            nextBlockId += 1
            blocks[projectId, default: []].append(block)
        }

        return Array(unclaimed.values)
    }

    /// Replaces a project's script from an uploaded file. The demo parses only
    /// plain Fountain — enough to prove the round trip — and rejects anything
    /// it cannot read as text, the way the server rejects an unparseable file.
    private func demoImportScript(projectId: Int, body: Data?) -> (Int, Data) {
        guard let index = projects.firstIndex(where: { $0.id == projectId }),
              let parsed = parseMultipart(body),
              let fileData = parsed.fileData,
              let text = String(data: fileData, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return badRequest("file")
        }
        snapshot(projectId)
        var imported: [DemoBlock] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            imported.append(DemoBlock(id: nextBlockId,
                                      order: imported.count + 1,
                                      content: trimmed,
                                      type: importedType(for: trimmed),
                                      personId: nil))
            nextBlockId += 1
        }
        guard !imported.isEmpty else { return badRequest("file") }
        blocks[projectId] = imported
        touch(projectId)
        return ok(projectJSON(projects[index]))
    }

    /// A deliberately small subset of the Fountain heuristics the real importer
    /// applies — the client-side detector in FountainDetect.swift is the one
    /// that matters for editing.
    private func importedType(for line: String) -> String {
        let upper = line.uppercased()
        if upper.hasPrefix("INT.") || upper.hasPrefix("EXT.") || upper.hasPrefix("INT/EXT") {
            return "SCENE"
        }
        // `... TO:` is the general form; the terminal transitions have no colon
        // and would otherwise read as action, since they end in a period and so
        // fail the character-cue test too.
        if upper.hasSuffix("TO:") { return "TRANSITION" }
        if ["FADE OUT.", "FADE TO BLACK.", "FADE IN:", "THE END."].contains(upper) {
            return "TRANSITION"
        }
        if line.hasPrefix("(") && line.hasSuffix(")") { return "PARENTHETICAL" }
        if line == upper && line.count <= 60 && !line.hasSuffix(".") {
            return "CHARACTER"
        }
        return "ACTION"
    }

    // MARK: - Actors (casting)

    /// Which characters an actor auditions for, keyed projectId → actorId → the
    /// set of character ids. Only meaningful in a project scope, mirroring the
    /// server's per-project audition table.
    private var auditions: [Int: [Int: Set<Int>]] = [:]

    private func routeActor(method: String, path: [String],
                            query: [String: String],
                            fields: [String: Any],
                            body: Data?) -> (Int, Data) {
        switch (method, path.count) {
        case ("GET", 0):
            let projectId = query["projectId"].flatMap(Int.init)
            let visible = projectId.map { id in
                actors.filter { $0.projectIds.contains(id) }
            } ?? actors
            let selfHref = projectId.map { "/api/actor?projectId=\($0)" } ?? "/api/actor"
            return ok(["_embedded": ["actorResourceList":
                        visible.map { actorJSON($0, projectId: projectId) }],
                       "_links": ["self": link(selfHref)]])
        case ("POST", 0):
            guard let first = fields["first"] as? String, !first.isEmpty else {
                return badRequest("first")
            }
            let actor = DemoActor(id: nextActorId,
                                  first: first,
                                  last: fields["last"] as? String ?? "",
                                  phone: fields["phone"] as? String,
                                  email: fields["email"] as? String,
                                  projectIds: fields["projectIds"] as? [Int] ?? [])
            nextActorId += 1
            actors.append(actor)
            return ok(actorJSON(actor))
        default:
            break
        }

        guard let id = path.first.flatMap(Int.init),
              let index = actors.firstIndex(where: { $0.id == id }) else { return notFound() }

        switch (method, path.dropFirst().first) {
        case ("GET", nil):
            return ok(actorJSON(actors[index]))
        case ("PUT", nil):
            if let value = fields["first"] as? String { actors[index].first = value }
            if let value = fields["last"] as? String { actors[index].last = value }
            if let value = fields["phone"] as? String { actors[index].phone = value }
            if let value = fields["email"] as? String { actors[index].email = value }
            if let value = fields["projectIds"] as? [Int] { actors[index].projectIds = value }
            return ok(actorJSON(actors[index]))
        case ("POST", "auditions"):
            // Replace the actor's auditions for one project, wholesale. Per
            // project, so a projectId is required; an empty list clears them.
            guard let projectId = query["projectId"].flatMap(Int.init),
                  actors[index].projectIds.contains(projectId) else {
                return badRequest("projectId")
            }
            let characterIds = fields["characterIds"] as? [Int] ?? []
            // Keep only ids that are real characters in the project.
            let valid = Set((people[projectId] ?? []).map(\.id))
            auditions[projectId, default: [:]][id] = Set(characterIds).intersection(valid)
            return ok(actorJSON(actors[index], projectId: projectId))
        case ("POST", "headshot"):
            // Multipart, like the server. The demo does not parse the envelope
            // — it only has to remember that a picture arrived, and how big it
            // was, for the links to change.
            guard let body, !body.isEmpty else { return badRequest("headshot") }
            actors[index].headshot = body
            return ok(actorJSON(actors[index]))
        case ("DELETE", "headshot"):
            actors[index].headshot = nil
            return ok(actorJSON(actors[index]))
        case ("GET", "headshot"):
            guard let data = actors[index].headshot else { return notFound() }
            return (200, data)
        case ("DELETE", nil):
            let removed = actors.remove(at: index)
            // Anyone cast as this actor becomes uncast rather than dangling, and
            // their auditions go with them.
            for (projectId, list) in people {
                for (i, person) in list.enumerated() where person.actorId == removed.id {
                    people[projectId]?[i].actorId = nil
                }
            }
            for projectId in auditions.keys {
                auditions[projectId]?[removed.id] = nil
            }
            return ok([:])
        default:
            return notFound()
        }
    }

    private func actorJSON(_ actor: DemoActor, projectId: Int? = nil) -> [String: Any] {
        var links: [String: Any] = [
            "self": link("/api/actor/\(actor.id)"),
            "actors": link("/api/actor"),
            "update": link("/api/actor/\(actor.id)"),
            "delete": link("/api/actor/\(actor.id)"),
            // Always on offer: replacing a headshot is the same action as
            // adding one.
            "setHeadshot": link("/api/actor/\(actor.id)/headshot"),
        ]
        // Reading and removing one are offered only where there is a headshot,
        // so a client can draw its controls from the links alone.
        if actor.headshot != nil {
            links["headshot"] = link("/api/actor/\(actor.id)/headshot")
            links["removeHeadshot"] = link("/api/actor/\(actor.id)/headshot")
        }
        var json: [String: Any] = [
            "id": actor.id,
            "first": actor.first,
            "last": actor.last,
            "hasHeadshot": actor.headshot != nil,
            "projectIds": actor.projectIds,
        ]
        // Auditions ride along only on a project-scoped actor — the same as the
        // server, which omits them (null) otherwise.
        if let projectId {
            let ids = (auditions[projectId]?[actor.id] ?? []).sorted()
            json["auditionCharacterIds"] = ids
            links["setAuditions"] = link("/api/actor/\(actor.id)/auditions?projectId=\(projectId)")
        }
        json["_links"] = links
        if let phone = actor.phone { json["phone"] = phone }
        if let email = actor.email { json["email"] = email }
        return json
    }

    private func routeBlock(method: String, path: [String],
                            query: [String: String],
                            fields: [String: Any]) -> (Int, Data) {
        switch (method, path.count) {
        case ("GET", 0):
            guard let projectId = query["projectId"].flatMap(Int.init) else {
                return badRequest("projectId")
            }
            // Naming an edition switches which script is being read. The
            // default edition's blocks are the project's own, so an unnamed
            // request behaves exactly as it always did.
            if let editionId = query["editionId"].flatMap(Int.init) {
                guard let edition = editions.first(where: {
                    $0.id == editionId && $0.projectId == projectId
                }) else { return notFound() }
                if !edition.isDefault {
                    return blockCollection(projectId, editionId: editionId)
                }
            }
            return blockCollection(projectId)
        case ("POST", 1) where path.first == "initial":
            guard let projectId = query["projectId"].flatMap(Int.init),
                  blocks[projectId] != nil else { return badRequest("projectId") }
            guard blocks[projectId]?.isEmpty ?? true else { return (409, Data("{}".utf8)) }
            snapshot(projectId)
            let block = DemoBlock(id: nextBlockId, order: 1, content: "", type: "ACTION", personId: nil)
            nextBlockId += 1
            blocks[projectId] = [block]
            touch(projectId)
            return ok(blockJSON(block, projectId: projectId))
        case ("POST", 0):
            guard let projectId = fields["projectId"] as? Int,
                  blocks[projectId] != nil,
                  let content = fields["content"] as? String else {
                return badRequest("projectId")
            }
            snapshot(projectId)
            let block = DemoBlock(id: nextBlockId,
                                  order: (blocks[projectId]?.map(\.order).max() ?? 0) + 1,
                                  content: content,
                                  type: fields["type"] as? String ?? "ACTION",
                                  personId: fields["personId"] as? Int)
            nextBlockId += 1
            blocks[projectId]?.append(block)
            touch(projectId)
            return ok(blockJSON(block, projectId: projectId))
        case ("POST", 2) where path.first == "bulk":
            return routeBulkBlocks(operation: path[1], fields: fields)
        default:
            break
        }

        // `/api/block/trash…`, `/api/block/comments/{id}` and
        // `/api/block/comment-counts` are siblings of the block resources, not
        // block ids, so they are picked off before the numeric lookup.
        if path.first == "trash" {
            return routeBlockTrash(method: method, path: Array(path.dropFirst()), query: query)
        }
        if path.first == "comment-counts", method == "GET" {
            guard let projectId = query["projectId"].flatMap(Int.init),
                  blocks[projectId] != nil else { return badRequest("projectId") }
            return commentCounts(projectId)
        }
        if path.first == "comments", path.count == 2, method == "DELETE",
           let commentId = Int(path[1]) {
            return routeDeleteComment(commentId)
        }

        guard let id = path.first.flatMap(Int.init),
              let (projectId, index) = locateBlock(id) else { return notFound() }

        switch (method, path.dropFirst().first) {
        case ("PUT", nil):
            snapshot(projectId)
            // Absent means "leave alone", never "clear" — the editor's debounced
            // content auto-save omits every field but `content`, and must not
            // wipe the speaker, tags or formatting on its way past.
            if let content = fields["content"] as? String {
                blocks[projectId]?[index].content = content
            }
            if let personId = fields["personId"] as? Int {
                blocks[projectId]?[index].personId = personId
            }
            if let tags = fields["tags"] as? String {
                blocks[projectId]?[index].tags = tags
            }
            if let align = fields["textAlign"] as? String {
                guard let canonical = canonicalAlign(align) else {
                    return badRequest("textAlign")
                }
                blocks[projectId]?[index].textAlign = canonical
            }
            if let font = fields["font"] as? String {
                guard let canonical = canonicalFont(font) else {
                    return badRequest("font")
                }
                blocks[projectId]?[index].font = canonical
            }
            if let bold = fields["textBold"] as? Bool {
                blocks[projectId]?[index].textBold = bold
            }
            if let italic = fields["textItalic"] as? Bool {
                blocks[projectId]?[index].textItalic = italic
            }
            if let underline = fields["textUnderline"] as? Bool {
                blocks[projectId]?[index].textUnderline = underline
            }
            touch(projectId)
            return ok(blockJSON(blocks[projectId]![index], projectId: projectId))
        case ("POST", "move"):
            guard let position = fields["position"] as? Int else {
                return badRequest("position")
            }
            snapshot(projectId)
            var list = (blocks[projectId] ?? []).sorted { $0.order < $1.order }
            guard let from = list.firstIndex(where: { $0.id == id }) else { return notFound() }
            // `position` is an absolute 1-based order; clamp so a stale client
            // index can't throw.
            let to = min(max(position - 1, 0), list.count - 1)
            let moved = list.remove(at: from)
            list.insert(moved, at: to)
            for i in list.indices { list[i].order = i + 1 }
            blocks[projectId] = list
            touch(projectId)
            let items = list.map { blockJSON($0, projectId: projectId) }
            return ok(["_embedded": ["blockResourceList": items],
                       "_links": ["self": link("/api/block?projectId=\(projectId)")]])
        case ("DELETE", nil):
            snapshot(projectId)
            if let removed = blocks[projectId]?.remove(at: index) {
                trashBlock(removed, projectId: projectId)
            }
            touch(projectId)
            return ok([:])
        case (_, "comments"):
            return routeComments(method: method, blockId: id, fields: fields)
        case ("POST", "bookmark"):
            blocks[projectId]?[index].bookmarked.toggle()
            return ok(blockJSON(blocks[projectId]![index], projectId: projectId))
        case ("POST", "pinned"):
            blocks[projectId]?[index].pinned.toggle()
            return ok(blockJSON(blocks[projectId]![index], projectId: projectId))
        case ("POST", "below"):
            snapshot(projectId)
            var list = blocks[projectId] ?? []
            let inserted = DemoBlock(id: nextBlockId,
                                     order: 0,
                                     content: fields["content"] as? String ?? "",
                                     type: (fields["type"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "ACTION",
                                     personId: fields["personId"] as? Int)
            nextBlockId += 1
            list.insert(inserted, at: index + 1)
            for i in list.indices { list[i].order = i + 1 }   // renumber to keep a clean sequence
            blocks[projectId] = list
            touch(projectId)
            return ok(blockJSON(list[index + 1], projectId: projectId))
        case ("POST", "type"):
            guard let type = fields["type"] as? String, !type.isEmpty else {
                return badRequest("type")
            }
            snapshot(projectId)
            var updated = blocks[projectId]![index]
            updated.type = type
            if let content = fields["content"] as? String { updated.content = content }
            if let personId = fields["personId"] as? Int { updated.personId = personId }
            if let tags = fields["tags"] as? String { updated.tags = tags }
            blocks[projectId]![index] = updated
            touch(projectId)
            return ok(blockJSON(updated, projectId: projectId))
        case ("POST", "replace"):
            guard let find = fields["find"] as? String, !find.isEmpty else {
                return badRequest("find")
            }
            let replacement = fields["replace"] as? String ?? ""
            let matchCase = fields["matchCase"] as? Bool ?? false
            let wholeWord = fields["wholeWord"] as? Bool ?? false
            let occurrence = fields["occurrence"] as? Int ?? 0
            snapshot(projectId)
            blocks[projectId]![index].content = Self.replaceOccurrence(
                in: blocks[projectId]![index].content,
                find: find, with: replacement,
                matchCase: matchCase, wholeWord: wholeWord, occurrence: occurrence)
            touch(projectId)
            return ok(blockJSON(blocks[projectId]![index], projectId: projectId))
        default:
            return notFound()
        }
    }

    private func routePerson(method: String, path: [String],
                             query: [String: String],
                             fields: [String: Any]) -> (Int, Data) {
        switch (method, path.count) {
        case ("GET", 0):
            guard let projectId = query["projectId"].flatMap(Int.init) else {
                return badRequest("projectId")
            }
            let items = (people[projectId] ?? []).map { personJSON($0, projectId: projectId) }
            return ok(["_embedded": ["personResourceList": items],
                       "_links": ["self": link("/api/person?projectId=\(projectId)")]])
        case ("POST", 0):
            guard let projectId = fields["projectId"] as? Int,
                  people[projectId] != nil,
                  let name = fields["name"] as? String else {
                return badRequest("projectId")
            }
            let person = DemoPerson(id: nextPersonId, name: name,
                                    fullName: fields["fullName"] as? String ?? name)
            nextPersonId += 1
            people[projectId]?.append(person)
            touch(projectId)
            return ok(personJSON(person, projectId: projectId))
        default:
            break
        }

        guard let id = path.first.flatMap(Int.init),
              let (projectId, index) = locatePerson(id) else { return notFound() }

        switch method {
        case "PUT":
            if let name = fields["name"] as? String {
                people[projectId]?[index].name = name
            }
            if let fullName = fields["fullName"] as? String {
                people[projectId]?[index].fullName = fullName
            }
            // Mirrors the server: an omitted actorId clears the casting, so
            // every character PUT must state the casting it means to keep.
            people[projectId]?[index].actorId = fields["actorId"] as? Int
            touch(projectId)
            return ok(personJSON(people[projectId]![index], projectId: projectId))
        case "DELETE":
            people[projectId]?.remove(at: index)
            touch(projectId)
            return ok([:])
        default:
            return notFound()
        }
    }

    // MARK: - Documents (songs & notes)

    private func routeDocument(method: String, path: [String],
                               query: [String: String],
                               fields: [String: Any],
                               body: Data?) -> (Int, Data) {
        // Collection: list / create.
        switch (method, path.first) {
        case ("GET", nil):
            guard let projectId = query["projectId"].flatMap(Int.init),
                  documents[projectId] != nil else { return badRequest("projectId") }
            let type = normalizeDocumentType(query["type"])
            let items = (documents[projectId] ?? [])
                .filter { type == nil || $0.documentType == type }
                .sorted { $0.sortOrder < $1.sortOrder }
                .map { documentJSON($0, includeContent: false) }
            var selfHref = "/api/document?projectId=\(projectId)"
            if let type { selfHref += "&type=\(type)" }
            var links = documentCollectionLinks(projectId: projectId)
            links["self"] = link(selfHref)
            return ok(["_embedded": ["textDocumentResourceList": items], "_links": links])
        case ("POST", nil):
            guard let projectId = fields["projectId"] as? Int,
                  documents[projectId] != nil,
                  let title = fields["title"] as? String, !title.isBlank else {
                return badRequest("title")
            }
            let type = normalizeDocumentType(fields["documentType"] as? String) ?? "SONG"
            let document = addDocument(projectId: projectId, title: title, type: type,
                                       content: fields["content"] as? String ?? "")
            touch(projectId)
            return ok(documentJSON(document, includeContent: true))
        case ("POST", "import"):
            return importDocument(body: body)
        default:
            break
        }

        // `/api/document/folder…` is a sibling too, and picked off first for
        // the same reason: on the server it is a literal path segment that
        // beats the `{id}` variable beside it.
        if path.first == "folder" {
            return routeDocumentFolder(method: method, path: Array(path.dropFirst()),
                                       query: query, fields: fields)
        }

        // `/api/document/trash…` is a sibling of the document resources, not a
        // document id, so it is picked off before the numeric lookup.
        if path.first == "trash" {
            return routeDocumentTrash(method: method, path: Array(path.dropFirst()), query: query)
        }

        // …and so is `/api/document/archive…`.
        if path.first == "archive" {
            return routeDocumentArchive(method: method, path: Array(path.dropFirst()),
                                        query: query, fields: fields)
        }

        // `/api/document/reorder` is likewise a sibling, not an id.
        if method == "POST", path.first == "reorder" {
            return reorderDocuments(query: query, fields: fields)
        }

        // …as is the songbook, which exports the collection rather than any one
        // document in it. An `ids` list narrows it to a selection, the way the
        // web's export menu does when songs are checked.
        if method == "GET", path.first == "export-songs" {
            guard let projectId = query["projectId"].flatMap(Int.init),
                  documents[projectId] != nil else { return badRequest("projectId") }
            // `type` names the other list, exactly as the server's parameter
            // does — one endpoint, two gatherings.
            return demoSongbookExport(projectId: projectId, format: query["format"] ?? "txt",
                                      type: query["type"], ids: idList(query["ids"]))
        }

        // …and so is the bulk delete, which trashes a selection of songs or
        // notes, and the bulk email, which sends one.
        if method == "POST", path.first == "bulk", path.dropFirst().first == "delete" {
            return bulkDeleteDocuments(query: query, fields: fields)
        }
        if method == "POST", path.first == "bulk", path.dropFirst().first == "share-email" {
            return bulkShareDocuments(query: query, fields: fields)
        }
        // …and the bulk archive, which takes either kind as they all now do.
        if method == "POST", path.first == "bulk", path.dropFirst().first == "archive" {
            return bulkArchiveDocuments(query: query, fields: fields)
        }
        // …and the bulk file, which takes notes as well as songs and reads a
        // missing folderId as "take them out of their folders".
        if method == "POST", path.first == "bulk", path.dropFirst().first == "folder" {
            return bulkMoveDocumentsToFolder(query: query, fields: fields)
        }

        guard let id = path.first.flatMap(Int.init) else { return notFound() }
        guard let (projectId, index) = locateDocument(id) else {
            // An archived document is out of the list but still whole: it can
            // be opened and it can be deleted, exactly as on the server, where
            // the by-id finders ask only that it is not trashed.
            return routeArchivedDocument(method: method, path: path, id: id)
        }

        switch (method, path.dropFirst().first) {
        case ("GET", nil):
            return ok(documentJSON(documents[projectId]![index], includeContent: true))
        case ("PUT", nil):
            if let title = fields["title"] as? String, !title.isBlank {
                documents[projectId]?[index].title = title
            }
            documents[projectId]?[index].content = fields["content"] as? String ?? ""
            documents[projectId]?[index].updatedAt = .now
            touch(projectId)
            return ok(documentJSON(documents[projectId]![index], includeContent: true))
        case ("DELETE", nil):
            // A soft delete, as on the server: the document is kept aside so a
            // restore can bring it back whole.
            if let removed = documents[projectId]?.remove(at: index) {
                deletedDocuments[projectId, default: []].append(
                    DeletedDemoDocument(document: removed, deletedAt: Date()))
            }
            return ok([:])
        case ("POST", "archive"):
            // Not a delete: the document is set aside whole, keeps its id, and
            // nothing ever expires it. Answers with the refreshed list, which is
            // what the client settles from.
            guard let removed = documents[projectId]?.remove(at: index) else { return notFound() }
            archivedDocuments[projectId, default: []].append(
                ArchivedDemoDocument(document: removed, archivedAt: Date()))
            return documentCollection(projectId)
        case ("POST", "folder"):
            // A folder of the other list is refused rather than quietly
            // ignored, as on the server: the caller asked for somewhere
            // specific. A missing folderId is the way out of a folder.
            let folderId = fields["folderId"] as? Int
            if let folderId {
                guard let folder = folders.first(where: {
                    $0.id == folderId && $0.projectId == projectId
                        && $0.documentType == documents[projectId]![index].documentType
                }) else {
                    return badRequest("folderId")
                }
                documents[projectId]?[index].folderId = folder.id
            } else {
                documents[projectId]?[index].folderId = nil
            }
            touch(projectId)
            return documentCollection(projectId)
        case ("POST", "insert"):
            return insertDocument(document: documents[projectId]![index],
                                  afterBlockId: fields["afterBlockId"] as? Int,
                                  asType: fields["asType"] as? String)
        case ("POST", "duplicate"):
            // Content only, as on the server: a song's lyric blocks and
            // editions are not carried over to the copy.
            let source = documents[projectId]![index]
            var copy = addDocument(projectId: projectId, title: copyTitle(source.title),
                                   type: source.documentType, content: source.content)
            // The copy lands beside what it was copied from, as on the server:
            // a duplicate that appeared outside the original's folder would
            // have to be filed by hand every time.
            copy.folderId = source.folderId
            if let at = documents[projectId]?.firstIndex(where: { $0.id == copy.id }) {
                documents[projectId]?[at] = copy
            }
            return created(documentJSON(copy, includeContent: true))
        case ("POST", "change-type"):
            // A blank type is the only rejection; the server maps any other
            // unrecognized value onto SONG rather than failing.
            guard let type = normalizeDocumentType(fields["type"] as? String) else {
                return badRequest("type")
            }
            documents[projectId]?[index].documentType = type
            // A folder belongs to one list, so a document crossing between
            // them cannot take its folder along — the new list has never heard
            // of it. Same rule the server applies.
            documents[projectId]?[index].folderId = nil
            documents[projectId]?[index].updatedAt = .now
            return ok(documentJSON(documents[projectId]![index], includeContent: true))
        case ("POST", "share-email"):
            let email = (fields["email"] as? String) ?? ""
            if email.isBlank { return badRequest("email") }
            return ok(["shared": true,
                       "title": documents[projectId]![index].title,
                       "email": email])
        case ("GET", "export-song"):
            return demoSongExport(documents[projectId]![index], format: query["format"] ?? "txt")
        default:
            return notFound()
        }
    }

    // MARK: - Folders

    /// `/api/document/folder…`: the headings a list's songs or notes are filed
    /// under.
    ///
    /// Every write answers with the refreshed folder collection, as the server
    /// does — renaming or removing one changes what the whole list looks like,
    /// so the one folder would not be enough.
    private func routeDocumentFolder(method: String, path: [String],
                                     query: [String: String],
                                     fields: [String: Any]) -> (Int, Data) {
        switch (method, path.first) {
        case ("GET", nil):
            guard let projectId = query["projectId"].flatMap(Int.init),
                  documents[projectId] != nil else { return badRequest("projectId") }
            return folderCollection(projectId, type: folderListType(query["type"]))
        case ("POST", nil):
            guard let projectId = query["projectId"].flatMap(Int.init),
                  documents[projectId] != nil else { return badRequest("projectId") }
            // A write lands in one list or the other; no type means songs,
            // which is what every other type-less document route defaults to.
            let type = folderListType(query["type"]) ?? "SONG"
            guard let name = folderName(fields["name"]) else { return badRequest("name") }
            guard !folderNameTaken(name, projectId: projectId, type: type, except: nil) else {
                return badRequest("name")
            }
            folders.append(DemoFolder(id: nextFolderId, projectId: projectId,
                                      documentType: type, name: name,
                                      createdAt: .now, updatedAt: .now))
            nextFolderId += 1
            touch(projectId)
            return folderCollection(projectId, type: folderListType(query["type"]))
        default:
            break
        }

        guard let id = path.first.flatMap(Int.init),
              let projectId = query["projectId"].flatMap(Int.init),
              let index = folders.firstIndex(where: { $0.id == id && $0.projectId == projectId })
        else {
            return notFound()
        }

        switch method {
        case "PUT":
            guard let name = folderName(fields["name"]) else { return badRequest("name") }
            guard !folderNameTaken(name, projectId: projectId,
                                   type: folders[index].documentType, except: id) else {
                return badRequest("name")
            }
            folders[index].name = name
            folders[index].updatedAt = .now
            touch(projectId)
            return folderCollection(projectId, type: folderListType(query["type"]))
        case "DELETE":
            // Unfiles what was in it rather than deleting anything: the same
            // promise the server's ON DELETE SET NULL and its service both make.
            for documentIndex in (documents[projectId] ?? []).indices
            where documents[projectId]?[documentIndex].folderId == id {
                documents[projectId]?[documentIndex].folderId = nil
            }
            folders.remove(at: index)
            touch(projectId)
            return folderCollection(projectId, type: folderListType(query["type"]))
        default:
            return notFound()
        }
    }

    /// Files the ticked rows, skipping anything this folder cannot take — a
    /// selection made before someone changed a song into a note still moves
    /// everything it can, exactly as on the server.
    private func bulkMoveDocumentsToFolder(query: [String: String],
                                           fields: [String: Any]) -> (Int, Data) {
        guard let projectId = query["projectId"].flatMap(Int.init),
              documents[projectId] != nil else { return badRequest("projectId") }
        let ids = (fields["ids"] as? [Any])?.compactMap { $0 as? Int } ?? []
        guard !ids.isEmpty else { return badRequest("ids") }
        let folderId = fields["folderId"] as? Int
        var folder: DemoFolder?
        if let folderId {
            guard let match = folders.first(where: {
                $0.id == folderId && $0.projectId == projectId
            }) else { return badRequest("folderId") }
            folder = match
        }
        var moved = 0
        for id in Set(ids) {
            guard let index = documents[projectId]?.firstIndex(where: { $0.id == id }) else { continue }
            if let folder, documents[projectId]?[index].documentType != folder.documentType {
                continue
            }
            documents[projectId]?[index].folderId = folder?.id
            moved += 1
        }
        guard moved > 0 else { return badRequest("ids") }
        touch(projectId)
        return documentCollection(projectId)
    }

    /// A project's folders as the collection resource, narrowed to one list
    /// when a type was asked for — and both lists when none was, which is how
    /// the app fetches them.
    private func folderCollection(_ projectId: Int, type: String?) -> (Int, Data) {
        let shown = folders
            .filter { $0.projectId == projectId && (type == nil || $0.documentType == type) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let counts = (documents[projectId] ?? []).reduce(into: [Int: Int]()) { counts, document in
            if let folderId = document.folderId { counts[folderId, default: 0] += 1 }
        }
        var selfHref = "/api/document/folder?projectId=\(projectId)"
        if let type { selfHref += "&type=\(type)" }
        let items = shown.map { folder -> [String: Any] in
            [
                "id": folder.id,
                "projectId": folder.projectId,
                "documentType": folder.documentType,
                "name": folder.name,
                "documentCount": counts[folder.id] ?? 0,
                "createdAt": iso.string(from: folder.createdAt),
                "updatedAt": iso.string(from: folder.updatedAt),
                "_links": [
                    "folders": link(selfHref),
                    "documents": link("/api/document?projectId=\(projectId)"),
                    // Both carry the query the collection was fetched with, so
                    // the answer comes back in the scope the caller is looking
                    // at — the same rule the server's item links follow.
                    "renameFolder": link(folderItemHref(folder.id, projectId: projectId, type: type)),
                    "deleteFolder": link(folderItemHref(folder.id, projectId: projectId, type: type)),
                ],
            ]
        }
        return ok([
            "_embedded": ["textDocumentFolderResourceList": items],
            "_links": [
                "self": link(selfHref),
                "project": link("/api/project/\(projectId)"),
                "documents": link("/api/document?projectId=\(projectId)"),
                // Unconditional, matching the server: a client needs somewhere
                // to send the first folder, and an empty list is when it needs
                // it most. The demo user can always edit.
                "createFolder": link(selfHref),
            ],
        ])
    }

    private func folderItemHref(_ id: Int, projectId: Int, type: String?) -> String {
        var href = "/api/document/folder/\(id)?projectId=\(projectId)"
        if let type { href += "&type=\(type)" }
        return href
    }

    /// The folder an archive entry names, made here if this project has not got
    /// one of that name in that list.
    ///
    /// A name is the only form an arrangement can cross in: the file was
    /// written somewhere that numbers its own folders, and nothing on either
    /// side can recognise the other's ids — the same problem `uid` solves for
    /// the documents themselves, answered the same way.
    ///
    /// Nil for an entry that names none, which is also what takes a folder off
    /// a document being written into: the file is the whole truth about where
    /// its songs sit.
    private func folderNamed(_ name: String?, type: String, in projectId: Int) -> Int? {
        guard let raw = name?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let listType = type == "SONG" ? "SONG" : "NOTES"
        let clean = String(raw.prefix(100))
        if let existing = folders.first(where: {
            $0.projectId == projectId && $0.documentType == listType
                && $0.name.localizedCaseInsensitiveCompare(clean) == .orderedSame
        }) {
            return existing.id
        }
        let folder = DemoFolder(id: nextFolderId, projectId: projectId,
                                documentType: listType, name: clean,
                                createdAt: .now, updatedAt: .now)
        nextFolderId += 1
        folders.append(folder)
        return folder.id
    }

    /// "SONG", "NOTES", or nil for both lists — the listing's own rule, where a
    /// missing type means everything rather than a default.
    private func folderListType(_ raw: String?) -> String? {
        guard let raw, !raw.isBlank else { return nil }
        return raw.uppercased() == "SONG" ? "SONG" : "NOTES"
    }

    /// A folder name the server would accept: present, trimmed, not blank.
    private func folderName(_ raw: Any?) -> String? {
        guard let name = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return String(name.prefix(100))
    }

    /// Two folders of one list cannot share a name, as the unique index says.
    private func folderNameTaken(_ name: String, projectId: Int,
                                 type: String, except id: Int?) -> Bool {
        folders.contains {
            $0.projectId == projectId && $0.documentType == type
                && $0.id != id
                && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }

    /// Reassigns sort order to the supplied sequence, exactly as the server
    /// does — ids from another project or unknown ids reject the whole request.
    private func reorderDocuments(query: [String: String], fields: [String: Any]) -> (Int, Data) {
        guard let projectId = query["projectId"].flatMap(Int.init),
              documents[projectId] != nil else { return badRequest("projectId") }
        let orderedIds = (fields["orderedIds"] as? [Any])?.compactMap { $0 as? Int } ?? []
        guard !orderedIds.isEmpty else { return badRequest("orderedIds") }
        let existing = Set((documents[projectId] ?? []).map(\.id))
        guard orderedIds.allSatisfy(existing.contains) else {
            return badRequest("orderedIds")
        }
        for (position, id) in orderedIds.enumerated() {
            if let index = documents[projectId]?.firstIndex(where: { $0.id == id }) {
                documents[projectId]?[index].sortOrder = position
            }
        }
        let items = (documents[projectId] ?? [])
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { documentJSON($0, includeContent: false) }
        // The reorder answer replaces the client's held collection links, so it
        // carries the same set the listing did — otherwise every other
        // affordance would disappear after a drag.
        return ok(["_embedded": ["textDocumentResourceList": items],
                   "_links": documentCollectionLinks(projectId: projectId)])
    }

    /// Trashes several documents at once — songs, notes, or a mix of the two,
    /// as the server's own bulk delete takes. It skipped anything that was not
    /// a song, which the service behind the real one used to do and no longer
    /// does. Ids that are missing or belong to another project are still
    /// skipped. Answers with what is left.
    private func bulkDeleteDocuments(query: [String: String], fields: [String: Any]) -> (Int, Data) {
        guard let projectId = query["projectId"].flatMap(Int.init),
              documents[projectId] != nil else { return badRequest("projectId") }
        let ids = (fields["ids"] as? [Any])?.compactMap { $0 as? Int } ?? []
        guard !ids.isEmpty else { return badRequest("ids") }
        var deleted = 0
        for id in Set(ids) {
            guard let index = documents[projectId]?.firstIndex(where: { $0.id == id })
            else { continue }
            if let removed = documents[projectId]?.remove(at: index) {
                deletedDocuments[projectId, default: []].append(
                    DeletedDemoDocument(document: removed, deletedAt: Date()))
                deleted += 1
            }
        }
        guard deleted > 0 else { return badRequest("ids") }
        return documentCollection(projectId)
    }

    /// Archives several documents at once — either kind, as the delete beside it
    /// now also takes. Ids already archived or from another project are skipped.
    private func bulkArchiveDocuments(query: [String: String], fields: [String: Any]) -> (Int, Data) {
        guard let projectId = query["projectId"].flatMap(Int.init),
              documents[projectId] != nil else { return badRequest("projectId") }
        let ids = (fields["ids"] as? [Any])?.compactMap { $0 as? Int } ?? []
        guard !ids.isEmpty else { return badRequest("ids") }
        var archived = 0
        for id in Set(ids) {
            guard let index = documents[projectId]?.firstIndex(where: { $0.id == id }),
                  let removed = documents[projectId]?.remove(at: index) else { continue }
            archivedDocuments[projectId, default: []].append(
                ArchivedDemoDocument(document: removed, archivedAt: Date()))
            archived += 1
        }
        guard archived > 0 else { return badRequest("ids") }
        return documentCollection(projectId)
    }

    /// A project's document list as the collection resource, which is what
    /// every write that changes the list answers with.
    private func documentCollection(_ projectId: Int) -> (Int, Data) {
        let items = (documents[projectId] ?? [])
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { documentJSON($0, includeContent: false) }
        return ok(["_embedded": ["textDocumentResourceList": items],
                   "_links": documentCollectionLinks(projectId: projectId)])
    }

    /// Emails several documents at once. Nothing leaves the device in demo mode
    /// — there is no mail to send — but the reply is shaped like the server's so
    /// the client can say honestly how many *would* have gone. Songs, notes or a
    /// mix, which is what the real one sends: notes in the selection were
    /// skipped here, and are not any more.
    private func bulkShareDocuments(query: [String: String], fields: [String: Any]) -> (Int, Data) {
        guard let projectId = query["projectId"].flatMap(Int.init),
              let chosen = documents[projectId] else { return badRequest("projectId") }
        let ids = (fields["ids"] as? [Any])?.compactMap { $0 as? Int } ?? []
        guard !ids.isEmpty else { return badRequest("ids") }
        let email = (fields["email"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !email.isEmpty else { return badRequest("email") }
        let titles = chosen
            .filter { ids.contains($0.id) }
            .map(\.title)
        guard !titles.isEmpty else { return badRequest("email") }
        return ok(["shared": titles.count, "titles": titles, "email": email])
    }

    /// The ids of a comma-separated query value, as Spring reads a `List<Integer>`
    /// parameter.
    /// Coerces a JSON array body field to `[Int]`, or nil when the field is
    /// absent — which is how a PUT tells "leave the teams alone" apart from
    /// "set them to none", the same absent-means-unchanged rule the title-page
    /// fields follow.
    private func intList(_ value: Any?) -> [Int]? {
        guard let value else { return nil }
        if let ints = value as? [Int] { return ints }
        if let anys = value as? [Any] { return anys.compactMap { $0 as? Int } }
        return nil
    }

    private func idList(_ value: String?) -> [Int] {
        (value ?? "").split(separator: ",").compactMap { Int($0) }
    }

    /// The links a project's document collection carries. The songbook exports
    /// appear only where there is a song to put in the book, matching the
    /// server, and sit outside the edit gate because exporting is a read.
    private func documentCollectionLinks(projectId: Int) -> [String: Any] {
        var links: [String: Any] = [
            "self": link("/api/document?projectId=\(projectId)"),
            "project": link("/api/project/\(projectId)"),
            "importDocument": link("/api/document/import"),
            "reorder": link("/api/document/reorder?projectId=\(projectId)"),
            "trash": link("/api/document/trash?projectId=\(projectId)"),
            // No has-a-song condition on either: notes archive too, and the
            // archive is advertised even when empty since a list can be empty
            // precisely because everything is in it.
            "archived": link("/api/document/archive?projectId=\(projectId)"),
            "bulkArchive": link("/api/document/bulk/archive?projectId=\(projectId)"),
            // Unscoped, as the server advertises it when the list itself was
            // fetched unscoped: no `type` means both lists' folders, which is
            // what one screen showing two lists wants.
            "folders": link("/api/document/folder?projectId=\(projectId)"),
            // Filing a selection. Like the archive above it, this needs no
            // song and no folder to be worth offering — the same call with no
            // folder id is how a selection comes back out of one.
            "bulkMoveToFolder": link("/api/document/bulk/folder?projectId=\(projectId)"),
        ]
        if (documents[projectId] ?? []).contains(where: { $0.documentType != "SONG" }) {
            // The same gathering made of notes, which the server advertises
            // once there is a note to put in it. Four rather than five: a note
            // is refused a score, so there is no MusicXML here.
            for (rel, format) in [("exportNotesTxt", "txt"), ("exportNotesPdf", "pdf"),
                                  ("exportNotesDocx", "docx"), ("exportNotesEpub", "epub")] {
                links[rel] = link(
                    "/api/document/export-songs?projectId=\(projectId)&format=\(format)&type=NOTES")
            }
        }
        if (documents[projectId] ?? []).contains(where: { $0.documentType == "SONG" }) {
            for (rel, format) in [("exportSongsTxt", "txt"), ("exportSongsPdf", "pdf"),
                                  ("exportSongsDocx", "docx"), ("exportSongsEpub", "epub"),
                                  ("exportSongsMusicXml", "musicxml")] {
                links[rel] = link("/api/document/export-songs?projectId=\(projectId)&format=\(format)")
            }
        }
        // Deleting and emailing a selection. These used to ride with the
        // songbook's condition above, because the services behind them skipped
        // anything that was not a song. They no longer do — a ticked note is
        // trashed and emailed exactly as a ticked song is — so the only question
        // left is whether there is anything at all to select, which is the rule
        // the server now goes by. Left here they made a project of notes the one
        // place where the selection bar came up missing two of its five buttons,
        // and only in the demo: signed in, the same list showed all five.
        //
        // Still inside the edit gate on the server. The demo is always on the
        // right side of that, as the import and reorder links above assume.
        if !(documents[projectId] ?? []).isEmpty {
            links["bulkDelete"] = link("/api/document/bulk/delete?projectId=\(projectId)")
            links["bulkShareEmail"] = link("/api/document/bulk/share-email?projectId=\(projectId)")
        }
        return links
    }

    /// What the exporter heads a sheet with when nobody named the document —
    /// the server's own two placeholders, which are also the words the list
    /// draws for it.
    private func untitled(_ document: DemoDocument) -> String {
        document.documentType == "SONG" ? "Untitled Song" : "Untitled Notes"
    }

    /// A song or a note exported on its own. The demo serves the format it can
    /// actually produce, so the export rel resolves offline; the point is the
    /// round trip, not a faithful renderer.
    ///
    /// The PDF is the exception, and stopped being a shell when printing
    /// arrived: `DocumentPDF` already draws a document the server's own way for
    /// the offline fallback, so the demo hands back the same file rather than
    /// an empty sheet with a title in the metadata. A demo print that produces
    /// a blank page looks like the feature is broken.
    private func demoSongExport(_ document: DemoDocument, format: String) -> (Int, Data) {
        switch format {
        case "pdf":
            return (200, DocumentPDF.render(
                [DocumentPDF.Section(title: document.title.isEmpty
                                        ? untitled(document) : document.title,
                                     text: document.content)],
                title: document.title))
        case "musicxml":
            // A real score, not a shell: this is the one export the demo can
            // produce faithfully, and the one whose file is meant to come back.
            return (200, DemoMusicXml.score(
                title: document.title,
                sections: [DemoMusicXml.Section(title: nil, lyrics: document.content)]))
        default:
            let header = document.title.isEmpty ? "" : document.title + "\n\n"
            return (200, Data((header + document.content).utf8))
        }
    }

    /// Every song in a project, one after another — the songbook the web's
    /// Export menu downloads — or the same gathering made of notes, which is
    /// what `type` asks for. Same shortcut as the single-document export: the
    /// point is that the rel resolves and a file comes back. A non-empty `ids`
    /// list narrows the file to those documents, keeping the project's order.
    private func demoSongbookExport(projectId: Int, format: String, type: String? = nil,
                                    ids: [Int] = []) -> (Int, Data) {
        let chosen = Set(ids)
        let wantsSongs = type == nil || type?.uppercased() == "SONG"
        let songs = (documents[projectId] ?? [])
            .filter { ($0.documentType == "SONG") == wantsSongs
                        && (chosen.isEmpty || chosen.contains($0.id)) }
            .sorted { $0.sortOrder < $1.sortOrder }
        let kind = wantsSongs ? "Songs" : "Notes"
        let title = projects.first { $0.id == projectId }?.title ?? kind
        switch format {
        case "pdf":
            return (200, DocumentPDF.render(
                songs.map {
                    DocumentPDF.Section(title: $0.title.isEmpty ? untitled($0) : $0.title,
                                        text: $0.content)
                },
                placeholder: wantsSongs ? "No songs yet." : "No notes yet.",
                title: title))
        case "musicxml":
            return (200, DemoMusicXml.score(
                title: title,
                sections: songs.map { DemoMusicXml.Section(title: $0.title, lyrics: $0.content) }))
        default:
            let book = songs
                .map { ($0.title.isEmpty ? "" : $0.title + "\n\n") + $0.content }
                .joined(separator: "\n\n\n")
            return (200, Data(book.utf8))
        }
    }

    private func insertDocument(document: DemoDocument, afterBlockId: Int?,
                                asType: String?) -> (Int, Data) {
        let projectId = document.projectId
        let type = asType ?? (document.documentType == "SONG" ? "LYRICS" : "ACTION")
        let lines = document.content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else {
            return ok(["inserted": 0, "projectId": projectId, "firstBlockId": NSNull()])
        }
        snapshot(projectId)
        var current = (blocks[projectId] ?? []).sorted { $0.order < $1.order }
        let newBlocks = lines.map { line -> DemoBlock in
            let block = DemoBlock(id: nextBlockId, order: 0, content: line, type: type)
            nextBlockId += 1
            return block
        }
        let firstId = newBlocks.first?.id
        // Drop the lines in right after the anchor, else append. Renumber the
        // whole list so the new lines sit in sequence rather than colliding
        // with the orders already in use — the same move `below` and the block
        // move make.
        if let afterBlockId, let anchor = current.firstIndex(where: { $0.id == afterBlockId }) {
            current.insert(contentsOf: newBlocks, at: anchor + 1)
        } else {
            current.append(contentsOf: newBlocks)
        }
        for i in current.indices { current[i].order = i + 1 }
        blocks[projectId] = current
        touch(projectId)
        return ok(["inserted": lines.count,
                   "projectId": projectId,
                   "firstBlockId": firstId ?? NSNull()])
    }

    /// Minimal multipart parse: pulls the `type` field and the uploaded file's
    /// name + text. Binary formats can't be extracted offline, so their text
    /// is best-effort UTF-8 (the real backend handles docx/pdf/fdx).
    private func importDocument(body: Data?) -> (Int, Data) {
        guard let parsed = parseMultipart(body) else { return badRequest("file") }
        guard let projectId = parsed.fields["projectId"].flatMap(Int.init),
              documents[projectId] != nil else { return badRequest("projectId") }
        let type = normalizeDocumentType(parsed.fields["type"]) ?? "SONG"
        let rawName = parsed.fileName ?? "Imported"
        var title = (rawName as NSString).deletingPathExtension
        var content = String(data: parsed.fileData ?? Data(), encoding: .utf8) ?? ""
        // A score carries its own words and its own name, so neither the raw
        // markup nor the filename is what the song should end up with.
        if let score = DemoMusicXml.read(parsed.fileData ?? Data()) {
            content = score.lyrics
            if let declared = score.title, !declared.isEmpty { title = declared }
        }
        let document = addDocument(projectId: projectId,
                                   title: title.isEmpty ? "Imported" : title,
                                   type: type, content: content)
        return ok(documentJSON(document, includeContent: true))
    }

    @discardableResult
    private func addDocument(projectId: Int, title: String, type: String,
                             content: String, uid: String? = nil) -> DemoDocument {
        let order = (documents[projectId] ?? []).map(\.sortOrder).max().map { $0 + 1 } ?? 0
        let document = DemoDocument(id: nextDocumentId, projectId: projectId, title: title,
                                    documentType: type, content: content, sortOrder: order,
                                    createdAt: .now, updatedAt: .now,
                                    // A name of its own from the moment it exists, so a song
                                    // written here can be recognised as the same song once an
                                    // account holds it too — see `DemoDocument.uid`. Callers
                                    // reading an archive pass the one the file already knows.
                                    uid: uid ?? UUID().uuidString)
        nextDocumentId += 1
        documents[projectId, default: []].append(document)
        return document
    }

    /// Gives every document written before uids existed one, once.
    ///
    /// Done on the way in rather than lazily on the way out, because the one
    /// thing that needs a uid is an archive being built — and archives are
    /// built by GETs, which deliberately do not write the workspace back. A name
    /// minted there and forgotten would be a different name next time, which is
    /// worse than none: the account would collect a fresh copy of the song on
    /// every crossing.
    ///
    /// Answers whether anything changed, so a workspace that needs nothing costs
    /// nothing.
    @discardableResult
    private func nameDocumentsWithoutUids() -> Bool {
        var changed = false
        func name(_ document: inout DemoDocument) {
            guard document.uid?.isEmpty ?? true else { return }
            document.uid = UUID().uuidString
            changed = true
        }
        for projectId in documents.keys {
            for index in documents[projectId]!.indices { name(&documents[projectId]![index]) }
        }
        for projectId in archivedDocuments.keys {
            for index in archivedDocuments[projectId]!.indices {
                name(&archivedDocuments[projectId]![index].document)
            }
        }
        for projectId in deletedDocuments.keys {
            for index in deletedDocuments[projectId]!.indices {
                name(&deletedDocuments[projectId]![index].document)
            }
        }
        return changed
    }

    /// One document as the server renders it.
    ///
    /// `archivedAt` is non-nil only when this is being fetched out of the
    /// archive, which is the one case where an editor holding the document has
    /// no other way to know what it is looking at. It also decides which
    /// direction is offered: `archive` and `unarchive` are never both there,
    /// because archiving something already archived is what the server refuses.
    private func documentJSON(_ document: DemoDocument, includeContent: Bool,
                              archivedAt: Date? = nil) -> [String: Any] {
        let isSong = document.documentType == "SONG"
        var links: [String: Any] = [
            "self": link("/api/document/\(document.id)"),
            "documents": link("/api/document?projectId=\(document.projectId)"),
            "project": link("/api/project/\(document.projectId)"),
            "update": link("/api/document/\(document.id)"),
            "delete": link("/api/document/\(document.id)"),
            "insert": link("/api/document/\(document.id)/insert"),
            // Both are editor affordances on the document itself; the demo user
            // always has edit rights, so they are unconditional here.
            "duplicate": link("/api/document/\(document.id)/duplicate"),
            "changeType": link("/api/document/\(document.id)/change-type"),
            // Which folder this is in is a write to the document, so it rides
            // here rather than on a folder. One link for both directions: the
            // same call with no folder id takes it out.
            "moveToFolder": link("/api/document/\(document.id)/folder"),
        ]
        // Songs and notes both archive. One direction or the other, never both.
        if archivedAt == nil {
            links["archive"] = link("/api/document/\(document.id)/archive")
        } else {
            links["unarchive"] = link(
                "/api/document/archive/\(document.id)/unarchive?projectId=\(document.projectId)")
        }
        // And both email. This was gated on being a song, which was the last
        // song-shaped thing left here — while `bulkShareEmail` on the
        // collection was not gated at all, so a note could be emailed by
        // ticking it in Edit mode and not from its own "…" menu. The real
        // server emits this for either kind unconditionally
        // (`TextDocumentResourceAssembler`: "The share service no longer skips
        // notes, so nothing here has to either"), and the handler on this side
        // was never gated, so the demo was simply advertising less than it
        // could do.
        links["shareEmail"] = link("/api/document/\(document.id)/share-email")
        if isSong {
            // Songs are lyric blocks on the server, so only they have editions
            // to scope. A note is plain text with nothing to vary.
            links["editions"] = link("/api/song/edition?documentId=\(document.id)")
            links["songBlocks"] = link("/api/song/block?documentId=\(document.id)")
            // The recordings kept with this song. Advertised whether or not
            // there are any, as the server does — a song with none is where a
            // client offers to add the first.
            links["audioRecordings"] = link("/api/song/audio?documentId=\(document.id)")
            // A score rather than a document to read, and the format the song
            // importer reads back. The one export that is still song-only: the
            // server refuses a note a stave rather than handing back an empty
            // one.
            links["exportSongMusicXml"] = link("/api/document/\(document.id)/export-song?format=musicxml")
        }
        // Not song-only any more, matching the server: the exporter lays out a
        // title and its lines, which is what a note is too. Outside the edit
        // gate as well, since taking a copy away is a read — which the demo,
        // where every document is the writer's own, cannot tell apart anyway.
        for (rel, format) in [("exportSongTxt", "txt"), ("exportSongPdf", "pdf"),
                              ("exportSongDocx", "docx"), ("exportSongEpub", "epub")] {
            links[rel] = link("/api/document/\(document.id)/export-song?format=\(format)")
        }
        var json: [String: Any] = [
            "id": document.id,
            "projectId": document.projectId,
            "title": document.title,
            "documentType": document.documentType,
            "documentTypeLabel": isSong ? "Song" : "Notes",
            "preview": documentPreview(document.content),
            "sortOrder": document.sortOrder,
            "createdAt": iso.string(from: document.createdAt),
            "updatedAt": iso.string(from: document.updatedAt),
            "_links": links,
        ]
        if includeContent {
            json["content"] = document.content
        }
        // As the server publishes it: the one thing that names this song in a
        // workspace that is not this one.
        if let uid = document.uid, !uid.isEmpty {
            json["uid"] = uid
        }
        // Omitted for an unfiled document rather than sent as null: absent is
        // how the server says "there isn't one", and the client reads it that
        // way. The name rides along so a document fetched on its own can say
        // where it lives without also fetching the folder list.
        if let folderId = document.folderId,
           let folder = folders.first(where: { $0.id == folderId }) {
            json["folderId"] = folder.id
            json["folderName"] = folder.name
        }
        if let archivedAt {
            json["archivedAt"] = iso.string(from: archivedAt)
        }
        return json
    }

    private func documentPreview(_ content: String) -> String {
        let flattened = content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return flattened.count > 90 ? String(flattened.prefix(90)) + "…" : flattened
    }

    /// The title the server gives a duplicate: the original with " (copy)"
    /// appended, trimmed to fit the column if that would overflow it.
    private func copyTitle(_ title: String) -> String {
        let suffix = " (copy)"
        var base = title.isBlank ? "Untitled" : title.trimmingCharacters(in: .whitespaces)
        if base.count + suffix.count > 200 {
            base = String(base.prefix(200 - suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return base + suffix
    }

    private func normalizeDocumentType(_ type: String?) -> String? {
        guard let type, !type.isBlank else { return nil }
        switch type.uppercased() {
        case "NOTES", "NOTE", "DRAFT", "DRAFTS", "OTHER":
            return "NOTES"
        default:
            return "SONG"
        }
    }

    private func locateDocument(_ id: Int) -> (projectId: Int, index: Int)? {
        for (projectId, list) in documents {
            if let index = list.firstIndex(where: { $0.id == id }) {
                return (projectId, index)
            }
        }
        return nil
    }

    /// Which store a document is in, and where — the list or the archive.
    ///
    /// `locateDocument` above deliberately answers for the list alone, because
    /// its callers index straight into `documents` to change something. This is
    /// for everything that only has to *find* the document, which on the server
    /// is every by-id finder: those ask only that it is not trashed, so an
    /// archived song still has its lyrics, its editions and its history. Without
    /// this the archive could open a song and then fail to load a word of it.
    private enum DocumentSite {
        case live(projectId: Int, index: Int)
        case archived(projectId: Int, index: Int)
    }

    private func siteOfDocument(_ id: Int) -> DocumentSite? {
        if let (projectId, index) = locateDocument(id) {
            return .live(projectId: projectId, index: index)
        }
        for (projectId, records) in archivedDocuments {
            if let index = records.firstIndex(where: { $0.document.id == id }) {
                return .archived(projectId: projectId, index: index)
            }
        }
        return nil
    }

    /// Whether there is such a document at all, archived or not.
    private func documentExists(_ id: Int) -> Bool { siteOfDocument(id) != nil }

    /// A document's words, wherever it is being kept.
    private func documentContent(_ id: Int) -> String? {
        switch siteOfDocument(id) {
        case let .live(projectId, index): return documents[projectId]?[index].content
        case let .archived(projectId, index): return archivedDocuments[projectId]?[index].document.content
        case nil: return nil
        }
    }

    /// Writes a document's words back where they came from. An archived song is
    /// still edited in place, so its preview has to keep up too.
    private func setDocumentContent(_ id: Int, to content: String) {
        switch siteOfDocument(id) {
        case let .live(projectId, index):
            documents[projectId]?[index].content = content
            documents[projectId]?[index].updatedAt = .now
            touch(projectId)
        case let .archived(projectId, index):
            archivedDocuments[projectId]?[index].document.content = content
            archivedDocuments[projectId]?[index].document.updatedAt = .now
            touch(projectId)
        case nil:
            break
        }
    }

    /// Parses the fixed-boundary multipart body produced by `APIClient.upload`.
    private func parseMultipart(_ body: Data?) -> (fields: [String: String], fileName: String?, fileData: Data?)? {
        guard let body else { return nil }
        let boundary = "--" + APIClient.multipartBoundary
        guard let boundaryData = boundary.data(using: .utf8),
              let crlfcrlf = "\r\n\r\n".data(using: .utf8),
              let crlf = "\r\n".data(using: .utf8) else { return nil }

        var fields: [String: String] = [:]
        var fileName: String?
        var fileData: Data?

        var searchStart = body.startIndex
        var parts: [Data] = []
        // Split on the boundary marker.
        var ranges: [Range<Data.Index>] = []
        while let range = body.range(of: boundaryData, in: searchStart..<body.endIndex) {
            ranges.append(range)
            searchStart = range.upperBound
        }
        for i in 0..<ranges.count {
            let start = ranges[i].upperBound
            let end = (i + 1 < ranges.count) ? ranges[i + 1].lowerBound : body.endIndex
            if start < end { parts.append(body.subdata(in: start..<end)) }
        }

        for part in parts {
            guard let headerEnd = part.range(of: crlfcrlf) else { continue }
            let headerData = part.subdata(in: part.startIndex..<headerEnd.lowerBound)
            guard let header = String(data: headerData, encoding: .utf8) else { continue }
            var contentStart = headerEnd.upperBound
            var contentEnd = part.endIndex
            // Strip the trailing CRLF before the next boundary.
            if let trailing = part.range(of: crlf, options: .backwards, in: contentStart..<part.endIndex) {
                contentEnd = trailing.lowerBound
            }
            if contentStart > contentEnd { contentStart = contentEnd }
            let content = part.subdata(in: contentStart..<contentEnd)

            if let name = value(in: header, for: "name") {
                if let file = value(in: header, for: "filename") {
                    fileName = file
                    fileData = content
                } else {
                    fields[name] = String(data: content, encoding: .utf8)
                }
            }
        }
        return (fields, fileName, fileData)
    }

    /// Extracts a `key="value"` token from a Content-Disposition header line.
    private func value(in header: String, for key: String) -> String? {
        guard let keyRange = header.range(of: "\(key)=\"") else { return nil }
        let rest = header[keyRange.upperBound...]
        guard let endQuote = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<endQuote])
    }

    // MARK: - Undo / redo

    /// History is snapshot-based: good enough for a demo, invisible to the UI.
    // MARK: - Invitations

    /// Someone invited to a screenplay. The demo enables this surface where a
    /// real deployment keeps it behind a flag, because nothing here leaves the
    /// process: no mail is sent and no account can be created.
    private struct DemoInvitation: Codable {
        var id: Int
        var projectId: Int
        var email: String
        var viewOnly: Bool
        var status: String
        /// The team a collaborator joined, so the row can name it. Nil for a
        /// reader, who joins no team.
        var teamName: String?
    }

    private func routeInvitations(method: String, projectId: Int, path: [String],
                                  fields: [String: Any]) -> (Int, Data) {
        guard projects.contains(where: { $0.id == projectId }) else { return notFound() }

        switch (method, path.count) {
        case ("GET", 0):
            return invitationCollection(projectId)

        // The teams a collaborator can be invited into: the project's own.
        case ("GET", 1) where path.first == "teams":
            return inviteTeamsCollection(projectId)

        case ("POST", 0):
            guard let email = (fields["email"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else {
                return badRequest("email")
            }
            let viewOnly = fields["viewOnly"] as? Bool ?? false
            // A collaborator must name one of the project's teams; the real
            // service rejects a missing or foreign team, so the demo does too.
            var teamName: String?
            if !viewOnly {
                guard let teamId = fields["teamId"] as? Int,
                      let team = inviteTeams(for: projectId).first(where: { $0.id == teamId }) else {
                    return badRequest("email")
                }
                teamName = team.name
            }
            // Answers the same whether or not the address is already known, so
            // the client cannot learn who has an account. The real service
            // returns null in that case for the same reason.
            let known = invitations.contains {
                $0.projectId == projectId && $0.email.caseInsensitiveCompare(email) == .orderedSame
            }
            if !known {
                invitations.append(DemoInvitation(
                    id: nextInvitationId,
                    projectId: projectId,
                    email: email,
                    viewOnly: viewOnly,
                    status: "Pending",
                    teamName: teamName))
                nextInvitationId += 1
            }
            recordActivity(projectId, type: "INVITATION_SEND",
                           summary: "Invited \(email)")
            return invitationCollection(projectId)

        default:
            break
        }

        guard let id = path.first.flatMap(Int.init),
              let index = invitations.firstIndex(where: {
                  $0.id == id && $0.projectId == projectId
              }), method == "DELETE" else { return notFound() }

        let removed = invitations.remove(at: index)
        recordActivity(projectId, type: "INVITATION_REVOKE",
                       summary: "Revoked the invitation for \(removed.email)")
        return invitationCollection(projectId)
    }

    private func invitationCollection(_ projectId: Int) -> (Int, Data) {
        let items = invitations
            .filter { $0.projectId == projectId }
            .map { invitation -> [String: Any] in
                var item: [String: Any] = [
                    "id": invitation.id,
                    "email": invitation.email,
                    "statusLabel": invitation.status,
                    "viewOnly": invitation.viewOnly,
                    "_links": [
                        "revoke": link("/api/project/\(projectId)/invitations/\(invitation.id)"),
                        "invitations": link("/api/project/\(projectId)/invitations"),
                    ],
                ]
                if let teamName = invitation.teamName { item["teamName"] = teamName }
                return item
            }
        return ok([
            "_embedded": ["invitationResourceList": items],
            "_links": [
                "self": link("/api/project/\(projectId)/invitations"),
                "sendInvitation": link("/api/project/\(projectId)/invitations"),
                // Always advertised, even where the project has no teams — the
                // client reads an empty list as "assign a team first".
                "inviteTeams": link("/api/project/\(projectId)/invitations/teams"),
                "project": link("/api/project/\(projectId)"),
            ],
        ])
    }

    /// The teams a collaborator can be invited into. The demo project carries
    /// the single "Demo" team, matching the badge it already shows.
    private func inviteTeams(for projectId: Int) -> [DemoTeam] {
        guard projects.contains(where: { $0.id == projectId }) else { return [] }
        return teamsStore.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func inviteTeamsCollection(_ projectId: Int) -> (Int, Data) {
        let items = inviteTeams(for: projectId).map { team -> [String: Any] in
            ["id": team.id, "name": team.name]
        }
        var payload: [String: Any] = [
            "_links": [
                "self": link("/api/project/\(projectId)/invitations/teams"),
                "invitations": link("/api/project/\(projectId)/invitations"),
            ],
        ]
        // An empty collection is a real answer; omit `_embedded` when there is
        // nothing, the same shape HAL serializes.
        if !items.isEmpty {
            payload["_embedded"] = ["inviteTeamResourceList": items]
        }
        return ok(payload)
    }

    // MARK: - Activity

    /// One entry in a project's activity log. Written by the demo's own
    /// mutations, never by a caller — the log records what happened, not what
    /// someone claimed happened.
    private struct DemoActivity: Codable {
        var id: Int
        var projectId: Int
        var actor: String
        var actionType: String
        var summary: String
        var createdAt: Date
    }

    private func recordActivity(_ projectId: Int, type: String, summary: String,
                                actor: String = "You", minutesAgo: Int = 0) {
        activity.append(DemoActivity(
            id: nextActivityId,
            projectId: projectId,
            actor: actor,
            actionType: type,
            summary: summary,
            createdAt: Date(timeIntervalSinceNow: -Double(minutesAgo) * 60)))
        nextActivityId += 1
    }

    private func activityCollection(_ projectId: Int, limit: Int) -> (Int, Data) {
        let items = activity
            .filter { $0.projectId == projectId }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map { entry -> [String: Any] in
                [
                    "id": entry.id,
                    "actorDisplayName": entry.actor,
                    "actionType": entry.actionType,
                    "summary": entry.summary,
                    "createdAt": iso.string(from: entry.createdAt),
                ]
            }
        return ok([
            "_embedded": ["projectActivityResourceList": Array(items)],
            "_links": [
                "self": link("/api/project/\(projectId)/activity"),
                "project": link("/api/project/\(projectId)"),
            ],
        ])
    }

    // MARK: - Comments

    private struct DemoComment: Codable {
        var id: Int
        var blockId: Int
        var authorName: String
        var body: String
        var createdAt: Date
        /// Whether the demo's single user wrote it. Only their own comments —
        /// and any comment on a script they can edit — offer a delete link.
        var mine: Bool
    }

    private func routeComments(method: String, blockId: Int,
                               fields: [String: Any]) -> (Int, Data) {
        switch method {
        case "GET":
            return commentCollection(blockId)
        case "POST":
            guard let body = (fields["body"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else {
                return badRequest("body")
            }
            comments.append(DemoComment(id: nextCommentId, blockId: blockId,
                                        authorName: "You", body: body,
                                        createdAt: Date(), mine: true))
            nextCommentId += 1
            // The log is written by the action, not by the caller.
            if let (projectId, _) = locateBlock(blockId) {
                recordActivity(projectId, type: "COMMENT_ADD",
                               summary: "Commented on an element")
            }
            return commentCollection(blockId)
        default:
            return notFound()
        }
    }

    private func routeDeleteComment(_ commentId: Int) -> (Int, Data) {
        guard let index = comments.firstIndex(where: { $0.id == commentId }) else {
            return notFound()
        }
        let blockId = comments[index].blockId
        comments.remove(at: index)
        return commentCollection(blockId)
    }

    private func commentCollection(_ blockId: Int) -> (Int, Data) {
        let items = comments
            .filter { $0.blockId == blockId }
            .sorted { $0.createdAt < $1.createdAt }
            .map { comment -> [String: Any] in
                var links: [String: Any] = [
                    "comments": link("/api/block/\(blockId)/comments"),
                ]
                // The demo user can edit the script, so every comment here is
                // deletable — but the link is still what says so.
                links["delete"] = link("/api/block/comments/\(comment.id)")
                return [
                    "id": comment.id,
                    "blockId": blockId,
                    "authorName": comment.authorName,
                    "body": comment.body,
                    "createdAt": iso.string(from: comment.createdAt),
                    "_links": links,
                ]
            }
        return ok([
            "_embedded": ["blockCommentResourceList": items],
            "_links": [
                "self": link("/api/block/\(blockId)/comments"),
                "addComment": link("/api/block/\(blockId)/comments"),
                "block": link("/api/block/\(blockId)"),
            ],
        ])
    }

    /// Comments per element for a whole project, keyed by block id. Elements
    /// with none are left out entirely rather than sent as zero — that absence
    /// is the contract, since it is what keeps the payload small enough to
    /// fetch alongside the script.
    private func commentCounts(_ projectId: Int) -> (Int, Data) {
        var counts: [String: Int] = [:]
        for comment in comments where ownsBlock(comment.blockId, projectId: projectId) {
            counts[String(comment.blockId), default: 0] += 1
        }
        return ok([
            "counts": counts,
            "_links": [
                "self": link("/api/block/comment-counts?projectId=\(projectId)"),
                "blocks": link("/api/block?projectId=\(projectId)"),
            ],
        ])
    }

    // MARK: - Editions

    /// A named variant of a script. Blocks belong to an edition; the demo keys
    /// them by edition id so switching genuinely shows different text.
    private struct DemoEdition: Codable {
        var id: Int
        var projectId: Int
        var name: String
        var isDefault: Bool
        var isPublished: Bool
        var lastEdited: Date
    }

    private func routeEdition(method: String, path: [String],
                              query: [String: String],
                              fields: [String: Any]) -> (Int, Data) {
        guard let projectId = query["projectId"].flatMap(Int.init),
              blocks[projectId] != nil else { return badRequest("projectId") }

        switch (method, path.count) {
        case ("GET", 0):
            return editionCollection(projectId)

        case ("POST", 0):
            guard let name = (fields["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return badRequest("name")
            }
            let source = fields["copyFromEditionId"] as? Int
            if let source, !editions.contains(where: { $0.id == source && $0.projectId == projectId }) {
                return badRequest("copyFromEditionId")
            }
            let edition = DemoEdition(id: nextEditionId, projectId: projectId, name: name,
                                      isDefault: false, isPublished: false, lastEdited: Date())
            nextEditionId += 1
            editions.append(edition)
            // A new edition starts as a copy of its source, or empty.
            if let source {
                editionBlocks[edition.id] = (editionBlocks[source] ?? []).map { block in
                    var copy = block
                    copy.id = nextBlockId
                    nextBlockId += 1
                    return copy
                }
            } else {
                editionBlocks[edition.id] = []
            }
            return editionCollection(projectId)

        default:
            break
        }

        guard let editionId = path.first.flatMap(Int.init),
              let index = editions.firstIndex(where: { $0.id == editionId && $0.projectId == projectId })
        else { return notFound() }

        switch (method, path.dropFirst().first) {
        case ("PUT", nil):
            guard let name = (fields["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return badRequest("name")
            }
            editions[index].name = name
            return editionCollection(projectId)

        case ("DELETE", nil):
            // A project always keeps somewhere to write.
            guard editions.filter({ $0.projectId == projectId }).count > 1 else {
                return (409, Data(#"{"edition":"That edition cannot be deleted."}"#.utf8))
            }
            let removed = editions.remove(at: index)
            editionBlocks[removed.id] = nil
            // Something has to be the default once the default is gone.
            if removed.isDefault,
               let next = editions.firstIndex(where: { $0.projectId == projectId }) {
                editions[next].isDefault = true
                blocks[projectId] = editionBlocks[editions[next].id] ?? []
            }
            return editionCollection(projectId)

        case ("POST", "set-default"):
            for i in editions.indices where editions[i].projectId == projectId {
                editions[i].isDefault = (editions[i].id == editionId)
            }
            return editionCollection(projectId)

        case ("POST", "set-published"):
            for i in editions.indices where editions[i].projectId == projectId {
                editions[i].isPublished = (editions[i].id == editionId)
            }
            return editionCollection(projectId)

        default:
            return notFound()
        }
    }

    private func editionCollection(_ projectId: Int) -> (Int, Data) {
        let mine = editions.filter { $0.projectId == projectId }
        let items = mine.map { edition -> [String: Any] in
            var links: [String: Any] = [
                "blocks": link("/api/block?projectId=\(projectId)&editionId=\(edition.id)"),
                "editions": link("/api/project/edition?projectId=\(projectId)"),
                "update": link("/api/project/edition/\(edition.id)?projectId=\(projectId)"),
            ]
            // The last edition offers no delete, so the client never shows an
            // action that could only fail.
            if mine.count > 1 {
                links["delete"] = link("/api/project/edition/\(edition.id)?projectId=\(projectId)")
            }
            if !edition.isDefault {
                links["setDefault"] = link("/api/project/edition/\(edition.id)/set-default?projectId=\(projectId)")
            }
            if !edition.isPublished {
                links["setPublished"] = link("/api/project/edition/\(edition.id)/set-published?projectId=\(projectId)")
            }
            return [
                "id": edition.id,
                "name": edition.name,
                "default": edition.isDefault,
                "published": edition.isPublished,
                "lastEdited": iso.string(from: edition.lastEdited),
                "blockCount": (editionBlocks[edition.id] ?? []).count,
                "_links": links,
            ]
        }
        return ok([
            "_embedded": ["scriptEditionResourceList": items],
            "_links": [
                "self": link("/api/project/edition?projectId=\(projectId)"),
                "create": link("/api/project/edition?projectId=\(projectId)"),
                "project": link("/api/project/\(projectId)"),
            ],
        ])
    }

    // MARK: - Song blocks

    /// One lyric line. Keyed by edition, since that is what an edition scopes.
    private struct DemoSongBlock: Codable {
        var id: Int
        var order: Int
        var content: String
        var highlight: String?
    }

    /// Splits a song's seeded text into lines the first time its lyric is
    /// asked for. The demo stores songs as text for the list preview; the real
    /// server has had them as blocks all along.
    private func ensureSongBlocks(_ documentId: Int, editionId: Int) {
        guard songBlocks[editionId] == nil else { return }
        // Archived as readily as listed: the archive opens a song in place, and
        // a song with no lines is not what it was put aside as.
        guard let content = documentContent(documentId) else {
            songBlocks[editionId] = []
            return
        }
        let lines = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        songBlocks[editionId] = lines.enumerated().map { offset, text in
            let block = DemoSongBlock(id: nextSongBlockId, order: offset + 1, content: text)
            nextSongBlockId += 1
            return block
        }
    }

    /// The edition whose lyric a request means: the one named, else the default.
    private func resolveSongEdition(_ documentId: Int, editionId: Int?) -> Int? {
        ensureSongEditions(documentId)
        if let editionId {
            return songEditions.first { $0.id == editionId && $0.documentId == documentId }?.id
        }
        return songEditions.first { $0.documentId == documentId && $0.isDefault }?.id
    }

    private func routeSongBlock(method: String, path: [String],
                                query: [String: String],
                                fields: [String: Any]) -> (Int, Data) {
        // `trash`, `undo`, `redo` and `undo-redo-status` are siblings of the
        // line resources rather than line ids, so they are picked off before
        // the numeric lookup below — the same shape /api/block uses.
        if path.first == "trash" {
            return routeSongBlockTrash(method: method,
                                       path: Array(path.dropFirst()), query: query)
        }
        // Replace All is a sibling too, for the same reason: "bulk" is not a
        // line id. The real server needs a routing test to keep these apart;
        // here the ordering is the whole guarantee.
        if path.first == "bulk", path.dropFirst().first == "replace" {
            guard method == "POST" else { return notFound() }
            guard let documentId = query["documentId"].flatMap(Int.init),
                  documentExists(documentId),
                  let editionId = resolveSongEdition(documentId,
                                                     editionId: query["editionId"].flatMap(Int.init))
            else { return badRequest("documentId") }
            ensureSongBlocks(documentId, editionId: editionId)
            guard let find = fields["find"] as? String, !find.isEmpty else {
                return badRequest("find")
            }
            // One snapshot for the whole sweep, exactly as the server takes one
            // checkpoint — so the demo shows the same single-step Undo.
            snapshotSong(editionId)
            let replacement = fields["replace"] as? String ?? ""
            let matchCase = fields["matchCase"] as? Bool ?? false
            let wholeWord = fields["wholeWord"] as? Bool ?? false
            var list = songBlocks[editionId] ?? []
            for index in list.indices {
                // The screenplay's own helper, deliberately: one idea of what a
                // literal match is, here as on the server.
                list[index].content = Self.literalReplace(
                    in: list[index].content, find: find, with: replacement,
                    matchCase: matchCase, wholeWord: wholeWord)
            }
            songBlocks[editionId] = list
            syncSongText(documentId, editionId: editionId)
            return songBlockCollection(documentId, editionId: editionId)
        }
        if let step = path.first, ["undo", "redo", "undo-redo-status"].contains(step) {
            guard let documentId = query["documentId"].flatMap(Int.init),
                  documentExists(documentId),
                  let editionId = resolveSongEdition(documentId,
                                                     editionId: query["editionId"].flatMap(Int.init))
            else { return badRequest("documentId") }
            ensureSongBlocks(documentId, editionId: editionId)
            if step == "undo-redo-status" {
                guard method == "GET" else { return notFound() }
                return ok(songUndoRedoJSON(documentId: documentId, editionId: editionId))
            }
            guard method == "POST" else { return notFound() }
            return applySongHistory(documentId: documentId,
                                    editionId: editionId, undoing: step == "undo")
        }

        switch (method, path.count) {
        case ("GET", 0), ("POST", 0):
            guard let documentId = query["documentId"].flatMap(Int.init),
                  documentExists(documentId),
                  let editionId = resolveSongEdition(documentId,
                                                     editionId: query["editionId"].flatMap(Int.init))
            else { return badRequest("documentId") }
            ensureSongBlocks(documentId, editionId: editionId)

            if method == "GET" {
                return songBlockCollection(documentId, editionId: editionId)
            }
            snapshotSong(editionId)
            let block = DemoSongBlock(
                id: nextSongBlockId,
                order: (songBlocks[editionId] ?? []).map(\.order).max().map { $0 + 1 } ?? 1,
                content: fields["content"] as? String ?? "")
            nextSongBlockId += 1
            songBlocks[editionId]?.append(block)
            syncSongText(documentId, editionId: editionId)
            return ok(songBlockJSON(block, documentId: documentId, editionId: editionId))
        default:
            break
        }

        guard let id = path.first.flatMap(Int.init),
              let editionId = songBlocks.first(where: { $0.value.contains { $0.id == id } })?.key,
              let index = songBlocks[editionId]?.firstIndex(where: { $0.id == id }),
              let documentId = songEditions.first(where: { $0.id == editionId })?.documentId
        else { return notFound() }

        switch (method, path.dropFirst().first) {
        case ("PUT", nil):
            snapshotSong(editionId)
            songBlocks[editionId]?[index].content = fields["content"] as? String ?? ""
            syncSongText(documentId, editionId: editionId)
            return ok(songBlockJSON(songBlocks[editionId]![index],
                                    documentId: documentId, editionId: editionId))

        case ("DELETE", nil):
            snapshotSong(editionId)
            trashSongBlock(songBlocks[editionId]![index], editionId: editionId)
            songBlocks[editionId]?.remove(at: index)
            renumberSongBlocks(editionId)
            syncSongText(documentId, editionId: editionId)
            return songBlockCollection(documentId, editionId: editionId)

        case ("POST", "below"):
            snapshotSong(editionId)
            var list = songBlocks[editionId] ?? []
            // Order is assigned by renumbering below, from where it lands in
            // the array; anything set here would only be overwritten.
            let block = DemoSongBlock(id: nextSongBlockId,
                                      order: 0,
                                      content: fields["content"] as? String ?? "")
            nextSongBlockId += 1
            list.insert(block, at: index + 1)
            songBlocks[editionId] = list
            renumberSongBlocks(editionId)
            syncSongText(documentId, editionId: editionId)
            return ok(songBlockJSON(block, documentId: documentId, editionId: editionId))

        case ("POST", "move"):
            guard let position = fields["position"] as? Int else { return badRequest("position") }
            snapshotSong(editionId)
            var list = (songBlocks[editionId] ?? []).sorted { $0.order < $1.order }
            let target = min(max(position - 1, 0), list.count - 1)
            let moved = list.remove(at: index)
            list.insert(moved, at: target)
            songBlocks[editionId] = list
            renumberSongBlocks(editionId)
            syncSongText(documentId, editionId: editionId)
            return songBlockCollection(documentId, editionId: editionId)

        case ("POST", "replace"):
            guard let find = fields["find"] as? String, !find.isEmpty else {
                return badRequest("find")
            }
            snapshotSong(editionId)
            songBlocks[editionId]?[index].content = Self.replaceOccurrence(
                in: songBlocks[editionId]![index].content,
                find: find,
                with: fields["replace"] as? String ?? "",
                matchCase: fields["matchCase"] as? Bool ?? false,
                wholeWord: fields["wholeWord"] as? Bool ?? false,
                occurrence: fields["occurrence"] as? Int ?? 0)
            syncSongText(documentId, editionId: editionId)
            return ok(songBlockJSON(songBlocks[editionId]![index],
                                    documentId: documentId, editionId: editionId))

        case ("POST", "highlight"):
            snapshotSong(editionId)
            let known = ["YELLOW", "GREEN", "BLUE", "RED", "GRAY"]
            let raw = (fields["highlight"] as? String)?
                .trimmingCharacters(in: .whitespaces).uppercased()
            // An unknown or blank tint clears, as on the server.
            songBlocks[editionId]?[index].highlight =
                (raw.map { known.contains($0) ? $0 : nil } ?? nil)
            return ok(songBlockJSON(songBlocks[editionId]![index],
                                    documentId: documentId, editionId: editionId))

        default:
            return notFound()
        }
    }

    /// Renumbers from the array's current arrangement, deliberately without
    /// sorting first. After an insert or a move the position in the array is
    /// the truth and the stored `order` values are stale — sorting by them
    /// would put the line straight back where it came from, which is exactly
    /// what the first version of this did.
    private func renumberSongBlocks(_ editionId: Int) {
        guard var list = songBlocks[editionId] else { return }
        for index in list.indices { list[index].order = index + 1 }
        songBlocks[editionId] = list
    }

    /// Keeps the document's text in step with its default edition's lines, so
    /// the songs list preview does not go stale while the lyric is edited.
    private func syncSongText(_ documentId: Int, editionId: Int) {
        guard songEditions.first(where: { $0.id == editionId })?.isDefault == true,
              documentExists(documentId) else { return }
        setDocumentContent(documentId, to: (songBlocks[editionId] ?? [])
            .sorted { $0.order < $1.order }
            .map(\.content)
            .joined(separator: "\n"))
        if let position = songEditions.firstIndex(where: { $0.id == editionId }) {
            songEditions[position].blockCount = (songBlocks[editionId] ?? []).count
            songEditions[position].lastEdited = .now
        }
    }

    private func songBlockCollection(_ documentId: Int, editionId: Int) -> (Int, Data) {
        let items = (songBlocks[editionId] ?? [])
            .sorted { $0.order < $1.order }
            .map { songBlockJSON($0, documentId: documentId, editionId: editionId) }
        return ok([
            "_embedded": ["songBlockResourceList": items],
            "_links": [
                "self": link("/api/song/block?documentId=\(documentId)&editionId=\(editionId)"),
                "create": link("/api/song/block?documentId=\(documentId)&editionId=\(editionId)"),
                "song": link("/api/document/\(documentId)"),
                "versions": link("/api/song/version?documentId=\(documentId)"),
                "trash": link("/api/song/block/trash?documentId=\(documentId)&editionId=\(editionId)"),
                // The version rides in the link, as it does on the server —
                // which is why the client never has to know its edition's id.
                "bulkReplace": link(
                    "/api/song/block/bulk/replace?documentId=\(documentId)&editionId=\(editionId)"),
                "undoRedoStatus": link(
                    "/api/song/block/undo-redo-status?documentId=\(documentId)&editionId=\(editionId)"),
            ],
        ])
    }

    // MARK: - Deleted lines, and stepping back

    /// A deleted lyric line. Like a screenplay element it comes back as a new
    /// line rather than the original id, which is what the server does too.
    private struct DeletedDemoSongBlock: Codable {
        var id: Int
        var block: DemoSongBlock
        var deletedAt: Date
    }

    private func trashSongBlock(_ block: DemoSongBlock, editionId: Int) {
        deletedSongBlocks[editionId, default: []].append(
            DeletedDemoSongBlock(id: nextDeletedSongBlockId, block: block, deletedAt: Date()))
        nextDeletedSongBlockId += 1
    }

    private func routeSongBlockTrash(method: String, path: [String],
                                     query: [String: String]) -> (Int, Data) {
        guard let documentId = query["documentId"].flatMap(Int.init),
              documentExists(documentId),
              let editionId = resolveSongEdition(documentId,
                                                 editionId: query["editionId"].flatMap(Int.init))
        else { return badRequest("documentId") }

        if method == "GET", path.isEmpty {
            return songTrashCollection(documentId, editionId: editionId)
        }

        guard let deletedId = path.first.flatMap(Int.init),
              let index = deletedSongBlocks[editionId]?.firstIndex(where: { $0.id == deletedId })
        else { return notFound() }

        switch (method, path.dropFirst().first) {
        case ("POST", "restore"):
            let record = deletedSongBlocks[editionId]!.remove(at: index)
            snapshotSong(editionId)
            var restored = record.block
            restored.id = nextSongBlockId
            nextSongBlockId += 1
            var list = (songBlocks[editionId] ?? []).sorted { $0.order < $1.order }
            // Back where it was, clamped in case the lyric has since shrunk.
            let target = min(max(restored.order - 1, 0), list.count)
            list.insert(restored, at: target)
            songBlocks[editionId] = list
            renumberSongBlocks(editionId)
            syncSongText(documentId, editionId: editionId)
            return songTrashCollection(documentId, editionId: editionId)

        case ("DELETE", nil):
            deletedSongBlocks[editionId]?.remove(at: index)
            return songTrashCollection(documentId, editionId: editionId)

        default:
            return notFound()
        }
    }

    private func songTrashCollection(_ documentId: Int, editionId: Int) -> (Int, Data) {
        let base = "/api/song/block/trash?documentId=\(documentId)&editionId=\(editionId)"
        let items = (deletedSongBlocks[editionId] ?? [])
            .sorted { $0.deletedAt > $1.deletedAt }
            .map { record -> [String: Any] in
                let content = record.block.content.trimmingCharacters(in: .whitespacesAndNewlines)
                var json: [String: Any] = [
                    "id": record.id,
                    "content": record.block.content,
                    "blank": content.isEmpty,
                    "deletedAt": iso.string(from: record.deletedAt),
                    "purgeAt": iso.string(from: record.deletedAt.addingTimeInterval(
                        Double(Self.trashRetentionDays) * 86_400)),
                    "_links": [
                        "restore": link("/api/song/block/trash/\(record.id)/restore"
                                        + "?documentId=\(documentId)&editionId=\(editionId)"),
                        "purge": link("/api/song/block/trash/\(record.id)"
                                      + "?documentId=\(documentId)&editionId=\(editionId)"),
                        "trash": link(base),
                    ],
                ]
                if let highlight = record.block.highlight { json["highlight"] = highlight }
                return json
            }
        return ok([
            "_embedded": ["deletedSongBlockResourceList": items],
            "_links": [
                "self": link(base),
                "songBlocks": link("/api/song/block?documentId=\(documentId)&editionId=\(editionId)"),
                "song": link("/api/document/\(documentId)"),
            ],
        ])
    }

    private func snapshotSong(_ editionId: Int) {
        songUndoStacks[editionId, default: []].append(songBlocks[editionId] ?? [])
        if songUndoStacks[editionId]!.count > 50 {
            songUndoStacks[editionId]!.removeFirst()
        }
        songRedoStacks[editionId] = []
    }

    private func applySongHistory(documentId: Int, editionId: Int, undoing: Bool) -> (Int, Data) {
        let popped = undoing
            ? songUndoStacks[editionId]?.popLast()
            : songRedoStacks[editionId]?.popLast()
        // An empty stack is not an error on the server either: the lyric comes
        // back unchanged and the status link is where a client learns why.
        if let state = popped {
            let current = songBlocks[editionId] ?? []
            if undoing {
                songRedoStacks[editionId, default: []].append(current)
            } else {
                songUndoStacks[editionId, default: []].append(current)
            }
            // Fresh ids for every line, because that is what the step really
            // does: the server's `replaceLines` deletes the version's lines and
            // re-inserts the snapshot, so not one id the client was holding
            // still exists afterwards. Handing back the old ids would make this
            // the one place a lyric step is gentler here than in the app, and
            // it is exactly the difference that hides a client still aiming at
            // a line the step destroyed.
            songBlocks[editionId] = state.map { line in
                var fresh = line
                fresh.id = nextSongBlockId
                nextSongBlockId += 1
                return fresh
            }
            syncSongText(documentId, editionId: editionId)
        }
        return songBlockCollection(documentId, editionId: editionId)
    }

    private func songUndoRedoJSON(documentId: Int, editionId: Int) -> [String: Any] {
        let canUndo = !(songUndoStacks[editionId] ?? []).isEmpty
        let canRedo = !(songRedoStacks[editionId] ?? []).isEmpty
        let suffix = "documentId=\(documentId)&editionId=\(editionId)"
        var links: [String: Any] = [
            "self": link("/api/song/block/undo-redo-status?" + suffix),
            "songBlocks": link("/api/song/block?" + suffix),
            "song": link("/api/document/\(documentId)"),
        ]
        if canUndo { links["undo"] = link("/api/song/block/undo?" + suffix) }
        if canRedo { links["redo"] = link("/api/song/block/redo?" + suffix) }
        return ["canUndo": canUndo, "canRedo": canRedo, "_links": links]
    }

    private func songBlockJSON(_ block: DemoSongBlock,
                               documentId: Int, editionId: Int) -> [String: Any] {
        var json: [String: Any] = [
            "id": block.id,
            "documentId": documentId,
            "order": block.order,
            "content": block.content,
            "_links": [
                "self": link("/api/song/block/\(block.id)"),
                "update": link("/api/song/block/\(block.id)"),
                "delete": link("/api/song/block/\(block.id)"),
                "createBelow": link("/api/song/block/\(block.id)/below"),
                "move": link("/api/song/block/\(block.id)/move"),
                "replace": link("/api/song/block/\(block.id)/replace"),
                "setHighlight": link("/api/song/block/\(block.id)/highlight"),
                "songBlocks": link("/api/song/block?documentId=\(documentId)&editionId=\(editionId)"),
                "song": link("/api/document/\(documentId)"),
            ],
        ]
        if let highlight = block.highlight { json["highlight"] = highlight }
        return json
    }

    // MARK: - Song editions

    /// A named edition of a song. Songs are lyric blocks on the server, so an
    /// edition scopes those; the demo tracks the count rather than the lines,
    /// since this client edits a song as plain text and never reads its blocks.
    private struct DemoSongEdition: Codable {
        var id: Int
        var documentId: Int
        var name: String
        var isDefault: Bool
        var isPublished: Bool
        var lastEdited: Date
        var blockCount: Int
    }

    /// Every song has at least one edition, created on first sight rather than
    /// up front — the server's ensureDefaultEdition does the same.
    private func ensureSongEditions(_ documentId: Int) {
        guard !songEditions.contains(where: { $0.documentId == documentId }) else { return }
        songEditions.append(DemoSongEdition(
            id: nextSongEditionId, documentId: documentId, name: "Original",
            isDefault: true, isPublished: true, lastEdited: Date(), blockCount: 0))
        nextSongEditionId += 1
    }

    private func routeSongEdition(method: String, path: [String],
                                  query: [String: String],
                                  fields: [String: Any]) -> (Int, Data) {
        guard let documentId = query["documentId"].flatMap(Int.init),
              documentExists(documentId) else { return badRequest("documentId") }
        ensureSongEditions(documentId)

        switch (method, path.count) {
        case ("GET", 0):
            return songEditionCollection(documentId)

        case ("POST", 0):
            guard let name = (fields["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return badRequest("name")
            }
            let source = fields["copyFromEditionId"] as? Int
            if let source,
               !songEditions.contains(where: { $0.id == source && $0.documentId == documentId }) {
                return badRequest("copyFromEditionId")
            }
            let copied = source.flatMap { id in
                songEditions.first { $0.id == id }?.blockCount
            } ?? 0
            songEditions.append(DemoSongEdition(
                id: nextSongEditionId, documentId: documentId, name: name,
                isDefault: false, isPublished: false, lastEdited: Date(), blockCount: copied))
            nextSongEditionId += 1
            return songEditionCollection(documentId)

        default:
            break
        }

        guard let editionId = path.first.flatMap(Int.init),
              let index = songEditions.firstIndex(where: {
                  $0.id == editionId && $0.documentId == documentId
              }) else { return notFound() }

        switch (method, path.dropFirst().first) {
        case ("PUT", nil):
            guard let name = (fields["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return badRequest("name")
            }
            songEditions[index].name = name
            return songEditionCollection(documentId)

        case ("DELETE", nil):
            // A song always keeps somewhere to write.
            guard songEditions.filter({ $0.documentId == documentId }).count > 1 else {
                return (409, Data(#"{"edition":"That edition cannot be deleted."}"#.utf8))
            }
            let removed = songEditions.remove(at: index)
            if removed.isDefault,
               let next = songEditions.firstIndex(where: { $0.documentId == documentId }) {
                songEditions[next].isDefault = true
            }
            return songEditionCollection(documentId)

        case ("POST", "set-default"):
            for i in songEditions.indices where songEditions[i].documentId == documentId {
                songEditions[i].isDefault = (songEditions[i].id == editionId)
            }
            return songEditionCollection(documentId)

        case ("POST", "set-published"):
            for i in songEditions.indices where songEditions[i].documentId == documentId {
                songEditions[i].isPublished = (songEditions[i].id == editionId)
            }
            return songEditionCollection(documentId)

        default:
            return notFound()
        }
    }

    private func songEditionCollection(_ documentId: Int) -> (Int, Data) {
        let mine = songEditions.filter { $0.documentId == documentId }
        let items = mine.map { edition -> [String: Any] in
            var links: [String: Any] = [
                "songBlocks": link("/api/song/block?documentId=\(documentId)&editionId=\(edition.id)"),
                "editions": link("/api/song/edition?documentId=\(documentId)"),
                "update": link("/api/song/edition/\(edition.id)?documentId=\(documentId)"),
            ]
            if mine.count > 1 {
                links["delete"] = link("/api/song/edition/\(edition.id)?documentId=\(documentId)")
            }
            if !edition.isDefault {
                links["setDefault"] = link("/api/song/edition/\(edition.id)/set-default?documentId=\(documentId)")
            }
            if !edition.isPublished {
                links["setPublished"] = link("/api/song/edition/\(edition.id)/set-published?documentId=\(documentId)")
            }
            return [
                "id": edition.id,
                "name": edition.name,
                "default": edition.isDefault,
                "published": edition.isPublished,
                "lastEdited": iso.string(from: edition.lastEdited),
                "blockCount": edition.blockCount,
                "_links": links,
            ]
        }
        return ok([
            "_embedded": ["songEditionResourceList": items],
            "_links": [
                "self": link("/api/song/edition?documentId=\(documentId)"),
                "create": link("/api/song/edition?documentId=\(documentId)"),
                "document": link("/api/document/\(documentId)"),
            ],
        ])
    }

    // MARK: - Trash

    /// A deleted screenplay, kept whole so a restore returns everything.
    private struct TrashedDemoProject: Codable {
        var project: DemoProject
        var deletedAt: Date
        var blocks: [DemoBlock]
        var people: [DemoPerson]
        var documents: [DemoDocument]
    }

    /// A deleted element. Restoring makes a *new* element at the old position —
    /// the original id does not come back, matching the server.
    private struct DeletedDemoBlock: Codable {
        var id: Int
        var block: DemoBlock
        var deletedAt: Date
    }

    /// A deleted song or note. Unlike an element, it keeps its id: the server
    /// restores the document itself rather than re-creating it.
    private struct DeletedDemoDocument: Codable {
        var document: DemoDocument
        var deletedAt: Date
    }

    private func routeDocumentTrash(method: String, path: [String],
                                    query: [String: String]) -> (Int, Data) {
        guard let projectId = query["projectId"].flatMap(Int.init),
              documents[projectId] != nil else { return badRequest("projectId") }

        if method == "GET", path.isEmpty {
            return documentTrashCollection(projectId)
        }

        guard let documentId = path.first.flatMap(Int.init),
              let index = deletedDocuments[projectId]?.firstIndex(where: {
                  $0.document.id == documentId
              }) else { return notFound() }

        switch (method, path.dropFirst().first) {
        case ("POST", "restore"):
            let record = deletedDocuments[projectId]!.remove(at: index)
            documents[projectId]?.append(record.document)
            documents[projectId]?.sort { $0.sortOrder < $1.sortOrder }
            return documentTrashCollection(projectId)

        case ("DELETE", nil):
            deletedDocuments[projectId]?.remove(at: index)
            return documentTrashCollection(projectId)

        default:
            return notFound()
        }
    }

    /// An archived song or note. Keeps its id and everything else: the archive
    /// is a place the document sits, not a copy of it.
    private struct ArchivedDemoDocument: Codable {
        var document: DemoDocument
        var archivedAt: Date
    }

    private func routeDocumentArchive(method: String, path: [String],
                                      query: [String: String],
                                      fields: [String: Any]) -> (Int, Data) {
        guard let projectId = query["projectId"].flatMap(Int.init),
              documents[projectId] != nil else { return badRequest("projectId") }

        if method == "GET", path.isEmpty {
            return documentArchiveCollection(projectId)
        }

        // `/bulk/unarchive` is a sibling of the archived documents, not one of
        // their ids, so it is picked off before the numeric lookup — the way
        // `/bulk/archive` is on the document list.
        if method == "POST", path.first == "bulk", path.dropFirst().first == "unarchive" {
            return bulkUnarchiveDocuments(projectId: projectId, fields: fields)
        }

        guard let documentId = path.first.flatMap(Int.init),
              let index = archivedDocuments[projectId]?.firstIndex(where: {
                  $0.document.id == documentId
              }) else { return notFound() }

        switch (method, path.dropFirst().first) {
        case ("POST", "unarchive"):
            let record = archivedDocuments[projectId]!.remove(at: index)
            documents[projectId]?.append(record.document)
            documents[projectId]?.sort { $0.sortOrder < $1.sortOrder }
            return documentArchiveCollection(projectId)

        default:
            // No purge: nothing is ever destroyed from the archive. Deleting an
            // archived document goes through the ordinary DELETE on the
            // document itself, which lands it in the trash.
            return notFound()
        }
    }

    /// Opening or deleting a document that is in the archive rather than the
    /// list. Deleting sends it to the trash like any other, so it stays
    /// recoverable — the archive is not a second bin.
    private func routeArchivedDocument(method: String, path: [String], id: Int) -> (Int, Data) {
        guard let projectId = archivedDocuments.first(where: { _, records in
                  records.contains { $0.document.id == id }
              })?.key,
              let index = archivedDocuments[projectId]?.firstIndex(where: {
                  $0.document.id == id
              }) else { return notFound() }

        switch (method, path.dropFirst().first) {
        case ("GET", nil):
            return ok(documentJSON(archivedDocuments[projectId]![index].document,
                                   includeContent: true,
                                   archivedAt: archivedDocuments[projectId]![index].archivedAt))
        case ("DELETE", nil):
            let record = archivedDocuments[projectId]!.remove(at: index)
            deletedDocuments[projectId, default: []].append(
                DeletedDemoDocument(document: record.document, deletedAt: Date()))
            return ok([:])
        default:
            return notFound()
        }
    }

    /// Bring a ticked set back into the list. Ids that are not in this archive
    /// are skipped rather than refused, so a selection that went stale while
    /// the sheet was open still does what it can — and the reply is the
    /// refreshed *archive*, not the list, because the archive is what the
    /// caller is looking at and what just shrank.
    private func bulkUnarchiveDocuments(projectId: Int, fields: [String: Any]) -> (Int, Data) {
        let ids = (fields["ids"] as? [Any])?.compactMap { $0 as? Int } ?? []
        guard !ids.isEmpty else { return badRequest("ids") }
        var restored = 0
        for id in Set(ids) {
            guard let index = archivedDocuments[projectId]?.firstIndex(where: {
                $0.document.id == id
            }) else { continue }
            let record = archivedDocuments[projectId]!.remove(at: index)
            documents[projectId]?.append(record.document)
            restored += 1
        }
        guard restored > 0 else { return badRequest("ids") }
        documents[projectId]?.sort { $0.sortOrder < $1.sortOrder }
        return documentArchiveCollection(projectId)
    }

    private func documentArchiveCollection(_ projectId: Int) -> (Int, Data) {
        let items = (archivedDocuments[projectId] ?? [])
            .sorted { $0.archivedAt > $1.archivedAt }
            .map { record -> [String: Any] in
                let id = record.document.id
                var json: [String: Any] = [
                    "id": id,
                    "title": record.document.title,
                    "documentType": record.document.documentType,
                    "documentTypeLabel": record.document.documentType == "SONG" ? "Song" : "Notes",
                    "archivedAt": iso.string(from: record.archivedAt),
                    // No purge date, and no purge link: the absence is the whole
                    // difference from the trash beside it.
                    "_links": [
                        "unarchive": link("/api/document/archive/\(id)/unarchive?projectId=\(projectId)"),
                        "document": link("/api/document/\(id)"),
                        "delete": link("/api/document/\(id)"),
                        "archived": link("/api/document/archive?projectId=\(projectId)"),
                    ],
                ]
                let preview = record.document.content
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !preview.isEmpty { json["preview"] = String(preview.prefix(120)) }
                return json
            }
        var links: [String: Any] = [
            "self": link("/api/document/archive?projectId=\(projectId)"),
            "documents": link("/api/document?projectId=\(projectId)"),
            "project": link("/api/project/\(projectId)"),
        ]
        // Unlike the archive itself, which is advertised empty so a client has
        // somewhere to send the first document, this is worth offering only
        // when there is something in here to tick.
        if !items.isEmpty {
            links["bulkUnarchive"] = link("/api/document/archive/bulk/unarchive?projectId=\(projectId)")
        }
        return ok([
            "_embedded": ["archivedDocumentResourceList": items],
            "_links": links,
        ])
    }

    private func documentTrashCollection(_ projectId: Int) -> (Int, Data) {
        let items = (deletedDocuments[projectId] ?? [])
            .sorted { $0.deletedAt > $1.deletedAt }
            .map { record -> [String: Any] in
                let id = record.document.id
                var json: [String: Any] = [
                    "id": id,
                    "title": record.document.title,
                    "documentType": record.document.documentType,
                    "documentTypeLabel": record.document.documentType == "SONG" ? "Song" : "Note",
                    "deletedAt": iso.string(from: record.deletedAt),
                    "purgesAt": iso.string(from: record.deletedAt.addingTimeInterval(
                        Double(Self.trashRetentionDays) * 86_400)),
                    "_links": [
                        "restore": link("/api/document/trash/\(id)/restore?projectId=\(projectId)"),
                        "purge": link("/api/document/trash/\(id)?projectId=\(projectId)"),
                        "trash": link("/api/document/trash?projectId=\(projectId)"),
                    ],
                ]
                let preview = record.document.content
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !preview.isEmpty { json["preview"] = String(preview.prefix(120)) }
                return json
            }
        return ok([
            "_embedded": ["deletedDocumentResourceList": items],
            "_links": [
                "self": link("/api/document/trash?projectId=\(projectId)"),
                "documents": link("/api/document?projectId=\(projectId)"),
                "project": link("/api/project/\(projectId)"),
            ],
        ])
    }

    /// Elements are recoverable for thirty days, as on the server.
    private static let trashRetentionDays = 30

    private func trashBlock(_ block: DemoBlock, projectId: Int) {
        deletedBlocks[projectId, default: []].append(
            DeletedDemoBlock(id: nextDeletedBlockId, block: block, deletedAt: Date()))
        nextDeletedBlockId += 1
    }

    private func routeBlockTrash(method: String, path: [String],
                                 query: [String: String]) -> (Int, Data) {
        guard let projectId = query["projectId"].flatMap(Int.init),
              blocks[projectId] != nil else { return badRequest("projectId") }

        if method == "GET", path.isEmpty {
            return blockTrashCollection(projectId)
        }

        guard let deletedId = path.first.flatMap(Int.init),
              let index = deletedBlocks[projectId]?.firstIndex(where: { $0.id == deletedId })
        else { return notFound() }

        switch (method, path.dropFirst().first) {
        case ("POST", "restore"):
            let record = deletedBlocks[projectId]!.remove(at: index)
            snapshot(projectId)
            var restored = record.block
            restored.id = nextBlockId
            nextBlockId += 1
            var list = blocks[projectId] ?? []
            // Back at the position it held, clamped in case the script shrank.
            let target = min(max(restored.order - 1, 0), list.count)
            list.insert(restored, at: target)
            for i in list.indices { list[i].order = i + 1 }
            blocks[projectId] = list
            touch(projectId)
            return blockTrashCollection(projectId)

        case ("DELETE", nil):
            deletedBlocks[projectId]?.remove(at: index)
            return blockTrashCollection(projectId)

        default:
            return notFound()
        }
    }

    private func blockTrashCollection(_ projectId: Int) -> (Int, Data) {
        let items = (deletedBlocks[projectId] ?? [])
            .sorted { $0.deletedAt > $1.deletedAt }
            .map { record -> [String: Any] in
                let content = record.block.content.trimmingCharacters(in: .whitespacesAndNewlines)
                var json: [String: Any] = [
                    "id": record.id,
                    "empty": content.isEmpty,
                    "typeLabel": record.block.type.capitalized,
                    "deletedAt": iso.string(from: record.deletedAt),
                    "purgeAt": iso.string(from: record.deletedAt.addingTimeInterval(
                        Double(Self.trashRetentionDays) * 86_400)),
                    "deletedByName": "You",
                    "_links": [
                        "restore": link("/api/block/trash/\(record.id)/restore?projectId=\(projectId)"),
                        "purge": link("/api/block/trash/\(record.id)?projectId=\(projectId)"),
                        "trash": link("/api/block/trash?projectId=\(projectId)"),
                    ],
                ]
                if !content.isEmpty { json["preview"] = String(content.prefix(120)) }
                return json
            }
        return ok([
            "_embedded": ["deletedBlockResourceList": items],
            "_links": [
                "self": link("/api/block/trash?projectId=\(projectId)"),
                "blocks": link("/api/block?projectId=\(projectId)"),
                "project": link("/api/project/\(projectId)"),
            ],
        ])
    }

    private func routeProjectTrash(method: String, path: [String]) -> (Int, Data) {
        if path.isEmpty {
            switch method {
            case "GET":
                return projectTrashCollection()
            case "DELETE":
                trashedProjects.removeAll()
                return projectTrashCollection()
            default:
                return notFound()
            }
        }

        guard let projectId = path.first.flatMap(Int.init),
              let index = trashedProjects.firstIndex(where: { $0.project.id == projectId })
        else { return notFound() }

        switch (method, path.dropFirst().first) {
        case ("POST", "restore"):
            var record = trashedProjects.remove(at: index)
            // Something archived and then deleted comes back where the person
            // looking for it is looking, not into the archive.
            record.project.archivedAt = nil
            projects.append(record.project)
            projects.sort { $0.id < $1.id }
            blocks[record.project.id] = record.blocks
            people[record.project.id] = record.people
            documents[record.project.id] = record.documents
            return projectTrashCollection()

        case ("DELETE", nil):
            trashedProjects.remove(at: index)
            return projectTrashCollection()

        default:
            return notFound()
        }
    }

    private func projectTrashCollection() -> (Int, Data) {
        let items = trashedProjects
            .sorted { $0.deletedAt > $1.deletedAt }
            .map { record -> [String: Any] in
                [
                    "id": record.project.id,
                    "title": record.project.title,
                    "deletedAt": iso.string(from: record.deletedAt),
                    "_links": [
                        "restore": link("/api/project/trash/\(record.project.id)/restore"),
                        "purge": link("/api/project/trash/\(record.project.id)"),
                        "trash": link("/api/project/trash"),
                    ],
                ]
            }
        var links: [String: Any] = [
            "self": link("/api/project/trash"),
            "projects": link("/api/project"),
        ]
        if !items.isEmpty {
            links["emptyTrash"] = link("/api/project/trash")
        }
        return ok(["_embedded": ["trashedProjectResourceList": items], "_links": links])
    }

    private func projectCollection() -> (Int, Data) {
        var links: [String: Any] = [
            "self": link("/api/project"),
            "importProject": link("/api/project/import"),
            "trash": link("/api/project/trash"),
            // Advertised even when the archive is empty, since a list can be
            // empty precisely because everything in it was archived.
            "archived": link("/api/project/archive"),
        ]
        let listed = projects.filter { $0.archivedAt == nil }
        // Nothing to bundle from an empty list, so the rel goes away with the
        // last project — the same rule the server applies.
        if !listed.isEmpty {
            links["exportProjects"] = link("/api/project/export-projects")
        }
        return ok(["_embedded": ["projectResourceList": listed.map(projectJSON)],
                   "_links": links])
    }

    /// The screenplay archive. No purge, no "empty", nothing on a clock — the
    /// absent rels are the distinction from the trash, not a flag.
    private func routeProjectArchive(method: String, path: [String],
                                     fields: [String: Any]) -> (Int, Data) {
        if path.isEmpty {
            return method == "GET" ? projectArchiveCollection() : notFound()
        }
        // A sibling of the archived screenplays, not one of their ids.
        if method == "POST", path.first == "bulk", path.dropFirst().first == "unarchive" {
            return bulkUnarchiveProjects(fields: fields)
        }
        guard let projectId = path.first.flatMap(Int.init),
              let index = projects.firstIndex(where: { $0.id == projectId && $0.archivedAt != nil })
        else { return notFound() }

        switch (method, path.dropFirst().first) {
        case ("POST", "unarchive"):
            projects[index].archivedAt = nil
            return projectArchiveCollection()
        default:
            return notFound()
        }
    }

    /// Bring a ticked set of screenplays back. Ids not in the archive are
    /// skipped, and the reply is the refreshed archive — the collection the
    /// caller is looking at, and the one that shrank.
    private func bulkUnarchiveProjects(fields: [String: Any]) -> (Int, Data) {
        let ids = (fields["ids"] as? [Any])?.compactMap { $0 as? Int } ?? []
        guard !ids.isEmpty else { return badRequest("ids") }
        var restored = 0
        for id in Set(ids) {
            guard let index = projects.firstIndex(where: {
                $0.id == id && $0.archivedAt != nil
            }) else { continue }
            projects[index].archivedAt = nil
            restored += 1
        }
        guard restored > 0 else { return badRequest("ids") }
        return projectArchiveCollection()
    }

    private func projectArchiveCollection() -> (Int, Data) {
        let items = projects
            .filter { $0.archivedAt != nil }
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
            .map { project -> [String: Any] in
                [
                    "id": project.id,
                    "title": project.title,
                    "lastEdited": iso.string(from: project.lastEdited),
                    "archivedAt": iso.string(from: project.archivedAt ?? .now),
                    "teams": project.teamIds.compactMap { id in
                        teamsStore.first(where: { $0.id == id })?.name
                    },
                    "_links": [
                        "unarchive": link("/api/project/archive/\(project.id)/unarchive"),
                        // Still openable in place — the whole point of putting
                        // something aside rather than binning it.
                        "project": link("/api/project/\(project.id)"),
                        // The ordinary soft delete, so it lands in the trash.
                        "delete": link("/api/project/\(project.id)"),
                        "archived": link("/api/project/archive"),
                    ],
                ]
            }
        var links: [String: Any] = ["self": link("/api/project/archive"),
                                    "projects": link("/api/project")]
        // Only worth offering when there is something here to tick.
        if !items.isEmpty {
            links["bulkUnarchive"] = link("/api/project/archive/bulk/unarchive")
        }
        return ok(["_embedded": ["archivedProjectResourceList": items],
                   "_links": links])
    }

    // MARK: - Version history

    /// A saved snapshot. Holds the blocks themselves, so restoring is just
    /// putting them back.
    private struct DemoVersion: Codable {
        var id: Int
        var label: String?
        var createdAt: Date
        var autoSave: Bool
        var blocks: [DemoBlock]
        var sceneCount: Int
        var blockCount: Int
    }

    private func routeVersion(method: String, path: [String],
                              query: [String: String],
                              fields: [String: Any]) -> (Int, Data) {
        switch (method, path.count) {
        case ("GET", 0):
            guard let projectId = query["projectId"].flatMap(Int.init),
                  blocks[projectId] != nil else { return badRequest("projectId") }
            return versionCollection(projectId)

        case ("POST", 0):
            guard let projectId = query["projectId"].flatMap(Int.init),
                  blocks[projectId] != nil else { return badRequest("projectId") }
            let label = (fields["label"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let version = recordVersion(projectId,
                                        label: (label?.isEmpty ?? true) ? "Version" : label,
                                        autoSave: false)
            return ok(versionJSON(version, projectId: projectId))

        default:
            break
        }

        guard let versionId = path.first.flatMap(Int.init),
              let projectId = query["projectId"].flatMap(Int.init),
              let index = versions[projectId]?.firstIndex(where: { $0.id == versionId })
        else { return notFound() }

        switch (method, path.dropFirst().first) {
        case ("GET", nil):
            return ok(versionJSON(versions[projectId]![index], projectId: projectId))

        case ("POST", "restore"):
            // Restoring snapshots the current state first, so nothing is lost
            // by rolling back — the same promise the server makes.
            _ = recordVersion(projectId, label: "Before restore", autoSave: true)
            blocks[projectId] = versions[projectId]![index].blocks
            snapshot(projectId)
            touch(projectId)
            return versionCollection(projectId)

        case ("DELETE", nil):
            versions[projectId]?.remove(at: index)
            return versionCollection(projectId)

        default:
            return notFound()
        }
    }

    @discardableResult
    private func recordVersion(_ projectId: Int, label: String?, autoSave: Bool) -> DemoVersion {
        let current = blocks[projectId] ?? []
        let version = DemoVersion(
            id: nextVersionId,
            label: label,
            createdAt: Date(),
            autoSave: autoSave,
            blocks: current,
            sceneCount: current.filter { $0.type == "SCENE" }.count,
            blockCount: current.count)
        nextVersionId += 1
        versions[projectId, default: []].append(version)
        return version
    }

    private func versionCollection(_ projectId: Int) -> (Int, Data) {
        let items = (versions[projectId] ?? [])
            .sorted { $0.createdAt > $1.createdAt }
            .map { versionJSON($0, projectId: projectId) }
        return ok([
            "_embedded": ["projectVersionResourceList": items],
            "_links": [
                "self": link("/api/project/version?projectId=\(projectId)"),
                "create": link("/api/project/version?projectId=\(projectId)"),
                "project": link("/api/project/\(projectId)"),
            ],
        ])
    }

    private func versionJSON(_ version: DemoVersion, projectId: Int) -> [String: Any] {
        var json: [String: Any] = [
            "id": version.id,
            "createdAt": iso.string(from: version.createdAt),
            "autoSave": version.autoSave,
            "sceneCount": version.sceneCount,
            "blockCount": version.blockCount,
            "characterCount": (people[projectId] ?? []).count,
            "_links": [
                "self": link("/api/project/version/\(version.id)?projectId=\(projectId)"),
                "versions": link("/api/project/version?projectId=\(projectId)"),
                "restore": link("/api/project/version/\(version.id)/restore?projectId=\(projectId)"),
                "delete": link("/api/project/version/\(version.id)?projectId=\(projectId)"),
                "project": link("/api/project/\(projectId)"),
            ],
        ]
        if let label = version.label { json["label"] = label }
        return json
    }

    // MARK: - Song recordings

    /// A recording kept with a song, described. What it sounds like is not in
    /// here — see `songAudioData`.
    private struct DemoSongAudio: Codable {
        var id: Int
        var documentId: Int
        var title: String
        var fileName: String
        var contentType: String
        var byteSize: Int
        var durationMs: Int?
        var sortOrder: Int
        var createdAt: Date
    }

    /// Descriptions, per song. Persisted with the rest of the workspace.
    private var songAudio: [Int: [DemoSongAudio]] = [:]
    private var nextSongAudioId = 1

    /// The bytes, by recording id.
    ///
    /// Deliberately *not* in the workspace snapshot. That file is one JSON
    /// document rewritten after every change, and a signed-out writer with four
    /// takes on a song would have the whole of them re-encoded to base64 and
    /// written to disk on every keystroke that touched anything. They go to
    /// files of their own instead, beside the workspace, and are read back the
    /// first time a take is played rather than at launch.
    private var songAudioData: [Int: Data] = [:]

    private func routeSongAudio(method: String, path: [String],
                                query: [String: String],
                                fields: [String: Any],
                                body: Data?) -> (Int, Data) {
        guard let documentId = query["documentId"].flatMap(Int.init) else {
            return badRequest("documentId")
        }
        switch (method, path.count) {
        case ("GET", 0):
            return ok(songAudioCollection(documentId))
        case ("POST", 0):
            return storeSongAudio(documentId, body: body)
        default:
            break
        }

        guard let audioId = path.first.flatMap(Int.init),
              let index = songAudio[documentId]?.firstIndex(where: { $0.id == audioId })
        else { return notFound() }

        switch (method, path.dropFirst().first) {
        case ("GET", nil):
            return ok(songAudioJSON(songAudio[documentId]![index]))
        case ("GET", "file"):
            // The one route in this backend that answers with something other
            // than JSON — the same thing the real one does, so the client's
            // player is handed a file either way.
            guard let data = songAudioBytes(audioId) else { return notFound() }
            return (200, data)
        case ("PUT", nil):
            let title = (fields["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return badRequest("title") }
            songAudio[documentId]![index].title = String(title.prefix(200))
            return ok(songAudioJSON(songAudio[documentId]![index]))
        case ("DELETE", nil):
            songAudio[documentId]?.remove(at: index)
            songAudioData[audioId] = nil
            store?.deleteMedia(named: Self.mediaName(audioId))
            return ok(songAudioCollection(documentId))
        default:
            return notFound()
        }
    }

    /// Adds a recording, refusing the same two things the server refuses: a
    /// document that is not a song, and a file that is not audio.
    private func storeSongAudio(_ documentId: Int, body: Data?) -> (Int, Data) {
        guard documentType(documentId) == "SONG" else {
            return (400, (try? JSONSerialization.data(
                withJSONObject: ["file": "Only songs can hold recordings."])) ?? Data("{}".utf8))
        }
        guard let parsed = parseMultipart(body),
              let fileName = parsed.fileName,
              let data = parsed.fileData, !data.isEmpty else {
            return badRequest("file")
        }
        guard let contentType = Self.audioContentType(for: fileName) else {
            return (400, (try? JSONSerialization.data(withJSONObject: [
                "file": "That file is not audio. Add an MP3, M4A, WAV, AIFF, FLAC or OGG recording."
            ])) ?? Data("{}".utf8))
        }

        let title = (parsed.fields["title"]?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? (fileName as NSString).deletingPathExtension
        let audio = DemoSongAudio(
            id: nextSongAudioId,
            documentId: documentId,
            title: String(title.prefix(200)),
            fileName: fileName,
            contentType: contentType,
            byteSize: data.count,
            durationMs: parsed.fields["durationMs"].flatMap(Int.init),
            sortOrder: songAudio[documentId]?.count ?? 0,
            createdAt: .now)
        nextSongAudioId += 1
        songAudio[documentId, default: []].append(audio)
        songAudioData[audio.id] = data
        store?.saveMedia(data, named: Self.mediaName(audio.id))
        return (201, (try? JSONSerialization.data(withJSONObject: songAudioJSON(audio)))
                ?? Data("{}".utf8))
    }

    /// The bytes of a take, from memory or — after a relaunch — from the file
    /// they were written to.
    private func songAudioBytes(_ audioId: Int) -> Data? {
        if let held = songAudioData[audioId] { return held }
        guard let loaded = store?.loadMedia(named: Self.mediaName(audioId)) else { return nil }
        songAudioData[audioId] = loaded
        return loaded
    }

    private func songAudioCollection(_ documentId: Int) -> [String: Any] {
        let recordings = (songAudio[documentId] ?? []).sorted {
            ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id)
        }
        return [
            "_embedded": ["audioRecordings": recordings.map { songAudioJSON($0) }],
            "_links": [
                "self": link("/api/song/audio?documentId=\(documentId)"),
                "uploadAudio": link("/api/song/audio?documentId=\(documentId)"),
                "song": link("/api/document/\(documentId)"),
                "songBlocks": link("/api/song/block?documentId=\(documentId)"),
            ],
        ]
    }

    private func songAudioJSON(_ audio: DemoSongAudio) -> [String: Any] {
        let suffix = "?documentId=\(audio.documentId)"
        var json: [String: Any] = [
            "id": audio.id,
            "documentId": audio.documentId,
            "title": audio.title,
            "fileName": audio.fileName,
            "contentType": audio.contentType,
            "byteSize": audio.byteSize,
            "sortOrder": audio.sortOrder,
            "createdAt": iso.string(from: audio.createdAt),
            "_links": [
                "self": link("/api/song/audio/\(audio.id)\(suffix)"),
                "audioFile": link("/api/song/audio/\(audio.id)/file\(suffix)"),
                "audioRecordings": link("/api/song/audio\(suffix)"),
                "song": link("/api/document/\(audio.documentId)"),
                "renameAudio": link("/api/song/audio/\(audio.id)\(suffix)"),
                "deleteAudio": link("/api/song/audio/\(audio.id)\(suffix)"),
            ],
        ]
        if let durationMs = audio.durationMs {
            json["durationMs"] = durationMs
        }
        return json
    }

    private static func mediaName(_ audioId: Int) -> String {
        "song-audio-\(audioId)"
    }

    /// What kind of document this is, wherever it is being kept — an archived
    /// song still holds its recordings, as it holds its lyrics.
    private func documentType(_ id: Int) -> String? {
        switch siteOfDocument(id) {
        case let .live(projectId, index): return documents[projectId]?[index].documentType
        case let .archived(projectId, index):
            return archivedDocuments[projectId]?[index].document.documentType
        case nil: return nil
        }
    }

    /// What to serve a file back as, read from its extension. Shorter than the
    /// server's table on purpose: this one only has to recognise what a picker
    /// on this device can hand over.
    private static func audioContentType(for fileName: String) -> String? {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "mp3": return "audio/mpeg"
        case "m4a", "mp4": return "audio/mp4"
        case "aac": return "audio/aac"
        case "wav": return "audio/wav"
        case "aif", "aiff": return "audio/aiff"
        case "flac": return "audio/flac"
        case "ogg", "oga": return "audio/ogg"
        case "opus": return "audio/opus"
        case "webm": return "audio/webm"
        case "caf": return "audio/x-caf"
        default: return nil
        }
    }

    // MARK: - Song versions

    /// A song's snapshot history, kept per document. Mirrors the project one but
    /// counts lyric lines instead of scenes, which is what the shared history
    /// view shows for a song.
    private struct DemoSongVersion: Codable {
        var id: Int
        var label: String?
        var title: String
        var createdAt: Date
        var autoSave: Bool
        var lines: [DemoSongBlock]
    }

    private var songVersions: [Int: [DemoSongVersion]] = [:]

    private func routeSongVersion(method: String, path: [String],
                                  query: [String: String],
                                  fields: [String: Any]) -> (Int, Data) {
        guard let documentId = query["documentId"].flatMap(Int.init) else {
            return badRequest("documentId")
        }
        switch (method, path.count) {
        case ("GET", 0):
            return songVersionCollection(documentId)
        case ("POST", 0):
            let label = (fields["label"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            recordSongVersion(documentId,
                              label: (label?.isEmpty ?? true) ? "Version" : label,
                              autoSave: false)
            return songVersionCollection(documentId)
        default:
            break
        }

        guard let versionId = path.first.flatMap(Int.init),
              let index = songVersions[documentId]?.firstIndex(where: { $0.id == versionId })
        else { return notFound() }

        switch (method, path.dropFirst().first) {
        case ("POST", "restore"):
            recordSongVersion(documentId, label: "Before restore", autoSave: true)
            if let editionId = defaultSongEditionId(for: documentId) {
                songBlocks[editionId] = songVersions[documentId]![index].lines
            }
            return songVersionCollection(documentId)
        case ("DELETE", nil):
            songVersions[documentId]?.remove(at: index)
            return songVersionCollection(documentId)
        default:
            return notFound()
        }
    }

    /// The edition whose lines a song version snapshots — the default one, which
    /// is what a single-edition song always resolves to.
    private func defaultSongEditionId(for documentId: Int) -> Int? {
        songEditions.first { $0.documentId == documentId }?.id
    }

    private func recordSongVersion(_ documentId: Int, label: String?, autoSave: Bool) {
        let lines = defaultSongEditionId(for: documentId).flatMap { songBlocks[$0] } ?? []
        let title = documents.values.flatMap { $0 }
            .first { $0.id == documentId }?.title ?? "Song"
        let version = DemoSongVersion(
            id: nextVersionId, label: label, title: title,
            createdAt: Date(), autoSave: autoSave, lines: lines)
        nextVersionId += 1
        songVersions[documentId, default: []].append(version)
    }

    private func songVersionCollection(_ documentId: Int) -> (Int, Data) {
        let items = (songVersions[documentId] ?? [])
            .sorted { $0.createdAt > $1.createdAt }
            .map { songVersionJSON($0, documentId: documentId) }
        return ok([
            "_embedded": ["songVersionResourceList": items],
            "_links": [
                "self": link("/api/song/version?documentId=\(documentId)"),
                "create": link("/api/song/version?documentId=\(documentId)"),
                "song": link("/api/document/\(documentId)"),
            ],
        ])
    }

    private func songVersionJSON(_ version: DemoSongVersion, documentId: Int) -> [String: Any] {
        var json: [String: Any] = [
            "id": version.id,
            "title": version.title,
            "createdAt": iso.string(from: version.createdAt),
            "autoSave": version.autoSave,
            "lineCount": version.lines.count,
            "_links": [
                "self": link("/api/song/version/\(version.id)?documentId=\(documentId)"),
                "versions": link("/api/song/version?documentId=\(documentId)"),
                "restore": link("/api/song/version/\(version.id)/restore?documentId=\(documentId)"),
                "delete": link("/api/song/version/\(version.id)?documentId=\(documentId)"),
                "song": link("/api/document/\(documentId)"),
            ],
        ]
        if let label = version.label { json["label"] = label }
        return json
    }

    private func snapshot(_ projectId: Int) {
        undoStacks[projectId, default: []].append(blocks[projectId] ?? [])
        if undoStacks[projectId]!.count > 50 {
            undoStacks[projectId]!.removeFirst()
        }
        redoStacks[projectId] = []
    }

    private func applyHistory(projectId: Int, undoing: Bool) -> (Int, Data) {
        let popped = undoing
            ? undoStacks[projectId]?.popLast()
            : redoStacks[projectId]?.popLast()
        guard let state = popped else {
            return ok(undoRedoJSON(projectId: projectId, success: false))
        }
        let current = blocks[projectId] ?? []
        if undoing {
            redoStacks[projectId, default: []].append(current)
        } else {
            undoStacks[projectId, default: []].append(current)
        }
        blocks[projectId] = state
        touch(projectId)
        return ok(undoRedoJSON(projectId: projectId, success: true))
    }

    private func undoRedoJSON(projectId: Int, success: Bool?) -> [String: Any] {
        let canUndo = !(undoStacks[projectId] ?? []).isEmpty
        let canRedo = !(redoStacks[projectId] ?? []).isEmpty
        var links: [String: Any] = ["self": link("/api/project/\(projectId)/undo-redo-status")]
        if canUndo { links["undo"] = link("/api/project/\(projectId)/undo") }
        if canRedo { links["redo"] = link("/api/project/\(projectId)/redo") }
        var json: [String: Any] = ["canUndo": canUndo, "canRedo": canRedo, "_links": links]
        if let success { json["success"] = success }
        return json
    }

    // MARK: - Resource JSON

    // MARK: - Teams

    private struct DemoTeam: Codable {
        var id: Int
        var name: String
    }

    /// Seeded with the team every demo project already shows a badge for, so the
    /// list is not empty on first open.
    private lazy var teamsStore: [DemoTeam] = [DemoTeam(id: 1, name: "Demo")]
    private lazy var nextTeamId = 2

    private func routeTeam(method: String, path: [String],
                           query: [String: String],
                           fields: [String: Any]) -> (Int, Data) {
        switch (method, path.count) {
        case ("GET", 0):
            return teamCollection()
        case ("POST", 0):
            guard let name = (fields["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return badRequest("name")
            }
            let team = DemoTeam(id: nextTeamId, name: name)
            nextTeamId += 1
            teamsStore.append(team)
            return ok(teamJSON(team))
        default:
            break
        }

        guard let id = path.first.flatMap(Int.init),
              let index = teamsStore.firstIndex(where: { $0.id == id }) else { return notFound() }

        switch (method, path.dropFirst().first) {
        case ("GET", nil):
            return ok(teamJSON(teamsStore[index]))
        case ("PUT", nil):
            guard let name = (fields["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return badRequest("name")
            }
            teamsStore[index].name = name
            return ok(teamJSON(teamsStore[index]))
        case ("PUT", "productions"):
            // The demo does not re-badge its projects, so this just acknowledges
            // the assignment; the point offline is that the flow completes.
            return ok(teamJSON(teamsStore[index]))
        case ("DELETE", nil):
            let removed = teamsStore.remove(at: index)
            return ok(teamJSON(removed))
        default:
            return notFound()
        }
    }

    private func teamCollection() -> (Int, Data) {
        let items = teamsStore
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { teamJSON($0) }
        return ok([
            "_embedded": ["teamResourceList": items],
            "_links": ["self": link("/api/team")],
        ])
    }

    private func teamJSON(_ team: DemoTeam) -> [String: Any] {
        [
            "id": team.id,
            "name": team.name,
            "_links": [
                "self": link("/api/team/\(team.id)"),
                "teams": link("/api/team"),
                "update": link("/api/team/\(team.id)"),
                "assignProductions": link("/api/team/\(team.id)/productions"),
                "delete": link("/api/team/\(team.id)"),
            ],
        ]
    }

    // MARK: - Users (admin)

    private struct DemoUser: Codable {
        var id: Int
        var username: String
        var firstName: String
        var lastName: String
        var team: String?
        var admin: Bool
        var director: Bool
        var producer: Bool
        var writer: Bool
        var actor: Bool
        var crew: Bool
        var directorOfPhotography: Bool
        var castingDirector: Bool
        var viewCasting: Bool
        var developer: Bool
        var enabled: Bool
    }

    /// Seeded with the demo's own admin plus a couple of ordinary accounts, so
    /// the list is not empty and the different role summaries are visible. The
    /// admin (id 1) stands in for the signed-in user, so — like the server — it
    /// carries no `delete` link: an admin cannot remove their own account.
    private lazy var usersStore: [DemoUser] = [
        DemoUser(id: 1, username: "demo", firstName: "Demo", lastName: "Admin",
                 team: "Demo", admin: true, director: false, producer: false,
                 writer: false, actor: false, crew: false,
                 directorOfPhotography: false, castingDirector: false,
                 viewCasting: false, developer: false, enabled: true),
        DemoUser(id: 2, username: "wes", firstName: "Wes", lastName: "Halloran",
                 team: "Demo", admin: false, director: true, producer: false,
                 writer: true, actor: false, crew: false,
                 directorOfPhotography: false, castingDirector: false,
                 viewCasting: true, developer: false, enabled: true),
        DemoUser(id: 3, username: "rin", firstName: "Rin", lastName: "Kobayashi",
                 team: "Demo", admin: false, director: false, producer: false,
                 writer: false, actor: true, crew: false,
                 directorOfPhotography: false, castingDirector: false,
                 viewCasting: false, developer: false, enabled: false),
    ]
    private lazy var nextUserId = 4

    private func routeUser(method: String, path: [String],
                           query: [String: String],
                           fields: [String: Any]) -> (Int, Data) {
        switch (method, path.count) {
        case ("GET", 0):
            return userCollection()
        case ("POST", 0):
            guard let username = (fields["username"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty else {
                return badRequest("username")
            }
            guard let password = fields["password"] as? String, password.count >= 8 else {
                return badRequest("password")
            }
            var user = DemoUser(id: nextUserId, username: username,
                                firstName: fields["firstName"] as? String ?? "",
                                lastName: fields["lastName"] as? String ?? "",
                                team: (fields["team"] as? String),
                                admin: false, director: false, producer: false,
                                writer: false, actor: false, crew: false,
                                directorOfPhotography: false, castingDirector: false,
                                viewCasting: false, developer: false, enabled: true)
            applyRoles(&user, from: fields)
            nextUserId += 1
            usersStore.append(user)
            return ok(userJSON(user))
        default:
            break
        }

        guard let id = path.first.flatMap(Int.init),
              let index = usersStore.firstIndex(where: { $0.id == id }) else { return notFound() }

        switch (method, path.dropFirst().first) {
        case ("GET", nil):
            // The single-user resource is the one place the access breakdown
            // rides, exactly as the server computes it only on the profile.
            return ok(userJSON(usersStore[index], includeAccess: true))
        case ("PUT", nil):
            if let value = (fields["username"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                usersStore[index].username = value
            }
            if let value = fields["firstName"] as? String { usersStore[index].firstName = value }
            if let value = fields["lastName"] as? String { usersStore[index].lastName = value }
            if fields.keys.contains("team") { usersStore[index].team = fields["team"] as? String }
            applyRoles(&usersStore[index], from: fields)
            return ok(userJSON(usersStore[index]))
        case ("DELETE", nil):
            // The signed-in admin (id 1) cannot delete their own account, matching
            // the server's guard.
            guard id != 1 else {
                return (400, (try? JSONSerialization.data(
                    withJSONObject: ["message": "You cannot delete your own account."]))
                    ?? Data("{}".utf8))
            }
            let removed = usersStore.remove(at: index)
            return ok(userJSON(removed))
        default:
            return notFound()
        }
    }

    private func applyRoles(_ user: inout DemoUser, from fields: [String: Any]) {
        if let value = fields["admin"] as? Bool { user.admin = value }
        if let value = fields["director"] as? Bool { user.director = value }
        if let value = fields["producer"] as? Bool { user.producer = value }
        if let value = fields["writer"] as? Bool { user.writer = value }
        if let value = fields["actor"] as? Bool { user.actor = value }
        if let value = fields["crew"] as? Bool { user.crew = value }
        if let value = fields["directorOfPhotography"] as? Bool { user.directorOfPhotography = value }
        if let value = fields["castingDirector"] as? Bool { user.castingDirector = value }
        if let value = fields["viewCasting"] as? Bool { user.viewCasting = value }
        if let value = fields["developer"] as? Bool { user.developer = value }
    }

    private func userCollection() -> (Int, Data) {
        let items = usersStore
            .sorted { ($0.firstName + $0.lastName)
                .localizedCaseInsensitiveCompare($1.firstName + $1.lastName) == .orderedAscending }
            .map { userJSON($0) }
        return ok([
            "_embedded": ["userResourceList": items],
            "_links": ["self": link("/api/user")],
        ])
    }

    private func userJSON(_ user: DemoUser, includeAccess: Bool = false) -> [String: Any] {
        var links: [String: Any] = [
            "self": link("/api/user/\(user.id)"),
            "users": link("/api/user"),
            "update": link("/api/user/\(user.id)"),
        ]
        // The signed-in admin's own account carries no delete link.
        if user.id != 1 {
            links["delete"] = link("/api/user/\(user.id)")
        }
        var json: [String: Any] = [
            "id": user.id,
            "username": user.username,
            "firstName": user.firstName,
            "lastName": user.lastName,
            "admin": user.admin,
            "director": user.director,
            "producer": user.producer,
            "writer": user.writer,
            "actor": user.actor,
            "crew": user.crew,
            "directorOfPhotography": user.directorOfPhotography,
            "castingDirector": user.castingDirector,
            "viewCasting": user.viewCasting,
            "developer": user.developer,
            "enabled": user.enabled,
            "_links": links,
        ]
        if let team = user.team { json["team"] = team }
        if includeAccess { json["projectAccess"] = userProjectAccess(for: user) }
        return json
    }

    /// The demo's stand-in for the server's per-user project access, computed
    /// the same way: a disabled account reaches nothing; otherwise every demo
    /// project, with edit rights for writers/admins and a reason drawn from a
    /// privileged role, the team, or "Open project". Enough to exercise the
    /// profile's access list, chips and empty states.
    private func userProjectAccess(for user: DemoUser) -> [[String: Any]] {
        guard user.enabled else { return [] }
        let canEdit = user.writer || user.admin
        let reason = userAccessReason(for: user)
        return projects
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .map { project in
                [
                    "projectId": project.id,
                    "projectName": project.title,
                    "canEdit": canEdit,
                    "permissionLabel": canEdit ? "Can edit" : "View only",
                    "accessReason": reason,
                ]
            }
    }

    private func userAccessReason(for user: DemoUser) -> String {
        if user.admin { return "Admin" }
        if user.director { return "Director" }
        if user.producer { return "Producer" }
        if user.writer { return "Writer" }
        if user.actor { return "Actor" }
        if user.crew { return "Crew" }
        if user.directorOfPhotography { return "Director of Photography" }
        if user.castingDirector { return "Casting Director" }
        if let team = user.team, !team.trimmingCharacters(in: .whitespaces).isEmpty {
            return team
        }
        return "Open project"
    }

    private func rootJSON() -> [String: Any] {
        // `teams` and `users` are advertised here as they are on the server for a
        // user allowed to manage them; the demo's single account stands in for
        // that admin.
        //
        // Password recovery is deliberately absent, and is the one rel the real
        // server has that this does not. It rides on the 401 challenge rather
        // than on any document — and the demo never challenges anyone, because
        // there is no sign-in to fail. There is nothing here to recover from.
        ["_links": ["self": link("/api"),
                    "projects": link("/api/project"),
                    "actors": link("/api/actor"),
                    "capitalizationPreferences": link("/api/preferences/capitalization"),
                    // Your own account: offered to anyone signed in, unlike the
                    // admin-only `users` and `teams`.
                    "account": link("/api/account"),
                    "teams": link("/api/team"),
                    "users": link("/api/user")]]
    }

    /// Who can already see a project. Built from the same accounts the Users
    /// view lists, so the two agree — and, like the server, it is the roles and
    /// the team that put someone here, not an invitation. A disabled account is
    /// left out: it cannot sign in, so it cannot be reading anything.
    private func projectAccess(_ projectId: Int) -> (Int, Data) {
        let people = usersStore
            .filter(\.enabled)
            .map { user -> (name: String, why: String, canEdit: Bool) in
                let name = "\(user.firstName) \(user.lastName)"
                let canEdit = user.admin || user.writer
                let why: String
                if user.admin {
                    why = "Admin"
                } else if user.writer {
                    why = "Writer"
                } else if user.director {
                    why = "Director"
                } else if let team = user.team {
                    why = "On the \(team) team"
                } else {
                    why = "Has access"
                }
                return (name, why, canEdit)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { person -> [String: Any] in
                [
                    "displayName": person.name,
                    "accessLabel": person.why,
                    "canEdit": person.canEdit,
                    "permissionLabel": person.canEdit ? "Can edit" : "View only",
                ]
            }
        return ok([
            "_embedded": ["projectAccessUserResourceList": people],
            "_links": [
                "self": link("/api/project/\(projectId)/access"),
                "project": link("/api/project/\(projectId)"),
            ],
        ])
    }

    private func projectJSON(_ project: DemoProject) -> [String: Any] {
        // Names looked up from the team store by the ids the project carries,
        // so the badge tracks a reassignment instead of always saying "Demo".
        let teamNames = project.teamIds.compactMap { id in
            teamsStore.first(where: { $0.id == id })?.name
        }
        var json: [String: Any] = [
            "id": project.id,
            "title": project.title,
            "lastEdited": iso.string(from: project.lastEdited),
            "teams": teamNames,
            "default": project.id == defaultProjectId,
            "_links": [
                "self": link("/api/project/\(project.id)"),
                "update": link("/api/project/\(project.id)"),
                "delete": link("/api/project/\(project.id)"),
                "archive": link("/api/project/\(project.id)/archive"),
                "projectTeams": link("/api/project/\(project.id)/teams"),
                "toggleDefault": link("/api/project/\(project.id)/toggleDefault"),
                "blocks": link("/api/block?projectId=\(project.id)"),
                "characters": link("/api/person?projectId=\(project.id)"),
                "documents": link("/api/document?projectId=\(project.id)"),
                "undoRedoStatus": link("/api/project/\(project.id)/undo-redo-status"),
                "syncStatus": link("/api/project/\(project.id)/sync-status"),
                "export": link("/api/project/\(project.id)/export/fountain"),
                "exportPdf": link("/api/project/\(project.id)/export/pdf"),
                "exportDocx": link("/api/project/\(project.id)/export/docx"),
                "exportFdx": link("/api/project/\(project.id)/export/fdx"),
                "exportEpub": link("/api/project/\(project.id)/export/epub"),
                "exportArchive": link("/api/project/\(project.id)/export/scripty"),
                "actors": link("/api/actor?projectId=\(project.id)"),
                "importScript": link("/api/project/\(project.id)/import-script"),
                // The other direction of `exportArchive`: a whole archive read
                // back into this project rather than into a new one, which is
                // how a copy kept on a signed-out device comes home as the same
                // screenplay instead of as a second one.
                "replaceFromArchive": link("/api/project/\(project.id)/replace-from-archive"),
                "versions": link("/api/project/version?projectId=\(project.id)"),
                "editions": link("/api/project/edition?projectId=\(project.id)"),
                "activity": link("/api/project/\(project.id)/activity"),
                "invitations": link("/api/project/\(project.id)/invitations"),
                "access": link("/api/project/\(project.id)/access"),
                "contactSuggestions": link("/api/project/\(project.id)/contact-suggestions"),
            ],
        ]
        if let writers = project.writers { json["writers"] = writers }
        if let value = project.screenplayTitle { json["screenplayTitle"] = value }
        if let value = project.contactInfo { json["contactInfo"] = value }
        if let value = project.screenplayVersion { json["screenplayVersion"] = value }
        return json
    }

    /// Every team the project could belong to, each flagged whether it does now
    /// — the `projectTeams` collection. The roster is the whole team store (the
    /// real server offers `teamService.list()`), unlike `inviteTeams`, which
    /// shows only the teams already on the project. Sorted by name to match.
    private func projectTeamsCollection(_ project: DemoProject) -> (Int, Data) {
        let items = teamsStore
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { team -> [String: Any] in
                ["id": team.id, "name": team.name, "assigned": project.teamIds.contains(team.id)]
            }
        var payload: [String: Any] = [
            "_links": [
                "self": link("/api/project/\(project.id)/teams"),
                // Where the ticked ids go back — the write is the project's PUT.
                "update": link("/api/project/\(project.id)"),
                "project": link("/api/project/\(project.id)"),
            ],
        ]
        if !items.isEmpty {
            payload["_embedded"] = ["projectTeamOptionResourceList": items]
        }
        return ok(payload)
    }

    /// The block collection, with the affordances the real server advertises:
    /// only an untouched script offers `createInitial`, and only a script with
    /// something in it offers the bulk operations.
    private func blockCollection(_ projectId: Int, editionId: Int? = nil) -> (Int, Data) {
        let source = editionId.flatMap { editionBlocks[$0] } ?? blocks[projectId] ?? []
        let items = source
            .sorted { $0.order < $1.order }
            .map { blockJSON($0, projectId: projectId) }
        let selfHref = editionId.map { "/api/block?projectId=\(projectId)&editionId=\($0)" }
            ?? "/api/block?projectId=\(projectId)"
        var links: [String: Any] = ["self": link(selfHref)]
        if items.isEmpty, blocks[projectId] != nil {
            links["createInitial"] = link("/api/block/initial?projectId=\(projectId)")
        }
        if !items.isEmpty {
            links["bulkSetType"] = link("/api/block/bulk/type")
            links["bulkAddTags"] = link("/api/block/bulk/tags")
            links["bulkFormat"] = link("/api/block/bulk/format")
            links["bulkDelete"] = link("/api/block/bulk/delete")
            links["bulkReplace"] = link("/api/block/bulk/replace")
            // Like the bulk operations, this needs a script to act on — but
            // unlike them it is offered to readers too on the real server,
            // which the demo's always-an-editor user cannot show.
            links["commentCounts"] = link("/api/block/comment-counts?projectId=\(projectId)")
        }
        // Offered even for an empty script — that is exactly when everything
        // has just been deleted.
        links["trash"] = link("/api/block/trash?projectId=\(projectId)")
        return ok(["_embedded": ["blockResourceList": items], "_links": links])
    }

    /// Handles the five bulk operations. Each mutates a set of blocks under a
    /// single snapshot — one undo step for the batch, as on the server — and
    /// answers with the refreshed collection.
    private func routeBulkBlocks(operation: String, fields: [String: Any]) -> (Int, Data) {
        guard let ids = fields["ids"] as? [Int], !ids.isEmpty else {
            return badRequest("ids")
        }
        guard let projectId = fields["projectId"] as? Int, blocks[projectId] != nil else {
            return badRequest("projectId")
        }
        // A caller may not reach outside the project it named — but "the
        // project" means every edition of it, not just the default one. The
        // first version of this checked only the default edition's blocks, so
        // selecting elements while reading a revision and applying any bulk
        // action came back 403. The real server checks the blocks belong to
        // the project, which is edition-independent; this now matches.
        guard ids.allSatisfy({ ownsBlock($0, projectId: projectId) }) else {
            return (403, Data("{}".utf8))
        }

        snapshot(projectId)
        let targets = Set(ids)

        switch operation {
        case "type":
            guard let type = fields["type"] as? String, !type.isEmpty else {
                return badRequest("type")
            }
            mutate(projectId, where: targets) { $0.type = type }

        case "tags":
            guard let tags = fields["tags"] as? String, !tags.isEmpty else {
                return badRequest("tags")
            }
            let incoming = tags.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            mutate(projectId, where: targets) { block in
                var existing = (block.tags ?? "").split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                // Additive and case-insensitive, and the stored casing wins.
                for tag in incoming
                where !existing.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                    existing.append(tag)
                }
                block.tags = existing.isEmpty ? nil : existing.joined(separator: ", ")
            }

        case "delete":
            // Removes from wherever they live and renumbers that list, so a
            // bulk delete works while reading a revision, not only the default.
            for removed in (blocks[projectId] ?? []) where targets.contains(removed.id) {
                trashBlock(removed, projectId: projectId)
            }
            blocks[projectId]?.removeAll { targets.contains($0.id) }
            renumber(&blocks[projectId])
            for edition in editions where edition.projectId == projectId {
                for removed in (editionBlocks[edition.id] ?? []) where targets.contains(removed.id) {
                    trashBlock(removed, projectId: projectId)
                }
                editionBlocks[edition.id]?.removeAll { targets.contains($0.id) }
                renumber(&editionBlocks[edition.id])
            }

        case "format":
            if let align = fields["align"] as? String {
                guard let canonical = canonicalAlign(align) else { return badRequest("align") }
                mutate(projectId, where: targets) { $0.textAlign = canonical }
            }
            if fields["clearFont"] as? Bool == true {
                mutate(projectId, where: targets) { $0.font = nil }
            } else if let font = fields["font"] as? String {
                guard let canonical = canonicalFont(font) else { return badRequest("font") }
                mutate(projectId, where: targets) { $0.font = canonical }
            }
            if let style = fields["style"] as? String {
                switch style.uppercased() {
                case "BOLD":
                    mutate(projectId, where: targets) { $0.textBold = !($0.textBold ?? false) }
                case "ITALIC":
                    mutate(projectId, where: targets) { $0.textItalic = !($0.textItalic ?? false) }
                case "UNDERLINE":
                    mutate(projectId, where: targets) { $0.textUnderline = !($0.textUnderline ?? false) }
                default:
                    return badRequest("style")
                }
            }
            if fields["clearHighlight"] as? Bool == true {
                mutate(projectId, where: targets) { $0.highlight = nil }
            } else if let highlight = fields["highlight"] as? String {
                // An unrecognised tint clears rather than failing, as on the server.
                let known = ["YELLOW", "GREEN", "BLUE", "RED", "GRAY"]
                let key = highlight.trimmingCharacters(in: .whitespaces).uppercased()
                mutate(projectId, where: targets) { $0.highlight = known.contains(key) ? key : nil }
            }

        case "replace":
            guard let find = fields["find"] as? String, !find.isEmpty else {
                return badRequest("find")
            }
            let replacement = fields["replace"] as? String ?? ""
            let matchCase = fields["matchCase"] as? Bool ?? false
            let wholeWord = fields["wholeWord"] as? Bool ?? false
            let includeCues = fields["includeCharacterCues"] as? Bool ?? false
            mutate(projectId, where: targets) { block in
                // Cue content mirrors the person record, so it is left alone
                // unless the caller opted in.
                if !includeCues, block.type == "CHARACTER" || block.type == "DUAL_DIALOGUE" {
                    return
                }
                block.content = Self.literalReplace(
                    in: block.content, find: find, with: replacement,
                    matchCase: matchCase, wholeWord: wholeWord)
            }

        default:
            return notFound()
        }

        touch(projectId)
        return blockCollection(projectId)
    }

    /// Restores contiguous 1-based ordering after a removal.
    private func renumber(_ list: inout [DemoBlock]?) {
        guard var blocks = list else { return }
        blocks.sort { $0.order < $1.order }
        for index in blocks.indices { blocks[index].order = index + 1 }
        list = blocks
    }

    /// True when the block belongs to this project, in any of its editions.
    private func ownsBlock(_ id: Int, projectId: Int) -> Bool {
        if (blocks[projectId] ?? []).contains(where: { $0.id == id }) {
            return true
        }
        return editions
            .filter { $0.projectId == projectId }
            .contains { (editionBlocks[$0.id] ?? []).contains(where: { $0.id == id }) }
    }

    /// Applies a change wherever the blocks actually live — the project's own
    /// list, and every edition's — so a bulk action works the same whichever
    /// edition the writer is reading.
    private func mutate(_ projectId: Int,
                        where ids: Set<Int>,
                        _ change: (inout DemoBlock) -> Void) {
        if var list = blocks[projectId] {
            for index in list.indices where ids.contains(list[index].id) {
                change(&list[index])
            }
            blocks[projectId] = list
        }
        for edition in editions where edition.projectId == projectId {
            guard var list = editionBlocks[edition.id] else { continue }
            for index in list.indices where ids.contains(list[index].id) {
                change(&list[index])
            }
            editionBlocks[edition.id] = list
        }
    }

    /// Literal find-and-replace — `find` is never treated as a pattern and the
    /// replacement is inserted verbatim, matching the server's use of
    /// `Pattern.quote` and `Matcher.quoteReplacement`.
    private static func literalReplace(in text: String,
                                       find: String,
                                       with replacement: String,
                                       matchCase: Bool,
                                       wholeWord: Bool) -> String {
        guard !find.isEmpty else { return text }
        var pattern = NSRegularExpression.escapedPattern(for: find)
        if wholeWord { pattern = "\\b\(pattern)\\b" }
        let options: NSRegularExpression.Options = matchCase ? [] : [.caseInsensitive]
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        let template = NSRegularExpression.escapedTemplate(for: replacement)
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template)
    }

    /// Replaces a single occurrence — the `occurrence`-th match, zero-based —
    /// leaving the rest of the text alone. An index past the last match changes
    /// nothing, matching the server's single-replace. Same literal rules as
    /// `literalReplace`.
    private static func replaceOccurrence(in text: String,
                                          find: String,
                                          with replacement: String,
                                          matchCase: Bool,
                                          wholeWord: Bool,
                                          occurrence: Int) -> String {
        guard !find.isEmpty, occurrence >= 0 else { return text }
        var pattern = NSRegularExpression.escapedPattern(for: find)
        if wholeWord { pattern = "\\b\(pattern)\\b" }
        let options: NSRegularExpression.Options = matchCase ? [] : [.caseInsensitive]
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        let full = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: full)
        guard occurrence < matches.count,
              let hit = Range(matches[occurrence].range, in: text) else { return text }
        return text.replacingCharacters(in: hit, with: replacement)
    }

    private func blockJSON(_ block: DemoBlock, projectId: Int) -> [String: Any] {
        var json: [String: Any] = [
            "id": block.id,
            "projectId": projectId,
            "order": block.order,
            "content": block.content,
            "type": block.type,
            "bookmarked": block.bookmarked,
            "pinned": block.pinned,
            "scene": block.type == "SCENE",
            "_links": [
                "self": link("/api/block/\(block.id)"),
                "update": link("/api/block/\(block.id)"),
                "delete": link("/api/block/\(block.id)"),
                "toggleBookmark": link("/api/block/\(block.id)/bookmark"),
                "togglePinned": link("/api/block/\(block.id)/pinned"),
                "createBelow": link("/api/block/\(block.id)/below"),
                "setType": link("/api/block/\(block.id)/type"),
                "move": link("/api/block/\(block.id)/move"),
                "replace": link("/api/block/\(block.id)/replace"),
                // Commenting needs only read access, so this is offered
                // alongside the editing links rather than gated with them.
                "comments": link("/api/block/\(block.id)/comments"),
            ],
        ]
        if let personId = block.personId {
            json["personId"] = personId
            if let person = people[projectId]?.first(where: { $0.id == personId }) {
                json["personName"] = person.name
            }
        }
        if let tags = block.tags { json["tags"] = tags }
        if let value = block.textAlign { json["textAlign"] = value }
        if let value = block.font { json["font"] = value }
        if let value = block.highlight { json["highlight"] = value }
        if let value = block.textBold { json["textBold"] = value }
        if let value = block.textItalic { json["textItalic"] = value }
        if let value = block.textUnderline { json["textUnderline"] = value }
        return json
    }

    private func personJSON(_ person: DemoPerson, projectId: Int) -> [String: Any] {
        var json: [String: Any] = [
            "id": person.id,
            "name": person.name,
            "fullName": person.fullName,
            "projectId": projectId,
            "_links": [
                "self": link("/api/person/\(person.id)"),
                "update": link("/api/person/\(person.id)"),
                "delete": link("/api/person/\(person.id)"),
            ],
        ]
        if let actorId = person.actorId {
            json["actorId"] = actorId
            if let actor = actors.first(where: { $0.id == actorId }) {
                json["actorName"] = [actor.first, actor.last]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
        }
        return json
    }

    // MARK: - Export

    private func fountainExport(_ project: DemoProject) -> String {
        var lines = ["Title: \(project.title)", ""]
        for block in (blocks[project.id] ?? []).sorted(by: { $0.order < $1.order }) {
            switch block.type {
            case "SCENE", "TRANSITION":
                lines.append(block.content.uppercased())
                lines.append("")
            case "CHARACTER", "DUAL_DIALOGUE":
                lines.append(block.content.uppercased())
            case "PARENTHETICAL", "DIALOGUE":
                lines.append(block.content)
            default:
                lines.append(block.content)
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// A file for each export format the demo advertises.
    ///
    /// The demo has no real PDF/DOCX/EPUB engines, so it returns the fountain
    /// text for the text-shaped formats and a genuine one-page PDF for `pdf` —
    /// the latter so the print flow, which hands its bytes to the system print
    /// panel, has something valid to render offline.
    private func demoExport(_ project: DemoProject, format: String) -> (Int, Data) {
        switch format {
        case "pdf":
            return (200, minimalPDF(title: project.title))
        case "scripty", "json":
            var archive = projectArchive(project)
            archive["format"] = Self.archiveFormat
            archive["formatVersion"] = Self.archiveFormatVersion
            archive["exportedAt"] = iso.string(from: .now)
            let data = (try? JSONSerialization.data(withJSONObject: archive, options: [.prettyPrinted]))
                ?? Data()
            return (200, data)
        default:
            // fountain, docx, fdx, epub — the demo serves the plain text it can
            // actually produce; the point offline is that the rel resolves.
            return (200, Data(fountainExport(project).utf8))
        }
    }

    /// The `.scripty.json` markers the real server writes and checks for. A file
    /// without them is refused by `importProject` before it is even read, so
    /// anything this backend calls an archive has to carry them.
    static let archiveFormat = "scripty-project"
    static let bundleFormat = "scripty-projects"
    static let archiveFormatVersion = 1

    /// One project in the archive shape the server's importer reads: the title
    /// page, its characters, its songs and notes, and every element with the
    /// formatting hung on it.
    ///
    /// Editions are deliberately left out. The importer creates a default
    /// edition for a file that names none and files every element into it,
    /// which is what a demo session's alternate drafts should become on the way
    /// into a real account — the alternative is inventing edition keys here for
    /// blocks this backend keeps in a separate table anyway.
    private func projectArchive(_ project: DemoProject) -> [String: Any] {
        var info: [String: Any] = ["title": project.title]
        if let value = project.screenplayTitle { info["screenplayTitle"] = value }
        if let value = project.writers { info["writers"] = value }
        if let value = project.contactInfo { info["contactInfo"] = value }
        if let value = project.screenplayVersion { info["screenplayVersion"] = value }

        let characters = (people[project.id] ?? []).map { person -> [String: Any] in
            ["key": person.id, "name": person.name, "fullName": person.fullName]
        }

        // Archived songs and notes travel too, flagged as archived. They are
        // whole documents that happen not to be listed, and a file that left
        // them out would quietly lose them — which matters most where the file
        // is not a download but the device's copy of a screenplay being made to
        // match the account's.
        let liveEntries = (documents[project.id] ?? [])
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { ($0, false) }
        let archivedEntries = (archivedDocuments[project.id] ?? [])
            .map(\.document)
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { ($0, true) }
        let documentEntries = (liveEntries + archivedEntries)
            .map { document, isArchived -> [String: Any] in
                var entry: [String: Any] = [
                    "key": document.id, "title": document.title,
                    "documentType": document.documentType, "content": document.content,
                    "sortOrder": document.sortOrder, "archived": isArchived,
                ]
                // Unlike `key`, which only wires this file together and is
                // thrown away on the way in, this travels: it is how the far
                // end knows this is a song it already has rather than a new
                // one. See `DemoDocument.uid`.
                if let uid = document.uid, !uid.isEmpty { entry["uid"] = uid }
                // The folder it was filed under, by name — the only form an
                // arrangement can travel in, since the far end numbers its own
                // folders and has never heard of these ids. Absent for an
                // unfiled document, which is how the server reads "not in a
                // folder" too.
                if let folderId = document.folderId,
                   let folder = folders.first(where: { $0.id == folderId }) {
                    entry["folder"] = folder.name
                }
                return entry
            }

        let blockEntries = (blocks[project.id] ?? [])
            .sorted { $0.order < $1.order }
            .map { block -> [String: Any] in
                var entry: [String: Any] = [
                    "order": block.order,
                    "type": block.type,
                    "content": block.content,
                    "bookmarked": block.bookmarked,
                    "pinned": block.pinned,
                ]
                if let value = block.personId { entry["characterKey"] = value }
                if let value = block.tags { entry["tags"] = value }
                if let value = block.textAlign { entry["textAlign"] = value }
                if let value = block.font { entry["font"] = value }
                if let value = block.highlight { entry["highlight"] = value }
                if let value = block.textBold { entry["textBold"] = value }
                if let value = block.textItalic { entry["textItalic"] = value }
                if let value = block.textUnderline { entry["textUnderline"] = value }
                return entry
            }

        return ["project": info, "characters": characters,
                "documents": documentEntries, "blocks": blockEntries]
    }

    /// Every project as one archive, in the shape a single project's
    /// `exportArchive` uses — a bundle is the same document with a list at the
    /// top, so what goes out here is what `importProject` reads back.
    /// An empty `ids` means the whole shelf, which is what the real endpoint
    /// does with no selection.
    ///
    /// This is also how work written without an account reaches one: signing in
    /// asks this backend for a bundle of the guest session's projects and hands
    /// the bytes straight to the account's `importProject`.
    func demoProjectsBundle(ids: [Int] = []) -> (Int, Data) {
        let chosen = ids.isEmpty ? projects : projects.filter { ids.contains($0.id) }
        let bundle: [String: Any] = [
            "format": Self.bundleFormat,
            "formatVersion": Self.archiveFormatVersion,
            "exportedAt": iso.string(from: .now),
            "projects": chosen.map(projectArchive),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: bundle, options: [.prettyPrinted])) ?? Data()
        return (200, data)
    }

    /// The smallest well-formed PDF: one blank US-Letter page. Enough for the
    /// print panel to open on a real document rather than reject empty bytes.
    private func minimalPDF(title: String) -> Data {
        let objects = [
            "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
            "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
            "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\n",
        ]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for object in objects {
            offsets.append(pdf.utf8.count)
            pdf += object
        }
        let xrefStart = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            pdf += String(format: "%010d 00000 n \n", offset)
        }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\n"
        pdf += "startxref\n\(xrefStart)\n%%EOF"
        return Data(pdf.utf8)
    }

    /// A couple of stand-in contacts, filtered by what has been typed. Enough to
    /// show the invite autofill working offline without inventing a directory.
    private func contactSuggestions(matching query: String) -> (Int, Data) {
        let all: [(name: String, email: String, source: String)] = [
            ("Ava Collaborator", "ava@example.com", "Collaborator"),
            ("Sam Reader", "sam@example.com", "Reader"),
            ("Casting Office", "casting@example.com", "Cast"),
        ]
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matches = q.isEmpty ? [] : all.filter {
            $0.name.lowercased().contains(q) || $0.email.lowercased().contains(q)
        }
        let items = matches.map { ["name": $0.name, "email": $0.email, "sourceLabel": $0.source] }
        return ok(["_embedded": ["contactSuggestionViewModelList": items],
                   "_links": ["self": link("/api/project/contact-suggestions")]])
    }

    // MARK: - Helpers

    private let iso = ISO8601DateFormatter()

    /// The real server accepts either the display spelling or its own canonical
    /// form and always reads back the canonical one. The demo mirrors that, so
    /// a client that round-trips a value here behaves the same in production.
    private func canonicalAlign(_ value: String) -> String? {
        switch value.uppercased() {
        case "LEFT": return "LEFT"
        case "CENTER": return "CENTER"
        case "RIGHT": return "RIGHT"
        default: return nil
        }
    }

    private func canonicalFont(_ value: String) -> String? {
        switch value.uppercased().replacingOccurrences(of: " ", with: "_") {
        case "COURIER_PRIME": return "COURIER_PRIME"
        case "ARIAL": return "ARIAL"
        case "TIMES_NEW_ROMAN": return "TIMES_NEW_ROMAN"
        default: return nil
        }
    }

    private func locateBlock(_ id: Int) -> (projectId: Int, index: Int)? {
        for (projectId, list) in blocks {
            if let index = list.firstIndex(where: { $0.id == id }) {
                return (projectId, index)
            }
        }
        return nil
    }

    private func locatePerson(_ id: Int) -> (projectId: Int, index: Int)? {
        for (projectId, list) in people {
            if let index = list.firstIndex(where: { $0.id == id }) {
                return (projectId, index)
            }
        }
        return nil
    }

    private func touch(_ projectId: Int) {
        if let index = projects.firstIndex(where: { $0.id == projectId }) {
            projects[index].lastEdited = .now
            recordWork(projectId)
        }
    }

    /// Marks a project as written: the flag the sign-in offer and the linked
    /// crossing are both built from.
    ///
    /// Songs and notes reach this through `touch` like everything else. They
    /// used not to — the reasoning being that a note is its own resource with
    /// its own timestamp and the screenplay's date does not move for it — but
    /// the server does not work that way: `TextDocumentServiceImpl` and
    /// `SongBlockServiceImpl` both stamp the project on every save. That matters
    /// beyond where a row sorts. The account's `lastEdited` is the whole of how
    /// this client decides whether someone else has written in a screenplay
    /// since the two copies last met, and a demo that disagreed would have the
    /// checks rehearsing a conflict production cannot have.
    private func recordWork(_ projectId: Int) {
        writtenProjectIds.insert(projectId)
    }

    /// The projects worth keeping: everything this session created or changed,
    /// newest first, and never a sample screenplay left as it was seeded.
    /// Deleted ones fall out on their own — the id is remembered, but the
    /// project it named is gone from the list.
    ///
    /// `alreadyKept` marks one an account has been given a copy of before, and
    /// which has been written in since. Those newer words exist nowhere else,
    /// but sending them up makes a *second* screenplay rather than catching the
    /// first one up — so it is the one thing a sign-in leaves where it is. See
    /// `AppModel.adopt`.
    func guestWork() -> [(id: Int, title: String, alreadyKept: Bool)] {
        projects
            .filter { writtenProjectIds.contains($0.id) }
            .sorted { $0.lastEdited > $1.lastEdited }
            .map { ($0.id, $0.title, handedOffProjectIds.contains($0.id)) }
    }

    private func link(_ path: String) -> [String: String] {
        ["href": Self.baseURL.absoluteString + path]
    }

    private func ok(_ object: [String: Any]) -> (Int, Data) {
        ((try? JSONSerialization.data(withJSONObject: object)).map { (200, $0) }
            ?? (500, Data("{}".utf8)))
    }

    /// 201 with the new resource, for the routes the server answers that way.
    private func created(_ object: [String: Any]) -> (Int, Data) {
        ((try? JSONSerialization.data(withJSONObject: object)).map { (201, $0) }
            ?? (500, Data("{}".utf8)))
    }

    private func notFound() -> (Int, Data) {
        (404, Data("{}".utf8))
    }

    private func badRequest(_ field: String) -> (Int, Data) {
        let body = (try? JSONSerialization.data(withJSONObject: [field: "is required"]))
            ?? Data("{}".utf8)
        return (400, body)
    }

    // MARK: - Sample content

    private func seed() {
        var maya = addPerson(name: "MAYA", fullName: "Maya Okafor")
        let dev = addPerson(name: "DEV", fullName: "Dev Ramaswamy")

        // One character arrives already cast and one still open, so the casting
        // screen shows both states without the user having to set them up.
        let rosa = addActor(first: "Rosa", last: "Delgado",
                            email: "rosa@example.com", phone: "555-0142",
                            projectIds: [1])
        addActor(first: "Theo", last: "Nakamura",
                 email: "theo@example.com", phone: nil, projectIds: [1])
        addActor(first: "Priya", last: "Anand",
                 email: "priya@example.com", phone: nil, projectIds: [2])
        maya.actorId = rosa.id

        let lastTake = addProject(title: "The Last Take",
                                  writers: "Demo Screenwriter",
                                  editedMinutesAgo: 12,
                                  people: [maya, dev])
        seedBlocks(project: lastTake, entries: [
            ("SCENE", "INT. SOUNDSTAGE 7 - NIGHT", nil, true),
            ("ACTION", "The crew of a no-budget indie huddles around a single flickering work light. MAYA (30s, running on cold coffee and spite) stares at a playback monitor.", nil, false),
            ("CHARACTER", "MAYA", maya.id, false),
            ("DIALOGUE", "That was perfect. Why does nobody trust me when I say it was perfect?", maya.id, false),
            ("CHARACTER", "DEV", dev.id, false),
            ("PARENTHETICAL", "(without looking up)", dev.id, false),
            ("DIALOGUE", "Because you said that about the take where the boom fell on me.", dev.id, false),
            ("CHARACTER", "MAYA", maya.id, false),
            ("DIALOGUE", "The boom added realism.", maya.id, false),
            ("ACTION", "The work light sputters. Everyone looks up. It dies with a sad little pop.", nil, false),
            ("CHARACTER", "DEV", dev.id, false),
            ("DIALOGUE", "We have four minutes of battery and one working light, Maya.", dev.id, false),
            ("CHARACTER", "MAYA", maya.id, false),
            ("PARENTHETICAL", "(standing)", maya.id, false),
            ("DIALOGUE", "Then we shoot the ending first. Right now. One take.", maya.id, false),
            ("TRANSITION", "SMASH CUT TO:", nil, false),
            ("SCENE", "EXT. STUDIO PARKING LOT - NIGHT", nil, false),
            ("ACTION", "Rain. Of course it's raining. Maya and Dev sprint across the lot, the camera cradled between them like a newborn.", nil, false),
            ("CHARACTER", "DEV", dev.id, false),
            ("DIALOGUE", "For the record, this is insane.", dev.id, false),
            ("CHARACTER", "MAYA", maya.id, false),
            ("DIALOGUE", "For the record, it's going to be beautiful.", maya.id, false),
            ("ACTION", "Maya skids to a stop and frames the shot with her hands: the night guard asleep in his booth, lit gold by a humming vending machine.", nil, false),
            ("CHARACTER", "MAYA", maya.id, false),
            ("PARENTHETICAL", "(whispering)", maya.id, false),
            ("DIALOGUE", "There it is. Roll.", maya.id, false),
            ("ACTION", "Dev rolls. Somewhere, thunder. The little red record light burns like a tiny sun.", nil, false),
            ("CHARACTER", "DEV", dev.id, false),
            ("PARENTHETICAL", "(quietly)", dev.id, false),
            ("DIALOGUE", "...Yeah, okay. It's beautiful.", dev.id, false),
            ("TRANSITION", "FADE OUT.", nil, false),
        ])

        let juniper = addPerson(name: "JUNIPER", fullName: "Juniper Vale")
        let dustAndNeon = addProject(title: "Dust & Neon",
                                     writers: "Demo Screenwriter",
                                     editedMinutesAgo: 60 * 26,
                                     people: [juniper])
        seedBlocks(project: dustAndNeon, entries: [
            ("SCENE", "EXT. FRONTIER TOWN OF LAST CHANCE - DUSK", nil, false),
            ("ACTION", "Two moons rise over a dirt main street lined with holographic saloon signs. A rider approaches, boots dusty, jacket flickering with dead pixels.", nil, false),
            ("CHARACTER", "JUNIPER", juniper.id, false),
            ("DIALOGUE", "They said this town was empty. They said a lot of things.", juniper.id, false),
            ("SYNOPSIS", "Juniper discovers the town isn't abandoned - it's hiding.", nil, false),
        ])

        // Arrive with a bookmark, a pin and a tag already set, so those
        // affordances are visible in the script — and in the outline's marked
        // lists — without the user having to add them first.
        flag(project: lastTake, order: 17, bookmarked: true, tags: "vfx, rain")
        flag(project: lastTake, order: 23, pinned: true)
        flag(project: dustAndNeon, order: 1, bookmarked: true)

        // A song and a note per project so the Songs & Notes screen isn't empty.
        addDocument(projectId: lastTake.id, title: "One More Take", type: "SONG", content: """
        Roll the film, we're running out of night
        One more take before we lose the light
        The reel keeps spinning, so do I
        One more take, one more try
        """)
        addDocument(projectId: lastTake.id, title: "Production Notes", type: "NOTES", content: """
        Reshoot the parking-lot ending if the rain rig is available.
        Ask props for a second vending machine practical light.
        Dev's boom mic still rattles on wide shots — tape it.
        """)
        addDocument(projectId: dustAndNeon.id, title: "Ballad of Last Chance", type: "SONG", content: """
        Two moons over a one-horse town
        Neon buzzing as the sun goes down
        I rode in chasing an empty street
        Found a town with a heartbeat
        """)

        // A little history to arrive with, so version history is not an empty
        // screen. Backdated, and one named against two automatic saves, which
        // is the ratio the real thing produces.
        seedVersion(lastTake.id, label: "First pass", autoSave: false, minutesAgo: 180)
        seedVersion(lastTake.id, label: nil, autoSave: true, minutesAgo: 95)
        seedVersion(lastTake.id, label: "Before the rain rewrite", autoSave: false, minutesAgo: 40)
        seedVersion(lastTake.id, label: nil, autoSave: true, minutesAgo: 12)
        seedVersion(dustAndNeon.id, label: nil, autoSave: true, minutesAgo: 1_500)

        // Every project has a default edition; the first one also has a
        // revision, so the picker has something to choose between and switching
        // shows genuinely different text.
        seedEdition(lastTake.id, name: "Shooting Draft", isDefault: true, isPublished: true)
        let revision = seedEdition(lastTake.id, name: "Rain Rewrite",
                                   isDefault: false, isPublished: false)
        editionBlocks[revision] = (blocks[lastTake.id] ?? []).prefix(12).map { block in
            var copy = block
            copy.id = nextBlockId
            nextBlockId += 1
            if copy.type == "ACTION", copy.content.contains("rain") || copy.content.contains("Rain") {
                copy.content = "The rain arrives early, and everything changes."
            }
            return copy
        }
        seedEdition(dustAndNeon.id, name: "First Draft", isDefault: true, isPublished: true)

        // A little history, so the activity screen shows a record rather than
        // an empty state. Backdated and attributed to more than one person,
        // since a log with a single name in it teaches nothing.
        recordActivity(lastTake.id, type: "PROJECT_CREATE",
                       summary: "Created the screenplay", minutesAgo: 4_320)
        recordActivity(lastTake.id, type: "SCRIPT_IMPORT",
                       summary: "Imported the first draft from Final Draft", minutesAgo: 4_200)
        recordActivity(lastTake.id, type: "ACTOR_CAST",
                       summary: "Cast Rosa Delgado as MAYA",
                       actor: "Priya Anand", minutesAgo: 1_460)
        recordActivity(lastTake.id, type: "VERSION_SAVE",
                       summary: "Saved the version “Before the rain rewrite”", minutesAgo: 40)
        recordActivity(lastTake.id, type: "COMMENT_ADD",
                       summary: "Commented on an action line",
                       actor: "Rosa Delgado", minutesAgo: 220)
        recordActivity(dustAndNeon.id, type: "PROJECT_CREATE",
                       summary: "Created the screenplay", minutesAgo: 1_500)

        // A short thread already in place, so the comments screen shows a
        // conversation rather than an empty state — and a second one further
        // down the script, so the outline's Comments list has somewhere to
        // navigate to.
        if let commented = (blocks[lastTake.id] ?? []).first(where: { $0.type == "ACTION" }) {
            seedComment(commented.id, author: "Rosa Delgado",
                        body: "Can we lose the second half of this? It plays long.",
                        minutesAgo: 220, mine: false)
            seedComment(commented.id, author: "You",
                        body: "Agreed — trimming after the table read.",
                        minutesAgo: 55, mine: true)
        }
        if let commented = (blocks[lastTake.id] ?? []).first(where: { $0.order == 20 }) {
            seedComment(commented.id, author: "Priya Anand",
                        body: "Dev's line lands better if he's already running.",
                        minutesAgo: 90, mine: false)
        }

        // One of each kind of access, so the share screen shows the distinction
        // between a collaborator and a reader rather than describing it.
        invitations.append(DemoInvitation(id: nextInvitationId, projectId: lastTake.id,
                                          email: "rosa@example.com", viewOnly: false,
                                          status: "Pending"))
        nextInvitationId += 1
        invitations.append(DemoInvitation(id: nextInvitationId, projectId: lastTake.id,
                                          email: "financier@example.com", viewOnly: true,
                                          status: "Active"))
        nextInvitationId += 1
    }

    private func seedComment(_ blockId: Int, author: String, body: String,
                             minutesAgo: Int, mine: Bool) {
        comments.append(DemoComment(
            id: nextCommentId,
            blockId: blockId,
            authorName: author,
            body: body,
            createdAt: Date(timeIntervalSinceNow: -Double(minutesAgo) * 60),
            mine: mine))
        nextCommentId += 1
    }

    @discardableResult
    private func seedEdition(_ projectId: Int, name: String,
                             isDefault: Bool, isPublished: Bool) -> Int {
        let edition = DemoEdition(id: nextEditionId, projectId: projectId, name: name,
                                  isDefault: isDefault, isPublished: isPublished,
                                  lastEdited: Date())
        nextEditionId += 1
        editions.append(edition)
        // The default edition reads the project's own blocks, so an unnamed
        // request behaves exactly as it did before editions existed.
        editionBlocks[edition.id] = isDefault ? (blocks[projectId] ?? []) : []
        return edition.id
    }

    private func seedVersion(_ projectId: Int, label: String?, autoSave: Bool, minutesAgo: Int) {
        var version = recordVersion(projectId, label: label, autoSave: autoSave)
        version.createdAt = Date(timeIntervalSinceNow: -Double(minutesAgo) * 60)
        if let index = versions[projectId]?.firstIndex(where: { $0.id == version.id }) {
            versions[projectId]?[index] = version
        }
    }

    private func flag(project: DemoProject, order: Int,
                      bookmarked: Bool = false, pinned: Bool = false,
                      tags: String? = nil) {
        guard let index = blocks[project.id]?.firstIndex(where: { $0.order == order }) else { return }
        blocks[project.id]?[index].bookmarked = bookmarked
        blocks[project.id]?[index].pinned = pinned
        blocks[project.id]?[index].tags = tags
    }

    private func addProject(title: String, writers: String?,
                            editedMinutesAgo: Double,
                            people members: [DemoPerson]) -> DemoProject {
        let project = DemoProject(id: nextProjectId, title: title, writers: writers,
                                  lastEdited: Date(timeIntervalSinceNow: -editedMinutesAgo * 60))
        nextProjectId += 1
        projects.append(project)
        blocks[project.id] = []
        people[project.id] = members
        documents[project.id] = []
        return project
    }

    private func addPerson(name: String, fullName: String) -> DemoPerson {
        let person = DemoPerson(id: nextPersonId, name: name, fullName: fullName)
        nextPersonId += 1
        return person
    }

    @discardableResult
    private func addActor(first: String, last: String, email: String?,
                          phone: String?, projectIds: [Int]) -> DemoActor {
        let actor = DemoActor(id: nextActorId, first: first, last: last,
                              phone: phone, email: email, projectIds: projectIds)
        nextActorId += 1
        actors.append(actor)
        return actor
    }

    private func seedBlocks(project: DemoProject,
                            entries: [(type: String, content: String, personId: Int?, pinned: Bool)]) {
        for (index, entry) in entries.enumerated() {
            let block = DemoBlock(id: nextBlockId,
                                  order: index + 1,
                                  content: entry.content,
                                  type: entry.type,
                                  personId: entry.personId,
                                  pinned: entry.pinned)
            nextBlockId += 1
            blocks[project.id]?.append(block)
        }
    }
}

private extension String {
    nonisolated var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
