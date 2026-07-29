//
//  DocumentEntity.swift
//  scripty
//
//  A song or a note, as the rest of the system sees it. The shape of
//  ScreenplayEntity next door, for the same reasons and with the same
//  `nonisolated` note.
//
//  One entity for both halves rather than two, matching the app: songs and notes
//  are the two sides of one screen, they share an id space, and a writer asking
//  for something by name rarely stops to say which of the two it was. Which one
//  it turned out to be is drawn on the row instead, with the symbol the app uses.
//

import AppIntents

nonisolated struct DocumentEntity: AppEntity, IndexedEntity {
    let id: Int
    let title: String
    let isSong: Bool
    /// The screenplay it belongs to. Carried because opening it needs both ids —
    /// a song is reached through its project, never on its own.
    let projectId: Int
    let projectTitle: String

    init(_ document: WidgetDocument) {
        id = document.id
        title = document.title
        isSong = document.isSong
        projectId = document.projectId
        projectTitle = document.projectTitle
    }

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Song or Note")

    static let defaultQuery = DocumentQuery()

    /// The screenplay is the subtitle because it is the disambiguator: two
    /// drafts each having a note called *Beats* is the normal case, not an edge
    /// one, and the title alone would leave the picker showing the same row
    /// twice.
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)",
                              subtitle: "\(projectTitle)",
                              image: .init(systemName: isSong ? "music.note" : "note.text"))
    }
}

// MARK: - Finding one

nonisolated struct DocumentQuery: EntityStringQuery {
    func entities(for identifiers: [Int]) async throws -> [DocumentEntity] {
        let rows = IntentTargets.documents(in: SongsNotesWidgetStore.load())
        // Answered in the order asked, and silently short where a saved shortcut
        // names a song since deleted — a normal thing to be handed, not a
        // failure. Shortcuts asks the writer to pick again.
        return identifiers.compactMap { id in rows.first { $0.id == id } }
            .map(DocumentEntity.init)
    }

    func entities(matching string: String) async throws -> [DocumentEntity] {
        let rows = IntentTargets.documents(in: SongsNotesWidgetStore.load())
        return IntentTargets.documents(matching: string, in: rows).map(DocumentEntity.init)
    }

    func suggestedEntities() async throws -> [DocumentEntity] {
        IntentTargets.documents(in: SongsNotesWidgetStore.load()).map(DocumentEntity.init)
    }
}
