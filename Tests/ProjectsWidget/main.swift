//
//  Home Screen projects widget checks
//
//  Three things the app and the extension have to agree on, none of which fail
//  loudly when they stop agreeing:
//
//  The ordering, because a widget is a handful of rows out of a list that can
//  be any length, and picking the wrong handful looks exactly like picking the
//  right one. The `scripty://project` links, because a URL the extension writes
//  and the app cannot read opens the app on whatever was last on screen — which
//  reads as a slow tap rather than a broken one. And the JSON, because a date
//  written one way and read another leaves the widget permanently empty with
//  nothing logged anywhere.
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

private func ids(_ projects: [WidgetProject]) -> String {
    projects.map { String($0.id) }.joined(separator: ",")
}

/// Days back from a fixed instant, so "more recently edited" means the same
/// thing on every run.
private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

private func project(id: Int,
                     title: String,
                     writers: String? = nil,
                     version: String? = nil,
                     lastEdited: Date? = nil,
                     isDefault: Bool = false) -> WidgetProject {
    WidgetProject(id: id, title: title, writers: writers, version: version,
                  lastEdited: lastEdited, isDefault: isDefault)
}

func runOrdering() {
    print("Which screenplays the widget draws")

    let projects = [project(id: 1, title: "Oldest", lastEdited: daysAgo(30)),
                    project(id: 2, title: "Newest", lastEdited: daysAgo(1)),
                    project(id: 3, title: "Middle", lastEdited: daysAgo(10))]

    check("most recently edited first", ids(ProjectsWidgetStore.ordered(projects)), "2,3,1")
    check("a short list is not padded",
          ids(ProjectsWidgetStore.ordered([projects[0]])), "1")
    check("an account with no projects draws none", ids(ProjectsWidgetStore.ordered([])), "")

    // The largest family draws six; the spare rows are what keeps the widget
    // full after a project is deleted rather than leaving a gap.
    check("more rows are kept than any family draws", ProjectsWidgetStore.limit >= 6, true)
    check("but not without limit",
          ids(ProjectsWidgetStore.ordered(projects, limit: 2)), "2,3")
    check("a limit of none keeps none",
          ids(ProjectsWidgetStore.ordered(projects, limit: 0)), "")
    check("a negative limit is not a crash",
          ids(ProjectsWidgetStore.ordered(projects, limit: -1)), "")

    // The star answers "which screenplay is mine", which is the question the
    // Home Screen menu's Songs entry asks. This widget asks "what have I been
    // working on", so the star is drawn on its row rather than floated to the
    // top of one.
    let starredButStale = project(id: 4, title: "Starred", lastEdited: daysAgo(40),
                                  isDefault: true)
    check("the starred project does not jump the queue",
          ids(ProjectsWidgetStore.ordered([starredButStale, projects[1]])), "2,4")

    // A never-edited project still belongs on the widget — an account whose
    // only screenplay has never been touched should not find it empty.
    let undated = project(id: 5, title: "Never touched")
    check("a project with no edit date is drawn when there is room",
          ids(ProjectsWidgetStore.ordered([undated])), "5")
    check("but sorts behind one that has been edited",
          ids(ProjectsWidgetStore.ordered([undated, projects[0]])), "1,5")

    // Swift's sort promises nothing about equal elements, so ties are broken on
    // title rather than left to reshuffle the widget between reloads.
    let sameDay = [project(id: 6, title: "Beta", lastEdited: daysAgo(2)),
                   project(id: 7, title: "Alpha", lastEdited: daysAgo(2))]
    check("projects edited at the same moment order by title",
          ids(ProjectsWidgetStore.ordered(sameDay)), "7,6")
}

