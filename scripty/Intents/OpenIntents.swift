//
//  OpenIntents.swift
//  scripty
//
//  What Siri, Spotlight and the Shortcuts app can ask this app to open.
//
//  Every one of them ends the same way: it hands back a `scripty://` link and
//  lets the app's own front door answer it. That is the point of the shape.
//  Opening anything here needs a signed-in session and a loaded project list,
//  and an intent has neither — it runs in a copy of the app woken without a
//  screen, possibly before the session has even been established. The front door
//  has absorbed exactly that since the first widget shipped: the request is
//  parked, and ContentView carries it out once there is a list to carry it out
//  against. An intent that reached for the state directly would be a second
//  arrival path for the same requests, racing the first.
//
//  It also means these intents ask for nothing a writer could not ask for by
//  hand. `scripty://songs` in a Shortcut does what "open my songs" does, because
//  it is the same link.
//
//  None of this can be verified in the Simulator, whose App Intents metadata
//  store fails for Apple's own bundles too. Use a device.
//

import AppIntents

// MARK: - A screenplay by name

/// "Open Wakefield" — from Siri, from a Spotlight result, or from a shortcut.
///
/// `OpenIntent` rather than a plain intent: it is what makes tapping a
/// screenplay in Spotlight run this, and it gives the system the phrasing for
/// free rather than having it spelled out in three places.
nonisolated struct OpenScreenplayIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Screenplay"
    static let description = IntentDescription(
        "Opens a screenplay in Scripty.",
        categoryName: "Screenplays")

    @Parameter(title: "Screenplay", requestValueDialog: "Which screenplay?")
    var target: ScreenplayEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$target)")
    }

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(ShortcutLink.url(for: .project(id: target.id))))
    }
}

// MARK: - A song or a note by name

/// "Open the ballad" — straight to the document, in the screenplay it belongs
/// to, with that half of the Songs & Notes screen already showing.
nonisolated struct OpenDocumentIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Song or Note"
    static let description = IntentDescription(
        "Opens one of a screenplay's songs or notes in Scripty.",
        categoryName: "Songs & Notes")

    @Parameter(title: "Song or Note", requestValueDialog: "Which song or note?")
    var target: DocumentEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$target)")
    }

    func perform() async throws -> some IntentResult & OpensIntent {
        // The widget's own link, unchanged: a row tapped on the Home Screen and
        // a song asked for out loud are the same request arriving two ways.
        let url = WidgetLink.url(projectId: target.projectId,
                                 documentId: target.id,
                                 isSong: target.isSong)
        return .result(opensIntent: OpenURLIntent(url))
    }
}

// MARK: - The fixed destinations

/// The songs of whichever screenplay is the writer's — the starred one, or
/// failing that the one edited last.
///
/// Named no screenplay on purpose. This is the Home Screen menu's Songs entry
/// said out loud, and it means what that has always meant; the choice is made
/// against the live list rather than here, in the one place it is already made.
nonisolated struct OpenSongsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Songs"
    static let description = IntentDescription(
        "Opens the songs of your default screenplay in Scripty.",
        categoryName: "Songs & Notes")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(ShortcutLink.url(for: .songs)))
    }
}

/// The other half of that same screen.
nonisolated struct OpenNotesIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Notes"
    static let description = IntentDescription(
        "Opens the notes of your default screenplay in Scripty.",
        categoryName: "Songs & Notes")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(ShortcutLink.url(for: .notes)))
    }
}

/// The project list, with nothing selected — "show me my screenplays".
nonisolated struct OpenScreenplaysIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Screenplays"
    static let description = IntentDescription(
        "Opens your list of screenplays in Scripty.",
        categoryName: "Screenplays")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(ShortcutLink.screenplaysURL))
    }
}

/// The offline demo — the one thing here that works with no account at all,
/// which is why it is worth offering by voice to someone who has just installed
/// the app and has nothing else to open.
nonisolated struct OpenDemoIntent: AppIntent {
    static let title: LocalizedStringResource = "Open the Demo"
    static let description = IntentDescription(
        "Opens Scripty's offline demo screenplay. No account needed.",
        categoryName: "Screenplays")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(ShortcutLink.demoURL))
    }
}
