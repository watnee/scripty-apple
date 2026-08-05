//
//  App Intents search checks
//
//  What Siri, Spotlight and the Shortcuts app can find, and which of the things
//  they found comes first. None of it fails loudly:
//
//  A name matched wrong opens a screenplay — just not the one that was named,
//  and a writer who says "open Wake" and lands in *Wakefield* has no way to tell
//  that from having mumbled. A Find action that filters one row too many looks
//  exactly like a screenplay that is not there.
//
//  The AppIntents half of the surface is not checked here — an entity query
//  wants an App Group container and a running system, and neither exists in a
//  command-line binary. What is checked is everything those queries delegate to,
//  which is all of the decisions and none of the framework: the ranking behind
//  every picker and every spoken title, and the filtering and ordering behind
//  **Find Screenplays** and **Find Songs & Notes**.
//
//  The links the intents hand back are checked next door in Tests/QuickActions,
//  which owns ScriptyLink and IntentRouting.
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

private func project(id: Int, title: String, writers: String? = nil,
                     lastEdited: Date? = nil, isDefault: Bool = false) -> WidgetProject {
    WidgetProject(id: id, title: title, writers: writers,
                  lastEdited: lastEdited, isDefault: isDefault)
}

private func document(id: Int,
                      title: String,
                      projectId: Int = 1,
                      projectTitle: String = "A Draft",
                      isSong: Bool = true,
                      updatedAt: Date) -> WidgetDocument {
    WidgetDocument(id: id, projectId: projectId, projectTitle: projectTitle,
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
          titles(SongsNotesWidgetStore.ordered(documents.documents,
                                               limit: documents.documents.count)))
}

// MARK: - Matching a name

