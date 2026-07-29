//
//  Song shortcut ordering checks
//
//  Two screens offer a shortcut straight to a song — the script's Songs menu
//  and the strip at the head of the songs list — and both take their handful
//  from `mostRecentlyEdited`. So the rule is worth pinning: which songs it
//  picks, in which order, and what it does with one the server never dated.
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

/// The same, as the server's other kinds spell themselves. A nil type is what
/// an older server sends for a document it never classified.
func document(_ id: Int, _ title: String, type: String?, minutesAgo: Int?) -> TextDocument {
    var made = song(id, title, minutesAgo: minutesAgo)
    made.documentType = type
    return made
}

func titles(_ documents: [TextDocument]) -> String {
    documents.map(\.displayTitle).joined(separator: ", ")
}

/// How the two shortcut menus divide one project's documents between them —
/// the same predicates `ScriptModel.songs` and `.notes` use.
func songsAmong(_ documents: [TextDocument]) -> [TextDocument] {
    documents.filter { $0.kind == .song }
}

func notesAmong(_ documents: [TextDocument]) -> [TextDocument] {
    documents.filter { $0.kind != .song }
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
    print("Songs and notes are two shortcut lists")
    do {
        // One project's documents, interleaved in time, as the server returns
        // them: the script's Songs & Notes menu draws a section from each.
        let all = [
            document(1, "Ballad", type: "SONG", minutesAgo: 40),
            document(2, "Blocking", type: "NOTES", minutesAgo: 30),
            document(3, "Finale", type: "SONG", minutesAgo: 10),
            document(4, "Casting", type: "NOTES", minutesAgo: 20)
        ]
        // The failure this guards is a menu whose "Recent Notes" quietly leads
        // with a song, or vice versa — each section is drawn from its own kind
        // and takes its own newest, not the project's.
        check("the songs section holds only songs, newest first",
              titles(songsAmong(all).mostRecentlyEdited(limit: 3)), "Finale, Ballad")
        check("the notes section holds only notes, newest first",
              titles(notesAmong(all).mostRecentlyEdited(limit: 3)), "Casting, Blocking")
        // Each section is capped on its own, so a busy week of songs cannot
        // crowd the notes out of the menu.
        check("the caps do not share a budget",
              titles(notesAmong(all).mostRecentlyEdited(limit: 1)), "Casting")
    }

    print("")
    print("Documents the server typed oddly")
    do {
        let all = [
            document(1, "Sketch", type: "OTHER", minutesAgo: 20),
            document(2, "Unclassified", type: nil, minutesAgo: 10)
        ]
        // OTHER is not a song, and the notes list is where the screen puts it —
        // it is the half that means "everything else".
        check("OTHER goes to the notes", titles(notesAmong(all).mostRecentlyEdited(limit: 2)),
              "Sketch")
        // An untyped document falls back to SONG, which is the server's own
        // default for a new one, so the two shortcut lists between them still
        // account for every document in the project.
        check("an untyped one falls back to a song",
              titles(songsAmong(all).mostRecentlyEdited(limit: 2)), "Unclassified")
    }
}

MainActor.assumeIsolated { run() }

print("")
if failures == 0 {
    print("Song shortcut checks passed.")
    exit(0)
} else {
    print("\(failures) song shortcut check(s) FAILED.")
    exit(1)
}
