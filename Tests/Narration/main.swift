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
    check("a stop is not required",
          ScriptNarration.spoken("INT HOUSE - DAY", as: .scene),
          "interior, house, day")
    check("a heading typed in a hurry still expands",
          ScriptNarration.spoken("INT.HOUSE", as: .scene), "interior,house")
    // An abbreviation has to be the whole word. Plain substring replacement —
    // which is what this was — found "est." inside "WEST." and "int." inside
    // "SPRINT.", so a west-facing house was "westablishing" and a sprint was
    // an interior.
    check("EST. inside WEST. is left alone",
          ScriptNarration.spoken("WEST. HOUSE - DAY", as: .scene),
          "west. house, day")
    check("INT. inside SPRINT. is left alone",
          ScriptNarration.spoken("SPRINT. FINISH LINE", as: .scene),
          "sprint. finish line")
    check("POV", ScriptNarration.spoken("MAYA'S POV - THE DOOR", as: .scene),
          "maya's point of view, the door")
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

print("\nA song")
do {
    // Two verses, with the blank line between them that a writer typed and a
    // singer leaves a beat for.
    let lyric = [
        NarrationLine(id: 10, text: "We drove out past the water"),
        NarrationLine(id: 11, text: "with the radio down low"),
        NarrationLine(id: 12, text: ""),
        NarrationLine(id: 13, text: "AND YOU SAID YOU'D NEVER GO"),
    ]
    let cues = ScriptNarration.cues(forLyric: lyric)
    check("blank lines make no cue", cues.count, 3)
    check("the line keeps its own id", cues[0].blockId, 10)
    check("every line is speech", cues.allSatisfy { $0.kind == .speech }, true)
    // A lyric has one voice. Naming a speaker would put a name on the Lock
    // Screen that no cue in the song actually says.
    check("nobody is named", cues.contains { $0.speaker != nil }, false)
    // The shouted line is the one that would otherwise come back spelled out
    // a letter at a time.
    check("shouting is lowered", cues[2].text, "and you said you'd never go")
    check("a line inside the verse follows closely",
          cues[1].pause, NarrationKind.speech.pause)
    check("the line after the break waits",
          cues[2].pause, ScriptNarration.breakPause)
    check("a lyric of blank lines is silent",
          ScriptNarration.cues(forLyric: [NarrationLine(id: 1, text: "  ")]).count, 0)
}

print("\nA note")
do {
    let note = """
    # Act One

    - find the ending
    - and the way back to it

    It was always the same road.
    """
    let cues = ScriptNarration.cues(forNote: note)
    check("cue count", cues.count, 4)
    // The markers are how the line is written, not what it says: a heading is
    // read as a heading, and a bullet is read as its words.
    check("the hash comes off the heading", shape(cues[0]), "heading|-|Act One")
    check("the dash comes off the item", shape(cues[1]), "description|-|find the ending")
    check("prose is the narrator's", shape(cues[3]), "description|-|It was always the same road.")
    // The heading takes its own air; the paragraph after the list takes the
    // break the blank line asked for; an item inside a list does not.
    check("the second item follows on",
          cues[2].pause, NarrationKind.description.pause)
    check("a new paragraph waits", cues[3].pause, ScriptNarration.breakPause)
    check("an empty note is silent", ScriptNarration.cues(forNote: "\n\n  \n").count, 0)
}

print("\nWhat each kind of document offers")
do {
    let song = NarrationSource.lyric([NarrationLine(id: 4, text: "one line")])
    let note = NarrationSource.note("one line")
    let script = NarrationSource.script([block(1, .action, "One line.")])

    // The four "Read" switches are screenplay grammar — character names,
    // parentheticals, a voice each. Offered over a lyric they would change
    // nothing, and "Action and Headings" left off from a run-lines session
    // would read as the reason the song had gone quiet.
    check("only a script offers the read options",
          [script, song, note].map(\.offersScriptOptions), [true, false, false])
    check("a song's options are ignored",
          song.cues(options: NarrationOptions(announcesSpeakers: false,
                                              includesDescription: false,
                                              includesDirections: false,
                                              usesDistinctVoices: false)).count,
          1)
    check("elements are lines outside a script",
          [script, song, note].map(\.elementNoun), ["Element", "Line", "Line"])
    check("a song's elements are its lines", song.elementIds, [4])
}

