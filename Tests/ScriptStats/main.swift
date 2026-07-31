//
//  ScriptStats / ScriptOutline checks
//
//  Guards the port of the server's ScriptStatsServiceImpl.java against a
//  fixture whose expected numbers were computed by hand from the Java.
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

/// Blocks are built from the HAL JSON the API actually emits, so this exercises
/// decoding as well as the arithmetic.
func makeBlock(_ id: Int, _ type: String, _ content: String) -> Block {
    let encoded = String(
        data: try! JSONSerialization.data(withJSONObject: [content], options: .fragmentsAllowed),
        encoding: .utf8)!.dropFirst().dropLast()
    let json = #"{"id":\#(id),"order":\#(id),"type":"\#(type)","content":\#(encoded)}"#
    return try! JSONDecoder().decode(Block.self, from: Data(json.utf8))
}

var blocks: [Block] = []
func add(_ type: String, _ content: String) {
    blocks.append(makeBlock(blocks.count + 1, type, content))
}

add("SCENE", "INT. SOUNDSTAGE 7 - NIGHT")
add("ACTION", "The crew huddles around a single flickering work light.")
add("CHARACTER", "MAYA")
add("DIALOGUE", "That was perfect. Why does nobody trust me?")
add("CHARACTER", "MAYA (V.O.)")
add("DIALOGUE", "I said it was perfect.")
add("CHARACTER", "DEV")
add("DIALOGUE", "Because the boom fell on me.")
add("TRANSITION", "SMASH CUT TO:")
add("SCENE", "EXT. STUDIO PARKING LOT - NIGHT")
add("ACTION", "Rain. Of course it is raining.")
add("SECTION", "Act Two")
add("LYRICS", "Roll the film, we are running out of night")
add("LYRICS", "One more take before we lose the light")

print("ScriptStats")
let stats = ScriptStats(blocks: blocks)
check("blockCount", stats.blockCount, 14)
check("sceneCount", stats.sceneCount, 2)
check("interior scenes", stats.interiorSceneCount, 1)
check("exterior scenes", stats.exteriorSceneCount, 1)
check("night scenes", stats.nightSceneCount, 2)
check("day scenes", stats.daySceneCount, 0)
check("locationCount", stats.locationCount, 2)

// MAYA and "MAYA (V.O.)" are the same speaker — the Java strips the extension.
check("speakingCharacterCount", stats.speakingCharacterCount, 2)
check("MAYA speeches", stats.characters.first { $0.name == "MAYA" }?.speechCount ?? -1, 2)
check("MAYA words", stats.characters.first { $0.name == "MAYA" }?.wordCount ?? -1, 13)
check("DEV words", stats.characters.first { $0.name == "DEV" }?.wordCount ?? -1, 6)

// LYRICS count toward dialogueWords (ScriptStatsServiceImpl.java line ~162) and
// the per-character share divides by that same total (line ~213), so shares
// deliberately sum to less than 100% whenever a script has unattributed lyrics.
check("dialogueWords includes lyrics", stats.dialogueWords, 36)
check("actionWords", stats.actionWords, 15)
check("MAYA share", stats.characters.first { $0.name == "MAYA" }?.dialogueSharePercent ?? -1, 36)

check("locations sorted by scene count",
      stats.locations.map(\.name), ["SOUNDSTAGE 7", "STUDIO PARKING LOT"])

print("\nScriptOutline")
let outline = ScriptOutline(blocks: blocks)
check("outline entry count", outline.entries.count, 3)
check("scenes numbered sequentially", outline.entries.compactMap(\.sceneNumber), [1, 2])
check("SECTION is unnumbered", outline.entries.last?.sceneNumber == nil, true)
check("characters sorted", outline.characters.map(\.name), ["DEV", "MAYA"])
check("locations", outline.locations.map(\.name), ["SOUNDSTAGE 7", "STUDIO PARKING LOT"])
check("adjacent LYRICS group into one song", outline.songs.count, 1)
check("song line count", outline.songs.first?.lineCount ?? -1, 2)

