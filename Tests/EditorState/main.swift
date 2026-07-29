//
//  Reopening what was left open — storage checks
//
//  The whole feature is storage semantics, and the two rules that matter are
//  the ones that are easy to get backwards.
//
//  The record has to survive being *read*: a restored screen announces itself
//  on the way up, and if re-recording what is already stored counted as a
//  change, the announcement would truncate the path and the song editor two
//  screens deep would never arrive. And it has to be handed over exactly once,
//  or a writer who closes the songs list and opens it again an hour later gets
//  last night's song thrown back at them.
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
    let suite = "scripty.tests.editorstate.\(name)"
    UserDefaults.standard.removePersistentDomain(forName: suite)
    return UserDefaults(suiteName: suite)!
}

let pathKey = "scripty-open-editors"
let projectKey = "scripty-open-project"

@MainActor
func runFirstRun() {
    print("A first run remembers nothing")
    let store = scratch("firstrun")
    let state = OpenEditorState(defaults: store)
    check("no project", state.rememberedProjectId as Int? ?? -1, -1)
    check("no path", state.claimReopenPath(forProject: 7).count, 0)
}

@MainActor
func runRoundTrip() {
    print("")
    print("What was open comes back")
    let store = scratch("roundtrip")
    let writing = OpenEditorState(defaults: store)
    writing.rememberProject(7)
    writing.record(.songsAndNotes(.song), atDepth: 0)
    writing.record(.document(42), atDepth: 1)

    check("stored so it reads as English",
          store.string(forKey: pathKey) ?? "", "songs-and-notes:SONG/document:42")

    // A fresh instance is what the next launch gets.
    let reopening = OpenEditorState(defaults: store)
    check("the project comes back", reopening.rememberedProjectId ?? -1, 7)
    let path = reopening.claimReopenPath(forProject: 7)
    check("both screens come back", path.count, 2)
    check("the list is outermost", path.first == .songsAndNotes(.song), true)
    check("the editor is on top of it", path.last == .document(42), true)
}

@MainActor
func runClaimIsOneShot() {
    print("")
    print("The record is handed over once")
    let store = scratch("oneshot")
    let writing = OpenEditorState(defaults: store)
    writing.rememberProject(7)
    writing.record(.outline, atDepth: 0)

    let state = OpenEditorState(defaults: store)
    check("the first asker gets it", state.claimReopenPath(forProject: 7).count, 1)
    check("the second gets nothing", state.claimReopenPath(forProject: 7).count, 0)
    // Asking must not erase the record — closing the app again has to have
    // something to write over, and a crash before the first record would
    // otherwise lose the place.
    check("but the record is still kept",
          store.string(forKey: pathKey) ?? "", "outline")
}

@MainActor
func runClaimIsPerProject() {
    print("")
    print("Only the remembered project reopens anything")
    let store = scratch("perproject")
    let writing = OpenEditorState(defaults: store)
    writing.rememberProject(7)
    writing.record(.characters, atDepth: 0)

    let state = OpenEditorState(defaults: store)
    check("another script gets nothing", state.claimReopenPath(forProject: 9).count, 0)
    // Still spent: reaching past the restore for a different script is the
    // writer saying where they want to be.
    check("and the restore is over", state.claimReopenPath(forProject: 7).count, 0)
}

@MainActor
func runProjectChange() {
    print("")
    print("Switching project forgets the screens")
    let store = scratch("projectchange")
    let state = OpenEditorState(defaults: store)
    state.rememberProject(7)
    state.record(.songsAndNotes(.notes), atDepth: 0)

    state.rememberProject(9)
    check("the path is dropped", store.string(forKey: pathKey) ?? "—", "—")
    check("the new project is kept", state.rememberedProjectId ?? -1, 9)

    // Deselecting on iPad is a place too, and it is the one the app was left in.
    state.record(.outline, atDepth: 0)
    state.rememberProject(nil)
    check("deselecting forgets the project", state.rememberedProjectId as Int? ?? -1, -1)
    check("and the path with it", store.string(forKey: pathKey) ?? "—", "—")
}