func runLinks() {
    print("")
    print("What a tapped row asks for")

    let wanted = project(id: 42, title: "Wide Awake", lastEdited: daysAgo(1))
    let url = ProjectWidgetLink.url(for: wanted)
    check("the row's link names the project", url.absoluteString, "scripty://project?id=42")
    check("and is read back", ProjectWidgetLink.projectId(in: url).map(String.init) ?? "none", "42")

    // The widget's empty state links here. It asks for no screenplay in
    // particular, so there is nothing for the app to do beyond coming to the
    // front — which it is already doing by the time this is read.
    check("the list link names no project",
          ProjectWidgetLink.projectId(in: ProjectWidgetLink.listURL).map(String.init) ?? "none",
          "none")

    // Three other kinds of URL arrive at the same door, and reading a project
    // id out of any of them would open a screenplay nobody asked for.
    check("the demo link is not a project",
          ProjectWidgetLink.projectId(in: URL(string: "scripty://demo")!)
              .map(String.init) ?? "none",
          "none")
    check("a password reset link is not a project",
          ProjectWidgetLink.projectId(in: URL(string:
              "https://example.invalid/forgot-password/reset?token=abc")!)
              .map(String.init) ?? "none",
          "none")
    check("another app's scheme is not a project",
          ProjectWidgetLink.projectId(in: URL(string: "other://project?id=9")!)
              .map(String.init) ?? "none",
          "none")
    // An id that is present but not a number is a malformed link, not a request
    // for the list: dropping it beats opening something arbitrary.
    check("an id that is not a number is dropped",
          ProjectWidgetLink.projectId(in: URL(string: "scripty://project?id=seven")!)
              .map(String.init) ?? "none",
          "none")
}

func runCoding() {
    print("")
    print("Writing a snapshot the extension can read")

    let snapshot = ProjectsSnapshot(projects: [
        project(id: 1, title: "Wide Awake", writers: "A. Marlowe",
                version: "Second Draft", lastEdited: daysAgo(1), isDefault: true),
        project(id: 2, title: "Never touched"),
    ], savedAt: now)

    guard let data = ProjectsWidgetStore.encode(snapshot) else {
        failures += 1
        print("  FAIL  a snapshot encodes")
        return
    }
    let read = ProjectsWidgetStore.decode(data)

    check("the rows survive the round trip", ids(read.projects), "1,2")
    check("and so does the date they were saved", read.savedAt, now)
    // The fields the row is drawn from, each of which the server can omit.
    check("the title survives", read.projects.first?.title ?? "none", "Wide Awake")
    check("the writers survive", read.projects.first?.writers ?? "none", "A. Marlowe")
    check("the draft version survives", read.projects.first?.version ?? "none", "Second Draft")
    check("the edit date survives", read.projects.first?.lastEdited ?? .distantPast, daysAgo(1))
    check("the star survives", read.projects.first?.isDefault ?? false, true)
    check("and a project the server never dated stays undated",
          read.projects.last?.lastEdited.map(String.init(describing:)) ?? "none", "none")

    // Nothing readable in the file means the same as no file: an empty widget,
    // not a crashed one.
    check("a file full of nonsense reads as empty",
          ProjectsWidgetStore.decode(Data("not json".utf8)).isEmpty, true)
    check("and so does an empty one", ProjectsWidgetStore.decode(Data()).isEmpty, true)
}

func runNoSnapshotYet() {
    print("")
    print("Before anything has been published")

    // A development build signed without the App Group capability has no
    // container at all, and a fresh install has one with nothing in it. Both
    // have to degrade to an empty widget rather than trap — the app still runs,
    // it simply has nothing to draw.
    //
    // Which of the two this binary is in is not asserted: macOS hands a
    // command-line process a group container path whether or not anything
    // granted it one, so `containerURL` is nil on a device and non-nil here.
    // What is worth checking is that neither answer is a crash.
    check("loading gives an empty snapshot", ProjectsWidgetStore.load().isEmpty, true)
    ProjectsWidgetStore.clear()
    check("clearing what was never written is survivable",
          ProjectsWidgetStore.load().isEmpty, true)

    // `save` is deliberately not called: on this machine it would write into a
    // real ~/Library/Group Containers path, and a logic check has no business
    // leaving files on the developer's disk. What it writes is `encode`, which
    // runCoding covers; the rest is Foundation writing a Data.

    // No team means no prefixed spelling, rather than a stray leading dot or a
    // group literally called `$(TeamIdentifierPrefix)group.…`.
    check("no team prefix is invented", ProjectsWidgetStore.prefixedAppGroup == nil, true)

    // The identifiers the entitlement files spell out. A change here that is not
    // made in all four builds cleanly and leaves the widget permanently empty.
    check("the group is the one in the entitlements",
          ProjectsWidgetStore.appGroup, "group.scripty.scripty")
    check("the kind is the one the widget declares",
          ProjectsWidgetStore.widgetKind, "ProjectsWidget")
}

print("== Home Screen projects widget ==")
runOrdering()
runLinks()
runCoding()
runNoSnapshotYet()

print("")
if failures == 0 {
    print("Projects widget checks passed.")
} else {
    print("\(failures) projects widget check(s) FAILED.")
}
exit(failures == 0 ? 0 : 1)
