//
//  Lyric find-and-replace checks
//
//  The song editor's search used to be a filter: matching lines stayed, the
//  rest were hidden. It is a walk now, the way the screenplay's is, and these
//  pin the two things a walk has to get right — where the cursor is after every
//  change to the query, and what "n of m" says.
//
//  The anchoring rules are the subtle half. Typing another letter must not throw
//  the writer back to the top of the song, and pressing Replace repeatedly must
//  walk forward rather than sticking on a line it has already dealt with. Both
//  are copied from `ScriptSearchModel` and both are checked here.
//
//  The last section is the one that matters most: this model asks
//  `ScriptSearchModel.containsMatch` rather than carrying its own idea of a
//  match, because that function is the client's copy of the server's rule. If
//  the two ever disagree, a Replace All rewrites a different set of lines from
//  the ones the writer was told about.
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
func lines(_ texts: [String]) -> [SongSearchModel.Line] {
    texts.enumerated().map { SongSearchModel.Line(id: $0.offset + 1, text: $0.element) }
}

@MainActor
func run() async {
    let verse = lines([
        "the sun came up",           // 1
        "and nothing moved",         // 2
        "the sun went down",         // 3
        "",                          // 4
        "the sun again",             // 5
    ])

    print("== Stepping ==")
    let model = SongSearchModel()
    model.query = "sun"
    model.refresh(in: verse)
    check("three lines hold it", model.matches.count, 3)
    check("starts on the first", model.statusText, "1 of 3")
    check("and it is the right line", model.current?.lineId ?? 0, 1)

    model.next()
    check("next steps down", model.statusText, "2 of 3")
    model.next()
    model.next()
    check("and wraps at the end", model.statusText, "1 of 3")
    model.previous()
    check("previous wraps backwards", model.statusText, "3 of 3")

    check("selecting a known hit jumps to it", model.select(model.matches[1])?.lineId ?? 0, 3)
    check("and the readout follows", model.statusText, "2 of 3")

    print()
    print("== No query, no results ==")
    let empty = SongSearchModel()
    check("nothing typed says nothing", empty.statusText, "")
    empty.query = "zebra"
    empty.refresh(in: verse)
    check("a word that is not there says so", empty.statusText, "No results")
    check("and there is no current hit", empty.current == nil, true)
    empty.query = "   "
    empty.refresh(in: verse)
    check("whitespace is not a query", empty.hasQuery, false)

    print()
    print("== The cursor holds its line as the query grows ==")
    let growing = SongSearchModel()
    growing.query = "the"
    growing.refresh(in: verse)
    growing.next()
    growing.next()
    check("parked on the third hit", growing.current?.lineId ?? 0, 5)
    growing.query = "the sun"
    growing.refresh(in: verse)
    // Line 5 still matches, so the writer stays where they were looking rather
    // than being thrown back to the top of the song.
    check("still on the same line", growing.current?.lineId ?? 0, 5)
    check("with the tally rewritten", growing.statusText, "3 of 3")

    growing.query = "came"
    growing.refresh(in: verse)
    check("a query its line cannot hold starts over", growing.current?.lineId ?? 0, 1)

    print()
    print("== Replace walks forward ==")
    let replacing = SongSearchModel()
    replacing.query = "sun"
    replacing.refresh(in: verse)
    replacing.next()
    check("on the second hit", replacing.current?.lineId ?? 0, 3)
    // Line 3 has been rewritten and no longer matches; the cursor should land on
    // what slid into its place, not snap back to the top.
    let afterOne = lines([
        "the sun came up",
        "and nothing moved",
        "the moon went down",
        "",
        "the sun again",
    ])
    replacing.refreshAfterReplace(in: afterOne)
    check("lands on what took its place", replacing.current?.lineId ?? 0, 5)
    check("and counts what is left", replacing.statusText, "2 of 2")

    print()
    print("== Replace targets ==")
    let targets = SongSearchModel()
    targets.query = "sun"
    targets.refresh(in: verse)
    check("every matching line is a target", targets.replaceTargets, [1, 3, 5])
    check("the current hit is replaceable", targets.currentReplaceTarget(in: verse) ?? 0, 1)
    targets.query = "zebra"
    targets.refresh(in: verse)
    check("nothing to replace", targets.replaceTargets, [Int]())
    check("and no single target either", targets.currentReplaceTarget(in: verse) == nil, true)

    print()
    print("== Agreeing with the server's rule ==")
    let cased = lines(["Sun and sun", "sunset at sun"])

    let matchCase = SongSearchModel()
    matchCase.query = "sun"
    matchCase.matchCase = true
    matchCase.refresh(in: cased)
    check("match case still finds the lower-case one", matchCase.matches.count, 2)

    let wholeWord = SongSearchModel()
    wholeWord.query = "sun"
    wholeWord.wholeWord = true
    wholeWord.refresh(in: lines(["sunset", "the sun"]))
    check("whole word skips a word it is only inside of", wholeWord.matches.count, 1)
    check("and it is the right line", wholeWord.current?.lineId ?? 0, 2)

    // The rule itself, asked directly — this is the function the server mirrors.
    check("art does not match start under whole word",
          ScriptSearchModel.containsMatch("start", needle: "art",
                                          matchCase: false, wholeWord: true), false)
    check("but does without it",
          ScriptSearchModel.containsMatch("start", needle: "art",
                                          matchCase: false, wholeWord: false), true)
    // A term is literal on both clients and on the server: a dot is a dot.
    check("a full stop is not a wildcard",
          ScriptSearchModel.containsMatch("abc", needle: "a.c",
                                          matchCase: false, wholeWord: false), false)

    print()
    print("== Clearing ==")
    let clearing = SongSearchModel()
    clearing.query = "sun"
    clearing.replacement = "moon"
    clearing.isReplacing = true
    clearing.refresh(in: verse)
    clearing.clear()
    check("the query goes", clearing.query, "")
    check("so does the replacement", clearing.replacement, "")
    check("the replace row closes", clearing.isReplacing, false)
    check("and the hits with it", clearing.matches.count, 0)
    check("targets too", clearing.replaceTargets, [Int]())
}

await run()

print()
if failures == 0 {
    print("ALL CHECKS PASSED")
} else {
    print("\(failures) CHECK(S) FAILED")
    exit(1)
}
