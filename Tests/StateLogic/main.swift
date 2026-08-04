//
//  Search and selection checks
//
//  ScriptSearchModel and BlockSelectionModel are pure logic the editor leans
//  on constantly — find/replace's switches decide which elements a bulk
//  replace rewrites, and the selection set is what every bulk endpoint is
//  sent. Neither had a check before this suite. What is worth pinning is the
//  narrowing: find hits names and tags, replace only ever touches content,
//  and the case/whole-word switches apply to replace alone.
//
//  Run via Tests/run.sh.
//

import Foundation

var failures = 0

func check(_ label: String, _ condition: Bool) {
    print(condition ? "  PASS  \(label)" : "  FAIL  \(label)")
    if !condition { failures += 1 }
}

func checkEqual<T: Equatable>(_ label: String, _ actual: T, _ expected: T) {
    let ok = actual == expected
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)\n          expected: \(expected)\n          actual:   \(actual)")
    if !ok { failures += 1 }
}

func block(_ id: Int, _ type: String, _ content: String,
           personName: String? = nil, tags: String? = nil) -> Block {
    let name = personName.map { ",\"personName\":\"\($0)\"" } ?? ""
    let tagged = tags.map { ",\"tags\":\"\($0)\"" } ?? ""
    let json = #"{"id":\#(id),"type":"\#(type)","content":"\#(content)"\#(name)\#(tagged)}"#
    return try! JSONDecoder().decode(Block.self, from: json.data(using: .utf8)!)
}

/// A small script with a hit in every field find covers: content, the
/// speaking character's name, and an element's tags.
let script = [
    block(1, "SCENE", "INT. BAR - NIGHT"),
    block(2, "ACTION", "The boom fell on the monitor."),
    block(3, "CHARACTER", "MAYA", personName: "Maya Boome"),
    block(4, "DIALOGUE", "The boom added realism.", tags: "boom, stunts"),
    block(5, "ACTION", "A boombox plays.")
]

@MainActor
func searchChecks() {
    print("== Find covers content, names and tags; the cursor stays put ==")
    do {
        let search = ScriptSearchModel()
        search.query = "boom"
        search.refresh(in: script)

        checkEqual("every field's hit is found", search.matches.map(\.blockId), [2, 3, 4, 5])
        checkEqual("a content hit says so", search.matches[0].field.label, "Text")
        checkEqual("a name hit says so", search.matches[1].field.label, "Character")
        checkEqual("the readout counts from one", search.statusText, "1 of 4")

        // Walking wraps in both directions.
        search.next(); search.next(); search.next()
        checkEqual("next reaches the last hit", search.current?.blockId, 5)
        search.next()
        checkEqual("and wraps to the first", search.current?.blockId, 2)
        search.previous()
        checkEqual("previous wraps to the last", search.current?.blockId, 5)

        // Typing on: the block under the cursor still matches, so the cursor
        // must not jump back to the top.
        search.select(search.matches[2])
        checkEqual("select lands on the chosen hit", search.current?.blockId, 4)
        search.query = "boom,"
        search.refresh(in: script)
        checkEqual("a narrowed query keeps the matching block", search.current?.blockId, 4)

        search.query = "nothing anywhere"
        search.refresh(in: script)
        checkEqual("no hits reads as no results", search.statusText, "No results")
        check("and there is no current hit", search.current == nil)
    }

    print()
    print("== The literal-match rules replace honours ==")
    do {
        check("plain find ignores case",
              ScriptSearchModel.containsMatch("The Boom fell", needle: "boom",
                                              matchCase: false, wholeWord: false))
        check("match-case does not",
              !ScriptSearchModel.containsMatch("The Boom fell", needle: "boom",
                                               matchCase: true, wholeWord: false))
        check("whole-word rejects a word that merely contains the query",
              !ScriptSearchModel.containsMatch("A boombox plays", needle: "boom",
                                               matchCase: false, wholeWord: true))
        check("and accepts the word on its own",
              ScriptSearchModel.containsMatch("The boom fell", needle: "boom",
                                              matchCase: false, wholeWord: true))
        check("a needle with regex characters stays literal",
              ScriptSearchModel.containsMatch("Cut to: INT. BAR", needle: "INT. BAR",
                                              matchCase: false, wholeWord: true))
    }

    print()
    print("== Replace is narrower than find ==")
    do {
        let search = ScriptSearchModel()
        search.query = "boom"
        search.refresh(in: script)

        // Character cues mirror their person record, so replace leaves them
        // alone unless asked; and only *content* is ever rewritten, so a hit
        // on a person's name or a tag is no target under either switch.
        let cueScript = script + [block(6, "CHARACTER", "BOOM OPERATOR")]
        checkEqual("targets are content matches outside the cues",
                   search.replaceTargetIds(in: cueScript), [2, 4, 5])
        search.includeCharacterCues = true
        checkEqual("opting in adds the cue whose text matches — and only that one",
                   search.replaceTargetIds(in: cueScript), [2, 4, 5, 6])
        search.includeCharacterCues = false

        search.wholeWord = true
        checkEqual("the switches narrow the targets",
                   search.replaceTargetIds(in: script), [2, 4])
        search.wholeWord = false

        // The single Replace acts on the current hit — but only when its
        // *text* holds a match under the switches.
        checkEqual("the current content hit is the single target",
                   search.currentReplaceTarget(in: script)?.id, 2)
        search.next()
        check("a hit on a character name has no text to swap",
              search.currentReplaceTarget(in: script) == nil)
        search.next(); search.next()
        search.wholeWord = true
        check("a hit the switches exclude has no target either",
              search.currentReplaceTarget(in: script) == nil)
    }

    print()
    print("== The replace tally is kept, not recomputed per keystroke ==")
    do {
        // The bar asks for this three times in one pass of its body, and
        // typing in the *replacement* field redraws that body per character.
        // So it is filled on the debounced path and read from there — which
        // only works if everything that can change the answer says so.
        let search = ScriptSearchModel()
        check("nothing is a target before a search", search.replaceTargets.isEmpty)

        search.query = "boom"
        search.refresh(in: script)
        checkEqual("a refresh fills it",
                   search.replaceTargets, search.replaceTargetIds(in: script))
        check("and it is not empty for a query that matches",
              !search.replaceTargets.isEmpty)

        // The three switches are not debounced. Each has to refresh, or the
        // tally silently describes the previous setting.
        search.wholeWord = true
        search.refreshReplaceTargets(in: script)
        checkEqual("whole word narrows it",
                   search.replaceTargets, search.replaceTargetIds(in: script))
        search.wholeWord = false

        let cueScript = script + [block(6, "CHARACTER", "BOOM OPERATOR")]
        search.includeCharacterCues = true
        search.refreshReplaceTargets(in: cueScript)
        checkEqual("opting into cues widens it",
                   search.replaceTargets, search.replaceTargetIds(in: cueScript))
        search.includeCharacterCues = false

        search.refreshAfterReplace(in: script)
        checkEqual("a replace leaves it describing what is there now",
                   search.replaceTargets, search.replaceTargetIds(in: script))

        search.clear()
        check("clearing the search clears it too", search.replaceTargets.isEmpty)

        // A query nothing matches has no targets, and the emptied query must
        // not leave the last one's tally behind it.
        search.query = "nothinghere"
        search.refresh(in: script)
        check("a query that matches nothing has no targets", search.replaceTargets.isEmpty)
    }

    print()
    print("== After a replace, the cursor walks forward ==")
    do {
        let search = ScriptSearchModel()
        search.query = "boom"
        search.refresh(in: script)
        search.select(search.matches[3])

        // The last hit's text was rewritten and no longer matches: the cursor
        // slides to the nearest remaining hit instead of snapping to the top.
        let rewritten = [
            script[0], script[1], script[2], script[3],
            block(5, "ACTION", "A stereo plays.")
        ]
        search.refreshAfterReplace(in: rewritten)
        checkEqual("the dropped block's place is taken by the nearest hit",
                   search.current?.blockId, 4)

        // A block that still matches keeps the cursor even when others left.
        search.refreshAfterReplace(in: [script[3]])
        checkEqual("a still-matching block keeps the cursor", search.current?.blockId, 4)
    }
}