func runMatching() {
    print()
    print("Matching what was said, or typed, against what there is")

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

    // What a search field needs and a dictated title did not. Someone typing
    // "wake" means the word: the screenplay that has it as a word is a better
    // answer than one that merely contains the letters, however recent.
    let buried = [project(id: 1, title: "Awakening", lastEdited: daysAgo(1)),
                  project(id: 2, title: "The Long Wake Up", lastEdited: daysAgo(30))]
    check("a whole word beats the same letters inside another",
          titles(IntentTargets.screenplays(matching: "wake", in: buried)),
          "The Long Wake Up,Awakening")

    // Words in whatever order they came to mind. Last of all the tiers, so it
    // can never displace a title that really does read that way.
    check("every word present is a match, in any order",
          titles(IntentTargets.screenplays(matching: "up long", in: rows)),
          "The Long Wake Up")
    check("but only if all of them are",
          titles(IntentTargets.screenplays(matching: "long casablanca", in: rows)), "")

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

// MARK: - Settling on one

func runBest() {
    print()
    print("Settling on the one a name meant")

    // What the lyric intent does with a song named out loud. There is no picker
    // and nobody to choose, so this has to be the same answer a picker would
    // have put at the top — and it has to be *an* answer, or a dictated line
    // has nowhere to go.
    let songs = [document(id: 1, title: "Wake Up", updatedAt: daysAgo(1)),
                 document(id: 2, title: "Wake", updatedAt: daysAgo(20))]
    check("an exact title still wins",
          IntentTargets.best(matching: "Wake", in: songs, name: \.title)?.id ?? 0, 2)
    check("a near miss lands somewhere rather than nowhere",
          IntentTargets.best(matching: "wake u", in: songs, name: \.title)?.id ?? 0, 1)
    check("a name nothing answers to still fails",
          IntentTargets.best(matching: "Casablanca", in: songs, name: \.title)?.id ?? 0, 0)
    // Unlike a picker, where an empty field means everything: writing into
    // "the first song there is" because nothing was said is not a near miss,
    // it is writing into a document nobody named.
    check("and an empty name settles on nothing at all",
          IntentTargets.best(matching: "  ", in: songs, name: \.title)?.id ?? 0, 0)
}

// MARK: - The Find actions

func runFinding() {
    print()
    print("What a Find action keeps")

    let rows = [project(id: 1, title: "Wakefield", writers: "A. Writer",
                        lastEdited: daysAgo(1)),
                project(id: 2, title: "Révolution", writers: "B. Writer",
                        lastEdited: daysAgo(20), isDefault: true),
                project(id: 3, title: "The Long Wake Up", lastEdited: daysAgo(10))]

    // The conditions are Shortcuts' own words, folded the way the picker folds
    // them: a shortcut filtering for "revolution" and a writer who typed
    // *Révolution* mean each other.
    let contains: (WidgetProject) -> Bool = {
        IntentTargets.TextTest.contains("wake").matches($0.title)
    }
    let starred: (WidgetProject) -> Bool = { $0.isDefault }

    check("a condition on the title keeps what matches it",
          titles(IntentTargets.rows(rows, passing: [contains], all: true)),
          "Wakefield,The Long Wake Up")
    check("an accent is not a screenplay nobody can filter for",
          titles(IntentTargets.rows(rows, passing: [{
              IntentTargets.TextTest.exactly("revolution").matches($0.title)
          }], all: true)),
          "Révolution")
    check("begins with is not contains",
          titles(IntentTargets.rows(rows, passing: [{
              IntentTargets.TextTest.beginsWith("wake").matches($0.title)
          }], all: true)),
          "Wakefield")

    check("all of the following means all of them",
          titles(IntentTargets.rows(rows, passing: [contains, starred], all: true)), "")
    check("any of the following means either",
          titles(IntentTargets.rows(rows, passing: [contains, starred], all: false)),
          "Wakefield,Révolution,The Long Wake Up")

    // What the action looks like the moment it is dragged into a shortcut. An
    // empty result there reads as a broken action rather than an unfinished one.
    check("no conditions is every row",
          titles(IntentTargets.rows(rows, passing: [], all: true)),
          "Wakefield,Révolution,The Long Wake Up")
}

func runOrdering() {
    print()
    print("What order a Find action returns them in")

    let rows = [project(id: 1, title: "Wakefield", lastEdited: daysAgo(1)),
                project(id: 2, title: "Anthem", lastEdited: daysAgo(20)),
                // Never dated: made and not yet touched.
                project(id: 3, title: "Untouched")]

    check("newest first is the default, and the undated sort last",
          titles(IntentTargets.screenplays(rows, sortedBy: .edited, ascending: false)),
          "Wakefield,Anthem,Untouched")
    check("oldest first turns it round rather than dropping anything",
          titles(IntentTargets.screenplays(rows, sortedBy: .edited, ascending: true)),
          "Untouched,Anthem,Wakefield")
    check("by title is alphabetical",
          titles(IntentTargets.screenplays(rows, sortedBy: .title, ascending: true)),
          "Anthem,Untouched,Wakefield")
    check("and reversed the other way",
          titles(IntentTargets.screenplays(rows, sortedBy: .title, ascending: false)),
          "Wakefield,Untouched,Anthem")

    // Swift's sort promises nothing about equal elements, and a shortcut that
    // reshuffles its own results between runs is a bug nobody can reproduce.
    let sameDay = [document(id: 1, title: "Beats", updatedAt: daysAgo(3)),
                   document(id: 2, title: "Alto", updatedAt: daysAgo(3))]
    check("documents of the same age break the tie on title",
          titles(IntentTargets.documents(sameDay, sortedBy: .edited, ascending: false)),
          "Alto,Beats")
    // The other way round: one name, two documents, and the newer of them first
    // whichever direction the titles were asked for.
    let sameName = [document(id: 1, title: "Beats", updatedAt: daysAgo(9)),
                    document(id: 2, title: "Beats", projectId: 2, updatedAt: daysAgo(2))]
    check("and a repeated name breaks it on age",
          IntentTargets.documents(sameName, sortedBy: .title, ascending: true)
              .map { String($0.id) }.joined(separator: ","),
          "2,1")

    check("songs and notes sort by their own date",
          titles(IntentTargets.documents(
              [document(id: 1, title: "Older", updatedAt: daysAgo(9)),
               document(id: 2, title: "Newer", isSong: false, updatedAt: daysAgo(2))],
              sortedBy: .edited, ascending: false)),
          "Newer,Older")
}

runNameable()
runMatching()
runBest()
runFinding()
runOrdering()

print()
if failures == 0 {
    print("App Intents search: all checks passed.")
} else {
    print("App Intents search: \(failures) check(s) FAILED.")
}
exit(failures == 0 ? 0 : 1)
