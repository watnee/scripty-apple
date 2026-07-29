//
//  OpenIntents.swift
//  scripty
//
//  The three intents that only ask for a screen: songs, notes, the screenplay.
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

import AppIntents
import Foundation

/// Shared by the three below: a named screenplay goes through the widget's
/// pending destination, which already means "this project's list, no
/// particular document", while an unnamed one goes through the quick action,
/// which already means "whichever screenplay is yours".
@MainActor
private func openDocuments(_ project: ProjectEntity?, songs: Bool, in app: AppModel) {
    if let project {
        app.pendingWidgetDestination = WidgetDestination(projectId: project.id,
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
    var project: ProjectEntity?

    nonisolated static var parameterSummary: some ParameterSummary {
        Summary("Open songs in \(\.$project)")
    }

    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        openDocuments(project, songs: true, in: app)
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
    var project: ProjectEntity?

    nonisolated static var parameterSummary: some ParameterSummary {
        Summary("Open notes in \(\.$project)")
    }

    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        openDocuments(project, songs: false, in: app)
        return .result()
    }
}

struct OpenScreenplayIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "Open Screenplay" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Opens a screenplay's script.", categoryName: "Screenplays")
    }
    nonisolated static var openAppWhenRun: Bool { true }

    @Parameter(title: "Screenplay")
    var project: ProjectEntity?

    nonisolated static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$project)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // No AppModel needed: both cases are quick actions, and that singleton
        // is reachable without the dependency graph.
        QuickActions.shared.pending = project.map { .project(id: $0.id) } ?? .preferredProject
        return .result()
    }
}
