//
//  ScreenplayEntity.swift
//  scripty
//
//  A screenplay, as the rest of the system sees it: the thing Siri can name, the
//  Shortcuts app can list in a picker, and Spotlight can turn up alongside a
//  contact and a calendar event.
//
//  `nonisolated`, unlike almost everything else in this app. The whole target
//  defaults to MainActor, and these are read by App Intents on its own queues,
//  in a copy of the app woken without a screen — an entity that had to hop to
//  the main actor to say its own title would be the wrong shape for its only
//  reader.
//

import AppIntents

nonisolated struct ScreenplayEntity: AppEntity, IndexedEntity {
    /// The server's project id, which is also what `scripty://project?id=` and
    /// the Screenplays widget have always carried. One identifier for a
    /// screenplay everywhere outside the app.
    let id: Int
    let title: String
    let writers: String?
    let version: String?
    /// The writer's starred screenplay, drawn with the star the sidebar uses.
    let isDefault: Bool

    init(_ project: WidgetProject) {
        id = project.id
        title = project.title
        writers = project.writers
        version = project.version
        isDefault = project.isDefault
    }

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Screenplay")

    static let defaultQuery = ScreenplayQuery()

    /// The sidebar row, in the two lines a picker gives it. The star is the
    /// image rather than a word in the subtitle, so the default screenplay is
    /// recognisable in a list at a glance — the same way it is in the app.
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)",
                              subtitle: subtitle.map { "\($0)" },
                              image: .init(systemName: isDefault ? "star.fill" : "film"))
    }

    /// Whatever of the title page has been filled in, which is often none of it.
    private var subtitle: String? {
        let parts = [writers, version].compactMap { part in
            part?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Finding one

/// Answers the three questions the system asks about screenplays: what is this
/// id, what answers to this name, and what would you offer unprompted.
///
/// Every answer comes out of the widget snapshot — see IntentTargets for why
/// that is the right source and not a compromise. An account with no snapshot
/// (signed out, or a fresh install that has not loaded a list yet) has no
/// screenplays to offer, which is the truthful answer rather than an error: it
/// leaves Siri saying it found nothing instead of that something went wrong.
nonisolated struct ScreenplayQuery: EntityStringQuery {
    func entities(for identifiers: [Int]) async throws -> [ScreenplayEntity] {
        let rows = IntentTargets.screenplays(in: ProjectsWidgetStore.load())
        // Answered in the order asked, and silently short where a saved shortcut
        // names a screenplay since deleted — which is a normal thing to be
        // handed, not a failure. Shortcuts asks the writer to pick again.
        return identifiers.compactMap { id in rows.first { $0.id == id } }
            .map(ScreenplayEntity.init)
    }

    func entities(matching string: String) async throws -> [ScreenplayEntity] {
        let rows = IntentTargets.screenplays(in: ProjectsWidgetStore.load())
        return IntentTargets.screenplays(matching: string, in: rows).map(ScreenplayEntity.init)
    }

    func suggestedEntities() async throws -> [ScreenplayEntity] {
        IntentTargets.screenplays(in: ProjectsWidgetStore.load()).map(ScreenplayEntity.init)
    }
}
