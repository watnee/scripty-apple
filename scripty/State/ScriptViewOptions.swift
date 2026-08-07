//
//  ScriptViewOptions.swift
//  scripty
//
//  What the script page shows, and whether it can be typed into: the marker
//  badges, the note blocks, and the editing lock. The web app's counterpart is
//  `scriptyInitBlockMarkerToggles` in nav.html, and these use its localStorage
//  keys so the intent stays traceable between the two clients.
//
//  Scoped to one project rather than to the device, again as the web does: a
//  writer marking up a rehearsal draft wants the pins on there and nowhere
//  else. The editing lock goes one narrower still — per edition, falling back
//  to the project — because locking the shooting draft while a revision stays
//  open is the point of having editions at all.
//
//  Nothing here reaches the server. These are choices about looking, not about
//  the script, so there is no link to gate them on and no request to make.
//

import Foundation
import Observation

@Observable
@MainActor
final class ScriptViewOptions {
    private let projectId: Int
    private let defaults: UserDefaults

    /// The edition currently open, when the project has more than one. Only the
    /// editing lock is scoped this narrowly; the markers are a property of the
    /// project however it is sliced.
    var editionId: Int? {
        didSet {
            guard editionId != oldValue else { return }
            isEditingLocked = readLock()
            rememberEdition()
        }
    }

    /// The edition this project was last read in, so reopening it lands back in
    /// the revision that was actually being written rather than in the default
    /// draft. The web does the same thing from the other end: `project/show`
    /// redirects to the remembered `editionId` when the URL names none.
    ///
    /// Read once when the script opens. An id the server no longer lists simply
    /// will not be found among the editions, so a deleted revision falls back
    /// to the default rather than to an empty script.
    var rememberedEditionId: Int? {
        defaults.object(forKey: Self.editionKey(project: projectId)) as? Int
    }

