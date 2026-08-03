//
//  main.swift
//  Tests/Shortcuts
//
//  The keyboard reference, checked against itself.
//
//  `ShortcutGroup.swift` promises a key for each row, and the promise is only
//  as good as the code that binds it — which this suite cannot see. What it
//  *can* see is the reference contradicting itself: one chord listed against
//  two actions in the same situation, which is the shape the bug this suite
//  was written for took. Two views each bound ⌘⇧F, one of them lost the
//  responder race, and the sheet listed the key as though it worked.
//
//  So: no chord claimed twice within a group, and nothing that a group's rows
//  can't be searched for.
//

import Foundation

var failures = 0

func check(_ label: String, _ condition: Bool) {
    print(condition ? "  PASS  \(label)" : "  FAIL  \(label)")
    if !condition { failures += 1 }
}

func checkEqual<T: Equatable>(_ label: String, _ actual: T, _ expected: T) {
    let ok = actual == expected
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)\n          expected: \(expected)\n          actual:   \(actual)")
    if !ok { failures += 1 }
}

print("== Every group is a usable page ==")
do {
    check("there are groups at all", !ShortcutGroup.groups.isEmpty)
    for group in ShortcutGroup.groups {
        check("\(group.id) has rows", !group.entries.isEmpty)
        check("\(group.id) says when it applies", !group.context.isEmpty)
        check("\(group.id)'s rows all name a key",
              group.entries.allSatisfy { !$0.keys.isEmpty && $0.keys.allSatisfy { !$0.isEmpty } })
        check("\(group.id)'s rows all name an action",
              group.entries.allSatisfy { !$0.action.isEmpty })
    }
    checkEqual("group ids are unique",
               Set(ShortcutGroup.groups.map(\.id)).count, ShortcutGroup.groups.count)
}

print()
print("== One chord, one claim ==")
do {
    // Within a situation, a chord that appears twice is a chord that does one
    // of the two things and silently drops the other. Across situations it is
    // fine and deliberate — ⌘⇧O is outline mode in the script and nothing at
    // all in a note editor.
    //
    // Only chords carrying a modifier. A bare Return or Tab is contextual by
    // construction: the text view answers it differently with a suggestion
    // list up than without, and listing both readings is the reference doing
    // its job. A ⌘ chord has no such context — whoever wins the responder race
    // wins it everywhere, which is the bug this checks for.
    let modifiers: Set<Character> = ["⌘", "⌃", "⌥"]
    for group in ShortcutGroup.groups {
        var claimed: [String: String] = [:]
        var clashes: [String] = []
        for entry in group.entries {
            for key in entry.keys where key.contains(where: modifiers.contains) {
                if let already = claimed[key], already != entry.action {
                    clashes.append("\(key): \(already) / \(entry.action)")
                }
                claimed[key] = entry.action
            }
        }
        check("\(group.id) claims each chord once" + (clashes.isEmpty ? "" : " — \(clashes.joined(separator: ", "))"),
              clashes.isEmpty)
    }
}

print()
print("== The two chords that were bound twice ==")
do {
    // Pinned by name because these are the ones that had a second, different
    // binding in the menu bar while the reference listed only the first.
    let view = ShortcutGroup.groups.first { $0.id == "view" }
    check("there is a View group", view != nil)
    let keys = Dictionary(uniqueKeysWithValues:
        (view?.entries ?? []).map { ($0.action.lowercased(), $0.keys) })
    checkEqual("focus mode is ⌘⇧F and only that", keys["focus mode"], ["⌘⇧F"])
    checkEqual("page view is ⌘⇧P and only that", keys["page view"], ["⌘⇧P"])
    // ⌘⌥1 belongs to the note editor's Heading 1; page view held it too until
    // the chords were reconciled, and a note cover is exactly where both were
    // reachable at once.
    check("nothing in View claims ⌘⌥1",
          (view?.entries ?? []).allSatisfy { !$0.keys.contains("⌘⌥1") })
    check("no note in the reference still points at ⌘⌃D",
          ShortcutGroup.groups.allSatisfy { ($0.note ?? "").contains("⌘⌃D") == false })
}

print()
print("== Searching the reference ==")
do {
    checkEqual("an empty query is every group",
               ShortcutGroup.groups(matching: "   ").count, ShortcutGroup.groups.count)
    let byKey = ShortcutGroup.groups(matching: "⌘⇧F")
    check("a chord finds its row", byKey.contains { $0.entries.contains { $0.keys.contains("⌘⇧F") } })
    let byAction = ShortcutGroup.groups(matching: "focus")
    check("an action word finds its row",
          byAction.contains { $0.entries.contains { $0.action.lowercased().contains("focus") } })
    check("every returned group kept at least one row",
          byAction.allSatisfy { !$0.entries.isEmpty })
    check("a query that matches nothing returns nothing",
          ShortcutGroup.groups(matching: "zzzznotachord").isEmpty)
    // Words are ANDed, so a query naming two different rows matches neither.
    check("the words of a query all have to land",
          ShortcutGroup.groups(matching: "focus zzzznotachord").isEmpty)
}

print()
if failures == 0 {
    print("ALL CHECKS PASSED")
    exit(0)
} else {
    print("\(failures) CHECK(S) FAILED")
    exit(1)
}