@MainActor
func runReRecordingIsNotAChange() {
    print("")
    print("Re-recording what is already stored leaves the path alone")
    let store = scratch("rerecord")
    let writing = OpenEditorState(defaults: store)
    writing.rememberProject(7)
    writing.record(.songsAndNotes(.song), atDepth: 0)
    writing.record(.document(42), atDepth: 1)

    // The project restore notices the same project it stored. If that counted
    // as a change it would drop the screens it came to reopen.
    let state = OpenEditorState(defaults: store)
    state.rememberProject(7)
    check("the same project keeps the path",
          store.string(forKey: pathKey) ?? "", "songs-and-notes:SONG/document:42")

    // The songs list re-announces itself as the restore opens it. Truncating on
    // that announcement is exactly how the nested editor gets lost.
    state.record(.songsAndNotes(.song), atDepth: 0)
    check("the reopened list keeps the editor above it",
          store.string(forKey: pathKey) ?? "", "songs-and-notes:SONG/document:42")
}

@MainActor
func runTruncation() {
    print("")
    print("A screen that closed takes what was on it")
    let store = scratch("truncation")
    let state = OpenEditorState(defaults: store)
    state.rememberProject(7)
    state.record(.songsAndNotes(.song), atDepth: 0)
    state.record(.document(42), atDepth: 1)

    // Closing the editor leaves the list it was opened from.
    state.record(nil, atDepth: 1)
    check("closing the editor keeps the list",
          store.string(forKey: pathKey) ?? "", "songs-and-notes:SONG")

    state.record(.songWorkspace, atDepth: 1)
    check("the workspace goes above the list",
          store.string(forKey: pathKey) ?? "", "songs-and-notes:SONG/song-workspace")

    // A different screen at depth 0 means the list is gone, and so is what it
    // was showing.
    state.record(.titlePage, atDepth: 0)
    check("swapping the outer screen drops the inner one",
          store.string(forKey: pathKey) ?? "", "title-page")

    state.record(nil, atDepth: 0)
    check("closing the last one empties the record",
          store.string(forKey: pathKey) ?? "—", "—")

    // Nothing is open beneath it, so there is nothing for it to be above.
    state.record(.document(9), atDepth: 1)
    check("a rung with no rung under it is ignored",
          store.string(forKey: pathKey) ?? "—", "—")
}

@MainActor
func runTokens() {
    print("")
    print("Every screen survives a round trip through storage")
    let screens: [OpenEditor] = [
        .songsAndNotes(.song), .songsAndNotes(.notes), .document(1),
        .songWorkspace, .characters, .outline, .titlePage,
    ]
    for screen in screens {
        check("\(screen.token)", OpenEditor(token: screen.token) == screen, true)
    }

    // An older build reading a newer one's record should reopen as far as it
    // understands rather than giving up on the whole path — the outer screens
    // are the ones worth getting right.
    let partial = OpenEditorState.decode("songs-and-notes:SONG/hologram:3")
    check("an unknown screen stops the path there", partial.count, 1)
    check("what came before it is kept", partial.first == .songsAndNotes(.song), true)
    check("a nonsense document id is not a screen",
          OpenEditor(token: "document:soon") == nil, true)
    check("an empty record is an empty path", OpenEditorState.decode("").count, 0)
}

MainActor.assumeIsolated {
    runFirstRun()
    runRoundTrip()
    runClaimIsOneShot()
    runClaimIsPerProject()
    runProjectChange()
    runReRecordingIsNotAChange()
    runTruncation()
    runTokens()
}

print("")
if failures == 0 {
    print("Editor state checks passed.")
    exit(0)
} else {
    print("\(failures) editor state check(s) FAILED.")
    exit(1)
}