    /// Going back to the default forgets the choice rather than storing the
    /// default's own id: the default is whatever the server currently calls
    /// one, and pinning today's answer would outlive it.
    private func rememberEdition() {
        let key = Self.editionKey(project: projectId)
        if let editionId {
            defaults.set(editionId, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Markers

    /// Whether the pin badge is drawn on the elements carrying one.
    ///
    /// The web hides pins and bookmarks until asked; this client has always
    /// drawn them, and an update that silently took them away would read as a
    /// bug rather than as a preference. So an unset key keeps them — once
    /// either client writes the key, both agree on what it means.
    var showsPins: Bool {
        didSet { defaults.set(showsPins, forKey: Self.markerKey("pins", project: projectId)) }
    }

    var showsBookmarks: Bool {
        didSet { defaults.set(showsBookmarks, forKey: Self.markerKey("bookmarks", project: projectId)) }
    }

    /// Names each element's type down the left margin. Off by default in both
    /// clients: the indentation already says what a line is, and the labels are
    /// for the writer who is reformatting rather than writing.
    var showsElementLabels: Bool {
        didSet {
            defaults.set(showsElementLabels,
                         forKey: Self.markerKey("element-labels", project: projectId))
        }
    }

    /// Note elements are content, not chrome, so they show unless hidden —
    /// which is what the web means by defaulting this one on.
    var showsNotes: Bool {
        didSet { defaults.set(showsNotes, forKey: Self.markerKey("notes", project: projectId)) }
    }

    // MARK: - Where the writer left off

    /// The element the writer was last working on, so reopening a long script
    /// lands where they stopped instead of at FADE IN.
    ///
    /// The web keeps a whole caret position here — block, selection range and
    /// scroll offset — because it is restoring a specific textarea in a
    /// specific window. Only the element travels here: a pixel offset means
    /// nothing across a rotation or a different device, and the row is the
    /// anchor that survives both. Storage is this app's own, so the shapes
    /// never meet; the key name is shared to keep the intent traceable.
    var rememberedBlockId: Int? {
        defaults.object(forKey: Self.positionKey(project: projectId)) as? Int
    }

    /// Called as the writer moves through the script. Nil is ignored rather
    /// than stored: putting the cursor away is not the same as leaving, and
    /// forgetting then would lose the position on the way out.
    func rememberBlock(_ blockId: Int?) {
        guard let blockId else { return }
        defaults.set(blockId, forKey: Self.positionKey(project: projectId))
    }

    // MARK: - Outline list

    /// Which list the outline sheet last showed — its Outline, Characters,
    /// Locations, Songs, Bookmarks or Pins tab — so reopening it lands back on
    /// the list the writer was working from rather than resetting to Outline.
    ///
    /// The web keeps a separate open/closed flag per side panel
    /// (`scripty-fountain-character-list`, `…-location-list`, and so on), all
    /// device-wide; this client collapses those panels into one sheet that shows
    /// a single list at a time, so the faithful analog is "which tab", one stored
    /// value rather than six. It is scoped to the project like the remembered
    /// edition and position beside it — a writer casting one draft and blocking
    /// another wants each to reopen on the list it was left on. Stored as the
    /// tab's raw name; an unrecognised or absent value falls back to Outline,
    /// which the caller supplies by treating nil as the default.
    var rememberedOutlineTab: String? {
        defaults.string(forKey: Self.outlineTabKey(project: projectId))
    }

    func rememberOutlineTab(_ tab: String) {
        defaults.set(tab, forKey: Self.outlineTabKey(project: projectId))
    }

    // MARK: - Songs & Notes list

    /// Which of the two lists the Songs & Notes screen last showed, so reopening
    /// it lands on the one the writer works in rather than always on Songs.
    ///
    /// It was written because one toolbar button had to pick a list and always
    /// picked Songs, costing a writer working from the notes a segment tap
    /// every single trip. The bar carries one button again, and this is what
    /// stops it picking Songs: the button reads this at the tap and opens what
    /// it finds. The routes that mean a particular list — the quick actions, a
    /// widget row, the menu bar's two items — still name it and never consult
    /// this. Scoped to the project like the outline tab beside it: a musical is
    /// a songs project and the drama next to it is a notes project, and each
    /// should reopen as it was left.
    ///
    /// Stored as the type's raw server value, and read back the same way the
    /// outline tab is — an absent or unrecognised value is nil, and the caller
    /// supplies the default by treating it as "Songs".
    var rememberedDocumentList: String? {
        defaults.string(forKey: Self.documentListKey(project: projectId))
    }

    func rememberDocumentList(_ type: String) {
        defaults.set(type, forKey: Self.documentListKey(project: projectId))
    }

    // MARK: - Editing lock

    /// Read-only until unlocked. A private setter because the value depends on
    /// which edition is open, and adopting the project's lock when an edition
    /// has none of its own must not write that inherited value back.
    private(set) var isEditingLocked: Bool

    func setEditingLocked(_ locked: Bool) {
        guard locked != isEditingLocked else { return }
        isEditingLocked = locked
        defaults.set(locked, forKey: lockKey())
    }

    // MARK: - Storage

    /// The web's localStorage keys, project-scoped exactly as they are there.
    private static func markerKey(_ marker: String, project: Int) -> String {
        "scripty-show-block-\(marker)-project-\(project)"
    }

    private static func editionKey(project: Int) -> String {
        "scripty-edition-project-\(project)"
    }

    private static func positionKey(project: Int) -> String {
        "scripty-editor-position-project-\(project)"
    }

    /// This client's own key — the web has no single "which list" preference to
    /// mirror, since it tracks each panel separately. Kept project-scoped and in
    /// the same `scripty-…-project-<id>` family as its neighbours.
    private static func outlineTabKey(project: Int) -> String {
        "scripty-outline-list-tab-project-\(project)"
    }

    /// This client's own key too — the web reaches Songs and Notes as two
    /// separate pages, so it has no "which list" to remember. Same family and
    /// same project scoping as the outline tab above.
    private static func documentListKey(project: Int) -> String {
        "scripty-document-list-project-\(project)"
    }

    private static func lockKey(edition: Int) -> String {
        "scripty-block-edit-locked-edition-\(edition)"
    }

    private static func lockKey(project: Int) -> String {
        "scripty-block-edit-locked-project-\(project)"
    }

    /// Where a change to the lock is written: the edition when one is open, so
    /// locking a revision leaves the default draft as it was.
    private func lockKey() -> String {
        if let editionId { return Self.lockKey(edition: editionId) }
        return Self.lockKey(project: projectId)
    }

    /// An edition with no lock of its own inherits the project's, so opening a
    /// revision of a locked script does not hand back the keyboard.
    private func readLock() -> Bool {
        if let editionId,
           let own = defaults.object(forKey: Self.lockKey(edition: editionId)) as? Bool {
            return own
        }
        return defaults.bool(forKey: Self.lockKey(project: projectId))
    }

    init(projectId: Int, editionId: Int? = nil, defaults: UserDefaults = .standard) {
        self.projectId = projectId
        self.editionId = editionId
        self.defaults = defaults

        // `object(forKey:)` rather than `bool(forKey:)` throughout, so "never
        // chosen" keeps the documented default instead of collapsing to false.
        func stored(_ marker: String, or fallback: Bool) -> Bool {
            defaults.object(forKey: Self.markerKey(marker, project: projectId)) as? Bool ?? fallback
        }
        showsPins = stored("pins", or: true)
        showsBookmarks = stored("bookmarks", or: true)
        showsElementLabels = stored("element-labels", or: false)
        showsNotes = stored("notes", or: true)

        isEditingLocked = false
        isEditingLocked = readLock()
    }
}
