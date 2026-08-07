//
//  Rel.swift
//  scripty
//
//  Link relation names advertised by the Scripty API.
//  Mirrors ApiRel.java on the server — the one deliberate coupling point.
//

import Foundation

/// `nonisolated` because a rel name is a string constant, not state. The target
/// defaults to MainActor, which made every one of the constants below
/// MainActor-isolated — so naming one from anywhere else warned, including from
/// a plain default argument (`TrashModel.init`, whose `restoreRel: Rel = .restore`
/// is evaluated in the caller's isolation and could not know what that is).
nonisolated struct Rel: RawRepresentable, Hashable, Sendable {
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
    // Replace one occurrence in one block — the single-step "Replace", advertised
    // per block. Its "Replace All" sibling is `bulkReplace` on the collection.
    static let replace = Rel("replace")

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

    /// The same archive read back into a project that already exists, rather
    /// than into a new one. Advertised on a project the caller can edit.
    ///
    /// This is what keeps a screenplay one screenplay across signing in and out.
    /// A device with no account writes locally and hands the account a copy;
    /// afterwards both copies are live, and words written on the device while
    /// signed out have nowhere to go — `importProject` can only ever make a
    /// second screenplay out of them. See `AppModel.syncLinkedProjects`.
    static let replaceFromArchive = Rel("replaceFromArchive")

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
    /// The lyric as a score, for setting to music in a notation program. The
    /// odd one out among the song exports: the others are documents to read,
    /// this one is meant to be opened and worked on — and it is the format
    /// `importDocument` reads back, so a song can make the round trip through
    /// MuseScore or Finale and come home.
    static let exportSongMusicXml = Rel("exportSongMusicXml")

    /// The project's songs gathered into one songbook, in the same formats.
    /// Advertised on the document collection, and only when it holds a song.
    static let exportSongsTxt = Rel("exportSongsTxt")
    static let exportSongsPdf = Rel("exportSongsPdf")
    static let exportSongsDocx = Rel("exportSongsDocx")
    static let exportSongsEpub = Rel("exportSongsEpub")

    /// Every song as sections of one score. MusicXML has no notion of a second
    /// piece in the same file, so the songbook becomes one score in which each
    /// song is a titled section on its own page.
    static let exportSongsMusicXml = Rel("exportSongsMusicXml")

    /// The same gathering made of the project's notes, advertised on the
    /// document collection when it holds one. Rels of their own rather than the
    /// songbook's, because the two lists export separately and a screen showing
    /// one of them has to know which href is its — the two differ only by the
    /// `type` on the query.
    ///
    /// There is no MusicXML twin here on purpose: a score of scene notes is not
    /// a thing, and the server refuses it.
    static let exportNotesTxt = Rel("exportNotesTxt")
    static let exportNotesPdf = Rel("exportNotesPdf")
    static let exportNotesDocx = Rel("exportNotesDocx")
    static let exportNotesEpub = Rel("exportNotesEpub")

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

    /// The document itself, as an item in a collection of something else —
    /// the archive rows follow it to open the song or note behind one.
    static let document = Rel("document")

    /// The song a lyric collection, edition or snapshot belongs to. A back-link
    /// home from the resources hung beneath it.
    static let song = Rel("song")
    static let insert = Rel("insert")
    static let shareEmail = Rel("shareEmail")
    static let bulkShareEmail = Rel("bulkShareEmail")
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

    /// Folders: the headings a writer files a list's songs or notes under.
    ///
    /// `folders` is the collection, advertised on the document collection and
    /// scoped by the list it belongs to — a folder is a Songs folder or a Notes
    /// folder, never both, so the two lists never see each other's. It comes to
    /// anyone who can read the list, not only to editors: where a song is filed
    /// is part of how the list reads.
    ///
    /// `createFolder` rides on that collection (advertised even when empty —
    /// that is when somewhere to send the first one is most needed);
    /// `renameFolder` and `deleteFolder` ride on a folder, so the controls are
    /// drawn only where the server would take them.
    ///
    /// `moveToFolder` is on the *document*: a folder holds nothing, and what a
    /// move changes is which folder this document is in. One rel for both
    /// directions — the same call with no folder id takes it out.
    /// `bulkMoveToFolder` is the selection form, on the document collection
    /// beside the other bulk rels.
    static let folders = Rel("folders")
    static let createFolder = Rel("createFolder")
    static let renameFolder = Rel("renameFolder")
    static let deleteFolder = Rel("deleteFolder")
    static let moveToFolder = Rel("moveToFolder")
    static let bulkMoveToFolder = Rel("bulkMoveToFolder")

    /// Putting a song or note aside without deleting it. Deliberately not the
    /// trash: nothing in the archive expires, an archived document is still
    /// whole and openable, and it stays in a project bundle export — it is only
    /// kept out of the list.
    ///
    /// `archived` is the collection it went to (on the document collection, for
    /// an editor, advertised even when empty); `archive` and `unarchive` are the
    /// two directions, and `bulkArchive`/`bulkUnarchive` the selection form of
    /// each. Unlike `bulkDelete` none of these needs the project to hold a song
    /// — notes archive too.
    ///
    /// The two bulk rels are advertised on different collections, because the
    /// two selections are made in different places: a set to archive is ticked
    /// in the list, a set to bring back is ticked in the archive. So
    /// `bulkUnarchive` arrives on the *archive* collection, not on its items —
    /// and only when there is something in there to tick.
    ///
    /// `archive` and `unarchive` are never both advertised on one document. An
    /// archived song or note is still opened and edited by id, so an editor can
    /// be looking at one, and there the only useful direction is back.
    static let archive = Rel("archive")
    static let unarchive = Rel("unarchive")
    static let archived = Rel("archived")
    static let bulkArchive = Rel("bulkArchive")
    static let bulkUnarchive = Rel("bulkUnarchive")

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

    /// The teams a collaborator can be invited into. Inviting an editor needs
    /// a team, and only the project's own teams are valid choices, so without
    /// this list the "Can edit" invitation cannot be sent at all. Advertised on
    /// the invitation collection even when the project has no teams — an empty
    /// list is the answer that tells the sender to assign one first.
    static let inviteTeams = Rel("inviteTeams")

    /// Every team the writer could assign this project to, each flagged whether
    /// it is assigned now — the project side of the web production page's team
    /// checkboxes. Distinct from `inviteTeams`, which lists only the teams the
    /// project already has; this lists the whole roster so a box can be ticked.
    /// Advertised only to an editor; the write rides on `update`'s `teamIds`.
    static let projectTeams = Rel("projectTeams")

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

    /// The recordings kept with a song — the voice memo the tune was first sung
    /// into, the demo, the reference track.
    ///
    /// `audioRecordings` hangs off the song document and off songs only: a note
    /// has nothing to hear. It arrives whether or not there are any, and for a
    /// reader as well as an editor — listening needs no permission to write —
    /// so its absence means the server has never heard of recordings, which is
    /// how this client decides whether to draw them at all.
    ///
    /// `uploadAudio` rides on that collection; `renameAudio` and `deleteAudio`
    /// ride on a take, all three behind the edit gate. `audioFile` is the one
    /// href in the vocabulary that answers with something other than JSON, and
    /// every use of a recording — playing it, saving it, sharing it — is that
    /// one link.
    static let audioRecordings = Rel("audioRecordings")
    static let uploadAudio = Rel("uploadAudio")
    static let audioFile = Rel("audioFile")
    static let renameAudio = Rel("renameAudio")
    static let deleteAudio = Rel("deleteAudio")

    // Named variants of a script or a song.
    /// A screenplay's editions, hung off the project — and a song's, hung off
    /// the document. One rel for both: the resource on the other end is shaped
    /// exactly like a script edition, `ScriptEdition` decodes both, and
    /// `CreateEditionCommand` and `RenameEditionCommand` write to both, which
    /// is why there is no separate song edition type. The server reuses its
    /// request records the same way.
    ///
    /// `setDefault` and `setPublished` below are advertised on a song edition
    /// too, and song snapshots arrive as `ProjectVersion` under the `versions`
    /// rel — a song version reports `title` and `lineCount` where a screenplay
    /// reports scenes and elements, and that model already carries both.
    ///
    /// There is no `songEditions` link rel, though there was a constant for
    /// one here for a while. `songEditions` is the server's *collection* name
    /// inside `_embedded` (`SongEditionResource`'s `@Relation`), which
    /// `HALCollection` reads key-agnostically — the same mistake `songEdition`
    /// was, and removed for the same reason.
    static let editions = Rel("editions")
    static let setDefault = Rel("setDefault")
    static let setPublished = Rel("setPublished")

    // The signed-in user's own account — advertised on the API root to anyone
    // signed in, unlike the admin-only `users`. `passkeys` appears only where
    // the deployment has passkeys configured.
    static let account = Rel("account")
    static let changePassword = Rel("changePassword")
    static let passkeys = Rel("passkeys")

    // The WebAuthn ceremonies, opened to this client by the API. Each rel
    // points at an options endpoint whose response carries a `verify` link for
    // the ceremony's second half. `registerPasskey` rides on the passkeys
    // collection; `passkeyLogin` rides on the signed-out 401 challenge (the one
    // document an anonymous caller sees, like `forgotPassword`); a verified
    // sign-in answers with a bearer token whose `revokeToken` link is the
    // API's sign-out.
    static let registerPasskey = Rel("registerPasskey")
    static let passkeyLogin = Rel("passkeyLogin")
    static let verify = Rel("verify")
    static let revokeToken = Rel("revokeToken")

    // Editor preferences the server keeps because exports bake them in.
    // Advertised on the API root; `update` (declared above) posts a change.
    static let capitalizationPreferences = Rel("capitalizationPreferences")
}
