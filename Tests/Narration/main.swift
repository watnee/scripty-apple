//
//  Read-aloud narration checks
//
//  `ScriptNarration` is the half of Read Aloud that can be checked without
//  making a sound: which elements become cues, in what order, whose line each
//  one is, and what the text turns into on the way to the synthesizer.
//
//  The two things worth pinning hardest:
//
//    - **The speaker carries.** A dialogue block does not name its own
//      speaker; the cue above it does. Getting that wrong is inaudible with
//      one voice and completely wrong with a cast.
//    - **Shouting is lowered.** A synthesizer spells an all-caps word out a
//      letter at a time, and a screenplay shouts every heading, cue and
//      transition. "INT." coming back as "I-N-T" is the failure this exists
//      to prevent.
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

/// Blocks are decoded, not constructed — `Block` has no memberwise init.
func block(_ id: Int, _ type: BlockType, _ content: String, person: String? = nil) -> Block {
    var json = """
    {"id": \(id), "order": \(id), "type": "\(type.rawValue)", \
    "content": \(jsonString(content))
    """
    if let person { json += ", \"personName\": \(jsonString(person))" }
    json += "}"
    return try! JSONDecoder().decode(Block.self, from: Data(json.utf8))
}

func jsonString(_ value: String) -> String {
    let data = try! JSONEncoder().encode(value)
    return String(decoding: data, as: UTF8.self)
}

/// "kind|speaker|text", so one check covers a whole cue.
func shape(_ cue: NarrationCue) -> String {
    "\(cue.kind)|\(cue.speaker ?? "-")|\(cue.text)"
}

// A scene of the shape every screenplay is made of: heading, action, cue,
// parenthetical, dialogue, and a working note that is nobody's business.
let scene: [Block] = [
    block(1, .scene, "INT. DINER - NIGHT"),
    block(2, .action, "MAYA slides into the booth."),
    block(3, .character, "MAYA"),
    block(4, .parenthetical, "(quietly)"),
    block(5, .dialogue, "You came."),
    block(6, .note, "check this beat"),
    block(7, .character, "SAM"),
    block(8, .dialogue, "I said I would."),
    block(9, .transition, "CUT TO:"),
]

print("The run, with everything read")
do {
    let cues = ScriptNarration.cues(for: scene)
    check("cue count", cues.count, 8)
    check("heading",      shape(cues[0]), "heading|-|interior, diner, night")
    check("action",       shape(cues[1]), "description|-|MAYA slides into the booth.")
    check("character cue", shape(cues[2]), "cue|MAYA|maya")
    check("parenthetical", shape(cues[3]), "direction|MAYA|quietly")
    check("dialogue",     shape(cues[4]), "speech|MAYA|You came.")
    check("second cue",   shape(cues[5]), "cue|SAM|sam")
    check("second line",  shape(cues[6]), "speech|SAM|I said I would.")
    check("transition",   shape(cues[7]), "description|-|cut to:")
    check("notes are left out", cues.contains { $0.blockId == 6 }, false)
    check("indexes number the run", cues.map(\.index), Array(0..<8))
    check("each cue names its element", cues.map(\.blockId), [1, 2, 3, 4, 5, 7, 8, 9])
}

print("\nThe speaker carries from the cue")
do {
    let cues = ScriptNarration.cues(for: scene)
    // The dialogue blocks say nothing about who is speaking; the cue above
    // each one is the only place the name appears.
    check("first speech", cues[4].speaker ?? "-", "MAYA")
    check("second speech", cues[6].speaker ?? "-", "SAM")
    // An action beat ends the speech: whatever follows it is the narrator's
    // until a new cue names somebody.
    let interrupted = [
        block(1, .character, "MAYA"),
        block(2, .dialogue, "You came."),
        block(3, .action, "She looks away."),
        block(4, .dialogue, "Orphaned line."),
    ]
    let after = ScriptNarration.cues(for: interrupted)
    check("action clears the speaker", after.last?.speaker ?? "-", "-")

    check("speakers, in the order they speak",
          ScriptNarration.speakers(in: cues), ["MAYA", "SAM"])
}

