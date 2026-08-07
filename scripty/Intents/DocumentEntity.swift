//
//  DocumentEntity.swift
//  scripty
//
//  A song or a note, as the rest of the system sees it. The shape of
//  ScreenplayEntity next door, for the same reasons and with the same
//  `nonisolated` and `@Property` notes.
//
//  One entity for both halves rather than two, matching the app: songs and notes
//  are the two sides of one screen, they share an id space, and a writer asking
//  for something by name rarely stops to say which of the two it was. Which one
//  it turned out to be is drawn on the row instead, with the symbol the app uses
//  — and is a condition the Find action can ask about, for the shortcut that
//  does mean only the songs.
//

import AppIntents
import CoreSpotlight
import Foundation

/// Which half a document belongs to, in a form a shortcut can name.
///
/// Not `DocumentType`: that is the app's own vocabulary, spells notes in the
/// plural because the server's rel does, and is not an `AppEnum`. Two cases
/// mapped by hand is cheaper than teaching the model type about App Intents.
enum DocumentKindAppEnum: String, AppEnum {
    case song
    case note

    nonisolated static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Kind"
    }

    nonisolated static var caseDisplayRepresentations: [DocumentKindAppEnum: DisplayRepresentation] {
        [.song: DisplayRepresentation(title: "Song", image: .init(systemName: "music.note")),
         .note: DisplayRepresentation(title: "Note", image: .init(systemName: "note.text"))]
    }

    init(isSong: Bool) {
        self = isSong ? .song : .note
    }

    var isSong: Bool { self == .song }
}

nonisolated struct DocumentEntity: AppEntity, IndexedEntity {
    let id: Int

    /// The screenplay it belongs to. Carried because opening it needs both ids —
    /// a song is reached through its project, never on its own.
    let projectId: Int

    @Property(title: "Title")
    var title: String

    @Property(title: "Kind")
    var kind: DocumentKindAppEnum

    @Property(title: "Screenplay")
    var projectTitle: String

    @Property(title: "Last Edited")
    var updatedAt: Date

    init(_ document: WidgetDocument) {
        id = document.id
        projectId = document.projectId
        title = document.title
        kind = DocumentKindAppEnum(isSong: document.isSong)
        projectTitle = document.projectTitle
        updatedAt = document.updatedAt
    }

    var isSong: Bool { kind.isSong }

    static let typeDisplayRepresentation =
        TypeDisplayRepresentation(name: "Song or Note",
                                  numericFormat: "\(placeholder: .int) songs and notes")

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

    /// What Spotlight matches on. The screenplay's name is the point: a writer
    /// searching for a note reaches for the story it belongs to at least as
    /// often as for what they called the note, and half of these are called
    /// something like *Beats*.
    var attributeSet: CSSearchableItemAttributeSet {
        let set = defaultAttributeSet
        set.title = title
        set.contentDescription = projectTitle
        set.keywords = [projectTitle, isSong ? "song" : "note", isSong ? "lyrics" : "notes"]
        // What the app already knows about it, so a Spotlight result can say
        // when it was last written to rather than only what it is called.
        set.contentModificationDate = updatedAt
        return set
    }
}

// MARK: - Finding one

/// The same four questions ScreenplayQuery answers, about the other list. Read
/// that file first; only what differs is commented here.
nonisolated struct DocumentQuery: EntityStringQuery, EntityPropertyQuery {
    typealias ComparatorMappingType = @Sendable (WidgetDocument) -> Bool

    /// Silently short where a saved shortcut names a song since deleted — a
    /// normal thing to be handed, not a failure, and Shortcuts asks the writer
    /// to pick again.
    ///
    /// Deliberately unlike the screenplay query, which substitutes a placeholder
    /// rather than drop an id. That one is also answering for a *placed widget*,
    /// where being told nothing throws the writer's configuration away; nothing
    /// holds a document id that way, and a ghost row reading "Song" with no
    /// screenplay under it would be worse than an honest re-prompt.
    func entities(for identifiers: [Int]) async throws -> [DocumentEntity] {
        let rows = IntentTargets.documents(in: SongsNotesWidgetStore.load())
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

    // MARK: The Find Songs & Notes action

    static var properties = QueryProperties {
        Property(\DocumentEntity.$title) {
            ContainsComparator { term in { @Sendable in IntentTargets.TextTest.contains(term).matches($0.title) } }
            HasPrefixComparator { term in
                { @Sendable in IntentTargets.TextTest.beginsWith(term).matches($0.title) }
            }
            EqualToComparator { term in { @Sendable in IntentTargets.TextTest.exactly(term).matches($0.title) } }
        }
        /// The condition that makes this one action serve two lists: **Kind is
        /// Song** is how a shortcut says it meant only the songs.
        Property(\DocumentEntity.$kind) {
            EqualToComparator { kind in { @Sendable in $0.isSong == kind.isSong } }
            NotEqualToComparator { kind in { @Sendable in $0.isSong != kind.isSong } }
        }
        /// By name rather than by picking a `ScreenplayEntity`: a document and
        /// its screenplay reach this process through two different snapshots,
        /// and matching them by id would quietly find nothing whenever one of
        /// the two had been trimmed and the other had not.
        Property(\DocumentEntity.$projectTitle) {
            ContainsComparator { term in
                { @Sendable in IntentTargets.TextTest.contains(term).matches($0.projectTitle) }
            }
            EqualToComparator { term in
                { @Sendable in IntentTargets.TextTest.exactly(term).matches($0.projectTitle) }
            }
        }
        Property(\DocumentEntity.$updatedAt) {
            GreaterThanComparator { date in { @Sendable in $0.updatedAt > date } }
            LessThanComparator { date in { @Sendable in $0.updatedAt < date } }
        }
    }

    static var sortingOptions = SortingOptions {
        SortableBy(\DocumentEntity.$title)
        SortableBy(\DocumentEntity.$updatedAt)
    }

    func entities(matching comparators: [ComparatorMappingType],
                  mode: ComparatorMode,
                  sortedBy: [EntityQuerySort<DocumentEntity>],
                  limit: Int?) async throws -> [DocumentEntity] {
        let rows = IntentTargets.documents(in: SongsNotesWidgetStore.load())
        let kept = IntentTargets.rows(rows, passing: comparators, all: mode == .and)
        let sort = sortedBy.first
        let ordered = IntentTargets.documents(
            kept,
            sortedBy: sort?.by == \DocumentEntity.$title ? .title : .edited,
            ascending: sort.map { $0.order == .ascending } ?? false)
        return Array(ordered.prefix(limit ?? ordered.count)).map(DocumentEntity.init)
    }
}
