//
//  Home Screen bookmarks widget checks
//
//  The same three things the other two widgets have to get right — the
//  ordering, the links, the JSON — with one more that is particular to this
//  one: the widget holds several screenplays' rows at once and only ever has
//  one screenplay's in hand, so the merge is what decides whether flagging a
//  line in one draft quietly empties another.
//
//  The ordering is worth more here than on the other widgets. Those draw lists
//  of titles, where a wrong order is untidy; these rows are sentences out of a
//  script, and a run of them in the wrong order does not read as a widget with
//  a sorting bug — it reads as a screenplay that makes no sense.
//
//  The file half of the store is not checked here: there is no App Group
//  container in a command-line binary. What is checked is that its absence is
//  survivable, since a development build signed without the capability is in
//  exactly that state and still has to run.
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

private func ids(_ bookmarks: [WidgetBookmark]) -> String {
    bookmarks.map { String($0.blockId) }.joined(separator: ",")
}

/// Fixed instants, so "more recently marked up" means the same thing on every
/// run.
private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

private func bookmark(_ blockId: Int,
                      project: Int = 1,
                      title: String = "Wide Awake",
                      preview: String = "INT. DINER — NIGHT",
                      label: String? = "Scene",
                      order: Int,
                      markedAt: Date = now) -> WidgetBookmark {
    WidgetBookmark(blockId: blockId, projectId: project, projectTitle: title,
                   preview: preview, elementLabel: label, order: order,
                   markedAt: markedAt)
}

func runOrdering() {
    print("Which flagged lines the widget draws, and in what order")

    // Within one screenplay the rows are the script's own order — not the order
    // the filter happened to visit them, and emphatically not by anything about
    // the flag, which the server does not date.
    let scattered = [bookmark(3, order: 30), bookmark(1, order: 10), bookmark(2, order: 20)]
    check("one screenplay's lines read in script order",
          ids(BookmarksWidgetStore.ordered(scattered)), "1,2,3")

    // Across screenplays the runs stay whole: the most recently marked-up
    // script leads, and its lines are not interleaved with anyone else's.
    let older = [bookmark(11, project: 2, title: "Nightfall", order: 5, markedAt: daysAgo(3)),
                 bookmark(12, project: 2, title: "Nightfall", order: 99, markedAt: daysAgo(3))]
    check("the most recently marked-up screenplay leads, in whole runs",
          ids(BookmarksWidgetStore.ordered(older + scattered)), "1,2,3,11,12")

    // Swift's sort promises nothing about equal elements. Two elements the
    // server gave the same order — or none at all, which reads as zero — must
    // not reshuffle the widget between reloads.
    let tied = [bookmark(9, order: 0), bookmark(4, order: 0)]
    check("lines with the same position order by element id",
          ids(BookmarksWidgetStore.ordered(tied)), "4,9")

    check("a writer who has flagged nothing draws nothing",
          ids(BookmarksWidgetStore.ordered([])), "")
    // The largest family draws five; the spare rows are what let one
    // screenplay's bookmarks survive another being opened on top of them.
    check("more rows are kept than any family draws", BookmarksWidgetStore.limit >= 5, true)
}

func runMerging() {
    print("")
    print("Folding one screenplay's bookmarks into the rest")

    let nightfall = [bookmark(11, project: 2, title: "Nightfall", order: 5, markedAt: daysAgo(3)),
                     bookmark(12, project: 2, title: "Nightfall", order: 9, markedAt: daysAgo(3))]
    let wideAwake = [bookmark(1, order: 10), bookmark(2, order: 20)]

    check("another screenplay's rows are left alone",
          ids(BookmarksWidgetStore.merging(wideAwake, forProject: 1, into: nightfall)),
          "1,2,11,12")

    // The app holds one script at a time, so the only way a row leaves is by
    // this project's list coming back without it. Unflagging the last line has
    // to take the screenplay off the widget entirely rather than leaving its
    // rows behind forever.
    let both = BookmarksWidgetStore.merging(wideAwake, forProject: 1, into: nightfall)
    check("unflagging a line drops its row",
          ids(BookmarksWidgetStore.merging([wideAwake[0]], forProject: 1, into: both)),
          "1,11,12")
    check("and unflagging every line drops the screenplay",
          ids(BookmarksWidgetStore.merging([], forProject: 1, into: both)), "11,12")

    // A publisher that handed over another project's rows by mistake must not
    // be able to smuggle them in under this project's name — the merge has just
    // dropped whatever was stored for them.
    check("rows belonging to another screenplay are not adopted",
          ids(BookmarksWidgetStore.merging(nightfall, forProject: 1, into: [])), "")

    check("but not without limit",
          ids(BookmarksWidgetStore.merging(wideAwake, forProject: 1, into: nightfall, limit: 3)),
          "1,2,11")
    check("a limit of none keeps none",
          ids(BookmarksWidgetStore.merging(wideAwake, forProject: 1, into: nightfall, limit: 0)),
          "")
    check("a negative limit is not a crash",
          ids(BookmarksWidgetStore.merging(wideAwake, forProject: 1, into: nightfall, limit: -1)),
          "")
}

