//
//  Presentation and appearance settings checks
//
//  Like the view-option checks next door, the whole feature here is storage
//  semantics — and two of these are easy to get backwards. The word-count key
//  names the *hidden* state, so writing "shown" into it would hide the readout
//  for anyone who had asked to see it; spellcheck reads the ordinary way round
//  but must survive an absent key as *on*, since that is what a browser does.
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

/// A throwaway store per case, so one check cannot colour the next.
func scratch(_ name: String) -> UserDefaults {
    let suite = "scripty.tests.viewsettings.\(name)"
    UserDefaults.standard.removePersistentDomain(forName: suite)
    return UserDefaults(suiteName: suite)!
}

@MainActor
func runWordCount() {
    print("Word count readout")
    let store = scratch("wordcount")
    let settings = PresentationSettings(defaults: store)
    // Off until asked for, as in the web app.
    check("hidden on a first run", settings.showsWordCount, false)

    settings.showsWordCount = true
    check("asking for it stores 'not hidden'",
          store.object(forKey: "scripty-word-count-hidden") as? Bool ?? true, false)
    check("the choice survives reopening",
          PresentationSettings(defaults: store).showsWordCount, true)

    settings.showsWordCount = false
    check("putting it away stores 'hidden'",
          store.object(forKey: "scripty-word-count-hidden") as? Bool ?? false, true)
}

@MainActor
func runOutlineMode() {
    print("")
    print("Outline mode")
    let store = scratch("outlinemode")
    let settings = PresentationSettings(defaults: store)
    check("the whole script shows on a first run", settings.isOutlineMode, false)

    settings.isOutlineMode = true
    // The web writes "1"/"0", not a boolean, and reads anything else as off.
    check("it lands in the web's key as a string",
          store.string(forKey: "scripty-outline-mode") ?? "", "1")
    check("and survives a relaunch",
          PresentationSettings(defaults: store).isOutlineMode, true)

    settings.isOutlineMode = false
    check("turning it off writes zero rather than clearing the key",
          store.string(forKey: "scripty-outline-mode") ?? "", "0")

    // Paper sheets full of gaps where the scenes used to be are nobody's idea
    // of an outline, so the two modes cannot both be on.
    settings.isPageView = true
    settings.isOutlineMode = true
    check("turning it on leaves page view", settings.isPageView, false)

    // UserDefaults renders a stored boolean as "1"/"0", so a key written as a
    // boolean by something older still reads the way it was meant to.
    let legacy = scratch("outlinemode-legacy")
    legacy.set(true, forKey: "scripty-outline-mode")
    check("a boolean in the key still reads as on",
          PresentationSettings(defaults: legacy).isOutlineMode, true)
    legacy.set(false, forKey: "scripty-outline-mode")
    check("and a false one as off",
          PresentationSettings(defaults: legacy).isOutlineMode, false)
}

@MainActor
func runSpellcheck() {
    print("")
    print("Spellcheck")
    let store = scratch("spellcheck")
    let settings = PresentationSettings(defaults: store)
    check("on until turned off", settings.isSpellcheckEnabled, true)

    settings.isSpellcheckEnabled = false
    check("it lands in the web's unprefixed key",
          store.object(forKey: "spellcheck") as? Bool ?? true, false)
    check("and stays off across a relaunch",
          PresentationSettings(defaults: store).isSpellcheckEnabled, false)
}

