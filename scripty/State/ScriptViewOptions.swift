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