func runContentComparison() {
    print("")
    print("Deciding whether a publish is worth a reload")

    // The elements land again on every visit to a script, every sync poll and
    // every edit, and almost none of those change a bookmark. Each publish
    // stamps the rows afresh, so comparing them whole would make every one of
    // those look like a change — and would keep bumping a script that is merely
    // open above one the writer actually flagged something in.
    let before = [bookmark(1, order: 10), bookmark(2, order: 20)]
    let restamped = [bookmark(1, order: 10, markedAt: now.addingTimeInterval(60)),
                     bookmark(2, order: 20, markedAt: now.addingTimeInterval(60))]
    check("the same lines published again are not a change",
          BookmarksWidgetStore.isSameContent(before, restamped), true)

    // Everything the row is drawn from, on the other hand, is a change — the
    // widget would otherwise keep quoting the old wording of a line that was
    // rewritten after it was flagged.
    check("but a rewritten line is",
          BookmarksWidgetStore.isSameContent(
              before, [bookmark(1, preview: "INT. DINER — DAY", order: 10), before[1]]),
          false)
    check("and so is a retyped element",
          BookmarksWidgetStore.isSameContent(
              before, [bookmark(1, label: "Action", order: 10), before[1]]),
          false)
    check("and a renamed screenplay",
          BookmarksWidgetStore.isSameContent(
              before, [bookmark(1, title: "Sleepless", order: 10), before[1]]),
          false)
    check("and a line that moved in the script",
          BookmarksWidgetStore.isSameContent(
              before, [bookmark(1, order: 15), before[1]]),
          false)
    check("and a different line entirely",
          BookmarksWidgetStore.isSameContent(before, [bookmark(7, order: 10), before[1]]),
          false)
    check("and one fewer of them",
          BookmarksWidgetStore.isSameContent(before, [before[0]]), false)
}

func runLinks() {
    print("")
    print("What a tapped row asks for")

    let wanted = bookmark(88, project: 42, order: 3)
    let url = BookmarkWidgetLink.url(for: wanted)
    check("the row's link names the screenplay and the element",
          url.absoluteString, "scripty://bookmark?project=42&block=88")

    let destination = BookmarkWidgetLink.destination(in: url)
    check("the screenplay is read back", destination?.projectId.description ?? "none", "42")
    check("and so is the element", destination?.blockId?.description ?? "none", "88")

    // A link naming only a screenplay asks for the script itself, which is a
    // real request: the app opens it and scrolls nowhere in particular.
    let listURL = BookmarkWidgetLink.url(projectId: 42)
    check("a link with no element is still a screenplay",
          BookmarkWidgetLink.destination(in: listURL)?.projectId.description ?? "none", "42")
    check("and names no element",
          BookmarkWidgetLink.destination(in: listURL)?.blockId?.description ?? "none", "none")

    // Every other kind of `scripty://` URL arrives at the same door. Reading a
    // bookmark out of one would send the app somewhere nobody asked for — and
    // the other two widgets' links are the ones most likely to be confused,
    // since they differ only in their host.
    func rejected(_ string: String) -> String {
        BookmarkWidgetLink.destination(in: URL(string: string)!)
            .map { "\($0.projectId)/\($0.blockId.map(String.init) ?? "none")" } ?? "none"
    }
    check("a Songs & Notes row is not a bookmark",
          rejected("scripty://document?project=1&id=2&kind=song"), "none")
    check("a Screenplays row is not a bookmark", rejected("scripty://project?id=1"), "none")
    check("the demo link is not a bookmark", rejected("scripty://demo"), "none")
    check("another app's scheme is not a bookmark",
          rejected("other://bookmark?project=1&block=2"), "none")
    check("a link naming no screenplay is dropped", rejected("scripty://bookmark?block=2"), "none")
    // An id that is present but not a number is a malformed link, not a request
    // for the top of the script: dropping it beats scrolling somewhere
    // arbitrary.
    check("an element that is not a number is dropped",
          rejected("scripty://bookmark?project=1&block=seven"), "none")
    check("and neither is a screenplay",
          rejected("scripty://bookmark?project=one&block=2"), "none")
}

