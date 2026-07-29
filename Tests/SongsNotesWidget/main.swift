//
//  Songs and Notes widget checks
//
//  The pure halves of the two widgets: which rows survive a publish, which of
//  those each widget draws, and the URLs a tapped row — or a pressed Control
//  Center button — hands back to the app.
//
//  Worth checking without a simulator because all of it fails quietly. A merge
//  that keeps the wrong project's rows draws a plausible-looking widget of
//  stale titles, a filter that keeps the wrong half draws a widget of the
//  wrong thing, and a link that parses to the wrong document opens something
//  real but not what was asked for — none of it looks like a bug from outside.
//
//  The file half of the store is not exercised here: it writes into an App
//  Group container, which a command-line process has none of. That is why
//  `merging` is a pure function separate from `publish` in the first place.
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

/// A fixed instant, so "more recently edited" means the same thing every run.
private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func hoursAgo(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

private func document(_ id: Int,
                      project: Int = 1,
                      title: String = "Song",
                      isSong: Bool = true,
                      edited: Date) -> WidgetDocument {
    WidgetDocument(id: id, projectId: project, projectTitle: "Project \(project)",
                   title: title, isSong: isSong, updatedAt: edited)
}

private func ids(_ documents: [WidgetDocument]) -> String {
    documents.map { String($0.id) }.joined(separator: ",")
}

func runOrdering() {
    print("What the widget draws, in what order")

    let rows = [document(1, title: "Oldest", edited: hoursAgo(50)),
                document(2, title: "Newest", edited: hoursAgo(1)),
                document(3, title: "Middle", edited: hoursAgo(10))]
    check("most recently edited first",
          ids(SongsNotesWidgetStore.merging(rows, forProject: 1, into: [])), "2,3,1")

    // Swift's sort promises nothing about equal elements, so ties break on
    // title rather than letting the widget reshuffle itself between reloads.
    let sameMoment = [document(4, title: "Beta", edited: hoursAgo(2)),
                      document(5, title: "Alpha", edited: hoursAgo(2))]
    check("documents edited at the same moment order by title",
          ids(SongsNotesWidgetStore.merging(sameMoment, forProject: 1, into: [])), "5,4")

    // Songs and notes are stored as one list even though two widgets draw it,
    // so the order has to hold across both. Each widget then filters its own
    // half out of it, in the order it was stored.
    let mixed = [document(6, title: "A note", isSong: false, edited: hoursAgo(1)),
                 document(7, title: "A song", isSong: true, edited: hoursAgo(2))]
    check("notes and songs interleave by date",
          ids(SongsNotesWidgetStore.merging(mixed, forProject: 1, into: [])), "6,7")
}

func runSplit() {
    print("")
    print("Which rows each widget draws")

    let rows = [document(1, title: "Newest song", edited: hoursAgo(1)),
                document(2, title: "A note", isSong: false, edited: hoursAgo(2)),
                document(3, title: "Older song", edited: hoursAgo(3)),
                document(4, title: "Older note", isSong: false, edited: hoursAgo(4))]
    let snapshot = SongsNotesSnapshot(documents: SongsNotesWidgetStore.merging(rows,
                                                                               forProject: 1,
                                                                               into: []),
                                      savedAt: now)

    check("the Songs widget draws only songs, newest first",
          ids(snapshot.documents(.song)), "1,3")
    check("the Notes widget draws only notes, newest first",
          ids(snapshot.documents(.note)), "2,4")

    // A writer with songs and no notes has an empty Notes widget, not one
    // quietly showing songs.
    let songsOnly = SongsNotesSnapshot(documents: rows.filter(\.isSong), savedAt: now)
    check("a writer with no notes gets an empty Notes widget",
          songsOnly.documents(.note).count, 0)
    check("and a full Songs widget", songsOnly.documents(.song).count, 2)
    check("an empty snapshot filters to nothing rather than trapping",
          ids(SongsNotesSnapshot().documents(.song)), "")

    // The kinds each widget declares. Renaming one without renaming the
    // reload it is reached by builds cleanly and leaves that widget frozen on
    // whatever it last drew.
    check("the songs widget's kind", WidgetDocumentKind.song.widgetKind, "SongsWidget")
    check("the notes widget's kind", WidgetDocumentKind.note.widgetKind, "NotesWidget")
    check("both kinds are reloaded on sign-out",
          SongsNotesWidgetStore.widgetKinds.sorted().joined(separator: ","),
          "NotesWidget,SongsWidget")
}

func runMerging() {
    print("")
    print("Folding one project into the rest")

    let other = [document(10, project: 2, title: "Other project", edited: hoursAgo(5))]
    let mine = [document(11, project: 1, title: "Mine", edited: hoursAgo(9))]

    check("another project's rows are left alone",
          ids(SongsNotesWidgetStore.merging(mine, forProject: 1, into: other)), "10,11")

    // The project's previous rows go entirely, so a song deleted or renamed
    // since the last publish leaves with them rather than lingering.
    let stale = other + [document(12, project: 1, title: "Since deleted", edited: hoursAgo(1))]
    check("this project's previous rows are replaced, not merged",
          ids(SongsNotesWidgetStore.merging(mine, forProject: 1, into: stale)), "10,11")
    check("a project whose documents are all gone leaves only the others",
          ids(SongsNotesWidgetStore.merging([], forProject: 1, into: stale)), "10")

    // The publisher labels every row with the project it is publishing, but a
    // caller that got that wrong would otherwise smuggle a row past the
    // replace above and leave two projects claiming the same slot.
    let mislabelled = [document(13, project: 2, title: "Not mine", edited: hoursAgo(1))]
    check("a row belonging to another project is not published under this one",
          ids(SongsNotesWidgetStore.merging(mislabelled, forProject: 1, into: [])), "")
}

func runLimit() {
    print("")
    print("How many rows are kept")

    // Sized off the limit rather than at a round number, so this goes on
    // checking that the cap is applied when the cap changes — it has already
    // grown once, when Siri became a second reader of the same snapshot, and a
    // fixture shorter than the limit quietly stops testing anything.
    let overflowing = SongsNotesWidgetStore.limit + 5
    let many = (1...overflowing).map {
        document($0, title: "Song \($0)", edited: hoursAgo(Double($0)))
    }
    let kept = SongsNotesWidgetStore.merging(many, forProject: 1, into: [])
    check("capped at the store's limit", kept.count, SongsNotesWidgetStore.limit)
    check("and it is the most recent that are kept", ids(kept.prefix(3).map { $0 }), "1,2,3")
    check("a short list is not padded",
          SongsNotesWidgetStore.merging(Array(many.prefix(2)), forProject: 1, into: []).count, 2)
    // The largest family draws six, so the cap has to leave room for a full
    // widget even after one project's documents drop out.
    check("the limit leaves the largest family room to spare",
          SongsNotesWidgetStore.limit >= 6, true)

    // The cap is per kind, not per file. A burst of songs must not push the
    // notes out of a list the Notes widget is the only reader of — it would
    // draw an empty widget while the notes it wanted sat in the app.
    let notes = (101...(100 + overflowing)).map {
        document($0, title: "Note \($0)", isSong: false,
                 edited: hoursAgo(Double($0 - 100) + 0.5))
    }
    let both = SongsNotesWidgetStore.merging(many + notes, forProject: 1, into: [])
    let snapshot = SongsNotesSnapshot(documents: both, savedAt: now)
    check("songs are capped on their own",
          snapshot.documents(.song).count, SongsNotesWidgetStore.limit)
    check("and notes are not capped against them",
          snapshot.documents(.note).count, SongsNotesWidgetStore.limit)
    check("both halves are still one list, newest first",
          ids(Array(both.prefix(4))), "1,101,2,102")

    // A pile of songs and one old note: the note survives, however far down
    // the combined order it lands.
    let lonely = document(999, title: "The only note", isSong: false, edited: hoursAgo(500))
    let crowded = SongsNotesWidgetStore.merging(many + [lonely], forProject: 1, into: [])
    check("a single old note outlives a pile of songs",
          crowded.contains(lonely), true)
}

func runControlLinks() {
    print("")
    print("What a Control Center button asks for")

    func described(_ route: ScriptyLink.Route) -> String {
        ScriptyLink.url(for: route).absoluteString
    }
    check("songs names a screen and no project", described(.songs), "scripty://songs")
    check("notes likewise", described(.notes), "scripty://notes")
    check("the screenplay likewise", described(.screenplay), "scripty://screenplay")
    check("a new song says which half it is for",
          described(.compose(isSong: true)), "scripty://compose?kind=song")
    check("and so does a new note",
          described(.compose(isSong: false)), "scripty://compose?kind=notes")

    func read(_ raw: String) -> String {
        guard let url = URL(string: raw), let route = ScriptyLink.route(in: url) else {
            return "none"
        }
        return "\(route)"
    }
    for route in [ScriptyLink.Route.songs, .notes, .screenplay,
                  .compose(isSong: true), .compose(isSong: false)] {
        check("\(route) reads back", read(described(route)), "\(route)")
    }

    // Every scripty:// URL arrives at the same door. Both widgets' rows, the
    // demo shortcut and the reset email are each somebody else's to answer, and
    // claiming one of them here would open the wrong screen on a tap that was
    // never meant for a control.
    check("a widget row is not a control route",
          read("scripty://document?project=1&id=2&kind=song"), "none")
    check("a screenplay row is not a control route", read("scripty://project?id=1"), "none")
    check("the demo link is not a control route", read("scripty://demo"), "none")
    check("a different scheme is not a control route", read("https://example.com/songs"), "none")
    check("an unknown host is not a control route", read("scripty://nowhere"), "none")

    // A compose link with no kind is the notes composer, which is what a link
    // built by hand most likely meant. One with a kind that is neither word is
    // malformed — opening the wrong half beats nothing only if you are sure
    // which half, and here nobody is.
    check("compose with no kind opens the notes composer",
          read("scripty://compose"), "\(ScriptyLink.Route.compose(isSong: false))")
    check("compose with a kind that is neither word is dropped",
          read("scripty://compose?kind=zzz"), "none")
}

func runLinks() {
    print("")
    print("What a tapped row asks for")

    let song = document(42, project: 7, title: "Opening Number", edited: hoursAgo(1))
    let url = WidgetLink.url(for: song)
    check("a row's link names the scheme the app claims", url.scheme ?? "none", "scripty")

    guard let destination = WidgetLink.destination(in: url) else {
        failures += 1
        print("  FAIL  a row's own link reads back — got nothing")
        return
    }
    check("a row's own link reads back: project", destination.projectId, 7)
    check("a row's own link reads back: document", destination.documentId ?? -1, 42)
    check("a row's own link reads back: which list", destination.isSong, true)

    let note = document(43, project: 7, title: "Beats", isSong: false, edited: hoursAgo(1))
    check("a note's link opens the notes list",
          WidgetLink.destination(in: WidgetLink.url(for: note))?.isSong ?? true, false)

    // The whole-widget link names a project and no document — the empty state
    // and a tap on a large widget's spare room.
    let listOnly = WidgetLink.url(projectId: 7, isSong: true)
    check("a project-only link carries no document",
          WidgetLink.destination(in: listOnly)?.documentId ?? -1, -1)
    check("and still names its project",
          WidgetLink.destination(in: listOnly)?.projectId ?? -1, 7)

    // Every scripty:// URL arrives at the same door, so this has to decline
    // the ones that belong to the demo shortcut and the reset email.
    func described(_ raw: String) -> String {
        guard let url = URL(string: raw), let found = WidgetLink.destination(in: url) else {
            return "none"
        }
        return "\(found.projectId)/\(found.documentId.map(String.init) ?? "-")"
    }
    check("the demo link is not a widget link", described("scripty://demo"), "none")
    check("some other host is not a widget link",
          described("scripty://project?project=1"), "none")
    check("a different scheme is not a widget link",
          described("https://example.com/document?project=1&id=2"), "none")
    check("a link with no project is dropped", described("scripty://document?id=2"), "none")
    // A malformed id is a broken link, not a request for the list: opening
    // something arbitrary would be worse than opening nothing.
    check("a link whose document id is not a number is dropped",
          described("scripty://document?project=1&id=abc"), "none")
    check("an unknown kind falls back to songs",
          WidgetLink.destination(in: URL(string: "scripty://document?project=1&kind=zzz")!)?.isSong
            ?? false, true)
}

print("== Songs and Notes widgets ==")
runOrdering()
runSplit()
runMerging()
runLimit()
runLinks()
runControlLinks()

print("")
if failures == 0 {
    print("Widget checks passed.")
} else {
    print("\(failures) widget check(s) FAILED.")
}
exit(failures == 0 ? 0 : 1)
