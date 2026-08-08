//
//  Text case checks
//
//  The four transforms offered on a selection. Uppercase and lowercase are
//  Foundation's, and are here only for the one case that catches callers out —
//  a scalar whose case change moves its length, which is what the caret
//  arithmetic in EditorEditMenu has to survive.
//
//  Title Case and Sentence case are the ones with judgement in them, and every
//  check below is a place the obvious implementation gets it wrong:
//  `String.capitalized` makes "don't" into "Don'T", a stop-word list applied
//  everywhere makes "The Book Of" into "The Book of" at the end of a title, and
//  a sentence rule that only watches for "." never capitalises the second line
//  of a lyric.
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

func upper(_ text: String) -> String { TextCaseTransform.uppercase.apply(to: text) }
func lower(_ text: String) -> String { TextCaseTransform.lowercase.apply(to: text) }
func title(_ text: String) -> String { TextCaseTransform.titleCase.apply(to: text) }
func sentence(_ text: String) -> String { TextCaseTransform.sentenceCase.apply(to: text) }

print("== Uppercase and lowercase ==")
check("a slugline shouted", upper("int. kitchen - day"), "INT. KITCHEN - DAY")
check("a cue quietened", lower("JANE"), "jane")

// The reason EditorEditMenu measures the new selection off the result rather
// than reusing the old length: this one gets longer.
check("a scalar that grows when it shouts", upper("straße"), "STRASSE")
check("and the length really moved", upper("straße").count, 7)

print()
print("== Title Case ==")
check("an apostrophe is not a word boundary", title("don't stop"), "Don't Stop")
check("stop words stay down in the middle", title("a tale of two cities"), "A Tale of Two Cities")
// The first and last word are always capitalised, however small they are —
// "The Book Of" reads as a mistake, and "of" ending a title is not a stop.
check("the first word is always up", title("the end"), "The End")
check("the last word is always up", title("what are you waiting for"),
      "What Are You Waiting For")
check("a single stop word on its own", title("the"), "The")
check("already shouted text is brought down", title("THE LONG GOODBYE"), "The Long Goodbye")
check("a hyphenated run is one word", title("rock-'n'-roll"), "Rock-'n'-roll")
check("punctuation does not absorb the capital", title("\"hello there\""), "\"Hello There\"")
check("a stop word wearing a bracket still stops",
      title("the sound (of the city) again"), "The Sound (of the City) Again")
check("spacing is preserved exactly", title("a   tale  of\ttwo"), "A   Tale  of\tTwo")
check("trailing space does not steal last-word status", title("the end "), "The End ")
check("empty text", title(""), "")
check("whitespace only", title("   "), "   ")

print()
print("== Sentence case ==")
check("one sentence", sentence("THE DOOR OPENS."), "The door opens.")
check("two sentences", sentence("he left. she stayed."), "He left. She stayed.")
check("a question mark starts the next one",
      sentence("who was it? nobody knows."), "Who was it? Nobody knows.")
check("so does an exclamation mark",
      sentence("stop! it is over."), "Stop! It is over.")
// A lyric line is its own sentence whether or not it was punctuated. Without
// this, every line after the first in a selected verse would stay lower case.
check("a line break starts a sentence",
      sentence("FIRST LINE\nsecond line"), "First line\nSecond line")
check("a quote between the stop and the letter is transparent",
      sentence("he said. \"come in.\""), "He said. \"Come in.\"")
check("a standalone I survives being lowered", sentence("SHE AND I LEFT"), "She and I left")
check("and so do its contractions", sentence("I'M HERE AND I'LL WAIT"), "I'm here and I'll wait")
check("but a word merely starting with i does not",
      sentence("IT IS INSIDE"), "It is inside")
check("empty text", sentence(""), "")

print()
print("== The menu's own vocabulary ==")
// The titles are what the menu shows, so each should read as its own result.
check("four transforms offered", TextCaseTransform.allCases.count, 4)
check("uppercase reads as itself", TextCaseTransform.uppercase.title, "UPPERCASE")
check("lowercase reads as itself", TextCaseTransform.lowercase.title, "lowercase")
check("every transform has an image",
      TextCaseTransform.allCases.allSatisfy { !$0.systemImage.isEmpty }, true)
// Round-trips through the raw value, which is how a chord carries its transform
// in a UIKeyCommand's propertyList.
check("raw values round-trip",
      TextCaseTransform.allCases.compactMap { TextCaseTransform(rawValue: $0.rawValue) }.count, 4)

print()
if failures == 0 {
    print("ALL CHECKS PASSED")
} else {
    print("\(failures) CHECK(S) FAILED")
    exit(1)
}
