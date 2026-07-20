//
//  FountainScript checks
//
//  Guards the paste parser: what a block of screenplay text becomes, and what
//  a set of elements looks like on the way back out. The conservatism cases at
//  the bottom matter most — restructuring prose the writer meant to keep whole
//  is worse than not restructuring at all.
//  Run via Tests/run.sh.
//

import Foundation

var failures = 0

func check(_ label: String, _ actual: some Equatable, _ expected: some Equatable) {
    if "\(actual)" == "\(expected)" {
        print("  PASS  \(label)")
    } else {
        failures += 1
        print("  FAIL  \(label)\n        expected \(expected)\n        got      \(actual)")
    }
}

/// Parsed elements as "TYPE:content", which reads far better in a failure than
/// a wall of struct descriptions.
func parsed(_ text: String) -> [String] {
    FountainScript.parse(text).map { "\($0.type.rawValue):\($0.content)" }
}

print("\n-- speeches --")

check("a cue claims its first line and hands the rest to dialogue",
      parsed("MAYA\nThat was perfect."),
      ["CHARACTER:MAYA", "DIALOGUE:That was perfect."])

check("a parenthetical under a cue is its own element",
      parsed("MAYA\n(standing)\nThen we shoot the ending."),
      ["CHARACTER:MAYA", "PARENTHETICAL:(standing)", "DIALOGUE:Then we shoot the ending."])

check("a cue extension stays on the cue",
      parsed("DEV (V.O.)\nIt was not."),
      ["CHARACTER:DEV (V.O.)", "DIALOGUE:It was not."])

check("a caret makes it dual dialogue and is stripped",
      parsed("DEV ^\nAt the same time."),
      ["DUAL_DIALOGUE:DEV", "DIALOGUE:At the same time."])

print("\n-- structure --")

check("a scene heading is its own element",
      parsed("INT. SOUNDSTAGE 7 - NIGHT\n\nRain."),
      ["SCENE:INT. SOUNDSTAGE 7 - NIGHT", "ACTION:Rain."])

check("a transition is recognised",
      parsed("Rain.\n\nSMASH CUT TO:"),
      ["ACTION:Rain.", "TRANSITION:SMASH CUT TO:"])

// A heading is uppercase and has a line under it, which is exactly the shape
// of a cue. Reading it as one would make the next line dialogue.
check("an uppercase heading is not mistaken for a cue",
      parsed("INT. CAFE - DAY\nRain falls."),
      ["SCENE:INT. CAFE - DAY", "ACTION:Rain falls."])

check("a full speech and scene together",
      parsed("INT. CAFE - DAY\n\nMAYA\nWe are late.\n\nEXT. STREET - DAY"),
      ["SCENE:INT. CAFE - DAY",
       "CHARACTER:MAYA",
       "DIALOGUE:We are late.",
       "SCENE:EXT. STREET - DAY"])

check("a lone parenthetical is a parenthetical",
      parsed("(beat)"), ["PARENTHETICAL:(beat)"])

print("\n-- prose is left alone --")

check("one paragraph is one action element",
      parsed("The crew huddles around a single flickering work light."),
      ["ACTION:The crew huddles around a single flickering work light."])

// Wrapped prose is one thought, not several.
check("wrapped lines rejoin into one element",
      parsed("The crew huddles around\na single flickering work light."),
      ["ACTION:The crew huddles around a single flickering work light."])

check("plain prose is not worth splitting",
      FountainScript.looksLikeScreenplay("Just a sentence."), false)

check("two prose paragraphs are still not screenplay",
      FountainScript.looksLikeScreenplay("First thought.\n\nSecond thought."), false)

check("a cue and a line is screenplay",
      FountainScript.looksLikeScreenplay("MAYA\nThat was perfect."), true)

check("a heading and action is screenplay",
      FountainScript.looksLikeScreenplay("INT. CAFE - DAY\n\nRain."), true)

print("\n-- writing back out --")

func fountain(_ pairs: [(BlockType, String)]) -> String {
    FountainScript.fountain(from: pairs.map { FountainElement(type: $0.0, content: $0.1) })
}

// Dialogue glued to its cue; a blank line everywhere else. Fountain reads a
// cue separated from its line by a blank line as two pieces of action.
check("a speech stays glued together",
      fountain([(.character, "MAYA"), (.dialogue, "We are late."), (.action, "She runs.")]),
      "MAYA\nWe are late.\n\nShe runs.")

check("a parenthetical stays inside the speech",
      fountain([(.character, "MAYA"), (.parenthetical, "(quietly)"), (.dialogue, "Late.")]),
      "MAYA\n(quietly)\nLate.")

check("markers are restored",
      fountain([(.section, "Act One"), (.synopsis, "They meet"), (.note, "check this")]),
      "# Act One\n\n= They meet\n\n[[check this]]")

check("a page break writes as its marker",
      fountain([(.pageBreak, "===")]), "===")

// MARK: - Round trip

print("\n-- round trip --")

let original = "INT. CAFE - DAY\n\nMAYA\n(quietly)\nWe are late.\n\nShe runs.\n\nSMASH CUT TO:"
check("parsing what we wrote gives back what we had",
      FountainScript.fountain(from: FountainScript.parse(original)),
      original)

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
