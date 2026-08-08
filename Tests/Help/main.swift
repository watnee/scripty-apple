//
//  main.swift
//  Tests/Help
//
//  The help centre's search box, checked without one.
//
//  Search is the only part of the help centre with any behaviour in it, and
//  all of that behaviour is in `HelpSearch.swift` and `HelpTopic.results(for:)`
//  — no view, no environment, nothing to run. Which means the two things that
//  used to go wrong here are both checkable: a query finding topics it has
//  nothing to do with, and a query finding the right topic and burying it.
//
//  So the checks come in three kinds. What the words are (a query is cut the
//  same way the prose is, so punctuation and accents cannot hide a match).
//  What matches (a prefix of a word, not a substring of the paragraph). And
//  what comes first (a heading beats a keyword beats a paragraph, and ties do
//  not shuffle between keystrokes).
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

/// The ids of every topic a query finds, best first.
func found(_ query: String) -> [String] {
    HelpTopic.results(for: query).sections.flatMap { $0.topics.map(\.id) }
}

print("== The content is there to be searched ==")
do {
    check("there are sections", !HelpTopic.sections.isEmpty)
    check("every section has topics", HelpTopic.sections.allSatisfy { !$0.topics.isEmpty })
    let topics = HelpTopic.sections.flatMap(\.topics)
    checkEqual("topic ids are unique", Set(topics.map(\.id)).count, topics.count)
    check("every topic says something", topics.allSatisfy { !$0.paragraphs.isEmpty })
    check("every topic is indexed", topics.allSatisfy { HelpTopic.index[$0.id] != nil })
    checkEqual("the index holds nothing else", HelpTopic.index.count, topics.count)
}

print()
print("== Cutting text into words ==")
do {
    checkEqual("plain words", HelpText.words("Find and Replace"), ["find", "and", "replace"])
    checkEqual("punctuation is not part of a word",
               HelpText.words("Find & Replace, please."), ["find", "replace", "please"])
    checkEqual("an apostrophe holds a word together",
               HelpText.words("doesn\u{2019}t"), ["doesn't"])
    checkEqual("and either apostrophe is the same one",
               HelpText.words("doesn't"), HelpText.words("doesn\u{2019}t"))
    checkEqual("a quotation mark does not",
               HelpText.words("\u{201C}Untitled Song\u{201D}"), ["untitled", "song"])
    checkEqual("a closing single quote is trimmed off the end",
               HelpText.words("the writers\u{2019} room"), ["the", "writers", "room"])
    checkEqual("accents fold", HelpText.words("r\u{00E9}sum\u{00E9}"), ["resume"])
    checkEqual("digits are words", HelpText.words("iOS 26"), ["ios", "26"])
    checkEqual("nothing in, nothing out", HelpText.words("   \u{2014}  "), [])

    checkEqual("a plural loses its s", HelpText.stem("notes"), "note")
    checkEqual("a short word keeps it", HelpText.stem("its"), "its")
    checkEqual("a double s is not a plural", HelpText.stem("press"), "press")
}

print()
print("== A word matches the start of a word ==")
do {
    // The bug this replaced: three letters that are a substring of half the
    // help centre dragged half the help centre back with them.
    check("a word begins with the query", HelpQuery.word("action", answers: "act"))
    check("a word merely containing it does not",
          !HelpQuery.word("character", answers: "act")
              && !HelpQuery.word("exactly", answers: "act")
              && !HelpQuery.word("practice", answers: "act"))
    check("a prefix reaches its word", found("elem").contains("elements"))

    // The same rule, applied to a string with no index behind it — a row of
    // the keyboard reference, as the help results use it.
    check("every word of the query has to land", HelpQuery("move up").matches("Move Up"))
    check("one word missing is a miss", !HelpQuery("move sideways").matches("Move Up"))
    check("and it is a prefix there too", !HelpQuery("ove").matches("Move Up"))
    check("a singular query finds the plural", found("passkey").contains("passkeys"))
    check("a plural query finds the singular", found("passkeys").contains("passkeys"))
    check("punctuation in the query is ignored",
          found("find & replace").contains("find-replace"))
    checkEqual("punctuation alone is an empty query", HelpQuery("&\u{2014},").isEmpty, true)
}

