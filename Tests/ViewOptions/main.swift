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

    print("")
    print("Remembering the edition")
    do {
        let store = scratch("edition")
        let options = ScriptViewOptions(projectId: 7, defaults: store)
        check("nothing remembered to begin with", options.rememberedEditionId == nil, true)

        options.editionId = 3
        check("the choice lands in the web's key",
              store.object(forKey: "scripty-edition-project-7") as? Int ?? -1, 3)
        check("reopening the project offers it back",
              ScriptViewOptions(projectId: 7, defaults: store).rememberedEditionId ?? -1, 3)
        // One project's revision is not another's.
        check("it is remembered per project",
              ScriptViewOptions(projectId: 8, defaults: store).rememberedEditionId == nil, true)

        // Back to the default: forgotten rather than stored, since which
        // edition is default is the server's to change.
        options.editionId = nil
        check("going back to the default forgets",
              store.object(forKey: "scripty-edition-project-7") == nil, true)
        check("and reopening lands on the default",
              ScriptViewOptions(projectId: 7, defaults: store).rememberedEditionId == nil, true)

        // Opening straight into an edition must not clear what is stored:
        // property observers do not run during init, which is what keeps
        // `ScriptView` from wiping the key before it has read it.
        options.editionId = 5
        let reopened = ScriptViewOptions(projectId: 7, editionId: 5, defaults: store)
        check("opening in an edition leaves the key alone",
              reopened.rememberedEditionId ?? -1, 5)
    }

    print("")
    print("Where the writer left off")
    do {
        let store = scratch("position")
        let options = ScriptViewOptions(projectId: 7, defaults: store)
        check("nothing remembered to begin with", options.rememberedBlockId == nil, true)

        options.rememberBlock(42)
        check("the element lands in the web's key",
              store.object(forKey: "scripty-editor-position-project-7") as? Int ?? -1, 42)
        check("reopening the script offers it back",
              ScriptViewOptions(projectId: 7, defaults: store).rememberedBlockId ?? -1, 42)
        check("it is remembered per project",
              ScriptViewOptions(projectId: 8, defaults: store).rememberedBlockId == nil, true)

        // Tapping away from the text is not leaving the script, so the last
        // place the writer actually was must survive it.
        options.rememberBlock(nil)
        check("losing focus does not forget", options.rememberedBlockId ?? -1, 42)

        options.rememberBlock(43)
        check("moving on overwrites", options.rememberedBlockId ?? -1, 43)
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
