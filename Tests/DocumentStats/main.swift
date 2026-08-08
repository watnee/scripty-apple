//
//  Song and note statistics checks
//
//  The arithmetic behind the two stats sheets. Most of it is counting, and the
//  reason it is worth pinning is the one thing counting can do wrong quietly:
//  disagree with the count already on screen. The first check below is the
//  anti-drift one — `DocumentStats.words` has to equal `ScriptStats.countWords`
//  over the same text, because the "…" row a writer taps and the Words tile
//  they land on are a single gesture apart, and two different numbers for one
//  song reads as one of them being broken.
//
//  Sections are the other place judgement crept in: they are runs of non-blank
//  lines, which is the only structural signal a lyric really carries. Leading
//  and trailing blanks, and runs of several, all have to fall out right.
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

func song(_ lines: [String]) -> DocumentStats { DocumentStats(lyricLines: lines) }
func note(_ text: String) -> DocumentStats { DocumentStats(noteText: text) }

print("== Agreeing with the count already on screen ==")
let verse = ["the sun goes down", "and I go with it", "", "over and over"]
check("words match ScriptStats.countWords over the same text",
      song(verse).words,
      verse.reduce(0) { $0 + ScriptStats.countWords($1) })
check("and that is twelve of them", song(verse).words, 12)

print()
print("== Lines and sections ==")
check("blank lines are counted apart", song(verse).blankLines, 1)
check("only lines with something on them", song(verse).lines, 3)
check("two runs of lines is two sections", song(verse).sections, 2)
check("no blank line at all is one section",
      song(["one", "two", "three"]).sections, 1)
// A writer's spacing is theirs: several blank lines in a row is still one gap,
// and a gap at either end opens or closes nothing.
check("a run of blanks is still one gap",
      song(["one", "", "", "", "two"]).sections, 2)
check("a leading blank opens no section",
      song(["", "one", "two"]).sections, 1)
check("a trailing blank closes nothing extra",
      song(["one", "two", ""]).sections, 1)
check("whitespace-only counts as blank",
      song(["one", "   ", "two"]).sections, 2)

print()
print("== The empty song ==")
check("nothing at all", song([]).hasNothingToMeasure, true)
check("one empty line is still nothing", song([""]).hasNothingToMeasure, true)
check("one word is something", song(["hello"]).hasNothingToMeasure, false)
check("and reads in under a minute", song(["hello"]).readingTimeText, "under a minute")

print()
print("== Longest line ==")
let mixed = ["short", "this line has rather more words in it", "middling words here"]
check("the longest is found", song(mixed).longestLine,
      "this line has rather more words in it")
check("and its length reported", song(mixed).longestLineWords, 8)
check("a one-line song is its own longest", song(["only this"]).longestLineWords, 2)
check("an empty song has none", song([]).longestLine, "")

print()
print("== Unique words ==")
check("case is folded", song(["Love love LOVE"]).uniqueWords, 1)
check("punctuation on the ends is stripped",
      song(["love, love. love!"]).uniqueWords, 1)
// An apostrophe is inside the word, not on the end of it — "don't" is one word
// and "dont" is not a word at all.
check("an apostrophe is kept", song(["don't", "dont"]).uniqueWords, 2)
check("different words counted separately",
      song(["the sun and the moon"]).uniqueWords, 4)

print()
print("== Characters ==")
check("counted as written, newlines and all", song(["ab", "cd"]).characters, 5)
check("and again without the spaces", song(["a b", "c d"]).charactersNoSpaces, 4)

print()
print("== Reading time ==")
// 200 words a minute, so 200 words is a minute and 600 is three.
check("two hundred words is a minute",
      song([Array(repeating: "word", count: 200).joined(separator: " ")]).readingTimeText,
      "1 min")
check("six hundred is three",
      song([Array(repeating: "word", count: 600).joined(separator: " ")]).readingTimeText,
      "3 min")
check("a handful is under a minute", song(["one two three"]).readingTimeText, "under a minute")

print()
print("== Notes ==")
let noteText = """
# Opening

Some prose here.

- first
- second
1. numbered
"""
let n = note(noteText)
check("headings counted through NoteFormatting", n.headings, 1)
check("list items too, ordered and not", n.listItems, 3)
check("a song has neither", song(["# not a heading here"]).headings, 0)
check("paragraphs are its sections", n.sections, 3)
check("it knows what it is", n.kind, DocumentStats.Kind.note)
check("and labels its longest accordingly", n.longestLineLabel, "Longest paragraph")
check("where a song says line", song(["a"]).longestLineLabel, "Longest line")
check("an empty note", note("").hasNothingToMeasure, true)

print()
if failures == 0 {
    print("ALL CHECKS PASSED")
} else {
    print("\(failures) CHECK(S) FAILED")
    exit(1)
}