print("\nWhat to leave out")
do {
    var options = NarrationOptions()
    options.announcesSpeakers = false
    let unannounced = ScriptNarration.cues(for: scene, options: options)
    check("no cues spoken", unannounced.contains { $0.kind == .cue }, false)
    // The name is still needed even when it is not said — it is what casts
    // the line to a voice.
    check("speaker still known",
          unannounced.first { $0.kind == .speech }?.speaker ?? "-", "MAYA")

    options = NarrationOptions()
    options.includesDescription = false
    let dialogueOnly = ScriptNarration.cues(for: scene, options: options)
    // Sorted, not a Set: `check` compares descriptions, and a Set's
    // description order is randomised per process.
    check("running lines: kinds",
          Set(dialogueOnly.map { "\($0.kind)" }).sorted(),
          ["cue", "direction", "speech"])

    options = NarrationOptions()
    options.includesDirections = false
    let undirected = ScriptNarration.cues(for: scene, options: options)
    check("no parentheticals", undirected.contains { $0.kind == .direction }, false)
    check("the rest survives", undirected.count, 7)
}

print("\nShouting, abbreviations and empties")
do {
    check("INT.", ScriptNarration.spoken("INT. HOUSE - DAY", as: .scene),
          "interior, house, day")
    check("EXT.", ScriptNarration.spoken("EXT. ROOFTOP - CONTINUOUS", as: .scene),
          "exterior, rooftop, continuous")
    check("INT./EXT. is taken before INT.",
          ScriptNarration.spoken("INT./EXT. CAR - DAY", as: .scene),
          "interior, exterior, car, day")
    check("I/E.", ScriptNarration.spoken("I/E. CAR - DAY", as: .scene),
          "interior, exterior, car, day")
    check("cue extension", ScriptNarration.spoken("MAYA (V.O.)", as: .character),
          "maya (voice over)")
    check("continued", ScriptNarration.spoken("MAYA (CONT'D)", as: .character),
          "maya (continued)")
    // A line written in ordinary case is left alone — lowering it would be
    // pointless, and the caps in "NASA" are the writer's.
    check("mixed case is untouched",
          ScriptNarration.spoken("She works at NASA now.", as: .dialogue),
          "She works at NASA now.")
    check("parens come off a parenthetical",
          ScriptNarration.spoken("(beat)", as: .parenthetical), "beat")
    check("a leftover force marker comes off",
          ScriptNarration.spoken(".INT. HOUSE", as: .scene), "interior, house")
    check("a trailing stop stays — it is the pause at the end of the sentence",
          ScriptNarration.spoken("She leaves.", as: .action), "She leaves.")

    // Nothing to say means no cue at all: an empty utterance is a stall in the
    // middle of the reading.
    let sparse = [block(1, .action, "   "), block(2, .action, "Real line.")]
    check("empty elements are skipped", ScriptNarration.cues(for: sparse).count, 1)
    check("an empty run is empty", ScriptNarration.cues(for: []).count, 0)
}

print("\nA cue with no text of its own")
do {
    // A character cue picked from the character list can carry the name on the
    // link rather than in the content — the reader view makes the same
    // substitution, and the narrator has to as well or the line is orphaned.
    let named = [
        block(1, .character, "", person: "SAM"),
        block(2, .dialogue, "Right here."),
    ]
    let cues = ScriptNarration.cues(for: named)
    check("cue reads the linked name", shape(cues[0]), "cue|SAM|sam")
    check("and the line is theirs", cues[1].speaker ?? "-", "SAM")
}

print("\nPacing")
do {
    // The pauses only have to be ordered the way the page is: air before a new
    // scene, almost none between a name and the line that follows it.
    check("a heading waits longest",
          NarrationKind.heading.pause > NarrationKind.description.pause, true)
    check("a line follows its cue closely",
          NarrationKind.speech.pause < NarrationKind.cue.pause, true)
    check("only people are spoken",
          [NarrationKind.cue, .speech].allSatisfy(\.isSpoken), true)
    check("the page is not",
          [NarrationKind.heading, .description, .direction].contains(where: \.isSpoken),
          false)
}

print()
if failures == 0 {
    print("Narration checks passed.")
} else {
    print("Narration checks FAILED (\(failures)).")
}
exit(failures == 0 ? 0 : 1)
