//
//  What a launch opens by itself
//
//  The rule is the web app's: the starred project, or nothing. Worth checking
//  without a simulator because both ways of getting it wrong are quiet. Opening
//  the wrong screenplay looks like the right one until the writer reads it, and
//  opening something for an account that starred nothing is invisible on iPad —
//  where the list is still in the next column — and only obvious on iPhone,
//  where it has swallowed the list.
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

private func id(_ project: Project?) -> String { project.map { String($0.id) } ?? "none" }

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

private let starred = project(id: 1, title: "Starred", lastEdited: daysAgo(30), isDefault: true)
private let recent = project(id: 2, title: "Recent", lastEdited: daysAgo(1))

func runSignedIn() {
    print("Signing in with a star set")

    check("opens the starred project",
          id(LaunchProject.opened(in: [recent, starred], isEphemeralDemo: false)), "1")
    check("whichever way round the list arrives",
          id(LaunchProject.opened(in: [starred, recent], isEphemeralDemo: false)), "1")

    print("")
    print("Signing in with no star")

    // The Home Screen menu falls back to the most recent; a launch does not.
    // Nobody asked for anything, so the list is the honest answer.
    check("stays on the list rather than guessing",
          id(LaunchProject.opened(in: [recent, project(id: 3, title: "Old", lastEdited: daysAgo(9))],
                                  isEphemeralDemo: false)),
          "none")
    // `default: false` is a real answer from the server, not a missing one.
    check("an unstarred flag is not a star",
          id(LaunchProject.opened(in: [project(id: 4, title: "Not it",
                                               lastEdited: daysAgo(40), isDefault: false)],
                                  isEphemeralDemo: false)),
          "none")
    check("an account with no projects opens nothing",
          id(LaunchProject.opened(in: [], isEphemeralDemo: false)), "none")
}

func runSignedOut() {
    print("")
    print("Signed out, on this device's own workspace")

    // The same rule as an account. A device with no account keeps what it
    // wrote, stars included, so the star here is a choice the writer made and
    // not a leftover of the seed.
    check("honours the star like any other session",
          id(LaunchProject.opened(in: [recent, starred], isEphemeralDemo: false)), "1")
    check("and stays on the list without one",
          id(LaunchProject.opened(in: [recent], isEphemeralDemo: false)), "none")
}

func runDemo() {
    print("")
    print("The throwaway demo")

    // Reseeded every launch, and nothing in it is ever starred.
    check("opens the sample screenplay it leads with",
          id(LaunchProject.opened(in: [recent, starred], isEphemeralDemo: true)), "2")
    check("with nothing to show, nothing opens",
          id(LaunchProject.opened(in: [], isEphemeralDemo: true)), "none")
}

func runStarLookup() {
    print("")
    print("Reading the star")

    check("the flag the server sends", Project.starred(in: [recent, starred])?.id ?? 0, 1)
    check("an omitted flag is not a star", starred.isTheDefault, true)
    check("and a project without one is not", recent.isTheDefault, false)
}

print("== What a launch opens ==")
runSignedIn()
runSignedOut()
runDemo()
runStarLookup()

print("")
if failures == 0 {
    print("Launch project checks passed.")
} else {
    print("\(failures) launch project check(s) FAILED.")
}
exit(failures == 0 ? 0 : 1)
