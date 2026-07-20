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

print("\n-- all-caps prose is not a speaker --")

// Found by review: the cue test only rejected lines the detector positively
// identified as something else, so anything it merely declined sailed through
// on "uppercase and short" — and the line beneath became that speaker's
// dialogue, persisted to the server.
check("an all-caps scene-setter is not a cue",
      parsed("MEANWHILE, ACROSS TOWN\nThe rain has not stopped."),
      ["ACTION:MEANWHILE, ACROSS TOWN The rain has not stopped."])

check("an all-caps exclamation is not a cue",
      parsed("BANG!\nThe door bursts open."),
      ["ACTION:BANG! The door bursts open."])

check("a real cue still reads as one",
      parsed("MAYA\nStill here."),
      ["CHARACTER:MAYA", "DIALOGUE:Still here."])

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

// Found by review: the glue rule only looked at what *preceded* the gap, so a
// parenthetical inside a speech got a blank line before it, which ends the
// speech — and the dialogue after it came back as action.
check("an interior parenthetical does not break the speech",
      fountain([(.character, "MAYA"), (.dialogue, "Hi."),
                (.parenthetical, "(beat)"), (.dialogue, "Okay.")]),
      "MAYA\nHi.\n(beat)\nOkay.")

check("markers are restored",
      fountain([(.section, "Act One"), (.synopsis, "They meet"), (.note, "check this")]),
      "# Act One\n\n= They meet\n\n[[check this]]")

check("a page break writes as its marker",
      fountain([(.pageBreak, "===")]), "===")

// Found by review: the multi-line branch sent a leading parenthetical through
// the detector, which strips the brackets — so the same clipboard text stored
// differently depending on whether a line happened to follow it.
check("a parenthetical keeps its brackets with a line under it",
      parsed("(beat)\nOkay."),
      ["PARENTHETICAL:(beat)", "ACTION:Okay."])

check("and stores the same way on its own",
      parsed("(beat)"), ["PARENTHETICAL:(beat)"])

// MARK: - Round trip

print("\n-- round trip --")

let original = "INT. CAFE - DAY\n\nMAYA\n(quietly)\nWe are late.\n(beat)\nReally late.\n\nShe runs.\n\nSMASH CUT TO:"
check("parsing what we wrote gives back what we had",
      FountainScript.fountain(from: FountainScript.parse(original)),
      original)

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
