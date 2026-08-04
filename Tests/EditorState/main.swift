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

/// The workspace every case below is written from — an account, spelled the way
/// `AppModel.workspaceScope` spells one. `elsewhere` is a different one.
let here = "scripty.example.com|writer"
let elsewhere = "local"

@MainActor
func runFirstRun() {
    print("A first run remembers nothing")
    let store = scratch("firstrun")
    let state = OpenEditorState(defaults: store)
    check("no project", state.rememberedProjectId(in: here) as Int? ?? -1, -1)
    check("no path", state.claimReopenPath(forProject: 7, in: here).count, 0)
}

@MainActor
func runAnotherWorkspace() {
    print("")
    print("A record from another workspace is no record")

    // The case this stamp exists for: a writer works without an account, then
    // signs in. Both workspaces number their screenplays from 1, so without it
    // the account would reopen whichever of *its* projects was number 7 — and
    // the songs that were open above someone else's.
    let store = scratch("workspace")
    let local = OpenEditorState(defaults: store)
    local.rememberProject(7, in: elsewhere)
    local.record(.songsAndNotes(.song), atDepth: 0)

    let account = OpenEditorState(defaults: store)
    check("the project is not offered to another workspace",
          account.rememberedProjectId(in: here) as Int? ?? -1, -1)
    check("nor is what was open above it",
          account.claimReopenPath(forProject: 7, in: here).count, 0)

    // And the workspace it belongs to still gets it.
    let back = OpenEditorState(defaults: store)
    check("its own workspace still comes back to it",
          back.rememberedProjectId(in: elsewhere) ?? -1, 7)
    check("with the screen it left open",
          back.claimReopenPath(forProject: 7, in: elsewhere).count, 1)
}

@MainActor
func runRoundTrip() {
    print("")
    print("What was open comes back")
    let store = scratch("roundtrip")
    let writing = OpenEditorState(defaults: store)
    writing.rememberProject(7, in: here)
    writing.record(.songsAndNotes(.song), atDepth: 0)
    writing.record(.document(id: 42, uid: nil), atDepth: 1)

    check("stored so it reads as English",
          store.string(forKey: pathKey) ?? "", "songs-and-notes:SONG/document:42")

    // A fresh instance is what the next launch gets.
    let reopening = OpenEditorState(defaults: store)
    check("the project comes back", reopening.rememberedProjectId(in: here) ?? -1, 7)
    let path = reopening.claimReopenPath(forProject: 7, in: here)
    check("both screens come back", path.count, 2)
    check("the list is outermost", path.first == .songsAndNotes(.song), true)
    check("the editor is on top of it", path.last == .document(id: 42, uid: nil), true)
}

@MainActor
func runClaimIsOneShot() {
    print("")
    print("The record is handed over once")
    let store = scratch("oneshot")
    let writing = OpenEditorState(defaults: store)
    writing.rememberProject(7, in: here)
    writing.record(.outline, atDepth: 0)

    let state = OpenEditorState(defaults: store)
    check("the first asker gets it", state.claimReopenPath(forProject: 7, in: here).count, 1)
    check("the second gets nothing", state.claimReopenPath(forProject: 7, in: here).count, 0)
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
    writing.rememberProject(7, in: here)
    writing.record(.characters, atDepth: 0)

    let state = OpenEditorState(defaults: store)
    check("another script gets nothing", state.claimReopenPath(forProject: 9, in: here).count, 0)
    // Still spent: reaching past the restore for a different script is the
    // writer saying where they want to be.
    check("and the restore is over", state.claimReopenPath(forProject: 7, in: here).count, 0)
}

@MainActor
func runProjectChange() {
    print("")
    print("Switching project forgets the screens")
    let store = scratch("projectchange")
    let state = OpenEditorState(defaults: store)
    state.rememberProject(7, in: here)
    state.record(.songsAndNotes(.notes), atDepth: 0)

    state.rememberProject(9, in: here)
    check("the path is dropped", store.string(forKey: pathKey) ?? "—", "—")
    check("the new project is kept", state.rememberedProjectId(in: here) ?? -1, 9)

    // Deselecting on iPad is a place too, and it is the one the app was left in.
    state.record(.outline, atDepth: 0)
    state.rememberProject(nil, in: here)
    check("deselecting forgets the project", state.rememberedProjectId(in: here) as Int? ?? -1, -1)
    check("and the path with it", store.string(forKey: pathKey) ?? "—", "—")
}

@MainActor
func runReRecordingIsNotAChange() {
    print("")
    print("Re-recording what is already stored leaves the path alone")
    let store = scratch("rerecord")
    let writing = OpenEditorState(defaults: store)
    writing.rememberProject(7, in: here)
    writing.record(.songsAndNotes(.song), atDepth: 0)
    writing.record(.document(id: 42, uid: nil), atDepth: 1)

    // The project restore notices the same project it stored. If that counted
    // as a change it would drop the screens it came to reopen.
    let state = OpenEditorState(defaults: store)
    state.rememberProject(7, in: here)
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
    state.rememberProject(7, in: here)
    state.record(.songsAndNotes(.song), atDepth: 0)
    state.record(.document(id: 42, uid: nil), atDepth: 1)

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
    state.record(.document(id: 9, uid: nil), atDepth: 1)
    check("a rung with no rung under it is ignored",
          store.string(forKey: pathKey) ?? "—", "—")
}

