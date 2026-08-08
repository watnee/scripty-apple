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
                ShortcutEntry("Find and replace", "⌘F"),
                ShortcutEntry("Comment on the element", "⌘⌥M"),
                ShortcutEntry("Title page", "⌘⇧T"),
                ShortcutEntry("Import a script", "⌘⇧I"),
                ShortcutEntry("Songs", "⌘⇧S"),
                ShortcutEntry("Print", "⌘P")
            ]),
        ShortcutGroup(
            id: "format",
            title: "Format",
            systemImage: "bold",
            context: "Acts on the words you have selected.",
            note: "Align Right carries no key on purpose: the two that do are the "
                + "ones a screenplay reaches for, and a third would be a chord "
                + "spent on something used once a script.",
            entries: [
                ShortcutEntry("Bold", "⌘B"),
                ShortcutEntry("Italic", "⌘I"),
                ShortcutEntry("Underline", "⌘U"),
                ShortcutEntry("Align left", "⌘⇧L"),
                ShortcutEntry("Align centre", "⌘⇧E")
            ]),
        ShortcutGroup(
            id: "case",
            title: "Text Case",
            systemImage: "textformat.alt",
            context: "With words selected, in a screenplay element, a lyric line or a note.",
            note: "These rewrite the selection itself rather than the line around "
                + "it, which is why they carry ⌥ rather than joining the ⇧ family "
                + "the screen-level toggles use — and why they are bound to the "
                + "text you are in rather than to the menu bar. With nothing "
                + "selected they do nothing at all, and are not offered.",
            entries: [
                ShortcutEntry("UPPERCASE", "⌘⌥U"),
                ShortcutEntry("lowercase", "⌘⌥L"),
                ShortcutEntry("Title Case", "⌘⌥T"),
                ShortcutEntry("Sentence case", "⌘⌥S")
            ]),
        ShortcutGroup(
            id: "lines",
            title: "Whole Lines",
            systemImage: "line.3.horizontal",
            context: "Acts on the screenplay element or lyric line the caret is in.",
            note: "A note carries none of these: it is one field of prose rather "
                + "than a list of lines, so there is nothing for them to act on. "
                + "Move matches the browser's own ⌥↑ and ⌥↓, and takes the "
                + "caret's paragraph movement in exchange. Delete is ⌘⇧⌫ rather "
                + "than ⌘⌫, which belongs to the system's delete-to-start-of-line.",
            entries: [
                ShortcutEntry("Duplicate the line", "⌘D"),
                ShortcutEntry("Move the line up", "⌥↑"),
                ShortcutEntry("Move the line down", "⌥↓"),
                ShortcutEntry("Delete the line", "⌘⇧⌫")
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
            note: "Each of these is bound in one place — the Mac menu bar — so the "
                + "key does the same thing whether the toolbar's View menu is on "
                + "screen or not.",
            entries: [
                ShortcutEntry("Page view", "⌘⇧P"),
                ShortcutEntry("Page setup", "⌘⌥P"),
                ShortcutEntry("Focus mode", "⌘⇧F"),
                ShortcutEntry("Full page width", "⌘\\"),
                ShortcutEntry("Outline mode", "⌘⇧O"),
                ShortcutEntry("Navigator", "⌘⌥O"),
                ShortcutEntry("Read script", "⌘⇧R"),
                ShortcutEntry("Read aloud", "⌘⇧A"),
                ShortcutEntry("Check spelling", "⌘⇧;"),
                ShortcutEntry("Word count", "⌘⇧Y"),
                ShortcutEntry("Pins", "⌘⇧N"),
                ShortcutEntry("Bookmarks", "⌘⇧B"),
                ShortcutEntry("Element labels", "⌘⇧U"),
                ShortcutEntry("Lock or unlock editing", "⌘⇧Q"),
                ShortcutEntry("Version history", "⌘⇧H"),
                ShortcutEntry("Editions", "⌘⇧J"),
                ShortcutEntry("Bigger text", "⌘+"),
                ShortcutEntry("Smaller text", "⌘−"),
                ShortcutEntry("Actual size", "⌘0"),
                // Off as well as on, and off is the half that matters: the
                // sound the key stops was picked in a menu, and reaching for a
                // menu to stop it is the wrong shape of thing at the end of a
                // session.
                ShortcutEntry("Background noise on or off", "⌘⌥B")
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
                ShortcutEntry("Heading 1, 2 or 3", "⌘⌥1", "⌘⌥2", "⌘⌥3"),
                // The same chord the script uses, aimed at the note: while a
                // note is open these belong to it and never to the screenplay
                // underneath.
                ShortcutEntry("Undo", "⌘Z"),
                ShortcutEntry("Redo", "⌘⇧Z"),
                // And the script's Read Aloud, aimed the same way: over an open
                // song or note the chord reads *that*, never the screenplay the
                // sheet is covering.
                ShortcutEntry("Read the note or song aloud", "⌘⇧A"),
                // And Find. The screenplay's own ⌘F used to be the only one
                // bound, which meant pressing it over a note opened the search
                // bar on the script underneath — out of sight, and waiting when
                // the note was closed.
                ShortcutEntry("Find in the note or song", "⌘F"),
                // Print is aimed the same way again — and on either workspace
                // it means every song or note on the screen, which is what that
                // screen is.
                ShortcutEntry("Print the note or song", "⌘P")
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
