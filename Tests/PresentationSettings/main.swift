//
//  PresentationSettings checks
//
//  Exists because of a crash: the type-size and zoom clamps used to live in
//  each property's own `didSet`, and assigning to a property inside its own
//  didSet recurses under @Observable. Pressing Bigger or Smaller ran until the
//  stack ran out — a segfault, from a menu item. These checks walk the range to
//  its limits and past them, which is enough to blow the stack if the clamp
//  ever moves back.
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

/// A private suite so the checks never touch the real app's stored settings.
let defaults = UserDefaults(suiteName: "scripty.tests.presentation")!
defaults.removePersistentDomain(forName: "scripty.tests.presentation")

let settings = await PresentationSettings(defaults: defaults)

print("\n-- text size --")

check("starts at the documented default",
      await settings.textSize, PresentationSettings.defaultTextSize)

// The crash: each of these used to re-enter its own didSet.
for _ in 0..<40 { await settings.increaseTextSize() }
check("cannot be pushed past the maximum",
      await settings.textSize, PresentationSettings.maxTextSize)
check("stops offering to grow", await settings.canIncreaseTextSize, false)

for _ in 0..<40 { await settings.decreaseTextSize() }
check("cannot be pushed below the minimum",
      await settings.textSize, PresentationSettings.minTextSize)
check("stops offering to shrink", await settings.canDecreaseTextSize, false)

await settings.resetTextSize()
check("resets to the default", await settings.textSize, PresentationSettings.defaultTextSize)
check("scale tracks the size", await settings.textScale, 1.0)

print("\n-- page zoom --")

for _ in 0..<40 { await settings.zoomIn() }
check("cannot zoom past the maximum", await settings.pageZoom, PresentationSettings.maxZoom)

for _ in 0..<40 { await settings.zoomOut() }
check("cannot zoom below the minimum", await settings.pageZoom, PresentationSettings.minZoom)

await settings.resetZoom()
check("resets to the default zoom", await settings.pageZoom, PresentationSettings.defaultZoom)

print("\n-- persistence --")

await settings.increaseTextSize()
let saved = await settings.textSize
let reloaded = await PresentationSettings(defaults: defaults)
check("a new instance reads back the stored size", await reloaded.textSize, saved)

defaults.removePersistentDomain(forName: "scripty.tests.presentation")

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
