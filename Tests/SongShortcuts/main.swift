//
//  Song and note shortcut checks
//
//  Two screens offer a shortcut straight to a song or a note — the script's
//  Songs & Notes menu and the strip at the head of each list — and both take
//  their handful from `mostRecentlyEdited`. So the rule is worth pinning: which
//  ones it picks, in which order, and what it does with one the server never
//  dated. The last group pins what tells one request for the Songs & Notes
//  screen from another, which is what decides the list it opens on.
//
//  The failure this guards against is quiet. A shortcut list that silently
//  ordered itself by id, or that let an undated row take a slot, still looks
//  like a list of songs — it is only wrong about the one thing it exists for.
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

/// A list-shaped song: a title, and the date the server last saw it change.
func song(_ id: Int, _ title: String, minutesAgo: Int?) -> TextDocument {
    // A fixed instant rather than `now`, so a check cannot depend on how long
    // the suite took to reach it.
    let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    return TextDocument(
        id: id,
        projectId: 1,
        projectTitle: nil,
        title: title,
        documentType: "SONG",
        documentTypeLabel: "Song",
        content: nil,
        preview: nil,
        sortOrder: id,
        createdAt: epoch,
        updatedAt: minutesAgo.map { epoch.addingTimeInterval(TimeInterval(-60 * $0)) },
        links: nil)
}

func titles(_ documents: [TextDocument]) -> String {
    documents.map(\.displayTitle).joined(separator: ", ")
}

@MainActor
func run() {
    print("Newest first")
    do {
        let songs = [
            song(1, "Oldest", minutesAgo: 90),
            song(2, "Newest", minutesAgo: 1),
            song(3, "Middle", minutesAgo: 30)
        ]
        check("ordered by when they were last edited",
              titles(songs.mostRecentlyEdited(limit: 3)), "Newest, Middle, Oldest")
        // The list arrives in the writer's own arrangement, which says nothing
        // about recency — the shortcut must not simply hand that back.
        check("the stored order is not what comes out",
              titles(songs.mostRecentlyEdited(limit: 3)) == titles(songs), false)
    }

    print("")
    print("The cap")
    do {
        let songs = (1...6).map { song($0, "Song \($0)", minutesAgo: $0) }
        check("takes no more than asked", songs.mostRecentlyEdited(limit: 3).count, 3)
        check("and takes the newest of them",
              titles(songs.mostRecentlyEdited(limit: 3)), "Song 1, Song 2, Song 3")
        check("a shorter list is not padded", songs.mostRecentlyEdited(limit: 10).count, 6)
        check("asking for none gives none", songs.mostRecentlyEdited(limit: 0).count, 0)
        check("an empty list stays empty",
              [TextDocument]().mostRecentlyEdited(limit: 3).count, 0)
    }

    print("")
    print("Songs the server never dated")
    do {
        let songs = [
            song(1, "Undated", minutesAgo: nil),
            song(2, "Dated", minutesAgo: 5)
        ]
        // Left out rather than sorted as ancient: an undated song has nothing
        // to be recent about, and taking a slot is the one thing it must not do.
        check("are left out", titles(songs.mostRecentlyEdited(limit: 3)), "Dated")
        check("even when nothing else is dated",
              [song(1, "Undated", minutesAgo: nil)].mostRecentlyEdited(limit: 3).count, 0)
    }

    print("")
    print("Two edited at the same moment")
    do {
        let songs = [
            song(1, "beta", minutesAgo: 5),
            song(2, "Alpha", minutesAgo: 5)
        ]
        // By title, and case-insensitively, so the pair keeps one order rather
        // than swapping places between two draws of the same menu.
        check("fall back to title", titles(songs.mostRecentlyEdited(limit: 2)), "Alpha, beta")
    }

    print("")
    print("A song with no title")
    do {
        let untitled = TextDocument(
            id: 9, projectId: 1, projectTitle: nil, title: nil,
            documentType: "SONG", documentTypeLabel: nil, content: nil, preview: nil,
            sortOrder: 1, createdAt: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000), links: nil)
        // It still gets a shortcut — it is a song the writer was just in — and
        // it is named the same way the lists name it.
        check("keeps the placeholder name the lists give it",
              titles([untitled].mostRecentlyEdited(limit: 1)), "Untitled Song")
    }

    print("")
    print("Which list the Songs & Notes screen was asked for")
    do {
        // The screen is presented as this request's *item*, and its list is
        // seeded from the request the first time that item exists. So two
        // requests for different lists have to be two identities — otherwise
        // the second opening reuses the first one's state and "All Notes…"
        // lands on songs, which is exactly the bug this identity exists to fix.
        check("songs and notes are told apart",
              DocumentsRequest(type: .song).id == DocumentsRequest(type: .notes).id, false)
        check("the same list asked for twice is one request",
              DocumentsRequest(type: .song).id, DocumentsRequest(type: .song).id)
        // A widget row names the document as well as the list, and opening two
        // different songs in turn has to re-present rather than reopen the first.
        check("two songs on one list are told apart",
              DocumentsRequest(type: .song, documentId: 1).id
                  == DocumentsRequest(type: .song, documentId: 2).id, false)
        check("naming a document differs from opening the list",
              DocumentsRequest(type: .song, documentId: 1).id
                  == DocumentsRequest(type: .song).id, false)
    }
}

MainActor.assumeIsolated { run() }

print("")
if failures == 0 {
    print("Song and note shortcut checks passed.")
    exit(0)
} else {
    print("\(failures) song and note shortcut check(s) FAILED.")
    exit(1)
}
