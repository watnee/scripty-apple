//
//  LastOpenedProject.swift
//  scripty
//
//  Which screenplay this device had open, so relaunching lands back in the
//  script rather than on the "Select a Project" pane. The place *inside* that
//  script is `ScriptViewOptions`' remembered element; this is the step before
//  it, and without it that one never gets a chance to run.
//
//  One record for the device, but stamped with the workspace it was written in.
//  The id on its own is not enough to tell workspaces apart: a local session and
//  a fresh account both number their screenplays from 1, so a writer who signs
//  in after working without an account would be dropped into whichever of
//  *their* screenplays happened to be number 3. The stamp is what makes a
//  record from somewhere else read as no record at all.
//
//  Within a workspace an id can still go stale — a screenplay since deleted —
//  and that case needs nothing: it is simply not found in the list that comes
//  back, and the app opens as it always did.
//
//  This client's own key. The web has no counterpart to mirror: a browser
//  reopens whatever URL the tab was left on, which is the same idea arrived at
//  for free. Kept in the `scripty-…` family as its neighbours.
//

import Foundation

@MainActor
struct LastOpenedProject {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The project to reopen, or nil when the writer left the app on the
    /// projects list — or left it in a different workspace entirely.
    func projectId(in workspace: String) -> Int? {
        guard defaults.string(forKey: Self.workspaceKey) == workspace else { return nil }
        return defaults.object(forKey: Self.key) as? Int
    }

    /// Called as the selection changes. Nil is stored as "nothing open" rather
    /// than ignored: on iPhone, going back to the list is a deliberate way of
    /// closing the script, and relaunching straight back into it would undo a
    /// thing the writer just did. (The element position inside a script takes
    /// the opposite view for the opposite reason — tapping out of the text is
    /// not leaving the page.)
    func remember(_ projectId: Int?, in workspace: String) {
        defaults.set(workspace, forKey: Self.workspaceKey)
        if let projectId {
            defaults.set(projectId, forKey: Self.key)
        } else {
            defaults.removeObject(forKey: Self.key)
        }
    }

    private static let key = "scripty-last-project"
    private static let workspaceKey = "scripty-last-project-workspace"
}