@MainActor
func runTokens() {
    print("")
    print("Every screen survives a round trip through storage")
    let screens: [OpenEditor] = [
        .songsAndNotes(.song), .songsAndNotes(.notes), .document(id: 1, uid: nil), .document(id: 2, uid: "abc-123"),
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

@MainActor
func runCarryingAcrossASignIn() {
    print("")
    print("A song being written when the session changes comes with it")

    // The whole point of the uid: the writer is mid-verse on a signed-out
    // device, signs in, and their song is now filed in the account under a
    // different number. The record crosses under the name both of them know.
    let store = scratch("carry")
    let local = OpenEditorState(defaults: store)
    local.rememberProject(7, in: elsewhere)
    local.record(.songsAndNotes(.song), atDepth: 0)
    local.record(.document(id: 42, uid: "the-song"), atDepth: 1)
    // Spent, exactly as it is by the time anyone signs in — this launch's
    // restore happened long ago.
    _ = local.claimReopenPath(forProject: 7, in: elsewhere)

    // Screenplay 7 on the device is screenplay 300 in the account.
    local.carry(from: elsewhere, to: here) { $0 == 7 ? 300 : nil }

    let account = OpenEditorState(defaults: store)
    check("the screenplay crossed", account.rememberedProjectId(in: here) ?? -1, 300)
    check("and is no longer claimed by the workspace left behind",
          account.rememberedProjectId(in: elsewhere) as Int? ?? -1, -1)
    let path = account.claimReopenPath(forProject: 300, in: here)
    check("both screens crossed with it", path.count, 2)
    check("the song is named by what it is, not by its number",
          path.last == .document(id: 42, uid: "the-song"), true)

    // A screenplay the account does not have is not a screenplay to cross to.
    let other = scratch("carrynowhere")
    let stranded = OpenEditorState(defaults: other)
    stranded.rememberProject(7, in: elsewhere)
    stranded.record(.outline, atDepth: 0)
    stranded.carry(from: elsewhere, to: here) { _ in nil }
    check("nothing is written for a screenplay with no counterpart",
          stranded.rememberedProjectId(in: here) as Int? ?? -1, -1)
    check("and the record it had is left where it was",
          stranded.rememberedProjectId(in: elsewhere) ?? -1, 7)
}

@MainActor
func runANamelessSongDoesNotCross() {
    print("")
    print("A song with no name of its own stops at the crossing")

    // Its id means something here and something else over there. Reopening by
    // it would not be a stale song — it would be somebody else's, which is the
    // one outcome worse than opening the list.
    let store = scratch("nameless")
    let local = OpenEditorState(defaults: store)
    local.rememberProject(7, in: elsewhere)
    local.record(.songsAndNotes(.song), atDepth: 0)
    local.record(.document(id: 42, uid: nil), atDepth: 1)
    local.carry(from: elsewhere, to: here) { _ in 300 }

    let account = OpenEditorState(defaults: store)
    let path = account.claimReopenPath(forProject: 300, in: here)
    check("the list still crosses", path.count, 1)
    check("the song does not", path.first == .songsAndNotes(.song), true)
}

@MainActor
func runResolvingTheRememberedSong() {
    print("")
    print("Finding the song a record names")

    // Ids as they would be in an account that has never met this device: the
    // song the writer means is number 9 here and was number 42 there, and 42 is
    // somebody else's note.
    func document(_ id: Int, _ uid: String?, _ title: String) -> TextDocument {
        let json = """
        {"id": \(id), \(uid.map { "\"uid\": \"\($0)\"," } ?? "") "title": "\(title)"}
        """
        return try! JSONDecoder().decode(TextDocument.self, from: Data(json.utf8))
    }
    let list = [document(9, "the-song", "Opening Number"),
                document(42, "another-thing", "Scratch Notes")]

    check("the name wins over the number",
          list.rememberedOne(id: 42, uid: "the-song")?.displayTitle ?? "—", "Opening Number")
    check("a record with no name falls back to the number",
          list.rememberedOne(id: 42, uid: nil)?.displayTitle ?? "—", "Scratch Notes")
    check("a name nothing answers to falls back too",
          list.rememberedOne(id: 9, uid: "deleted-since")?.displayTitle ?? "—", "Opening Number")
    check("and a song that is gone is nothing to reopen",
          list.rememberedOne(id: 404, uid: "gone") == nil, true)
}

MainActor.assumeIsolated {
    runFirstRun()
    runAnotherWorkspace()
    runRoundTrip()
    runClaimIsOneShot()
    runClaimIsPerProject()
    runProjectChange()
    runReRecordingIsNotAChange()
    runTruncation()
    runTokens()
    runCarryingAcrossASignIn()
    runANamelessSongDoesNotCross()
    runResolvingTheRememberedSong()
}

print("")
if failures == 0 {
    print("Editor state checks passed.")
    exit(0)
} else {
    print("\(failures) editor state check(s) FAILED.")
    exit(1)
}
