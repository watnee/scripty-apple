//
//  OpenIntents.swift
//  scripty
//
//  The intents that only ask for a screen: songs, notes, a screenplay, one song
//  or note.
//
//  None of them does any work. They park a request and return, which is what
//  every other route into this app already does — a widget row, a Home Screen
//  menu entry, a Control Center button — and for the same reason: running the
//  intent is often what launches the app, and at that moment there is no
//  session and no project list to open anything against. `ContentView` drains
//  the request once there is.
//
//  So there is no `awaitReady` here and no error to report. An intent run while
//  signed out parks something the sign-out path then clears, and the writer
//  lands on the login screen — which is the honest answer to "open my songs"
//  from a signed-out device, and is what tapping the widget already does.
//
//  Two of them are `OpenIntent`s. That is not decoration: an indexed entity is
//  only openable from a Spotlight result if the app declares an `OpenIntent`
//  for its type, so without these a screenplay found in Spotlight would bring
//  the app to the front on whatever was last on screen — which reads as the app
//  having lost it.
//

import AppIntents
import Foundation

/// Shared by the two list intents: a named screenplay goes through the widget's
/// pending destination, which already means "this project's list, no particular
/// document", while an unnamed one goes through the quick action, which already
/// means "whichever screenplay is yours".
@MainActor
private func openDocuments(_ screenplay: ScreenplayEntity?, songs: Bool, in app: AppModel) {
    if let screenplay {
        app.pendingWidgetDestination = WidgetDestination(projectId: screenplay.id,
                                                         documentId: nil,
                                                         isSong: songs)
    } else {
        QuickActions.shared.pending = songs ? .songs : .notes
    }
}

struct OpenSongsIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "Open Songs" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Opens the songs for a screenplay.",
                          categoryName: "Songs & Notes")
    }
    nonisolated static var openAppWhenRun: Bool { true }

    @Parameter(title: "Screenplay")
    var screenplay: ScreenplayEntity?

    nonisolated static var parameterSummary: some ParameterSummary {
        Summary("Open songs in \(\.$screenplay)")
    }

    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        openDocuments(screenplay, songs: true, in: app)
        return .result()
    }
}

struct OpenNotesIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "Open Notes" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Opens the notes for a screenplay.",
                          categoryName: "Songs & Notes")
    }
    nonisolated static var openAppWhenRun: Bool { true }

    @Parameter(title: "Screenplay")
    var screenplay: ScreenplayEntity?

    nonisolated static var parameterSummary: some ParameterSummary {
        Summary("Open notes in \(\.$screenplay)")
    }

    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        openDocuments(screenplay, songs: false, in: app)
        return .result()
    }
}

// MARK: - A screenplay by name

/// Opens the screenplay a picker, a search field or a Spotlight result named.
///
/// `OpenIntent`'s parameter has to be called `target` and cannot be optional,
/// which is why the "no particular screenplay" case is the separate intent
/// below rather than a nil passed to this one. Two actions, but each says one
/// thing: this one always asks which, and that one never does.
struct OpenScreenplayIntent: OpenIntent {
    nonisolated static var title: LocalizedStringResource { "Open Screenplay" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Opens a screenplay's script.", categoryName: "Screenplays")
    }
    nonisolated static var openAppWhenRun: Bool { true }

    @Parameter(title: "Screenplay")
    var target: ScreenplayEntity

    nonisolated static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$target)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // No AppModel needed: this is a quick action, and that singleton is
        // reachable without the dependency graph.
        QuickActions.shared.pending = .project(id: target.id)
        return .result()
    }
}

/// The one a phrase can carry: "open my screenplay in Scripty", with no title
/// to hear wrong and nothing to pick from.
///
/// It settles the same way the Home Screen menu's own entries do — the starred
/// screenplay, else the one edited last — and so works on a device whose
/// snapshot is empty, which is every demo and every signed-out launch.
struct OpenPreferredScreenplayIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "Open My Screenplay" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Opens your starred screenplay, or the one you edited last.",
                          categoryName: "Screenplays")
    }
    nonisolated static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickActions.shared.pending = .preferredProject
        return .result()
    }
}

// MARK: - One song or note

/// Opens a single song or note, in the screenplay it belongs to.
///
/// The destination carries both ids because that is what the Songs & Notes
/// screen needs, and it is the same `WidgetDestination` a tapped widget row
/// parks — one arrival path for a row tapped on the Home Screen, a song asked
/// for out loud, and a Spotlight result.
struct OpenSongOrNoteIntent: OpenIntent {
    nonisolated static var title: LocalizedStringResource { "Open Song or Note" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Opens a song or a note by name.", categoryName: "Songs & Notes")
    }
    nonisolated static var openAppWhenRun: Bool { true }

    @Parameter(title: "Song or Note")
    var target: DocumentEntity

    nonisolated static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$target)")
    }

    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        app.pendingWidgetDestination = WidgetDestination(projectId: target.projectId,
                                                         documentId: target.id,
                                                         isSong: target.isSong)
        return .result()
    }
}