print()
print("== A query narrows ==")
do {
    checkEqual("an empty query is the whole map",
               HelpTopic.results(for: "   ").sections.count, HelpTopic.sections.count)
    check("an empty query is not a partial one",
          !HelpTopic.results(for: "   ").isPartial)
    check("a query that matches nothing finds nothing",
          HelpTopic.results(for: "zzzznotatopic").isEmpty)
    check("no section comes back empty",
          HelpTopic.results(for: "song").sections.allSatisfy { !$0.topics.isEmpty })
    check("a second word narrows",
          found("title page").count <= found("page").count)
    checkEqual("matches(_:) agrees with the search",
               Set(found("passkey")),
               Set(HelpTopic.sections.flatMap(\.topics).filter { $0.matches("passkey") }.map(\.id)))
}

print()
print("== The best answer is first ==")
do {
    check("a heading beats a paragraph", found("passkey").first == "passkeys")
    check("the whole heading, in order, wins",
          found("find replace").first == "find-replace")
    check("a heading wins over a mention", found("title page").first == "title-page")
    check("a keyword beats a paragraph", found("backup").first == "project-transfer")

    // Ranking has to be a function of the query alone. A search that reorders
    // equally good answers between keystrokes cannot be read while typing.
    checkEqual("the same query gives the same order", found("song"), found("song"))

    // A word in the section heading is a word about its topics.
    check("a section heading is searchable",
          !HelpTopic.results(for: "collaboration").isEmpty)
}

print()
print("== Nothing matches all of it ==")
do {
    // Two words that each land, but never on the same topic. The old search
    // called that nothing at all.
    let partial = HelpTopic.results(for: "passkey epub")
    check("some of the words is better than none of them", !partial.isEmpty)
    check("and it says so", partial.isPartial)
    check("every topic in a partial result matched something",
          partial.sections.allSatisfy { !$0.topics.isEmpty })

    // One word either lands or it does not; there is no lesser match to fall
    // back to, and a partial banner over an empty screen helps nobody.
    let single = HelpTopic.results(for: "zzzznotatopic")
    check("one word has no partial reading", !single.isPartial)
    check("two words that both miss still find nothing",
          HelpTopic.results(for: "zzzznotatopic zzzzeither").isEmpty)
}

print()
print("== Showing the reader where it landed ==")
do {
    let query = HelpQuery("song")
    let text = "Songs and Notes are written outside the screenplay."
    let ranges = query.matchRanges(in: text)
    checkEqual("one word, one range", ranges.count, 1)
    checkEqual("and it is the word", ranges.first.map { String(text[$0]) }, "Songs")

    check("an empty query marks nothing", HelpQuery(" ").matchRanges(in: text).isEmpty)
    checkEqual("every match is marked, not just the first",
               HelpQuery("note").matchRanges(in: "A note, another note, a third note.").count, 3)

    // The ranges are into the string as given, so anything that is not one
    // Character per code unit has to survive the round trip.
    let emoji = "A \u{1F3AC} clapper: the film starts."
    let filmRanges = HelpQuery("film").matchRanges(in: emoji)
    checkEqual("an emoji does not shift the ranges",
               filmRanges.first.map { String(emoji[$0]) }, "film")

    checkEqual("a match is found through an accent",
               HelpQuery("resume").matchRanges(in: "the r\u{00E9}sum\u{00E9} of it").count, 1)
}

print()
if failures == 0 {
    print("ALL CHECKS PASSED")
    exit(0)
} else {
    print("\(failures) CHECK(S) FAILED")
    exit(1)
}