func runCoding() {
    print("")
    print("Writing a snapshot the extension can read")

    let snapshot = BookmarksSnapshot(bookmarks: [
        bookmark(1, preview: "INT. DINER — NIGHT", label: "Scene", order: 12),
        bookmark(2, preview: "(Untitled)", label: nil, order: 20, markedAt: daysAgo(2)),
    ], savedAt: now)

    guard let data = BookmarksWidgetStore.encode(snapshot) else {
        failures += 1
        print("  FAIL  a snapshot encodes")
        return
    }
    let read = BookmarksWidgetStore.decode(data)

    check("the rows survive the round trip", ids(read.bookmarks), "1,2")
    check("and so does the date they were saved", read.savedAt, now)
    // Every field the row is drawn from, and the two it is sorted by — a date
    // written one way and read another leaves the widget permanently empty with
    // nothing logged anywhere.
    check("the screenplay survives", read.bookmarks.first?.projectId ?? 0, 1)
    check("its title survives", read.bookmarks.first?.projectTitle ?? "none", "Wide Awake")
    check("the line survives", read.bookmarks.first?.preview ?? "none", "INT. DINER — NIGHT")
    check("the element type survives", read.bookmarks.first?.elementLabel ?? "none", "Scene")
    check("the position survives", read.bookmarks.first?.order ?? -1, 12)
    check("the stamp survives", read.bookmarks.first?.markedAt ?? .distantPast, now)
    check("a differing stamp is not flattened",
          read.bookmarks.last?.markedAt ?? .distantPast, daysAgo(2))
    // The publisher never writes a nil label today, but the field is optional
    // and a snapshot written by an older app has to keep decoding.
    check("and an element with no type stays untyped",
          read.bookmarks.last?.elementLabel ?? "none", "none")

    // Nothing readable in the file means the same as no file: an empty widget,
    // not a crashed one.
    check("a file full of nonsense reads as empty",
          BookmarksWidgetStore.decode(Data("not json".utf8)).isEmpty, true)
    check("and so does an empty one", BookmarksWidgetStore.decode(Data()).isEmpty, true)
}

func runNoSnapshotYet() {
    print("")
    print("Before anything has been published")

    // A development build signed without the App Group capability has no
    // container at all, and a fresh install has one with nothing in it. Both
    // have to degrade to an empty widget rather than trap.
    //
    // Which of the two this binary is in is not asserted: macOS hands a
    // command-line process a group container path whether or not anything
    // granted it one, so `containerURL` is nil on a device and non-nil here.
    // What is worth checking is that neither answer is a crash.
    check("loading gives an empty snapshot", BookmarksWidgetStore.load().isEmpty, true)
    BookmarksWidgetStore.clear()
    check("clearing what was never written is survivable",
          BookmarksWidgetStore.load().isEmpty, true)

    // `save` is deliberately not called: on this machine it would write into a
    // real ~/Library/Group Containers path, and a logic check has no business
    // leaving files on the developer's disk. What it writes is `encode`, which
    // runCoding covers; the rest is Foundation writing a Data.

    // No team means no prefixed spelling, rather than a stray leading dot or a
    // group literally called `$(TeamIdentifierPrefix)group.…`.
    check("no team prefix is invented", BookmarksWidgetStore.prefixedAppGroup == nil, true)

    // The identifiers the entitlement files and the extension spell out. A
    // change here that is not made in all of them builds cleanly and leaves the
    // widget permanently empty.
    check("the group is the one in the entitlements",
          BookmarksWidgetStore.appGroup, "group.scripty.scripty")
    check("the kind is the one the widget declares",
          BookmarksWidgetStore.widgetKind, "BookmarksWidget")
}

print("== Home Screen bookmarks widget ==")
runOrdering()
runMerging()
runContentComparison()
runLinks()
runCoding()
runNoSnapshotYet()

print("")
if failures == 0 {
    print("Bookmarks widget checks passed.")
} else {
    print("\(failures) bookmarks widget check(s) FAILED.")
}
exit(failures == 0 ? 0 : 1)
