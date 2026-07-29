//
//  ProjectEntity.swift
//  scripty
//
//  A screenplay, as Siri and the Shortcuts app know it: the thing a picker
//  offers when an intent asks which one.
//
//  Read out of the Screenplays widget's App Group snapshot rather than the
//  server. A picker has to answer while somebody is looking at it, from a
//  process that may have been launched for no other reason, possibly on a
//  device with no signal — and the snapshot is right there, already narrowed
//  to the five fields a row needs, already refreshed on every launch by the
//  same code that fills the widget. Asking the server instead would mean a
//  sign-in and a round trip before the list could be drawn at all.
//
//  What that costs is honest and worth stating: a screenplay made on the web
//  and never seen by this device is not in the picker until the next launch,
//  the picker is empty in the demo (a demo project id means nothing once the
//  demo ends), and it is empty signed out (nobody should read the last
//  writer's titles out of a Shortcuts picker either). All three are the
//  widget's existing contract, not new ones.
//

import AppIntents
import Foundation

struct ProjectEntity: AppEntity {
    let id: Int
    let title: String
    let lastEdited: Date?
    let isDefault: Bool

    init(_ project: WidgetProject) {
        id = project.id
        title = project.title
        lastEdited = project.lastEdited
        isDefault = project.isDefault
    }

    nonisolated static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Screenplay", numericFormat: "\(placeholder: .int) screenplays")
    }

    nonisolated static var defaultQuery: ProjectEntityQuery { ProjectEntityQuery() }

    /// The star is worth a line of its own: an account with several drafts of
    /// the same story ends up with several rows reading much the same, and
    /// "which one is mine" is the question the star already answers.
    nonisolated var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: subtitle)
    }

    private var subtitle: LocalizedStringResource? {
        if isDefault { return "Starred" }
        guard let lastEdited else { return nil }
        let when = lastEdited.formatted(.relative(presentation: .named))
        return "Edited \(when)"
    }
}

struct ProjectEntityQuery: EntityQuery {
    /// Both methods are `@MainActor` for the same reason `perform()` is: the
    /// store they read is main-actor isolated like everything else in this app,
    /// and an `async` protocol requirement can be satisfied by an isolated
    /// method. Left nonisolated they still compile, but every call becomes an
    /// implicit hop — which Swift 6 turns from a warning into an error.

    /// What a picker offers before anything has been typed or chosen. Already
    /// newest-edited first — the order the snapshot was written in, which is
    /// the order the widget draws.
    @MainActor
    func suggestedEntities() async throws -> [ProjectEntity] {
        ProjectsWidgetStore.suggested(in: ProjectsWidgetStore.load()).map(ProjectEntity.init)
    }

    /// What the ids a picker has already settled on stand for.
    ///
    /// Never returns fewer than it was asked about — see `pick(ids:in:)`. Told
    /// nothing about a saved id, iOS does not ask again; it decides whatever
    /// held that id needs reconfiguring and throws the choice away. A
    /// screenplay merely absent from this device's last snapshot is not a
    /// screenplay that is gone.
    @MainActor
    func entities(for identifiers: [Int]) async throws -> [ProjectEntity] {
        ProjectsWidgetStore.pick(ids: identifiers, in: ProjectsWidgetStore.load().projects)
            .map(ProjectEntity.init)
    }
}
