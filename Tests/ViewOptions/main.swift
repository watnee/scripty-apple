//
//  ScriptViewOptions checks
//
//  The whole feature is persistence semantics — which key a choice lands in,
//  and what an absent key means — so that is what is worth pinning. The keys
//  are the web app's, and the awkward one is the editing lock: it is written
//  per edition but inherited from the project, and getting that backwards
//  either hands the keyboard back on a locked script or locks a draft the
//  writer never locked.
//
//  Run via Tests/run.sh.
//

import Foundation

var failures = 0

func check(_ label: String, _ actual: some Equatable, _ expected: some Equatable) {
    if "\(actual)" == "\(expected)" {
        print("  PASS  \(label)")
    } else {
        failures += 1
        print("  FAIL  \(label) — expected \(expected), got \(actual)")
    }
}

/// A throwaway store per case, so one check cannot colour the next.
func scratch(_ name: String) -> UserDefaults {
    let suite = "scripty.tests.viewoptions.\(name)"
    UserDefaults.standard.removePersistentDomain(forName: suite)
    return UserDefaults(suiteName: suite)!
}

@MainActor
func run() {
    print("Defaults")
    do {
        let options = ScriptViewOptions(projectId: 7, defaults: scratch("defaults"))
        // Marks this client has always drawn stay drawn until asked otherwise.
        check("pins show", options.showsPins, true)
        check("bookmarks show", options.showsBookmarks, true)
        // Labels are off in both clients; notes are content, so they are on.
        check("element labels hidden", options.showsElementLabels, false)
        check("notes show", options.showsNotes, true)
        check("editing unlocked", options.isEditingLocked, false)
    }

    print("")
    print("Marker keys")
    do {
        let store = scratch("markers")
        let options = ScriptViewOptions(projectId: 7, defaults: store)
        options.showsPins = false
        options.showsElementLabels = true
        check("pins land in the web's key",
              store.object(forKey: "scripty-show-block-pins-project-7") as? Bool ?? true, false)
        check("labels land in the web's key",
              store.object(forKey: "scripty-show-block-element-labels-project-7") as? Bool ?? false,
              true)

        let reopened = ScriptViewOptions(projectId: 7, defaults: store)
        check("the choice survives reopening", reopened.showsPins, false)
        check("labels survive too", reopened.showsElementLabels, true)

        // Marking up one draft must leave the others alone.
        let other = ScriptViewOptions(projectId: 8, defaults: store)
        check("another project is unaffected", other.showsPins, true)
    }

    print("")
    print("Editing lock")
    do {
        let store = scratch("lock")
        let project = ScriptViewOptions(projectId: 7, defaults: store)
        project.setEditingLocked(true)
        check("with no edition open it locks the project",
              store.object(forKey: "scripty-block-edit-locked-project-7") as? Bool ?? false, true)

        // An edition with no lock of its own inherits the project's, so opening
        // a revision of a locked script does not hand back the keyboard.
        let revision = ScriptViewOptions(projectId: 7, editionId: 3, defaults: store)
        check("an edition inherits the project's lock", revision.isEditingLocked, true)

        // Unlocking the revision is about the revision, not the script.
        revision.setEditingLocked(false)
        check("unlocking writes the edition's own key",
              store.object(forKey: "scripty-block-edit-locked-edition-3") as? Bool ?? true, false)
        check("the project's lock is left alone",
              store.object(forKey: "scripty-block-edit-locked-project-7") as? Bool ?? false, true)
        check("reopening the revision reads its own key",
              ScriptViewOptions(projectId: 7, editionId: 3, defaults: store).isEditingLocked, false)
        check("reopening the default draft is still locked",
              ScriptViewOptions(projectId: 7, defaults: store).isEditingLocked, true)
    }

    print("")
    print("Switching edition")
    do {
        let store = scratch("switch")
        let options = ScriptViewOptions(projectId: 7, defaults: store)
        options.setEditingLocked(true)
        options.editionId = 3
        check("the switch re-reads the lock", options.isEditingLocked, true)
        // Adopting the project's lock must not write it to the edition, or the
        // revision would be pinned to whatever the project happened to be.
        check("adopting does not write the edition's key",
              store.object(forKey: "scripty-block-edit-locked-edition-3") == nil, true)
    }
}

MainActor.assumeIsolated { run() }

print("")
if failures == 0 {
    print("View option checks passed.")
    exit(0)
} else {
    print("\(failures) view option check(s) FAILED.")
    exit(1)
}
