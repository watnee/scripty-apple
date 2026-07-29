//
//  App Intents routing checks
//
//  What Siri, Spotlight and the Shortcuts app can ask for, and what the app does
//  when it arrives. Neither half fails loudly:
//
//  A name matched wrong opens a screenplay — just not the one that was named,
//  and a writer who says "open Wake" and lands in *Wakefield* has no way to tell
//  that from having mumbled. A link written by an intent and not read by the app
//  brings the app to the front on whatever was last on screen, which reads as a
//  slow request rather than a broken one.
//
//  The AppIntents half of the surface is not checked here — an entity query
//  wants an App Group container and a running system, and neither exists in a
//  command-line binary. What is checked is everything those queries and intents
//  delegate to, which is all of the decisions and none of the framework.
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

/// Days back from a fixed instant, so "more recently edited" means the same
/// thing on every run.
private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

private func titles(_ projects: [WidgetProject]) -> String {
    projects.map(\.title).joined(separator: ",")
}

private func titles(_ documents: [WidgetDocument]) -> String {
    documents.map(\.title).joined(separator: ",")
}

/// Spellings that do not depend on how the compiler happens to name this module,
/// which is not the app's name when these sources are built here.
private func describe(_ action: QuickAction?) -> String {
    switch action {
    case .songs: "songs"
    case .notes: "notes"
    case .project(let id): "project \(id)"
    case nil: "none"
    }
}

private func project(id: Int, title: String, lastEdited: Date? = nil) -> WidgetProject {
    WidgetProject(id: id, title: title, lastEdited: lastEdited)
}

private func document(id: Int,
                      title: String,
                      projectId: Int = 1,
                      isSong: Bool = true,
                      updatedAt: Date) -> WidgetDocument {
    WidgetDocument(id: id, projectId: projectId, projectTitle: "A Draft",
                   title: title, isSong: isSong, updatedAt: updatedAt)
}

// MARK: - What can be named

func runNameable() {
    print("What an intent can name")

    let snapshot = ProjectsSnapshot(
        projects: [project(id: 1, title: "Oldest", lastEdited: daysAgo(30)),
                   project(id: 2, title: "Newest", lastEdited: daysAgo(1)),
                   project(id: 3, title: "Middle", lastEdited: daysAgo(10))],
        savedAt: now)

    check("screenplays come back most recently edited first",
          titles(IntentTargets.screenplays(in: snapshot)), "Newest,Middle,Oldest")

    // The snapshot's own cap is the ceiling, and it is not the widget's six.
    // A writer with two dozen screenplays who cannot ask for the twenty-fourth
    // by name has been told it does not exist.
    check("every screenplay in the snapshot is nameable, not just the drawn ones",
          IntentTargets.screenplays(in: snapshot).count, snapshot.projects.count)
    check("the cap is well past what a widget draws",
          ProjectsWidgetStore.limit >= 24, true)
    check("and so is the songs and notes one",
          SongsNotesWidgetStore.limit >= 24, true)

    check("no snapshot is no screenplays rather than an error",
          IntentTargets.screenplays(in: ProjectsSnapshot()).count, 0)

    let documents = SongsNotesSnapshot(
        documents: [document(id: 1, title: "Older Song", updatedAt: daysAgo(9)),
                    document(id: 2, title: "Newer Note", isSong: false,
                             updatedAt: daysAgo(2))],
        savedAt: now)
    check("songs and notes come back together, newest first",
          titles(IntentTargets.documents(in: documents)), "Newer Note,Older Song")

    // The widget and the spoken request read one list. If these two ever
    // disagreed, "open my last song" and the top widget row would name
    // different documents, and only one of them could be right.
    check("one ordering, shared with the widget",
          titles(IntentTargets.documents(in: documents)),
          titles(SongsNotesWidgetStore.ordered(documents.documents)))
}

// MARK: - Matching a name

