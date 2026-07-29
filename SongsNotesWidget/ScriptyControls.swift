//
//  ScriptyControls.swift
//  SongsNotesWidget
//
//  The Control Center, Lock Screen and Action Button tiles.
//
//  In this extension rather than one of their own. A `ControlWidget` is a
//  `Widget`, and the widgetkit extension point that hosts the tile on the Home
//  Screen hosts these too — so a fourth target would buy a second copy of the
//  App Group boilerplate, two more entitlements files and a hundred lines of
//  hand-written project.pbxproj for something the writer cannot tell apart.
//
//  Every one of them is a button carrying a `scripty://` URL through the
//  system's own `OpenURLIntent`, and the reason is worth writing down: a custom
//  intent's *type* has to compile into whatever references it, and an intent
//  that could actually carry out a capture would have to reach AppModel and the
//  HAL client — neither of which an extension can compile, let alone run
//  without credentials or a network entitlement. A URL asks the app, which has
//  both. `ScriptyLink` in Shared/SongsNotesWidgetData.swift is the vocabulary;
//  `scriptyApp.onOpenURL` is the door.
//
//  Buttons, never toggles. A toggle owns a piece of binary app state and has to
//  report it back through a `ControlValueProvider`; there is no such state
//  here, and a toggle that flips itself back is worse than no control at all.
//
//  None of them names a screenplay. A fixed tile on a Lock Screen cannot know
//  which one it will be pressed for, so it asks for a screen and the app
//  settles the rest — the starred draft, else the one edited last, which is the
//  same answer the Home Screen's own Songs and Notes entries give.
//

import AppIntents
import SwiftUI
import WidgetKit

struct SongsControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "scripty.control.songs") {
            ControlWidgetButton(action: OpenURLIntent(ScriptyLink.url(for: .songs))) {
                Label("Songs", systemImage: "music.note.list")
            }
        }
        .displayName("Songs")
        .description("Open the songs for your screenplay.")
    }
}

struct NewNoteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "scripty.control.newNote") {
            ControlWidgetButton(
                action: OpenURLIntent(ScriptyLink.url(for: .compose(isSong: false)))
            ) {
                Label("New Note", systemImage: "note.text.badge.plus")
            }
        }
        .displayName("New Note")
        .description("Start a note in your screenplay.")
    }
}

struct NewSongControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "scripty.control.newSong") {
            ControlWidgetButton(
                action: OpenURLIntent(ScriptyLink.url(for: .compose(isSong: true)))
            ) {
                Label("New Song", systemImage: "waveform.badge.plus")
            }
        }
        .displayName("New Song")
        .description("Start a song in your screenplay.")
    }
}

struct ScreenplayControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "scripty.control.screenplay") {
            ControlWidgetButton(action: OpenURLIntent(ScriptyLink.url(for: .screenplay))) {
                Label("Screenplay", systemImage: "film")
            }
        }
        .displayName("Screenplay")
        .description("Open your screenplay.")
    }
}
