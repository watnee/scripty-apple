//
//  Songs & notes ordering checks
//
//  Rearranging the list is the one gesture that writes the writer's own
//  arrangement back to the server, and the two screens that offer it both do
//  it against a *view* of the list: one narrowed by a search box, or sorted by
//  title or by date rather than by the arrangement itself.
//
//  So the arithmetic that turns "these rows, in this order" back into the whole
//  list is worth pinning. Its failures are the quiet kind — a song that the
//  search happened to be hiding, silently sent to the bottom, is not visible
//  until the search is cleared, by which time nobody knows what moved it.
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

func song(_ id: Int, _ title: String) -> TextDocument {
    TextDocument(
        id: id,
        projectId: 1,
        projectTitle: nil,
        title: title,
        documentType: "SONG",
        documentTypeLabel: "Song",
        content: nil,
        preview: nil,
        sortOrder: id,
        createdAt: nil,
        updatedAt: nil,
        links: nil)
}

func titles(_ documents: [TextDocument]) -> String {
    documents.map(\.displayTitle).joined(separator: ", ")
}

/// A move that could not be made says so, rather than handing back a list that
/// looks unchanged.
func moved(_ documents: [TextDocument]?) -> String {
    guard let documents else { return "nothing" }
    return titles(documents)
}

@MainActor
func run() {
    let all = [song(1, "A"), song(2, "B"), song(3, "C"), song(4, "D")]

    print("One slot at a time")
    do {
        check("up swaps with the row above", moved(all.moving(all[2], by: -1)), "A, C, B, D")
        check("down swaps with the row below", moved(all.moving(all[1], by: 1)), "A, C, B, D")
        // Nothing rather than a no-op list: the caller must not save an order
        // it did not change, and a disabled menu item is the point of asking.
        check("the top row cannot go up", moved(all.moving(all[0], by: -1)), "nothing")
        check("the last row cannot go down", moved(all.moving(all[3], by: 1)), "nothing")
        check("a row that is not here moves nothing",
              moved(all.moving(song(9, "Elsewhere"), by: -1)), "nothing")
        check("the list itself is left alone", titles(all), "A, B, C, D")
    }

    print("")
    print("A move made against the whole list")
    do {
        // Nothing hidden: the merge has to be the identity, or every ordinary
        // drag would be rewritten on its way to the server.
        // What SwiftUI's `.onMove` hands over: the last row dragged to the top.
        let dragged = [all[3], all[0], all[1], all[2]]
        check("is saved exactly as it was made", titles(all.merging(shown: dragged)), "D, A, B, C")
    }

    print("")
    print("A move made while the search is hiding rows")
    do {
        // "B" and "D" are hidden. The writer sees A, C and puts C first.
        let onScreen = [all[2], all[0]]
        // B keeps the slot it held — second — and D keeps the last, because
        // neither was on screen to be moved past. Only the shown rows change
        // places with each other.
        check("the hidden rows keep their slots",
              titles(all.merging(shown: onScreen)), "C, B, A, D")
        check("and the list keeps its length", all.merging(shown: onScreen).count, 4)
    }

    print("")
    print("A move made against a sorted list")
    do {
        // Sorted Z–A, one row moved. The whole sorted sequence is what gets
        // saved — which is why the screen flips itself to "Custom order".
        let sorted = [all[3], all[2], all[1], all[0]]
        check("saves the sort, with the move in it",
              titles(sorted.merging(shown: sorted)), "D, C, B, A")
    }

    print("")
    print("Rows that no longer belong")
    do {
        // A row deleted on another device can still be on screen here. It must
        // not smuggle itself back into the saved order.
        let stale = [song(9, "Gone"), all[1], all[0]]
        check("are dropped rather than saved",
              titles(all.merging(shown: stale)), "B, A, C, D")
        check("an empty screen changes nothing",
              titles(all.merging(shown: [])), "A, B, C, D")
    }
}

MainActor.assumeIsolated { run() }

print("")
if failures == 0 {
    print("Document ordering checks passed.")
    exit(0)
} else {
    print("\(failures) document ordering check(s) FAILED.")
    exit(1)
}
