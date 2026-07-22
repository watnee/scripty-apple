//
//  Autocomplete checks
//
//  What is worth pinning here is the *staging*: a heading suggests different
//  things depending on how far through it the writer is, and getting that
//  wrong is the difference between offering NIGHT and offering every scene in
//  the script again. The quiet cases matter as much — an action line that is
//  merely short must not be treated as a character cue.
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

/// Blocks and people arrive as JSON everywhere else, so they are built that
/// way here too rather than by reaching for a memberwise initialiser.
func block(_ id: Int, _ type: String, _ content: String, personId: Int? = nil) -> Block {
    let person = personId.map { ",\"personId\":\($0)" } ?? ""
    let json = #"{"id":\#(id),"type":"\#(type)","content":"\#(content)"\#(person)}"#
    return try! JSONDecoder().decode(Block.self, from: json.data(using: .utf8)!)
}

func person(_ id: Int, _ name: String) -> Person {
    let json = #"{"id":\#(id),"name":"\#(name)"}"#
    return try! JSONDecoder().decode(Person.self, from: json.data(using: .utf8)!)
}

let script = [
    block(1, "SCENE", "INT. BAR - NIGHT"),
    block(2, "CHARACTER", "MAYA", personId: 7),
    block(3, "DIALOGUE", "You didn't call."),
    block(4, "SCENE", "EXT. ROOFTOP - DAY"),
    block(5, "CHARACTER", "THE STRANGER")
]
let cast = [person(7, "MAYA"), person(8, "MARCUS")]

func texts(_ text: String, _ type: BlockType) -> [String] {
    ScriptSuggestions.suggestions(forText: text, type: type,
                                  blocks: script, characters: cast).map(\.text)
}

print("Character cues")
do {
    check("a fresh cue offers the cast",
          texts("", .character), ["MARCUS", "MAYA", "THE STRANGER"])
    check("typing narrows it", texts("MA", .character), ["MARCUS", "MAYA"])
    // A cue written into the script but never made a character still counts.
    check("names only in the script are offered",
          texts("THE", .character), ["THE STRANGER"])
    check("a name typed in full is not suggested back", texts("MARCUS", .character), [String]())

    // An action line is prose until it looks deliberate.
    check("one letter of action is not a cue", texts("M", .action), [String]())
    check("two letters is", texts("MA", .action), ["MARCUS", "MAYA"])
    check("and the force marker is, at any length", texts("@M", .action), ["MARCUS", "MAYA"])
    check("accepting on an action line retypes it",
          ScriptSuggestions.suggestions(forText: "MA", type: .action,
                                        blocks: script, characters: cast).first?.becomesType,
          Optional(BlockType.character))

    let linked = ScriptSuggestions.suggestions(forText: "MAY", type: .character,
                                               blocks: script, characters: cast).first
    check("a suggestion carries the character it names", linked?.personId, Optional(7))
}

print("")
print("Scene headings, stage by stage")
do {
    // Empty: the shapes a heading can take, then the headings already written.
    check("an empty heading offers the prefixes, then the script's own",
          texts("", .scene),
          ["INT. ", "EXT. ", "EST. ", "INT./EXT. ", "I/E. ",
           "EXT. ROOFTOP - DAY", "INT. BAR - NIGHT"])

    // With a prefix: where this script has been. Locations come first, because
    // the writer is filling in a heading rather than repeating a whole one.
    check("a prefix offers locations first",
          texts("INT. ", .scene), ["INT. BAR", "INT. ROOFTOP", "INT. BAR - NIGHT"])
    check("and narrows them", texts("INT. BA", .scene), ["INT. BAR", "INT. BAR - NIGHT"])

    // Past the dash: times of day, and only by prefix — "NI" is NIGHT, not
    // MORNING or EVENING, which merely contain the letters.
    check("a dash offers times of day",
          texts("INT. BAR - NI", .scene), ["INT. BAR - NIGHT"])
    check("times are not offered without a location", texts("INT. - NI", .scene), [String]())

    // A stub still on an action line, before detection has retyped it.
    check("a heading stub on an action line is a heading",
          ScriptSuggestions.looksLikeSceneTyping("IN", type: .action), true)
    check("accepting one retypes the line",
          ScriptSuggestions.suggestions(forText: "INT. BA", type: .action,
                                        blocks: script, characters: cast).first?.becomesType,
          Optional(BlockType.scene))
}

print("")
print("When to stay quiet")
do {
    check("a broken line is never completed", texts("MA\nyes", .character), [String]())
    check("dialogue is the writer's own words", texts("You di", .dialogue), [String]())
    check("an empty action line offers nothing", texts("", .action), [String]())
}

print("")
if failures == 0 {
    print("Autocomplete checks passed.")
    exit(0)
} else {
    print("\(failures) autocomplete check(s) FAILED.")
    exit(1)
}
