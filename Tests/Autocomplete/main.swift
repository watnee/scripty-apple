//
//  ScriptAutocomplete checks
//
//  Guards the port of the web editor's fountain-power.js completion rules.
//  Every case asserts on the whole replacement line rather than on the chip
//  label, because the replacement is what actually lands in the element and
//  is where an off-by-one in the prefix arithmetic would show up.
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

func makeBlock(_ id: Int, _ type: String, _ content: String) -> Block {
    let encoded = String(
        data: try! JSONSerialization.data(withJSONObject: [content], options: .fragmentsAllowed),
        encoding: .utf8)!.dropFirst().dropLast()
    let json = #"{"id":\#(id),"order":\#(id),"type":"\#(type)","content":\#(encoded)}"#
    return try! JSONDecoder().decode(Block.self, from: Data(json.utf8))
}

func makePerson(_ id: Int, _ name: String) -> Person {
    let json = #"{"id":\#(id),"name":"\#(name)"}"#
    return try! JSONDecoder().decode(Person.self, from: Data(json.utf8))
}

var blocks: [Block] = []
func add(_ type: String, _ content: String) {
    blocks.append(makeBlock(blocks.count + 1, type, content))
}

add("SCENE", "INT. SOUNDSTAGE 7 - NIGHT")
add("ACTION", "The crew huddles around a work light.")
add("CHARACTER", "MAYA")
add("DIALOGUE", "That was perfect.")
add("CHARACTER", "DEV (V.O.)")
add("DIALOGUE", "It was not.")
add("SCENE", "EXT. STUDIO PARKING LOT - NIGHT")
add("ACTION", "Rain.")

let cast = [makePerson(1, "MAYA"), makePerson(2, "PRODUCER")]

/// Spelled out so an empty expectation still has a type to compare against.
let none: [String] = []

func replacements(_ text: String, _ type: BlockType) -> [String] {
    ScriptAutocomplete.suggestions(for: text, type: type, blocks: blocks, characters: cast)
        .map(\.replacement)
}

// MARK: - Character cues

print("\n-- character cues --")

check("cast and written cues both offered",
      replacements("", .character), ["DEV", "MAYA", "PRODUCER"])

// The cue in the script is "DEV (V.O.)"; completing against the extension
// would offer a name nobody typed.
check("extension stripped from a written cue",
      replacements("DE", .character), ["DEV"])

check("prefix narrows the list",
      replacements("P", .character), ["PRODUCER"])

// Offering what is already typed would put a chip there that does nothing.
check("an exact name offers nothing",
      replacements("MAYA", .character), none)

check("no match offers nothing",
      replacements("ZX", .character), none)

check("lowercase typing still matches",
      replacements("ma", .character), ["MAYA"])

check("dual dialogue completes like a cue",
      replacements("DE", .dualDialogue), ["DEV"])

// MARK: - Scene headings

print("\n-- scene headings --")

check("an empty heading offers the openers",
      replacements("", .scene),
      ["INT. ", "EXT. ", "EST. ", "INT./EXT. ", "I/E. "])

check("a partial opener narrows",
      replacements("EX", .scene), ["EXT. "])

// INT. also prefixes INT./EXT., so both are still live.
check("INT still offers the slashed opener",
      replacements("INT", .scene), ["INT. ", "INT./EXT. "])

check("after an opener, places already used",
      replacements("INT. ", .scene),
      ["INT. STUDIO PARKING LOT", "INT. SOUNDSTAGE 7"])

check("a partial place narrows",
      replacements("INT. SO", .scene), ["INT. SOUNDSTAGE 7"])

// The opener the writer typed is kept, not the one the place came from.
check("the writer's own opener is preserved",
      replacements("EXT. SO", .scene), ["EXT. SOUNDSTAGE 7"])

check("a complete place offers nothing",
      replacements("INT. SOUNDSTAGE 7", .scene), none)

print("\n-- times of day --")

check("after a dash, the times",
      replacements("INT. SOUNDSTAGE 7 - ", .scene).prefix(3),
      ["INT. SOUNDSTAGE 7 - DAY",
       "INT. SOUNDSTAGE 7 - NIGHT",
       "INT. SOUNDSTAGE 7 - DAWN"])

check("a partial time narrows",
      replacements("INT. SOUNDSTAGE 7 - NI", .scene), ["INT. SOUNDSTAGE 7 - NIGHT"])

check("a complete time offers nothing",
      replacements("INT. SOUNDSTAGE 7 - NIGHT", .scene), none)

// A location containing a dash must not be read as a time-of-day boundary
// before the writer has typed one.
check("only the last dash starts the time",
      replacements("INT. CAFE - BACK ROOM - NI", .scene),
      ["INT. CAFE - BACK ROOM - NIGHT"])

// MARK: - Types with no vocabulary

print("\n-- quiet types --")

check("action offers nothing", replacements("The crew", .action), none)
check("dialogue offers nothing", replacements("That was", .dialogue), none)
check("transition offers nothing", replacements("SMASH", .transition), none)

// MARK: - Ordering

print("\n-- ordering --")

// A writer returning to a location has usually just left it.
check("locations are most-recent-first",
      ScriptAutocomplete.knownLocations(blocks: blocks),
      ["STUDIO PARKING LOT", "SOUNDSTAGE 7"])

check("suggestions are capped",
      replacements("", .scene).count <= ScriptAutocomplete.limit, true)

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
