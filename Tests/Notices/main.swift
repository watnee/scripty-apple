//
//  DismissedNotices checks
//
//  The whole feature is one question — how long does a closed notice stay
//  closed — and the answer is "for as long as the situation it was about". The
//  two ways to get that wrong are both bad: forget the tap too eagerly and the
//  strip climbs back up the screen on the next keystroke; hold it too long and
//  a writer who dismissed "You're offline" this morning never hears that the
//  server has started refusing their words.
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

@MainActor
func run() {
    print("Closing a notice")
    do {
        let notices = DismissedNotices()
        let key = "script.held.7"
        check("nothing is dismissed to begin with",
              notices.isDismissed(key, state: "offline"), false)
        notices.dismiss(key, state: "offline")
        check("the closed situation stays closed",
              notices.isDismissed(key, state: "offline"), true)
        // The banner switching from patience to a refusal is news, and news
        // outranks a tap that was about something else.
        check("a different situation is not covered",
              notices.isDismissed(key, state: "failed:1"), false)
    }

    print("")
    print("Held work is named by kind, not by count")
    do {
        // What the screenplay hands in while the writer types offline. If the
        // count were part of it, the strip would come straight back up.
        let notices = DismissedNotices()
        let key = "script.held.7"
        notices.dismiss(key, state: "offline")
        check("typing another line does not raise it",
              notices.isDismissed(key, state: "offline"), true)
        // A refusal does carry its count, so a second one speaks up.
        notices.dismiss(key, state: "failed:1")
        check("the refusal that was read stays down",
              notices.isDismissed(key, state: "failed:1"), true)
        check("another refusal is a new one",
              notices.isDismissed(key, state: "failed:2"), false)
    }

    print("")
    print("The situation moving on retires the dismissal")
    do {
        let notices = DismissedNotices()
        let key = "script.held.7"
        notices.dismiss(key, state: "offline")
        // Back online: the strip has nothing to say, and the tap that put it
        // down stops applying.
        notices.situationChanged(key)
        check("offline again is told again",
              notices.isDismissed(key, state: "offline"), false)
    }

    print("")
    print("One notice at a time")
    do {
        let notices = DismissedNotices()
        notices.dismiss("script.held.7", state: "offline")
        check("another screenplay is unaffected",
              notices.isDismissed("script.held.8", state: "offline"), false)
        check("a song is unaffected",
              notices.isDismissed(DismissedNotices.offlineCopyKey(songId: 7),
                                  state: "12345.0"), false)
        notices.situationChanged("script.held.8")
        check("clearing one leaves the other closed",
              notices.isDismissed("script.held.7", state: "offline"), true)
    }

    print("")
    print("Stale copies")
    do {
        let notices = DismissedNotices()
        let savedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let newer = Date(timeIntervalSinceReferenceDate: 2_000)
        // The song editor and the songs workspace show the same lyric: one
        // key, one state, so closing it in either place closes it in both.
        let key = DismissedNotices.offlineCopyKey(songId: 7)
        check("both screens spell the key the same way", key, "song.offlineCopy.7")
        notices.dismiss(key, state: DismissedNotices.offlineCopyState(savedAt: savedAt))
        check("the copy that was read stays quiet",
              notices.isDismissed(key,
                                  state: DismissedNotices.offlineCopyState(savedAt: savedAt)),
              true)
        // A newer cached copy is a different thing to be told.
        check("a newer copy still announces itself",
              notices.isDismissed(key,
                                  state: DismissedNotices.offlineCopyState(savedAt: newer)),
              false)
    }

    print("")
    print("Nothing survives the app")
    do {
        // Deliberately not persisted: an app that opens offline should say so,
        // whatever was tapped in some earlier session.
        let notices = DismissedNotices()
        notices.dismiss("projects.offlineCopy", state: "12345.0")
        let relaunched = DismissedNotices()
        check("a fresh store remembers nothing",
              relaunched.isDismissed("projects.offlineCopy", state: "12345.0"), false)
    }
}

MainActor.assumeIsolated { run() }

print("")
if failures == 0 {
    print("Notice dismissal checks passed.")
    exit(0)
} else {
    print("\(failures) notice dismissal check(s) FAILED.")
    exit(1)
}