print("\nWhich voices are worth offering")
do {
    // A device's answer to "what voices have you got" is an inventory: the
    // same voice more than once when a better download exists, a dozen joke
    // voices, and every language it has ever shipped.
    let installed = [
        NarrationVoice(identifier: "compact.Samantha", name: "Samantha",
                       language: "en-US", grade: .compact),
        NarrationVoice(identifier: "enhanced.Samantha", name: "Samantha",
                       language: "en-US", grade: .enhanced),
        NarrationVoice(identifier: "compact.Daniel", name: "Daniel",
                       language: "en-GB", grade: .compact),
        NarrationVoice(identifier: "premium.Ava", name: "Ava",
                       language: "en-US", grade: .premium),
        NarrationVoice(identifier: "novelty.Zarvox", name: "Zarvox",
                       language: "en-US", grade: .compact, isNovelty: true),
        NarrationVoice(identifier: "compact.Amelie", name: "Amélie",
                       language: "fr-CA", grade: .compact),
    ]
    let offered = NarrationVoices.offered(from: installed, language: "en-GB")

    check("the joke voices are not offered",
          offered.contains { $0.isNovelty }, false)
    check("another language is not offered",
          offered.contains { $0.name == "Amélie" }, false)
    check("a British device is still offered American voices",
          offered.contains { $0.name == "Samantha" }, true)
    // One row per name: two "Samantha"s with no way to tell which is the good
    // one is the picker this sorting exists to avoid.
    check("one row per name", offered.map(\.name), ["Ava", "Samantha", "Daniel"])
    check("and it is the better edition of it",
          offered.first { $0.name == "Samantha" }?.identifier ?? "-", "enhanced.Samantha")
    check("the best-sounding come first", offered.map(\.grade),
          [NarrationVoiceGrade.premium, .enhanced, .compact])
    check("the grade is on the row", offered[0].label, "Ava (Premium)")
    check("except the ordinary one, which needs no warning",
          offered.last?.label ?? "-", "Daniel")

    // A picker whose current selection is missing from its own list shows no
    // selection at all, so the chosen voice survives the deduplication.
    let keeping = NarrationVoices.offered(from: installed, language: "en-US",
                                          keeping: "compact.Samantha")
    check("a chosen voice is kept even when outranked",
          keeping.contains { $0.identifier == "compact.Samantha" }, true)
    check("and the name is not then listed twice",
          keeping.filter { $0.name == "Samantha" }.count, 1)

    // Every rule here is a preference, and an empty picker looks broken.
    let jokesOnly = installed.filter(\.isNovelty)
    check("a device with nothing but joke voices offers them",
          NarrationVoices.offered(from: jokesOnly, language: "en-US").count, 1)
    check("a language with no voice at all is offered every other voice",
          NarrationVoices.offered(from: installed, language: "cy").count, 4)
}

print("\nThe voice to read in")
do {
    let compact = NarrationVoice(identifier: "compact.Samantha", name: "Samantha",
                                 language: "en-US", grade: .compact)
    let enhanced = NarrationVoice(identifier: "enhanced.Samantha", name: "Samantha",
                                  language: "en-US", grade: .enhanced)
    let premium = NarrationVoice(identifier: "premium.Ava", name: "Ava",
                                 language: "en-US", grade: .premium)

    // The system hands out the small built-in voice even when the writer has
    // gone and downloaded a better one. Upgrading in place comes first: a
    // writer who hears Samantha every day should keep hearing Samantha.
    check("the same voice, better",
          NarrationVoices.best(from: [premium, enhanced], systemDefault: compact)?.identifier ?? "-",
          "enhanced.Samantha")
    // Only when there is no better edition of it does the choice move house.
    check("otherwise the best there is",
          NarrationVoices.best(from: [premium, compact], systemDefault: compact)?.identifier ?? "-",
          "premium.Ava")
    check("nothing better means no change",
          NarrationVoices.best(from: [compact], systemDefault: compact)?.identifier ?? "-",
          "compact.Samantha")
    check("and with no default at all, the best on offer",
          NarrationVoices.best(from: [premium, compact], systemDefault: nil)?.identifier ?? "-",
          "premium.Ava")

    // A cast walking down the device's raw list is handed Zarvox without being
    // asked — worse than the picker, where at least somebody chose.
    let cast = NarrationVoices.cast(from: [premium, enhanced, compact],
                                    narrator: "premium.Ava")
    check("the narrator is not in their own cast",
          cast.contains { $0.identifier == "premium.Ava" }, false)
    check("and the best voices are cast first",
          cast.first?.grade == .enhanced, true)

    check("a device with only built-in voices says so",
          NarrationVoices.hasDownloadedVoice([compact]), false)
    check("and one with a download does not",
          NarrationVoices.hasDownloadedVoice([compact, enhanced]), true)
}

print("\nSpeed, against the engine's measured curve")
do {
    // `rate` is a 0…1 dial whose halves are on different scales, not a
    // multiplier. Multiplying the default by the writer's choice — the obvious
    // reading, and what this used to do — put "2×" at the top of the dial,
    // which is over four times the default pace.
    check("normal is the default rate",
          NarrationSpeed.rate(forSpeed: 1.0), Float(0.5))
    check("twice the pace is nowhere near the top of the dial",
          NarrationSpeed.rate(forSpeed: 2.0) < 0.7, true)
    check("and is not the old naive answer",
          NarrationSpeed.rate(forSpeed: 2.0) < 0.9 * 1.0, true)
    check("half again lands where the measurement says",
          abs(NarrationSpeed.rate(forSpeed: 1.5) - 0.585) < 0.01, true)

    let rates = NarrationSpeed.choices.map(NarrationSpeed.rate(forSpeed:))
    check("faster is always faster", zip(rates, rates.dropFirst()).allSatisfy(<), true)
    check("every choice is a rate the engine accepts",
          rates.allSatisfy { $0 >= 0 && $0 <= 1 }, true)

    // The slow end of the dial bottoms out at about three-quarters of the
    // default pace, so a "0.5×" the engine cannot deliver is not offered — and
    // one saved from before the scale was measured comes back clamped.
    check("the slowest offered is the slowest there is",
          NarrationSpeed.choices.first ?? 0, 0.75)
    check("an old stored speed is clamped", NarrationSpeed.clamped(0.5), 0.75)
    check("as is one from the wrong end", NarrationSpeed.clamped(4), 2.0)
    check("normal reads as normal", NarrationSpeed.label(1.0), "Normal")
}

print()
if failures == 0 {
    print("Narration checks passed.")
} else {
    print("Narration checks FAILED (\(failures)).")
}
exit(failures == 0 ? 0 : 1)
