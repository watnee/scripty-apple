//
//  ShortcutGroup.swift
//  scripty
//
//  The keyboard reference, as data.
//
//  Every entry below was read off the code that binds it — ScriptCommands for
//  the menu bar, ScriptView for the toolbar menus, and the key commands on the
//  two text views. The web app's list is longer and is deliberately not copied:
//  a reference that promises keys which do nothing is worse than no reference,
//  and it is the kind of wrong that is never noticed until a writer has pressed
//  the key four times.
//
//  Whoever adds a shortcut is expected to add it here too, which is why the
//  content sits beside the model rather than inside the view.
//

import Foundation

/// One row: what it does, and the key or keys that do it.
struct ShortcutEntry: Identifiable, Equatable {
    let action: String
    /// Alternatives, not a sequence. Two entries mean either will serve.
    let keys: [String]

    var id: String { action }

    init(_ action: String, _ keys: String...) {
        self.action = action
        self.keys = keys
    }

    func matches(_ query: String) -> Bool {
        let haystack = ([action] + keys).joined(separator: " ").lowercased()
        return query.lowercased()
            .split(separator: " ")
            .allSatisfy { haystack.contains($0) }
    }
}

/// A run of shortcuts that share a situation.
///
/// `context` says when they apply and `note` what is easy to get wrong about
/// them — both are the part a bare table of keys always leaves out.
struct ShortcutGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let systemImage: String
    let context: String
    let note: String?
    let entries: [ShortcutEntry]
}

extension ShortcutGroup {
    /// The groups with at least one matching row, each narrowed to its matches.
    static func groups(matching query: String) -> [ShortcutGroup] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return groups }
        return groups.compactMap { group in
            // A group whose title matches keeps all of its rows: someone who
            // searched for "elements" wants the set, not the one row that
            // happens to repeat the word.
            let titleMatches = group.title.lowercased().contains(trimmed.lowercased())
            let hits = titleMatches ? group.entries : group.entries.filter { $0.matches(trimmed) }
            return hits.isEmpty ? nil : ShortcutGroup(
                id: group.id,
                title: group.title,
                systemImage: group.systemImage,
                context: group.context,
                note: group.note,
                entries: hits)
        }
    }

    static let groups: [ShortcutGroup] = [
        ShortcutGroup(
            id: "script",
            title: "Script",
            systemImage: "doc.text",
            context: "With a screenplay open.",
            note: nil,
            entries: [
                ShortcutEntry("New element", "⌘N"),
                ShortcutEntry("Undo", "⌘Z"),
                ShortcutEntry("Redo", "⌘⇧Z"),
                ShortcutEntry("Find in script", "⌘F"),
                ShortcutEntry("Print", "⌘P")
            ]),
        ShortcutGroup(
            id: "typing",
            title: "Typing",
            systemImage: "text.cursor",
            context: "While the caret is in an element.",
            note: "The arrow keys and Escape are only borrowed while a suggestion "
                + "list is open; the rest of the time they belong to the caret.",
            entries: [
                ShortcutEntry("Split the element, or start the next one", "Return"),
                ShortcutEntry("Merge into the element above", "Backspace"),
                ShortcutEntry("Next element type", "Tab"),
                ShortcutEntry("Previous element type", "⇧Tab"),
                ShortcutEntry("Move through suggestions", "↑", "↓"),
                ShortcutEntry("Accept the suggestion", "Return", "Tab"),
                ShortcutEntry("Dismiss the suggestions", "Esc")
            ]),
        ShortcutGroup(
            id: "elements",
            title: "Element Types",
            systemImage: "square.stack.3d.up",
            context: "Retypes the element you are in.",
            note: "Lyrics, Centered, Section, Synopsis, Note and Page Break carry no "
                + "key — nine is as far as the numbers go. Pick them from the Format "
                + "menu or the element bar under the script.",
            entries: [
                ShortcutEntry("Scene", "⌘1"),
                ShortcutEntry("Action", "⌘2"),
                ShortcutEntry("Text", "⌘3"),
                ShortcutEntry("Character", "⌘4"),
                ShortcutEntry("Dialogue", "⌘5"),
                ShortcutEntry("Dual Dialogue", "⌘6"),
                ShortcutEntry("Parenthetical", "⌘7"),
                ShortcutEntry("Transition", "⌘8"),
                ShortcutEntry("Shot", "⌘9")
            ]),
        ShortcutGroup(
            id: "clipboard",
            title: "Whole Elements",
            systemImage: "doc.on.clipboard",
            context: "Acts on the element itself rather than on its text.",
            note: "Shifted on purpose: ⌘C, ⌘X and ⌘V belong to the words inside the "
                + "element you are typing in, and a copy that meant different things "
                + "depending on where the caret sat would be worse than no shortcut.",
            entries: [
                ShortcutEntry("Copy element", "⌘⇧C"),
                ShortcutEntry("Cut element", "⌘⇧X"),
                ShortcutEntry("Paste elements below", "⌘⇧V")
            ]),
        ShortcutGroup(
            id: "view",
            title: "View",
            systemImage: "eye",
            context: "How the screenplay is shown.",
            note: "Focus mode also answers to ⌘⌃D, the key the Mac menu bar lists.",
            entries: [
                ShortcutEntry("Page view", "⌘⇧P"),
                ShortcutEntry("Page setup", "⌘⌥P"),
                ShortcutEntry("Focus mode", "⌘⇧F"),
                ShortcutEntry("Full page width", "⌘\\"),
                ShortcutEntry("Outline mode", "⌘⇧O"),
                ShortcutEntry("Outline panel", "⌘⌥O"),
                ShortcutEntry("Read script", "⌘⇧R"),
                ShortcutEntry("Check spelling", "⌘⇧;"),
                ShortcutEntry("Bigger text", "⌘+"),
                ShortcutEntry("Smaller text", "⌘−"),
                ShortcutEntry("Actual size", "⌘0")
            ]),
        ShortcutGroup(
            id: "notes",
            title: "Notes Editor",
            systemImage: "note.text",
            context: "While editing a note.",
            note: "The prefixes these type are ordinary characters, and they survive "
                + "into the screenplay when the note is inserted.",
            entries: [
                ShortcutEntry("Carry the list down a line", "Return"),
                ShortcutEntry("Leave the list, on an empty item", "Return"),
                ShortcutEntry("Nest the item", "Tab"),
                ShortcutEntry("Un-nest the item", "⇧Tab"),
                ShortcutEntry("Heading 1, 2 or 3", "⌘⌥1", "⌘⌥2", "⌘⌥3")
            ]),
        ShortcutGroup(
            id: "help",
            title: "Help",
            systemImage: "questionmark.circle",
            context: "Anywhere.",
            note: nil,
            entries: [
                ShortcutEntry("This reference", "⌘/")
            ])
    ]
}
