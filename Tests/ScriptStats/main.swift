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

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
