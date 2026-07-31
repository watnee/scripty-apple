//
//  Where a document opens: reading view or edit view
//
//  The whole feature is one question — "how should this document come up?" —
//  and the answer is layered in a way that is easy to get subtly wrong. A
//  per-document choice has to outrank the app-wide switch, or turning "Open in
//  Edit View" on would quietly undo every "I only read this one"; and the
//  switch has to reach documents nobody has chosen for, or it would do nothing
//  at all. The two are checked against each other here rather than left to a
//  view to get right.
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
    let suite = "scripty.tests.readingview.\(name)"
    UserDefaults.standard.removePersistentDomain(forName: suite)
    return UserDefaults(suiteName: suite)!
}

@MainActor
func runDefaults() {
    print("What an unchosen document does")
    let store = scratch("defaults")
    let settings = ReadingViewSettings(defaults: store)

    // The point of the whole change: a first run opens documents to be read,
    // the way Pages and Word do on iOS.
    check("the switch is off on a first run", settings.opensInEditView, false)
    check("so a screenplay opens for reading",
          settings.opensInReadingView(.screenplay(project: 7)), true)
    check("and so does a song or note",
          settings.opensInReadingView(.document(id: 12)), true)

    settings.opensInEditView = true
    check("turning it on hands over unchosen screenplays",
          settings.opensInReadingView(.screenplay(project: 7)), false)
    check("and unchosen songs and notes",
          settings.opensInReadingView(.document(id: 12)), false)
    check("the switch survives a relaunch",
          ReadingViewSettings(defaults: store).opensInEditView, true)
}

@MainActor
func runRemembered() {
    print("")
    print("A choice made about one document")
    let store = scratch("remembered")
    let settings = ReadingViewSettings(defaults: store)

    settings.remember(false, for: .screenplay(project: 7))
    check("tapping Edit means it opens in the editor next time",
          settings.opensInReadingView(.screenplay(project: 7)), false)
    check("and says nothing about the screenplay next to it",
          settings.opensInReadingView(.screenplay(project: 8)), true)
    check("nor about a song that happens to share the number",
          settings.opensInReadingView(.document(id: 7)), true)
    check("the choice survives a relaunch",
          ReadingViewSettings(defaults: store).opensInReadingView(.screenplay(project: 7)),
          false)

    // Pages' own rule, and the one that makes the switch safe to offer: a
    // document you have deliberately put back into reading view stays there
    // even once the default has been turned round.
    settings.remember(true, for: .document(id: 3))
    settings.opensInEditView = true
    check("a document put into reading view outranks the switch",
          settings.opensInReadingView(.document(id: 3)), true)
    check("while an unchosen one follows it",
          settings.opensInReadingView(.document(id: 4)), false)

    // And the other way round, which is the case that would otherwise strand
    // a writer: Edit tapped while the switch was off must still be honoured.
    settings.opensInEditView = false
    check("a document handed to the writer stays handed over",
          settings.opensInReadingView(.screenplay(project: 7)), false)
}

@MainActor
func runKeys() {
    print("")
    print("Storage")
    let store = scratch("keys")
    let settings = ReadingViewSettings(defaults: store)

    settings.opensInEditView = true
    check("the switch has its own key",
          store.object(forKey: "scripty-open-in-edit-view") as? Bool ?? false, true)

    settings.remember(true, for: .screenplay(project: 42))
    settings.remember(false, for: .document(id: 42))
    // Kept in the same family as the per-project view options next door, and —
    // the reason both halves are checked — a screenplay and a song with the
    // same id must not land on the same key.
    check("a screenplay is filed under its project",
          store.object(forKey: "scripty-reading-view-project-42") as? Bool ?? false, true)
    check("a song or note under its own id",
          store.object(forKey: "scripty-reading-view-document-42") as? Bool ?? true, false)

    // "Never chosen" has to stay distinguishable from "chosen: edit view", or
    // the switch could never reach a document again once it had been opened.
    let untouched = scratch("untouched")
    check("an absent key is not a stored false",
          untouched.object(forKey: "scripty-reading-view-project-1") == nil, true)
}

MainActor.assumeIsolated {
    runDefaults()
    runRemembered()
    runKeys()
}

print("")
if failures == 0 {
    print("Reading view checks passed.")
    exit(0)
} else {
    print("\(failures) reading view check(s) FAILED.")
    exit(1)
}
