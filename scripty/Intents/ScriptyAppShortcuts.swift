//
//  ScriptyAppShortcuts.swift
//  scripty
//
//  The phrases Siri answers to, and what Spotlight offers when someone types
//  "new note" into search.
//
//  Exactly one provider per app, and it belongs to the app target. Two is
//  undefined; one inside an extension is ignored.
//
//  Every phrase has to carry `\(.applicationName)` — that is checked when the
//  App Intents metadata is extracted at build time, so getting it wrong fails
//  the build rather than leaving a phrase that quietly never matches. The name
//  it substitutes is `CFBundleDisplayName`, which is why the app target sets
//  one at all.
//
//  Ten shortcuts is the ceiling; eight leaves room. Deliberately none of them
//  takes a screenplay: a phrase with an entity in it makes Siri enumerate the
//  picker while it is matching, so what Siri would recognise would depend on
//  which screenplays this device happened to have cached — and the picker is
//  empty in the demo and signed out. "Open Notes in Wide Awake" is available in
//  the Shortcuts app, where a picker looks like a picker.
//
//  Which is why the two intents that *require* a name — Open Screenplay and
//  Open Song or Note — are not here at all. They are reached by searching:
//  through the Shortcuts app's picker, and through Spotlight, where typing half
//  a title is a better way to name one of thirty than a sentence that has to
//  guess the title in advance. What is here instead is their unnamed twin,
//  which needs no picker to work.
//

import AppIntents

struct ScriptyAppShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .navy }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenSongsIntent(),
                    phrases: ["Open Songs in \(.applicationName)",
                              "Show my \(.applicationName) songs"],
                    shortTitle: "Open Songs",
                    systemImageName: "music.note.list")

        AppShortcut(intent: OpenNotesIntent(),
                    phrases: ["Open Notes in \(.applicationName)",
                              "Show my \(.applicationName) notes"],
                    shortTitle: "Open Notes",
                    systemImageName: "note.text")

        AppShortcut(intent: OpenPreferredScreenplayIntent(),
                    phrases: ["Open my screenplay in \(.applicationName)",
                              "Open my \(.applicationName) script"],
                    shortTitle: "Open Screenplay",
                    systemImageName: "film")

        AppShortcut(intent: NewNoteIntent(),
                    phrases: ["New note in \(.applicationName)",
                              "Add a note to \(.applicationName)"],
                    shortTitle: "New Note",
                    systemImageName: "note.text.badge.plus")

        AppShortcut(intent: NewSongIntent(),
                    phrases: ["New song in \(.applicationName)",
                              "Add a song to \(.applicationName)"],
                    shortTitle: "New Song",
                    systemImageName: "music.note.list")

        AppShortcut(intent: AppendSongLineIntent(),
                    phrases: ["Add a lyric in \(.applicationName)"],
                    shortTitle: "Add Lyric Line",
                    systemImageName: "text.line.last.and.arrowtriangle.forward")

        AppShortcut(intent: NewScreenplayElementIntent(),
                    phrases: ["Add an action line in \(.applicationName)"],
                    shortTitle: "Add Element",
                    systemImageName: "text.append")
    }
}
