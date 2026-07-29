//
//  ScriptyShortcuts.swift
//  scripty
//
//  The shortcuts the app offers without being asked: what Siri answers to on a
//  fresh install, and what fills the Shortcuts app's Scripty page before anyone
//  has built anything.
//
//  Only the intents that need no parameter are here. Opening a screenplay or a
//  song by name is offered instead through the entities themselves — Spotlight
//  turns those up as you type, which is a better way to reach one of thirty
//  screenplays than a phrase that has to guess the title in advance.
//
//  Every phrase must contain `\(.applicationName)`; the system will not register
//  one that does not. Several spellings each, because a phrase is matched rather
//  than parsed, and "my Scripty songs" and "songs in Scripty" are the same
//  request from two people.
//

import AppIntents

nonisolated struct ScriptyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenSongsIntent(),
            phrases: ["Open my songs in \(.applicationName)",
                      "Open \(.applicationName) songs",
                      "Show my \(.applicationName) songs"],
            shortTitle: "Songs",
            systemImageName: "music.note.list")

        AppShortcut(
            intent: OpenNotesIntent(),
            phrases: ["Open my notes in \(.applicationName)",
                      "Open \(.applicationName) notes",
                      "Show my \(.applicationName) notes"],
            shortTitle: "Notes",
            systemImageName: "note.text")

        AppShortcut(
            intent: OpenScreenplaysIntent(),
            phrases: ["Open my screenplays in \(.applicationName)",
                      "Show my \(.applicationName) screenplays",
                      "Open my scripts in \(.applicationName)"],
            shortTitle: "Screenplays",
            systemImageName: "film")

        AppShortcut(
            intent: OpenDemoIntent(),
            phrases: ["Open the \(.applicationName) demo",
                      "Try \(.applicationName)"],
            shortTitle: "Demo",
            systemImageName: "play.rectangle")
    }
}
