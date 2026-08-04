//
//  OpenEditorState.swift
//  scripty
//
//  What the writer had open when they last put the app down: the project, and
//  the screen they were working in above it. A relaunch comes back to the song
//  they were mid-verse in rather than to the project list.
//
//  This is the sheet-level companion to the position and edition that
//  ScriptViewOptions already remembers. Those answer "where in the script"; a
//  writer who was in the lyric editor was not in the script at all, and being
//  put back at the right element of a screenplay they had left twenty minutes
//  ago is not the same as being put back where they were.
//
//  Only the screens a writer *works in* are remembered: the Songs & Notes list,
//  a song or note editor, the all-songs workspace, the character list, the
//  outline and the title page. The reader, the stats, version history, editions,
//  sharing, the trash and page setup are deliberately not — they are things you
//  glance at or administer and then leave, and an app that reopened talking
//  aloud, or onto a picker nobody was picking from, would be answering a
//  question that was already closed.
//
//  Nothing here reaches the server. It is one device's account of where it was,
//  and it is a single record rather than one per project: restoring is a launch
//  thing, so a second window (or a project switched away from and back to
//  mid-session) simply keeps the script it is already showing.
//
//  The web has no counterpart to mirror — a browser reopens its tabs by URL, so
//  there is nothing stored there — but the keys stay in the `scripty-…` family
//  the rest of the preferences use.
//

import Foundation

/// One screen the writer can have open above the script.
///
/// A path of these is what gets stored, outermost first, because two of them
/// nest: a song editor reached through the Songs & Notes list is two screens
/// deep, and reopening only the editor would strand the writer with no list to
/// go back to.
enum OpenEditor: Equatable {
    /// The Songs & Notes screen, on whichever of its two lists was showing.
    case songsAndNotes(DocumentType)
    /// A song or note in its own editor.
    ///
    /// Two names for it, because after a sign-in or a sign-out only one of them
    /// still means anything. `id` is the number this workspace files it under
    /// and is what reopens it in the ordinary case; `uid` is what the song *is*
    /// (see `TextDocument.uid`), the one name an account and a signed-out device
    /// both know it by. Crossing between the two renumbers everything, so a
    /// record carried across is resolved by uid and falls back to the id.
    ///
    /// Nil uid is a record written by an older build, or a server too old to
    /// publish one: it reopens by id exactly as it always did.
    case document(id: Int, uid: String?)
    /// Every song on one page.
    case songWorkspace
    case characters
    case outline
    case titlePage
}

extension OpenEditor {
    /// How this screen is spelled in storage.
    ///
    /// A word rather than an ordinal, so a defaults dump reads as English and
    /// so reordering the cases above cannot silently repoint an old record at a
    /// different screen.
    var token: String {
        switch self {
        case .songsAndNotes(let type): return "songs-and-notes:\(type.rawValue)"
        // `|` separates the two names. It cannot appear in either — the id is
        // digits and a uid is a uuid — and it is neither of the characters this
        // format already spends (`:` between name and value, `/` between rungs).
        case .document(let id, let uid):
            guard let uid, !uid.isEmpty else { return "document:\(id)" }
            return "document:\(id)|\(uid)"
        case .songWorkspace: return "song-workspace"
        case .characters: return "characters"
        case .outline: return "outline"
        case .titlePage: return "title-page"
        }
    }

    init?(token: String) {
        let name = token.prefix { $0 != ":" }
        let value = token.dropFirst(name.count + 1)
        switch name {
        case "songs-and-notes":
            guard let type = DocumentType(rawValue: String(value)) else { return nil }
            self = .songsAndNotes(type)
        case "document":
            let parts = value.split(separator: "|", maxSplits: 1)
            guard let first = parts.first, let id = Int(first) else { return nil }
            self = .document(id: id, uid: parts.count > 1 ? String(parts[1]) : nil)
        case "song-workspace": self = .songWorkspace
        case "characters": self = .characters
        case "outline": self = .outline
        case "title-page": self = .titlePage
        default: return nil
        }
    }
}

@MainActor
final class OpenEditorState {
    /// Shared because the record spans three views — the project list, the
    /// script, and the Songs & Notes screen inside it — and there is one answer
    /// to "where was I" for the whole app.
    static let shared = OpenEditorState()

    private let defaults: UserDefaults

    /// Whether this launch's record has been handed out yet. Held in memory
    /// rather than written down: it is a fact about this run of the app, not
    /// about the writer.
    private var hasHandedOverPath = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Coming back

    /// The project the writer was last in, if any.
    ///
    /// Stamped with the workspace it was written in, and nil when asked from a
    /// different one. Without that stamp a local session's project 3 and an
    /// account's project 3 are the same record, and signing in would reopen the
    /// songs of a screenplay nobody was looking at — see `AppModel`'s
    /// `workspaceScope`. An id that is merely stale within its own workspace —
    /// a screenplay since deleted — needs no such care: it is simply not found
    /// among the projects, and the list opens as it always did.
    func rememberedProjectId(in workspace: String) -> Int? {
        guard defaults.string(forKey: Key.workspace) == workspace else { return nil }
        return defaults.object(forKey: Key.project) as? Int
    }

