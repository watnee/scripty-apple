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

    /// Every project the signed-in user can see, as one archive. Advertised on
    /// the project collection rather than on a project — it is the collection
    /// it exports — and only when there is something in it.
    static let exportProjects = Rel("exportProjects")

    /// A single song, exported in the formats SongExportService offers. Advertised
    /// on each song document, not on the project — a note has no song layout to
    /// export, so these appear only for songs.
    static let exportSongTxt = Rel("exportSongTxt")
    static let exportSongPdf = Rel("exportSongPdf")
    static let exportSongDocx = Rel("exportSongDocx")
    static let exportSongEpub = Rel("exportSongEpub")
    /// The lyric as a score rather than as a document to read — and the format
    /// `importDocument` reads back.
    static let exportSongMusicXml = Rel("exportSongMusicXml")

    /// The project's songs gathered into one songbook, in the same formats.
    /// Advertised on the document collection, and only when it holds a song.
    static let exportSongsTxt = Rel("exportSongsTxt")
    static let exportSongsPdf = Rel("exportSongsPdf")
    static let exportSongsDocx = Rel("exportSongsDocx")
    static let exportSongsEpub = Rel("exportSongsEpub")
    static let exportSongsMusicXml = Rel("exportSongsMusicXml")

    /// Replace the set of characters an actor auditions for in a project.
    /// Advertised on a project-scoped actor only — auditions have no meaning
    /// without a project. The audition character ids ride on the same resource.
    static let setAuditions = Rel("setAuditions")

    static let headshot = Rel("headshot")
    static let forgotPassword = Rel("forgotPassword")
    static let resetPassword = Rel("resetPassword")
    static let setHeadshot = Rel("setHeadshot")
    static let removeHeadshot = Rel("removeHeadshot")
    static let documents = Rel("documents")
    static let document = Rel("document")

    /// The same document list narrowed to one kind, advertised beside
    /// `documents` on a project and on the API root. Following these beats
    /// fetching `documents` and filtering here: the server already knows which
    /// is which, and the root's copies come out templated on `{projectId}`.
    static let songs = Rel("songs")
    static let notes = Rel("notes")

    /// The song a lyric collection, edition or snapshot belongs to. A back-link
    /// home from the resources hung beneath it.
    static let song = Rel("song")
    static let insert = Rel("insert")
    static let shareEmail = Rel("shareEmail")
    static let importDocument = Rel("importDocument")
    static let importScript = Rel("importScript")

    /// New order for a project's songs & notes, advertised on the document
    /// collection for an editor. The client posts the ids in their new sequence.
    static let reorder = Rel("reorder")

    /// Copy a song or note into a new document titled "… (copy)", and switch a
    /// document between song and note. Both are advertised on the document
    /// itself for an editor. Note the rel names are camel-cased while the paths
    /// they point at are kebab-cased — the name is what counts here.
    static let duplicate = Rel("duplicate")
    static let changeType = Rel("changeType")

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

    /// How many comments each element carries, for the whole script at once.
    /// Advertised on a non-empty block collection, and to readers as well as
    /// editors — seeing where the discussion is needs only read access.
    static let commentCounts = Rel("commentCounts")
    static let activity = Rel("activity")
    static let invitations = Rel("invitations")
    static let sendInvitation = Rel("sendInvitation")
    static let revoke = Rel("revoke")

    /// Who can already see a project, which is a different question from who
    /// has been invited to it: a role or a team grants access with no
    /// invitation involved, so the invitation list alone never answers it.
    /// Advertised on every project the caller can open, invitations or not.
    static let access = Rel("access")

    /// Names known to this project, offered while typing an invite address so
    /// the sender need not remember the email. Scoped to the project, so it is
    /// not a directory of everyone.
    static let contactSuggestions = Rel("contactSuggestions")

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

    /// A song's editions. Named apart from `editions` because a song hangs its
    /// own collection off the document rather than the project, but the
    /// resource on the other end is shaped exactly like a script edition —
    /// `ScriptEdition` decodes both, and `CreateEditionCommand` and
    /// `RenameEditionCommand` write to both, which is why there is no separate
    /// song edition type. The server reuses its request records the same way.
    ///
    /// `setDefault` and `setPublished` above are advertised on a song edition
    /// too, and song snapshots arrive as `ProjectVersion` under the `versions`
    /// rel — a song version reports `title` and `lineCount` where a screenplay
    /// reports scenes and elements, and that model already carries both.
    static let songEditions = Rel("songEditions")
    static let songEdition = Rel("songEdition")

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
