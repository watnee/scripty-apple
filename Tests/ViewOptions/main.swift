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

    print("")
    print("Song editing lock")
    do {
        let store = scratch("songlock")
        let song = DocumentViewOptions(documentId: 11, defaults: store)
        check("a song opens unlocked", song.isEditingLocked, false)

        song.setEditingLocked(true)
        check("with no edition open it locks the song",
              store.object(forKey: "scripty-song-edit-locked-document-11") as? Bool ?? false, true)
        // Its own key family: a song edition and a script edition are different
        // things, and one must never lock the other.
        check("it does not touch the screenplay's key",
              store.object(forKey: "scripty-block-edit-locked-project-11") == nil, true)
        // Songs are locked one at a time, as each is finished.
        check("another song is unaffected",
              DocumentViewOptions(documentId: 12, defaults: store).isEditingLocked, false)
        check("reopening the song is still locked",
              DocumentViewOptions(documentId: 11, defaults: store).isEditingLocked, true)

        // An edition with no lock of its own inherits the song's, so opening a
        // rewrite of a locked lyric does not hand back the keyboard.
        let rewrite = DocumentViewOptions(documentId: 11, editionId: 4, defaults: store)
        check("an edition inherits the song's lock", rewrite.isEditingLocked, true)

        rewrite.setEditingLocked(false)
        check("unlocking writes the edition's own key",
              store.object(forKey: "scripty-song-edit-locked-edition-4") as? Bool ?? true, false)
        check("the song's lock is left alone",
              store.object(forKey: "scripty-song-edit-locked-document-11") as? Bool ?? false, true)
        check("reopening the rewrite reads its own key",
              DocumentViewOptions(documentId: 11, editionId: 4, defaults: store).isEditingLocked, false)
        check("reopening the default lyric is still locked",
              DocumentViewOptions(documentId: 11, defaults: store).isEditingLocked, true)
    }

    print("")
    print("Switching song edition")
    do {
        let store = scratch("songswitch")
        let options = DocumentViewOptions(documentId: 11, defaults: store)
        options.setEditingLocked(true)
        options.editionId = 4
        check("the switch re-reads the lock", options.isEditingLocked, true)
        // Adopting the song's lock must not write it to the edition, or the
        // rewrite would be pinned to whatever the song happened to be.
        check("adopting does not write the edition's key",
              store.object(forKey: "scripty-song-edit-locked-edition-4") == nil, true)
    }

    print("")
    print("Note editing lock")
    do {
        let store = scratch("notelock")
        let note = DocumentViewOptions(documentId: 11, kind: .note, defaults: store)
        check("a note opens unlocked", note.isEditingLocked, false)

        note.setEditingLocked(true)
        check("it lands in the note's own key",
              store.object(forKey: "scripty-note-edit-locked-document-11") as? Bool ?? false,
              true)
        // The two families are kept apart so a key says what it locks. Songs
        // and notes cannot in fact share an id — the server numbers all its
        // documents from one sequence — but a lock that could reach across
        // kinds if they ever did is a lock nobody can reason about.
        check("and nowhere near the song's",
              store.object(forKey: "scripty-song-edit-locked-document-11") == nil, true)
        check("so a song with that number is still open",
              DocumentViewOptions(documentId: 11, defaults: store).isEditingLocked, false)
        check("reopening the note is still locked",
              DocumentViewOptions(documentId: 11, kind: .note, defaults: store).isEditingLocked,
              true)

        note.setEditingLocked(false)
        check("unlocking hands the keyboard back",
              DocumentViewOptions(documentId: 11, kind: .note, defaults: store).isEditingLocked,
              false)
    }

    print("")
    print("Songs workspace open set")
    do {
        let store = scratch("workspace")
        let state = SongWorkspaceOpenState(projectId: 7, defaults: store)
        check("a fresh workspace opens collapsed", state.load().isEmpty, true)

        state.save([3, 1, 2])
        // Compared as a sorted array, not the set itself: `check` stringifies
        // its arguments, and a Set's description order is randomised per run,
        // so `\(Set([1,2,3]))` alone made this pass or fail by luck.
        check("the open set survives reopening",
              SongWorkspaceOpenState(projectId: 7, defaults: store).load().sorted(), [1, 2, 3])
        check("it lands in the web's dot-spelled key",
              store.string(forKey: "scripty.songWorkspace.open.7") ?? "", "[1,2,3]")
        check("it is remembered per project",
              SongWorkspaceOpenState(projectId: 8, defaults: store).load().isEmpty, true)

        // Collapsing everything is a real state, distinct from never having
        // opened the workspace — both read back as empty, which is what matters.
        state.save([])
        check("collapsing all is remembered as empty",
              SongWorkspaceOpenState(projectId: 7, defaults: store).load().isEmpty, true)

        // A hand-written or corrupt value must not throw; it just opens fresh.
        store.set("not json", forKey: "scripty.songWorkspace.open.7")
        check("unreadable storage opens collapsed",
              SongWorkspaceOpenState(projectId: 7, defaults: store).load().isEmpty, true)
    }

    print("")
    print("Remembered outline tab")
    do {
        let store = scratch("outlinetab")
        let options = ScriptViewOptions(projectId: 7, defaults: store)
        // A first open has no stored list — the view reads nil and shows Outline.
        check("nothing remembered to begin with", options.rememberedOutlineTab == nil, true)

        options.rememberOutlineTab("characters")
        check("the chosen list lands in this client's key",
              store.string(forKey: "scripty-outline-list-tab-project-7") ?? "", "characters")
        check("it reads back on reopen",
              ScriptViewOptions(projectId: 7, defaults: store).rememberedOutlineTab ?? "", "characters")
        // Scoped to the project, like the remembered edition and position.
        check("it is remembered per project",
              ScriptViewOptions(projectId: 8, defaults: store).rememberedOutlineTab == nil, true)
    }

    print("")
    print("Remembered Songs & Notes list")
    do {
        let store = scratch("documentlist")
        let options = ScriptViewOptions(projectId: 7, defaults: store)
        // Nothing remembered means Songs, which the screen supplies by treating
        // nil as the default — the same contract the outline tab has.
        check("nothing remembered to begin with", options.rememberedDocumentList == nil, true)

        // The server's own spelling for the type, so what lands in storage is
        // the value the screen decodes back into a list rather than a label.
        options.rememberDocumentList("NOTES")
        check("the chosen list lands in this client's key",
              store.string(forKey: "scripty-document-list-project-7") ?? "", "NOTES")
        check("it reads back on reopen",
              ScriptViewOptions(projectId: 7, defaults: store).rememberedDocumentList ?? "", "NOTES")

        // A writer with a musical and a drama open should not have the one
        // teach the other which half of the screen they work in.
        check("it is remembered per project",
              ScriptViewOptions(projectId: 8, defaults: store).rememberedDocumentList == nil, true)

        options.rememberDocumentList("SONG")
        check("switching back overwrites",
              ScriptViewOptions(projectId: 7, defaults: store).rememberedDocumentList ?? "", "SONG")
    }

    print("")
    print("Last opened project")
    do {
        // How `AppModel.workspaceScope` spells an account and a signed-out
        // device. Both number their screenplays from 1, which is the whole
        // reason the record carries one.
        let account = "scripty.example.com|writer"
        let local = "local"

        let store = scratch("lastproject")
        let last = LastOpenedProject(defaults: store)
        // A first run has nothing open, and lands on the projects list.
        check("nothing to reopen to begin with", last.projectId(in: account) == nil, true)

        last.remember(12, in: account)
        check("the screenplay lands in this client's key",
              store.object(forKey: "scripty-last-project") as? Int ?? -1, 12)
        check("relaunching offers it back",
              LastOpenedProject(defaults: store).projectId(in: account) ?? -1, 12)

        last.remember(13, in: account)
        check("opening another replaces it",
              LastOpenedProject(defaults: store).projectId(in: account) ?? -1, 13)

        // The case the stamp is for: signing in must not reopen the account's
        // screenplay number 13 because a local session left off at its own.
        check("a record from another workspace is not offered",
              LastOpenedProject(defaults: store).projectId(in: local) == nil, true)
        last.remember(4, in: local)
        check("the workspace that wrote last is the one that is answered",
              LastOpenedProject(defaults: store).projectId(in: local) ?? -1, 4)
        check("and the one before it no longer is",
              LastOpenedProject(defaults: store).projectId(in: account) == nil, true)

        // Going back to the projects list closes the script — the opposite of
        // what losing focus means inside one, and deliberately so.
        last.remember(nil, in: local)
        check("going back to the list forgets",
              LastOpenedProject(defaults: store).projectId(in: local) == nil, true)
        check("and leaves no key behind",
              store.object(forKey: "scripty-last-project") == nil, true)
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