@MainActor
func selectionChecks() {
    print()
    print("== Selection: what a bulk action is actually sent ==")
    do {
        let selection = BlockSelectionModel()
        selection.isSelecting = true
        selection.toggle(4)
        selection.toggle(2)
        selection.toggle(5)
        selection.toggle(5)
        checkEqual("toggling on, on, off leaves two", selection.count, 2)
        check("membership answers", selection.isSelected(4) && !selection.isSelected(5))

        // Order follows the script, not the taps — the request must be
        // reproducible whatever order the writer touched rows in.
        checkEqual("ordered ids follow the script", selection.orderedIds(in: script), [2, 4])

        // Select-all honours the visible (possibly filtered) set.
        selection.selectAll([1, 2])
        checkEqual("select-all unions the visible rows",
                   selection.orderedIds(in: script), [1, 2, 4])

        // A sync that removed blocks can't leave phantom ids to be posted.
        selection.prune(toExisting: [1, 4])
        checkEqual("pruning drops ids the script no longer has",
                   selection.orderedIds(in: script), [1, 4])

        // Leaving selection mode clears, so a stale set can't be reapplied.
        selection.isSelecting = false
        check("leaving selection mode clears it", selection.isEmpty)
    }

    // What a swipe across a row means: the mode comes on around the element it
    // was made on, and the element is in the set — the toolbar never involved.
    do {
        let selection = BlockSelectionModel()
        selection.toggleEnteringMode(4)
        check("a swipe turns the mode on", selection.isSelecting)
        checkEqual("and the element it was made on is in the set",
                   selection.orderedIds(in: script), [4])

        // Inside the mode it goes on meaning what a tap means, both ways.
        selection.toggleEnteringMode(2)
        checkEqual("a second swipe adds to the set",
                   selection.orderedIds(in: script), [2, 4])
        selection.toggleEnteringMode(4)
        checkEqual("swiping a picked element again drops it",
                   selection.orderedIds(in: script), [2])
        check("and the mode stays on whether the swipe took or dropped",
              selection.isSelecting)
    }
}

@MainActor
func run() {
    searchChecks()
    selectionChecks()

    print()
    if failures == 0 {
        print("ALL CHECKS PASSED")
    } else {
        print("\(failures) CHECK(S) FAILED")
    }
}

// The await is the hop onto the main actor — top-level code here is
// nonisolated, so a plain call would not compile.
await run()
exit(failures == 0 ? 0 : 1)