    /// The screens that were open above the script, handed over once.
    ///
    /// Asking is what ends the restore. The record goes on being kept as the
    /// writer moves around — it has to, or closing the app a second time would
    /// have nothing to write down — but only the first asker this launch
    /// reopens anything from it.
    ///
    /// Answers empty for any project but the remembered one: a writer who
    /// reached past the restore for a different script has said where they want
    /// to be, and that is not inside the last one's songs.
    func claimReopenPath(forProject projectId: Int, in workspace: String) -> [OpenEditor] {
        guard !hasHandedOverPath else { return [] }
        hasHandedOverPath = true
        guard projectId == rememberedProjectId(in: workspace) else { return [] }
        return storedPath
    }

    /// Moves the record onto the other side of a crossing between the local
    /// workspace and an account, so signing in or out comes back to the song the
    /// writer was in rather than to the screenplay it happens to live in.
    ///
    /// Only the screenplay is translated here, by the caller, which is the only
    /// one that knows which screenplay in the account each local one is. The
    /// songs and notes above it are left exactly as they are: each carries the
    /// name it has in both places (`OpenEditor.document`), and the screen that
    /// reopens it resolves that against the list it is holding — which is the
    /// only place either id is known for certain.
    ///
    /// The handover is opened again on the way through. It is spent once a
    /// launch precisely so a writer who reached past the restore is not dragged
    /// back into last night's song; a crossing is the opposite case — they were
    /// in that song a second ago, and the session changing under them is not
    /// them asking to leave it.
    ///
    /// Nothing is written when the two sides have no such screenplay in common,
    /// or when the record belongs to neither of them.
    func carry(from: String, to: String, translating translate: (Int) -> Int?) {
        guard let there = rememberedProjectId(in: from), let here = translate(there) else { return }
        // A song rung with no uid is the one thing that must not cross. Its id
        // is a number in the workspace being left, and the workspace being
        // entered numbers its songs from 1 as well — so reopening by it would
        // not be the writer's song at all, but whichever of the other side's
        // happened to share a number. Better the list than the wrong lyric, so
        // the path stops there.
        var path: [OpenEditor] = []
        for screen in storedPath {
            if case .document(_, let uid) = screen, uid?.isEmpty ?? true { break }
            path.append(screen)
        }
        defaults.set(to, forKey: Key.workspace)
        defaults.set(here, forKey: Key.project)
        store(path)
        hasHandedOverPath = false
    }

    // MARK: - Keeping the record

    /// Notes which project is open.
    ///
    /// Changing it forgets what was open above it: those screens belong to that
    /// project, and a lyric editor left open in one draft has nothing to reopen
    /// in another. Re-recording the same project deliberately leaves the path
    /// alone, which is what makes a restored selection survive being noticed.
    func rememberProject(_ projectId: Int?, in workspace: String) {
        guard projectId != rememberedProjectId(in: workspace) else { return }
        defaults.set(workspace, forKey: Key.workspace)
        if let projectId {
            defaults.set(projectId, forKey: Key.project)
        } else {
            defaults.removeObject(forKey: Key.project)
        }
        defaults.removeObject(forKey: Key.path)
    }

    /// Notes what is open at `depth` — 0 for a screen above the script, 1 for
    /// one opened from there.
    ///
    /// Anything deeper is dropped, since a screen that closed took whatever it
    /// was showing with it. Nil is how a screen says it has closed.
    func record(_ editor: OpenEditor?, atDepth depth: Int) {
        var path = storedPath
        // Already what is written there, so leave the path as it stands. This
        // is the case that makes restoring work: a reopened screen announces
        // itself on the way up, and truncating on that announcement would throw
        // away the rung it is still in the middle of reopening.
        if depth < path.count, path[depth] == editor { return }
        // Nothing recorded beneath it, so there is nothing for this to be above.
        guard depth <= path.count else { return }
        path.removeSubrange(depth...)
        if let editor { path.append(editor) }
        store(path)
    }

    // MARK: - Storage

    private var storedPath: [OpenEditor] {
        Self.decode(defaults.string(forKey: Key.path))
    }

    private func store(_ path: [OpenEditor]) {
        if path.isEmpty {
            defaults.removeObject(forKey: Key.path)
        } else {
            defaults.set(path.map(\.token).joined(separator: "/"), forKey: Key.path)
        }
    }

    /// A screen this build does not recognise stops the path there rather than
    /// voiding the whole thing: reading a newer version's record should still
    /// reopen as far as it is understood, and the outer screens are the ones
    /// worth getting right.
    static func decode(_ raw: String?) -> [OpenEditor] {
        guard let raw, !raw.isEmpty else { return [] }
        var path: [OpenEditor] = []
        for token in raw.split(separator: "/") {
            guard let editor = OpenEditor(token: String(token)) else { break }
            path.append(editor)
        }
        return path
    }

    private enum Key {
        static let project = "scripty-open-project"
        static let path = "scripty-open-editors"
        static let workspace = "scripty-open-workspace"
    }
}
