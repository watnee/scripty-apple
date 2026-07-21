//
//  Rel.swift
//  scripty
//
//  Link relation names advertised by the Scripty API.
//  Mirrors ApiRel.java on the server — the one deliberate coupling point.
//

import Foundation

struct Rel: RawRepresentable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    static let selfRel = Rel("self")
    static let users = Rel("users")
    static let projects = Rel("projects")
    static let importProject = Rel("importProject")
    static let blocks = Rel("blocks")
    static let characters = Rel("characters")
    static let actors = Rel("actors")
    static let teams = Rel("teams")
    static let update = Rel("update")
    static let delete = Rel("delete")
    static let toggleDefault = Rel("toggleDefault")
    static let project = Rel("project")
    static let actor = Rel("actor")
    static let undo = Rel("undo")
    static let redo = Rel("redo")
    static let undoRedoStatus = Rel("undoRedoStatus")
    static let syncStatus = Rel("syncStatus")
    static let toggleBookmark = Rel("toggleBookmark")
    static let togglePinned = Rel("togglePinned")
    static let createBelow = Rel("createBelow")
    static let createInitial = Rel("createInitial")
    static let setType = Rel("setType")
    static let move = Rel("move")

    // Bulk operations are advertised on the block collection, not on a block,
    // because they act on a set of them.
    static let bulkSetType = Rel("bulkSetType")
    static let bulkAddTags = Rel("bulkAddTags")
    static let bulkFormat = Rel("bulkFormat")
    static let bulkDelete = Rel("bulkDelete")
    static let bulkReplace = Rel("bulkReplace")
    static let export = Rel("export")
    static let exportPdf = Rel("exportPdf")
    static let exportDocx = Rel("exportDocx")
    static let exportFdx = Rel("exportFdx")
    static let exportEpub = Rel("exportEpub")

    /// The whole project as a `.scripty.json` bundle — the format `importProject`
    /// reads back, so this is the round trip that moves a project between servers.
    static let exportArchive = Rel("exportArchive")

    /// A single song, exported in the formats SongExportService offers. Advertised
    /// on each song document, not on the project — a note has no song layout to
    /// export, so these appear only for songs.
    static let exportSongTxt = Rel("exportSongTxt")
    static let exportSongPdf = Rel("exportSongPdf")
    static let exportSongDocx = Rel("exportSongDocx")
    static let exportSongEpub = Rel("exportSongEpub")

    /// Replace the set of characters an actor auditions for in a project.
    /// Advertised on a project-scoped actor only — auditions have no meaning
    /// without a project. The audition character ids ride on the same resource.
    static let setAuditions = Rel("setAuditions")

    static let headshot = Rel("headshot")
    static let documents = Rel("documents")
    static let document = Rel("document")
    static let insert = Rel("insert")
    static let shareEmail = Rel("shareEmail")
    static let importDocument = Rel("importDocument")
    static let importScript = Rel("importScript")

    /// New order for a project's songs & notes, advertised on the document
    /// collection for an editor. The client posts the ids in their new sequence.
    static let reorder = Rel("reorder")

    // Version history. The server has offered these all along.
    static let versions = Rel("versions")
    static let restore = Rel("restore")
    static let create = Rel("create")

    // Recovery. Each collection that can lose things points at its own trash.
    static let trash = Rel("trash")
    static let purge = Rel("purge")
    static let emptyTrash = Rel("emptyTrash")

    // Collaboration.
    static let comments = Rel("comments")
    static let addComment = Rel("addComment")
    static let activity = Rel("activity")
    static let invitations = Rel("invitations")
    static let sendInvitation = Rel("sendInvitation")
    static let revoke = Rel("revoke")

    /// Names known to this project, offered while typing an invite address so
    /// the sender need not remember the email. Scoped to the project, so it is
    /// not a directory of everyone.
    static let contactSuggestions = Rel("contact-suggestions")

    // Teams — a production's people, managed by an admin. The `teams` rel is
    // declared above; it is advertised on the API root only when the signed-in
    // user may see them.
    static let assignProductions = Rel("assignProductions")

    // A song's lyric, stored as ordered lines like a screenplay's elements.
    static let songBlocks = Rel("songBlocks")
    static let setHighlight = Rel("setHighlight")

    // Named variants of a script or a song.
    static let editions = Rel("editions")
    static let setDefault = Rel("setDefault")
    static let setPublished = Rel("setPublished")

    // The signed-in user's own account — advertised on the API root to anyone
    // signed in, unlike the admin-only `users`. `passkeys` appears only where
    // the deployment has passkeys configured; registering a new one stays a
    // browser ceremony, so the API offers listing and revoking only.
    static let account = Rel("account")
    static let changePassword = Rel("changePassword")
    static let passkeys = Rel("passkeys")

    // Editor preferences the server keeps because exports bake them in.
    // Advertised on the API root; `update` (declared above) posts a change.
    static let capitalizationPreferences = Rel("capitalizationPreferences")
}
