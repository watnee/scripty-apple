//
//  Home Screen quick action checks
//
//  The menu hands over a type string and, for a recents entry, a project id.
//  Everything after that is a choice made here: which project a Songs or Notes
//  tap opens, and which projects the menu names in the first place.
//
//  Worth checking without a simulator because the failures are quiet ones. An
//  entry that resolves to the wrong screenplay opens something plausible, and
//  a recents list one longer than the menu can show simply loses its last
//  entry — neither looks like a bug from the outside.
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

/// Spellings that do not depend on how the compiler happens to name this
/// module, which is not the app's name when these sources are built here.
private func describe(_ action: QuickAction?) -> String {
    switch action {
    case .songs: "songs"
    case .notes: "notes"
    case .project(let id): "project \(id)"
    case nil: "none"
    }
}

private func describe(_ type: DocumentType?) -> String { type?.rawValue ?? "none" }

private func ids(_ projects: [Project]) -> String {
    projects.map { String($0.id) }.joined(separator: ",")
}

private func id(_ project: Project?) -> String { project.map { String($0.id) } ?? "none" }

/// Days back from a fixed instant, so "more recently edited" means the same
/// thing on every run.
private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

private func project(id: Int,
                     title: String,
                     lastEdited: Date? = nil,
                     isDefault: Bool? = nil) -> Project {
    Project(id: id,
            title: title,
            screenplayTitle: nil,
            writers: nil,
            contactInfo: nil,
            screenplayVersion: nil,
            lastEdited: lastEdited,
            teams: nil,
            isDefault: isDefault,
            links: nil)
}

func runDecoding() {
    print("Reading an entry off the Home Screen")
    check("songs", describe(QuickAction(itemType: "scripty.songs", projectId: nil)), "songs")
    check("notes", describe(QuickAction(itemType: "scripty.notes", projectId: nil)), "notes")
    check("a named project",
          describe(QuickAction(itemType: "scripty.project", projectId: 42)), "project 42")
    // The dynamic entries an older version published outlive it — only this app
    // can take them down — so being handed nonsense is normal, not a bug.
    check("a project entry with no id is dropped",
          describe(QuickAction(itemType: "scripty.project", projectId: nil)), "none")
    check("a type this version no longer offers is dropped",
          describe(QuickAction(itemType: "scripty.retired", projectId: 1)), "none")

    // The static half of the menu spells these out in Info.plist, so the two
    // have to agree — a disagreement builds cleanly and shows up only as an
    // entry that does nothing when tapped.
    check("songs' type matches Info.plist", QuickAction.ItemType.songs, "scripty.songs")
    check("notes' type matches Info.plist", QuickAction.ItemType.notes, "scripty.notes")

    check("songs opens the songs list", describe(QuickAction.songs.documentType), "SONG")
    check("notes opens the notes list", describe(QuickAction.notes.documentType), "NOTES")
    check("a named project opens neither list",
          describe(QuickAction.project(id: 1).documentType), "none")
}

func runPreferredProject() {
    print("")
    print("Where Songs and Notes land")

    let starred = project(id: 1, title: "Starred", lastEdited: daysAgo(30), isDefault: true)
    let recent = project(id: 2, title: "Recent", lastEdited: daysAgo(1))

    // The star is the writer's own answer to "which screenplay is mine", and it
    // beats whichever project a stray edit happened to touch last.
    check("the star wins over the more recent project",
          id(QuickAction.preferredProject(in: [recent, starred])), "1")
    check("and wins whichever way round the list arrives",
          id(QuickAction.preferredProject(in: [starred, recent])), "1")

    check("with no star, the most recently edited",
          id(QuickAction.preferredProject(in: [project(id: 3, title: "Old", lastEdited: daysAgo(9)),
                                               recent])),
          "2")
    // `default: false` is a real answer from the server, not a missing one.
    check("an unstarred flag is not a star",
          id(QuickAction.preferredProject(in: [project(id: 4, title: "Not it",
                                                       lastEdited: daysAgo(40), isDefault: false),
                                               recent])),
          "2")
    check("an account with no projects lands nowhere",
          id(QuickAction.preferredProject(in: [])), "none")

    check("songs follows the same rule", id(QuickAction.songs.project(in: [recent, starred])), "1")
    check("notes follows it too", id(QuickAction.notes.project(in: [recent, starred])), "1")
}

func runNamedProject() {
    print("")
    print("Opening a project the menu named")

    let projects = [project(id: 7, title: "Wanted", lastEdited: daysAgo(5)),
                    project(id: 8, title: "Other", lastEdited: daysAgo(1), isDefault: true)]

    check("by id, not by whichever is default",
          id(QuickAction.project(id: 7).project(in: projects)), "7")
    // Deleting a screenplay leaves its entry on the Home Screen until the list
    // reloads. Tapping it in between must not open something else.
    check("a screenplay since deleted opens nothing",
          id(QuickAction.project(id: 99).project(in: projects)), "none")
}

func runRecents() {
    print("")
    print("Which projects the menu names")

    let projects = [project(id: 1, title: "Oldest", lastEdited: daysAgo(30)),
                    project(id: 2, title: "Newest", lastEdited: daysAgo(1)),
                    project(id: 3, title: "Middle", lastEdited: daysAgo(10))]

    check("most recently edited first", ids(QuickAction.recentProjects(in: projects)), "2,3")

    // Four entries, two of them static, leaves two. A third would be dropped by
    // the system rather than shown, which is worse than never offering it.
    check("no more than the menu can show", QuickAction.recentProjectLimit, 2)
    check("a short list is not padded", ids(QuickAction.recentProjects(in: [projects[0]])), "1")
    check("an account with no projects names none",
          ids(QuickAction.recentProjects(in: [])), "")

    // A never-edited project still belongs in the menu — an account whose only
    // screenplay has never been touched should not find it empty.
    let undated = project(id: 4, title: "Never touched")
    check("a project with no edit date is offered when there is room",
          ids(QuickAction.recentProjects(in: [undated])), "4")
    check("but sorts behind one that has been edited",
          ids(QuickAction.recentProjects(in: [undated, projects[0]], limit: 1)), "1")

    // Swift's sort promises nothing about equal elements, so ties are broken on
    // title rather than left to reshuffle the menu between launches.
    let sameDay = [project(id: 5, title: "Beta", lastEdited: daysAgo(2)),
                   project(id: 6, title: "Alpha", lastEdited: daysAgo(2))]
    check("projects edited at the same moment order by title",
          ids(QuickAction.recentProjects(in: sameDay)), "6,5")
}

print("== Home Screen quick actions ==")
runDecoding()
runPreferredProject()
runNamedProject()
runRecents()

print("")
if failures == 0 {
    print("Quick action checks passed.")
} else {
    print("\(failures) quick action check(s) FAILED.")
}
exit(failures == 0 ? 0 : 1)