func runMatching() {
    print()
    print("Matching what was said against what there is")

    let rows = [project(id: 1, title: "Wakefield", lastEdited: daysAgo(1)),
                project(id: 2, title: "Wake", lastEdited: daysAgo(20)),
                project(id: 3, title: "The Long Wake Up", lastEdited: daysAgo(10))]

    // The whole point of ranking rather than filtering. Every one of these
    // contains "wake", and the exactly-named one is twenty days staler than the
    // first — recency must not be allowed to overrule being asked for by name.
    check("an exact name wins outright, however stale",
          titles(IntentTargets.screenplays(matching: "Wake", in: rows)),
          "Wake,Wakefield,The Long Wake Up")
    check("a leading match beats one buried in the middle",
          titles(IntentTargets.screenplays(matching: "Wakef", in: rows)), "Wakefield")
    check("and a buried one still counts",
          titles(IntentTargets.screenplays(matching: "Long", in: rows)),
          "The Long Wake Up")

    check("case is not what was asked about",
          titles(IntentTargets.screenplays(matching: "wakefield", in: rows)), "Wakefield")
    check("nor is a stray space either end",
          titles(IntentTargets.screenplays(matching: "  Wakefield ", in: rows)), "Wakefield")

    // Dictation gives back what it heard, not what was typed when the
    // screenplay was named.
    let accented = [project(id: 4, title: "Révolution", lastEdited: daysAgo(1))]
    check("nor an accent Siri did not hear",
          titles(IntentTargets.screenplays(matching: "revolution", in: accented)),
          "Révolution")

    check("a name nothing answers to finds nothing",
          titles(IntentTargets.screenplays(matching: "Casablanca", in: rows)), "")
    // What the Shortcuts picker asks with before anything has been typed: an
    // empty field means "show me everything", not "show me nothing".
    check("an empty search is every row, in order",
          titles(IntentTargets.screenplays(matching: "", in: rows)),
          "Wakefield,Wake,The Long Wake Up")

    // Two equally good matches, and only their order in the list to separate
    // them — which is recency, because that is how the list arrived.
    let ties = [document(id: 1, title: "Beats", projectId: 1, updatedAt: daysAgo(1)),
                document(id: 2, title: "Beats", projectId: 2, updatedAt: daysAgo(8))]
    check("equally good matches keep the order they came in",
          IntentTargets.documents(matching: "beats", in: ties).map { String($0.projectId) }
              .joined(separator: ","),
          "1,2")
}

// MARK: - The links

func runLinks() {
    print()
    print("The links an intent hands back")

    // Every one of these is written by an intent and read by the app. A pair
    // that stops agreeing does not fail to build; it just stops opening
    // anything.
    check("songs round-trips", describe(ShortcutLink.action(in: ShortcutLink.url(for: .songs))),
          "songs")
    check("notes round-trips", describe(ShortcutLink.action(in: ShortcutLink.url(for: .notes))),
          "notes")
    check("a named screenplay round-trips",
          describe(ShortcutLink.action(in: ShortcutLink.url(for: .project(id: 42)))),
          "project 42")

    check("songs is spelled as it reads",
          ShortcutLink.url(for: .songs).absoluteString, "scripty://songs")
    check("notes likewise",
          ShortcutLink.url(for: .notes).absoluteString, "scripty://notes")

    // The screenplay link is the Screenplays widget's own, not a second
    // spelling of it — two spellings of one route is how the two quietly stop
    // agreeing.
    check("a screenplay reuses the widget's link",
          ShortcutLink.url(for: .project(id: 7)).absoluteString,
          ProjectWidgetLink.url(projectId: 7).absoluteString)

    check("the list link names no screenplay",
          describe(ShortcutLink.action(in: ShortcutLink.screenplaysURL)), "none")

    check("the demo link is the demo", ShortcutLink.isDemo(ShortcutLink.demoURL), true)
    // Both spellings people write, because a Shortcut that quietly does nothing
    // is a poor way to find out which one this app meant.
    check("written with a slash it is still the demo",
          ShortcutLink.isDemo(URL(string: "scripty:///demo")!), true)
    check("the demo is not a screen request",
          describe(ShortcutLink.action(in: ShortcutLink.demoURL)), "none")
    check("and a screen request is not the demo",
          ShortcutLink.isDemo(ShortcutLink.url(for: .songs)), false)

    // Everything else arriving at the same door. A recovery email's link must
    // not be read as a request to open a screenplay.
    check("another app's scheme is not ours",
          describe(ShortcutLink.action(in: URL(string: "other://songs")!)), "none")
    check("a recovery link is left alone",
          describe(ShortcutLink.action(in: URL(string: "https://example.com/reset?token=x")!)),
          "none")
    check("nor is a recovery link the demo",
          ShortcutLink.isDemo(URL(string: "https://example.com/demo")!), false)

    // The widget's document link is the one an intent reuses rather than
    // reinventing: a row tapped on the Home Screen and a song asked for out
    // loud are the same request arriving two ways.
    let song = WidgetLink.url(projectId: 3, documentId: 9, isSong: true)
    check("a song link still says which screenplay it belongs to",
          WidgetLink.destination(in: song).map { "\($0.projectId)/\($0.documentId ?? -1)" }
              ?? "none",
          "3/9")
    check("a song link is not mistaken for a screenplay request",
          describe(ShortcutLink.action(in: song)), "none")
}

runNameable()
runMatching()
runLinks()

print()
if failures == 0 {
    print("App Intents routing: all checks passed.")
} else {
    print("App Intents routing: \(failures) check(s) FAILED.")
}
exit(failures == 0 ? 0 : 1)
