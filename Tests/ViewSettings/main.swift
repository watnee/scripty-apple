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

MainActor.assumeIsolated {
    runWordCount()
    runOutlineMode()
    runSpellcheck()
    runAppearance()
}

print("")
if failures == 0 {
    print("View setting checks passed.")
    exit(0)
} else {
    print("\(failures) view setting check(s) FAILED.")
    exit(1)
}
