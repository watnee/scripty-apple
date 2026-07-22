//
//  Element clipboard checks
//
//  Two things are worth pinning here, and neither is visible by running the
//  app: the payload is shared byte-for-byte with the web editor, so a change
//  to its shape silently breaks copying between the two clients; and the
//  Fountain parser decides what a paste turns into, where getting it wrong
//  quietly shreds prose into one-line action elements.
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

func types(_ blocks: [ClipboardBlock]) -> String {
    blocks.map(\.type).joined(separator: ",")
}

print("Payload shape")
do {
    let blocks = [
        ClipboardBlock(type: .character, content: "MAYA", personId: 12, characterName: "MAYA"),
        ClipboardBlock(type: .dialogue, content: "We're late.", tags: "act1")
    ]
    // The readable half: a cue and its speech on separate lines, which is what
    // any other app receives.
    check("plain text", ScriptClipboard.plainText(blocks), "MAYA\nMAYA\nWe're late.")

    let data = ScriptClipboard.encode(blocks)!
    let json = String(data: data, encoding: .utf8)!
    check("carries a version", json.contains("\"version\":1"), true)
    // The web writes personId as a string even though it is a number.
    check("personId is a string", json.contains("\"personId\":\"12\""), true)

    let decoded = ScriptClipboard.decode(data)!
    check("round trips", decoded, blocks)
}

print("")
print("Reading the web's fallback")
do {
    // What a browser that could not put two things on the clipboard writes:
    // the text, then the payload fenced by invisible separators.
    let payload = #"{"version":1,"blocks":[{"type":"SCENE","content":"INT. BAR - NIGHT","personId":"","characterName":"","tags":""}]}"#
    let raw = "INT. BAR - NIGHT\n\u{2063}\(payload)\u{2063}"
    let (text, blocks) = ScriptClipboard.parseEmbedded(raw)
    check("text comes back clean", text, "INT. BAR - NIGHT")
    check("payload comes back", types(blocks ?? []), "SCENE")

    // Text with no fence is returned untouched rather than truncated.
    let (plain, none) = ScriptClipboard.parseEmbedded("just some words")
    check("unfenced text survives", plain, "just some words")
    check("and yields nothing", none == nil, true)
}

print("")
print("Parsing a pasted passage")
do {
    let passage = """
    INT. KITCHEN - DAY

    Rain against the window.

    MAYA
    (quietly)
    You didn't call.
    She waits.

    CUT TO:
    """
    let blocks = FountainDetector.parseBlocks(passage)
    check("element types",
          types(blocks),
          "SCENE,ACTION,CHARACTER,PARENTHETICAL,DIALOGUE,TRANSITION")
    // Speech runs to the blank line, so both lines are one element.
    check("speech is one element", blocks[4].content, "You didn't call.\nShe waits.")
    check("speech remembers the speaker", blocks[4].characterName, "MAYA")

    // Force markers name the element outright, whatever the text looks like.
    let forced = FountainDetector.parseBlocks(".HOME\n\n>FADE OUT\n\n~la la\n\n#Act One\n\n=A beat")
    check("forced types", types(forced), "SCENE,TRANSITION,LYRICS,SECTION,SYNOPSIS")
    check("marker is stripped", forced[0].content, "HOME")
}

print("")
print("Deciding whether to split at all")
do {
    // Soft-wrapped prose must paste as typing, not as a stack of elements.
    let prose = "It was a long afternoon and the light\nkept moving across the floor."
    check("wrapped prose is not a screenplay",
          FountainDetector.looksLikeScreenplay(prose), false)

    check("a scene heading is",
          FountainDetector.looksLikeScreenplay("INT. BAR - NIGHT\nHe waits."), true)
    check("so is a cue with speech under it",
          FountainDetector.looksLikeScreenplay("MAYA\nYou didn't call."), true)
    check("so is a force marker",
          FountainDetector.looksLikeScreenplay(".HOME\nsomething"), true)
    // A cue with nothing under it is just a shout.
    check("a lone caps line is not",
          FountainDetector.looksLikeScreenplay("MAYA\n"), false)
    check("empty text is not", FountainDetector.looksLikeScreenplay(""), false)
}

print("")
if failures == 0 {
    print("Clipboard checks passed.")
    exit(0)
} else {
    print("\(failures) clipboard check(s) FAILED.")
    exit(1)
}