@MainActor
func runIgnoredWords() {
    print("")
    print("Ignored words")
    let store = scratch("ignoredwords")
    let dictionary = SpellcheckDictionary(defaults: store)
    check("nothing ignored on a first run", dictionary.words, [String]())

    // Uppercased and stripped, so "Maya," and "maya" are one entry.
    dictionary.add("Maya,")
    dictionary.add("maya")
    dictionary.add("Kessler")
    check("normalised and deduplicated", dictionary.words, ["KESSLER", "MAYA"])
    check("and looked up either way", dictionary.contains("maya"), true)

    // The web's shape: an object keyed by the word.
    let json = store.string(forKey: "scripty-spell-ignored") ?? ""
    check("stored as the web stores it",
          json.contains("\"MAYA\":true") && json.contains("\"KESSLER\":true"), true)
    check("and survives a relaunch",
          SpellcheckDictionary(defaults: store).words, ["KESSLER", "MAYA"])

    // The spellings taught to the device, which the uppercase list cannot
    // reconstruct — the checker takes case at face value, so the word as
    // written has to be remembered to be untaught later.
    check("the written spelling is remembered too",
          store.stringArray(forKey: "scripty-spell-learned") ?? [],
          ["MAYA", "Maya", "KESSLER", "Kessler"])

    // What the editors redraw on. Not the words themselves: a view that has
    // already checked a line needs telling the answer changed.
    let before = dictionary.revision
    dictionary.add("Ondaatje")
    check("adding moves the revision on", dictionary.revision, before + 1)
    dictionary.add("Ondaatje")
    check("but adding the same word again does not", dictionary.revision, before + 1)
    dictionary.remove("ONDAATJE")
    check("and removing moves it on again", dictionary.revision, before + 2)
    check("removing takes the taught spellings with it",
          store.stringArray(forKey: "scripty-spell-learned") ?? [],
          ["MAYA", "Maya", "KESSLER", "Kessler"])

    dictionary.remove("MAYA")
    check("removing takes it off", dictionary.words, ["KESSLER"])

    // A word the browser took off its list is written as false, not deleted.
    let mixed = scratch("ignoredwords-false")
    mixed.set(#"{"MAYA":true,"KESSLER":false}"#, forKey: "scripty-spell-ignored")
    check("a false entry is not ignored",
          SpellcheckDictionary(defaults: mixed).words, ["MAYA"])

    // Nothing usable in the key must not throw away the feature.
    let broken = scratch("ignoredwords-broken")
    broken.set("not json", forKey: "scripty-spell-ignored")
    check("unreadable storage reads as empty",
          SpellcheckDictionary(defaults: broken).words, [String]())

    // An install from before the taught-spellings list existed, or a list
    // synced from the browser, has only the uppercase words to go on.
    let legacy = scratch("ignoredwords-legacy")
    legacy.set(#"{"MAYA":true}"#, forKey: "scripty-spell-ignored")
    let upgraded = SpellcheckDictionary(defaults: legacy)
    check("an older list still reads", upgraded.words, ["MAYA"])
    upgraded.add("Kessler")
    check("and the uppercase words stand in as taught spellings",
          legacy.stringArray(forKey: "scripty-spell-learned") ?? [],
          ["MAYA", "KESSLER", "Kessler"])
}

@MainActor
func runWordUnderSelection() {
    print("")
    print("The word to ignore")

    func word(_ text: String, _ location: Int, _ length: Int = 0) -> String {
        SpellcheckWord.word(in: text, around: NSRange(location: location, length: length)) ?? "—"
    }

    // A caret anywhere in the word, including either edge, means that word.
    check("caret inside", word("Maya walks in.", 2), "Maya")
    check("caret at the start", word("Maya walks in.", 0), "Maya")
    check("caret at the end", word("Maya walks in.", 4), "Maya")
    check("caret after the space belongs to the next word",
          word("Maya walks in.", 5), "walks")

    // A tap on an underlined word arrives as that word's range.
    check("a selected word", word("Maya walks in.", 0, 4), "Maya")
    check("punctuation at the edges is dropped", word("“Maya,” she says.", 0, 7), "Maya")
    check("an apostrophe inside is not", word("Maya doesn't walk.", 5, 7), "doesn't")

    // Two words is not a word, and neither is a comma on its own — offering to
    // ignore either would teach the device something nonsensical.
    check("two selected words are refused", word("Maya walks in.", 0, 10), "—")
    check("punctuation alone is refused", word("Maya, walks.", 4, 1), "—")
    check("empty text is refused", word("", 0), "—")

    // Offsets past the end arrive from a text view mid-edit; they must not trap.
    check("a location past the end clamps to the last word", word("Maya", 99), "Maya")
    check("a length past the end still finds the word", word("Maya", 0, 99), "Maya")

    // Digits are not part of a word: no dictionary was going to know "3D".
    check("digits are left out", word("A 3D print.", 3), "D")
}

@MainActor
func runAppearance() {
    print("")
    print("Appearance")
    let store = scratch("appearance")
    let settings = AppearanceSettings(defaults: store)
    check("follows the device by default", settings.appearance, AppearanceSettings.Appearance.system)

    settings.appearance = .dark
    check("stored as the web spells it", store.string(forKey: "theme") ?? "", "dark")
    check("chosen appearance survives a relaunch",
          AppearanceSettings(defaults: store).appearance, AppearanceSettings.Appearance.dark)

    // A value written by some future version — or by hand — must not strand the
    // app in a theme it cannot name.
    store.set("sepia", forKey: "theme")
    check("an unknown theme falls back to the device",
          AppearanceSettings(defaults: store).appearance, AppearanceSettings.Appearance.system)
}

@MainActor
func runZoomAndTextSizeBounds() {
    print("")
    print("Zoom and type size stay in bounds")
    let store = scratch("bounds")
    let settings = PresentationSettings(defaults: store)

    // These clamp themselves in a `didSet`, which under `@Observable` is a
    // property observer on a *computed* property — so a clamp that writes back
    // unconditionally recurses until the stack gives out. Every check here is
    // really asking "does setting this at all still return?".
    settings.pageZoom = 140
    check("an in-range zoom is taken as given", settings.pageZoom, 140)
    check("and is stored", store.object(forKey: "scripty-page-zoom") as? Int ?? 0, 140)

    settings.pageZoom = 5000
    check("too far in is pulled back to the maximum", settings.pageZoom, 200)
    check("and the pulled-back value is what gets stored",
          store.object(forKey: "scripty-page-zoom") as? Int ?? 0, 200)

    settings.pageZoom = 1
    check("too far out is pulled back to the minimum", settings.pageZoom, 50)

    settings.textSize = 120
    check("an in-range type size is taken as given", settings.textSize, 120)
    settings.textSize = 1000
    check("an outsized one is pulled back", settings.textSize, 200)
    settings.textSize = 0
    check("and so is a vanishing one", settings.textSize, 80)

    // The steppers are the surface a writer actually touches.
    settings.resetZoom()
    settings.zoomIn()
    check("zooming in steps up", settings.pageZoom, 110)
    settings.zoomOut()
    check("and back down again", settings.pageZoom, 100)
}

@MainActor
func runFitToWidth() {
    print("")
    print("Fit to width")
    let store = scratch("fittowidth")
    let settings = PresentationSettings(defaults: store)
    check("a first run zooms by percentage", settings.isPageZoomFit, false)
    check("and that percentage is 100", settings.effectiveZoom, 100)

    settings.isPageZoomFit = true
    check("fit is stored as the literal the web writes",
          store.string(forKey: "scripty-page-zoom") ?? "", "fit")
    check("fit survives a relaunch",
          PresentationSettings(defaults: store).isPageZoomFit, true)

    // The percentage on show is whatever the page view measured, not the one
    // stored — that is the whole point of a measured mode.
    settings.fitZoom = 150
    check("the readout follows the measurement", settings.effectiveZoom, 150)

    // Stepping away from fit starts from what fit resolved to, so the first
    // press nudges the size on screen rather than jumping back to 100%.
    settings.zoomOut()
    check("stepping away leaves fit", settings.isPageZoomFit, false)
    check("and starts from the measured size", settings.pageZoom, 140)
    check("which is what gets stored",
          store.object(forKey: "scripty-page-zoom") as? Int ?? 0, 140)

    // A second press on an active Fit returns to 100%, as in the web app.
    settings.toggleFitZoom()
    check("toggling turns fit on", settings.isPageZoomFit, true)
    settings.toggleFitZoom()
    check("toggling again leaves fit", settings.isPageZoomFit, false)
    check("at 100%", settings.pageZoom, 100)

    // An unreadable value means neither a percentage nor fit.
    store.set("enormous", forKey: "scripty-page-zoom")
    let odd = PresentationSettings(defaults: store)
    check("nonsense is not fit", odd.isPageZoomFit, false)
    check("nonsense falls back to 100%", odd.pageZoom, 100)
}

/// The point size in the format bar is the stored percentage in other units,
/// and the conversion runs through a rounded integer both ways. So the thing
/// worth checking is the round trip: every size the menu offers has to come
/// back as itself, or the checkmark lands on the wrong row and the chip reads
/// 13.9 for the 14 the writer just picked.
@MainActor
func runFontSizePoints() {
    print("")
    print("Type size in points")
    let store = scratch("fontsize")
    let settings = PresentationSettings(defaults: store)

    check("a first run is set in 12pt", settings.fontSizePt, 12.0)
    check("and says so without a decimal", settings.fontSizeLabel, "12")

    for size in PresentationSettings.fontSizePresets {
        settings.fontSizePt = size
        check("\(PresentationSettings.fontSizeLabel(size))pt comes back as itself",
              settings.fontSizePt, size)
        check("and matches its own preset", settings.isSetIn(fontSizePt: size), true)
    }

    settings.fontSizePt = 14
    check("14pt is stored as the percentage the web app reads",
          store.object(forKey: "scripty-text-size") as? Int ?? 0, 117)
    check("and does not match the size next to it",
          settings.isSetIn(fontSizePt: 16), false)

    // Out of range is pulled to the nearest end rather than refused — typing 72
    // means "as big as this goes", not "do nothing".
    settings.fontSizePt = 72
    check("an outsized point size is pulled back",
          settings.fontSizePt, PresentationSettings.maxFontSizePt)
    settings.fontSizePt = 2
    check("and a vanishing one too",
          settings.fontSizePt, PresentationSettings.minFontSizePt)

    // The floor rounds up, so the smallest size on offer is one the scale can
    // give back exactly; the ceiling rounds down for the same reason.
    check("the floor is a round point", PresentationSettings.minFontSizePt, 10.0)
    check("the ceiling is too", PresentationSettings.maxFontSizePt, 24.0)

    // The percentage and the points are one setting: stepping one moves the
    // other, and a step that lands off a whole point has to say so.
    settings.textSize = 110
    check("stepping the percentage moves the point size", settings.fontSizePt, 13.2)
    check("and a fractional size keeps its decimal", settings.fontSizeLabel, "13.2")
}

MainActor.assumeIsolated {
    runWordCount()
    runOutlineMode()
    runSpellcheck()
    runIgnoredWords()
    runWordUnderSelection()
    runAppearance()
    runZoomAndTextSizeBounds()
    runFontSizePoints()
    runFitToWidth()
}

print("")
if failures == 0 {
    print("View setting checks passed.")
    exit(0)
} else {
    print("\(failures) view setting check(s) FAILED.")
    exit(1)
}
