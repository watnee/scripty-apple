//
//  ScreenplayEntity.swift
//  scripty
//
//  A screenplay, as the rest of the system sees it: the thing Siri can name, the
//  Shortcuts app can list in a picker and search by title, and Spotlight can turn
//  up alongside a contact and a calendar event.
//
//  One entity, not two. There were two for a while — this one for Spotlight and
//  a `ProjectEntity` for the intents' pickers — which meant the Shortcuts app
//  offered two kinds of thing both called Screenplay, and only one of them could
//  be searched by name. Every intent takes this one now.
//
//  `nonisolated`, unlike almost everything else in this app. The whole target
//  defaults to MainActor, and these are read by App Intents on its own queues,
//  in a copy of the app woken without a screen — an entity that had to hop to
//  the main actor to say its own title would be the wrong shape for its only
//  reader.
//
//  The fields are `@Property` rather than plain lets, which costs a little
//  ceremony and buys two things: a shortcut can read them off a screenplay an
//  intent handed back (Get Details of Screenplay), and the Find Screenplays
//  action below can filter and sort on them.
//

import AppIntents
import CoreSpotlight

nonisolated struct ScreenplayEntity: AppEntity, IndexedEntity {
    /// The server's project id, which is also what `scripty://project?id=` and
    /// the Screenplays widget have always carried. One identifier for a
    /// screenplay everywhere outside the app.
    let id: Int

    @Property(title: "Title")
    var title: String

    @Property(title: "Writers")
    var writers: String?

    @Property(title: "Version")
    var version: String?

    /// When the server last saw it written to. Nil for a screenplay made and
    /// never touched, which is why the Find action treats it as the oldest
    /// thing there is rather than dropping it.
    @Property(title: "Last Edited")
    var lastEdited: Date?

    /// The writer's starred screenplay, drawn with the star the sidebar uses.
    @Property(title: "Starred")
    var isDefault: Bool

    init(_ project: WidgetProject) {
        id = project.id
        title = project.title
        writers = project.writers
        version = project.version
        lastEdited = project.lastEdited
        isDefault = project.isDefault
    }

    static let typeDisplayRepresentation =
        TypeDisplayRepresentation(name: "Screenplay",
                                  numericFormat: "\(placeholder: .int) screenplays")

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

    /// What Spotlight matches on, which is more than the title.
    ///
    /// The default attribute set is the display representation and nothing else,
    /// so a screenplay could only be found by the words in its name. A writer
    /// looking for the thing they wrote reaches for what they know about it —
    /// who it is by, which draft it is — and those are on the title page, not in
    /// the title. Keywords are the field Spotlight matches loosely, so they go
    /// there rather than into the description.
    var attributeSet: CSSearchableItemAttributeSet {
        let set = defaultAttributeSet
        set.contentDescription = subtitle
        set.keywords = ["screenplay", "script"] + [writers, version].compactMap { part in
            part?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        // Both are read out by Siri and shown in the result; `title` is not set
        // by the default set on every OS version, and setting it twice is
        // harmless where it is.
        set.title = title
        return set
    }
}

// MARK: - Finding one

/// Answers the four questions the system asks about screenplays: what is this
/// id, what answers to this name, what would you offer unprompted, and — for
/// the Find Screenplays action — which of them match these conditions.
///
/// Every answer comes out of the widget snapshot; see IntentTargets for why that
/// is the right source and not a compromise. An account with no snapshot (signed
/// out, or a fresh install that has not loaded a list yet) has no screenplays to
/// offer, which is the truthful answer rather than an error: it leaves Siri
/// saying it found nothing instead of that something went wrong.
nonisolated struct ScreenplayQuery: EntityStringQuery, EntityPropertyQuery {
    /// A Find action's conditions arrive as these and are applied by
    /// `IntentTargets.rows(_:passing:all:)`. A closure rather than a predicate
    /// object because the rows are already in memory — there is no store to push
    /// a query down into, and nothing to gain by describing the filter twice.
    typealias ComparatorMappingType = @Sendable (WidgetProject) -> Bool

    /// What a saved id stands for.
    ///
    /// Never returns fewer than it was asked about — see
    /// `ProjectsWidgetStore.pick(ids:in:)`. Told nothing about a saved id, iOS
    /// does not ask again; it decides whatever held that id needs reconfiguring
    /// and throws the writer's choice away. A screenplay merely absent from this
    /// device's last snapshot — signed out, in the demo, or simply not loaded
    /// yet — is not a screenplay that is gone.
    func entities(for identifiers: [Int]) async throws -> [ScreenplayEntity] {
        ProjectsWidgetStore.pick(ids: identifiers, in: ProjectsWidgetStore.load().projects)
            .map(ScreenplayEntity.init)
    }

    /// What was typed into the picker's search field, or heard by Siri.
    func entities(matching string: String) async throws -> [ScreenplayEntity] {
        let rows = IntentTargets.screenplays(in: ProjectsWidgetStore.load())
        return IntentTargets.screenplays(matching: string, in: rows).map(ScreenplayEntity.init)
    }

    /// What a picker offers before anything has been typed: all of them, most
    /// recently edited first.
    func suggestedEntities() async throws -> [ScreenplayEntity] {
        IntentTargets.screenplays(in: ProjectsWidgetStore.load()).map(ScreenplayEntity.init)
    }

    // MARK: The Find Screenplays action

    /// Declaring these is the whole of what it takes for the Shortcuts app to
    /// vend a **Find Screenplays** action with a condition builder — the app
    /// writes no such intent itself.
    ///
    /// Every comparison folds case and accents, because it is the same
    /// `TextTest` the picker's own matching uses. A shortcut filtering for
    /// "revolution" and a writer who typed *Révolution* mean each other.
    static var properties = QueryProperties {
        Property(\ScreenplayEntity.$title) {
            ContainsComparator { term in { IntentTargets.TextTest.contains(term).matches($0.title) } }
            HasPrefixComparator { term in
                { IntentTargets.TextTest.beginsWith(term).matches($0.title) }
            }
            EqualToComparator { term in { IntentTargets.TextTest.exactly(term).matches($0.title) } }
        }
        Property(\ScreenplayEntity.$writers) {
            ContainsComparator { term in
                { IntentTargets.TextTest.contains(term).matches($0.writers ?? "") }
            }
        }
        Property(\ScreenplayEntity.$lastEdited) {
            GreaterThanComparator { date in { ($0.lastEdited ?? .distantPast) > date } }
            LessThanComparator { date in { ($0.lastEdited ?? .distantPast) < date } }
        }
        Property(\ScreenplayEntity.$isDefault) {
            EqualToComparator { starred in { $0.isDefault == starred } }
        }
    }

    static var sortingOptions = SortingOptions {
        SortableBy(\ScreenplayEntity.$title)
        SortableBy(\ScreenplayEntity.$lastEdited)
    }

    /// Only the first sort is honoured. Shortcuts offers one, and a second would
    /// be a promise this cannot keep quietly — a stable tiebreak on the other
    /// term is what `IntentTargets` does instead.
    func entities(matching comparators: [ComparatorMappingType],
                  mode: ComparatorMode,
                  sortedBy: [EntityQuerySort<ScreenplayEntity>],
                  limit: Int?) async throws -> [ScreenplayEntity] {
        let rows = IntentTargets.screenplays(in: ProjectsWidgetStore.load())
        let kept = IntentTargets.rows(rows, passing: comparators, all: mode == .and)
        let sort = sortedBy.first
        let ordered = IntentTargets.screenplays(
            kept,
            sortedBy: sort?.by == \ScreenplayEntity.$title ? .title : .edited,
            // No sort at all is the list as it already is: newest first, which
            // is what every other reader of this snapshot shows.
            ascending: sort.map { $0.order == .ascending } ?? false)
        return Array(ordered.prefix(limit ?? ordered.count)).map(ScreenplayEntity.init)
    }
}