// Where a marked element sits, which the marked lists show beside it. Ids are
// the seeding order above: 4 is MAYA's first speech (scene 1), 11 the rain
// action (scene 2), 1 the first scene heading itself.
let scenes = ScriptOutline.sceneContexts(for: [1, 4, 11], in: blocks)
check("a line takes the scene it falls under", scenes[4]?.number ?? -1, 1)
check("and its heading", scenes[4]?.heading ?? "", "INT. SOUNDSTAGE 7 - NIGHT")
check("a later line takes the later scene", scenes[11]?.number ?? -1, 2)
check("a heading is in its own scene", scenes[1]?.number ?? -1, 1)
check("only what was asked for comes back", scenes.count, 3)
check("nothing asked, nothing walked", ScriptOutline.sceneContexts(for: [], in: blocks).isEmpty, true)
// A block before the first scene heading is in no scene at all, rather than in
// a made-up scene zero.
let headless = [makeBlock(1, "ACTION", "Cold open, no heading.")]
check("an element before any heading has no scene",
      ScriptOutline.sceneContexts(for: [1], in: headless).isEmpty, true)

print("\nScriptWordCount")
// The running readout counts what the stats call script content — structure
// (sections, synopses, notes) is left out of both, so the number in the corner
// agrees with the one in the stats sheet.
check("running total matches the stats total", ScriptWordCount.total(in: blocks), stats.totalWords)
check("a section is not script", ScriptWordCount.counts(.section), false)
// The cue is the one the web counts and this does not — see ScriptWordCount.
check("a character cue is not counted", ScriptWordCount.counts(.character), false)
check("a note is not script", ScriptWordCount.counts(.note), false)
check("action is", ScriptWordCount.counts(.action), true)

// The web's formatPageEstimate: a decimal below ten pages, whole above, and a
// bare "0" for an empty script rather than "0.0".
check("an empty script has no pages", ScriptWordCount.pageEstimate(words: 0), "0")
check("a short script keeps its decimal", ScriptWordCount.pageEstimate(words: 375), "1.5")
check("a round short script drops it", ScriptWordCount.pageEstimate(words: 500), "2")
check("a feature rounds to whole pages", ScriptWordCount.pageEstimate(words: 27_500), "110")

print("\nWriting in outline mode")
// Outline mode hides everything but these three, so every rule that makes or
// retypes an element while it is on has to stay inside them — otherwise the
// line the writer is typing leaves the screen mid-word, which is exactly the
// bug these answers exist to prevent. Worth pinning because the ordinary
// answers, right beside them, are all `action`.
check("the outline is scenes, sections and synopses",
      BlockType.outlineTypes, [BlockType.scene, .section, .synopsis])
check("action is not part of it", BlockType.action.isOutlineType, false)

// Return: another element of the same kind, the way Return in a list gives
// another item at the same level.
check("Return after a scene gives a scene", BlockType.scene.followingOutlineType, BlockType.scene)
check("after a section, a section", BlockType.section.followingOutlineType, BlockType.section)
check("after a synopsis, a synopsis", BlockType.synopsis.followingOutlineType, BlockType.synopsis)
check("and the ordinary answer is still action", BlockType.scene.followingType, BlockType.action)
// Only an outline element can be focused while outlining; the fallback is
// there so a stale focus cannot create an invisible line.
check("anything else falls back to a scene", BlockType.dialogue.followingOutlineType, BlockType.scene)

// Tab: the ordinary cycle's very next stop after a scene is action, so the
// narrowed cycle is what keeps one keypress from erasing the line.
check("Tab walks scene to section", BlockType.scene.cyclingOutlineType(backward: false), BlockType.section)
check("then to synopsis", BlockType.section.cyclingOutlineType(backward: false), BlockType.synopsis)
check("and wraps back to scene", BlockType.synopsis.cyclingOutlineType(backward: false), BlockType.scene)
check("Shift-Tab wraps the other way",
      BlockType.scene.cyclingOutlineType(backward: true), BlockType.synopsis)
check("the ordinary cycle would have left the outline",
      BlockType.scene.cyclingType(backward: false), BlockType.action)
check("a type off the cycle enters at the scene",
      BlockType.action.cyclingOutlineType(backward: false), BlockType.scene)

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
