//
//  IntentTargets.swift
//  scripty
//
//  Turning what Siri heard, or what someone typed into the Shortcuts app's
//  picker, into a row this app can open.
//
//  The rows come from the two widget snapshots and nowhere else. That is not a
//  shortcut taken: an entity query is answered by a copy of the app woken in the
//  background, with no screen, and often with no network — asking the server
//  would mean a spoken request that works at a desk and fails on the Tube. The
//  snapshots are already written on every project load, already scoped to one
//  account, and already taken away at sign-out, which is the whole of what this
//  needs. See Shared/ProjectsWidgetData.swift for why their caps are what they
//  are; they are sized for this reader now, not for six widget rows.
//
//  Pure Foundation on purpose — no AppIntents — so the matching can be checked
//  by Tests/run.sh. It is worth checking. Every failure here is silent from the
//  outside: a match ranked wrong opens a plausible screenplay rather than the
//  named one, and a match missed becomes "I couldn't find that" for something
//  the writer is looking straight at.
//

import Foundation

/// `nonisolated`, like the snapshots it reads: App Intents calls this from
/// its own queues, and the app target's MainActor default is not the
/// isolation the entity queries above it actually run under.
nonisolated enum IntentTargets {

    // MARK: Everything nameable

    /// The screenplays an intent can name, most recently edited first.
    ///
    /// Sorted again rather than trusted: the snapshot is written ordered, but
    /// that ordering is the widget's business and a query that quietly followed
    /// it would break the day the widget changed its mind.
    static func screenplays(in snapshot: ProjectsSnapshot) -> [WidgetProject] {
        ProjectsWidgetStore.ordered(snapshot.projects, limit: snapshot.projects.count)
    }

    /// The songs and notes an intent can name, newest first.
    ///
    /// Both halves together, as the entity is — see DocumentEntity for why.
    static func documents(in snapshot: SongsNotesSnapshot) -> [WidgetDocument] {
        SongsNotesWidgetStore.ordered(snapshot.documents, limit: snapshot.documents.count)
    }

    // MARK: Matching a name

    /// The screenplays that answer to what was said, best match first.
    static func screenplays(matching term: String,
                            in rows: [WidgetProject]) -> [WidgetProject] {
        ranked(term, rows) { $0.title }
    }

    /// The same for a song or a note.
    static func documents(matching term: String,
                          in rows: [WidgetDocument]) -> [WidgetDocument] {
        ranked(term, rows) { $0.title }
    }

    /// The one row a name meant, or nil where nothing answers to it.
    ///
    /// For the places that have to act rather than offer a list — an intent
    /// adding a lyric to a song named out loud, where a picker never appears
    /// and there is nobody to choose between two candidates. The ranking is the
    /// picker's, so the row this settles on is the row that would have been at
    /// the top of it; anything less would be two ideas of what a name means.
    static func best<Row>(matching term: String,
                          in rows: [Row],
                          name: (Row) -> String) -> Row? {
        guard !normalized(term).isEmpty else { return nil }
        return ranked(term, rows, name: name).first
    }

    /// Rows whose name answers to `term`, best first, ties broken by the order
    /// they arrived in — which is recency, so the more recently edited of two
    /// equally good matches wins.
    ///
    /// An empty term is every row rather than none: it is what the Shortcuts
    /// picker asks with before anything has been typed.
    private static func ranked<Row>(_ term: String,
                                    _ rows: [Row],
                                    name: (Row) -> String) -> [Row] {
        let needle = normalized(term)
        guard !needle.isEmpty else { return rows }
        return rows.enumerated()
            .compactMap { position, row -> (rank: Int, position: Int, row: Row)? in
                guard let rank = rank(needle, in: normalized(name(row))) else { return nil }
                return (rank, position, row)
            }
            .sorted { ($0.rank, $0.position) < ($1.rank, $1.position) }
            .map(\.row)
    }

    /// How good a match this is, or nil for none.
    ///
    /// Tiers rather than a similarity score. Dictation gives back a whole title
    /// when it heard one, so an exact match is the common case and has to win
    /// outright — a screenplay called *Wake* must not lose to *Wakefield* merely
    /// because *Wakefield* was edited more recently. Below that, a leading match
    /// beats one buried in the middle, which is how a person shortens a title
    /// they are about to say.
    ///
    /// The two lower tiers are what a search field needs and a spoken title did
    /// not. Someone typing *wake* into the Shortcuts picker means the word, so
    /// *The Long Wake Up* is a better answer than *Awakening* even though both
    /// merely contain the letters; and someone typing *wake long*, in the order
    /// the words came to them, still means the screenplay that has both.
    private static func rank(_ needle: String, in name: String) -> Int? {
        if name == needle { return 0 }
        if name.hasPrefix(needle) { return 1 }
        if words(in: name).contains(where: { $0.hasPrefix(needle) }) { return 2 }
        if name.contains(needle) { return 3 }
        // Only for a search of several words: for one word this asks exactly
        // what the tier above already answered, and would rank the same row
        // twice over.
        let asked = words(in: needle)
        if asked.count > 1, asked.allSatisfy({ name.contains($0) }) { return 4 }
        return nil
    }

    /// A name broken where a reader would break it. Punctuation counts as a gap
    /// so that *Act 2 — Reprise* is four words rather than one long one.
    private static func words(in text: String) -> [Substring] {
        text.split { !$0.isLetter && !$0.isNumber }
    }

    /// Case and accents folded, ends trimmed. Siri hands over what it heard, not
    /// what was typed when the screenplay was named: *the révolution* and *The
    /// Revolution* are one title being asked for twice.
    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Answering a Find action

    /// Whether a name satisfies one of the Find action's own text conditions.
    ///
    /// Shortcuts asks in its words — *contains*, *begins with*, *is* — and each
    /// arrives here as the same folded comparison the picker uses, so a filter
    /// typed into a shortcut and a title said out loud agree about what a name
    /// is. In particular an accent nobody typed is not a screenplay nobody can
    /// filter for.
    enum TextTest: Sendable {
        case contains(String)
        case beginsWith(String)
        case exactly(String)

        func matches(_ name: String) -> Bool {
            let subject = normalized(name)
            return switch self {
            case .contains(let term): subject.contains(normalized(term))
            case .beginsWith(let term): subject.hasPrefix(normalized(term))
            case .exactly(let term): subject == normalized(term)
            }
        }
    }

    /// The rows left after a Find action's conditions have had their say.
    ///
    /// `all` is Shortcuts' own "all/any of the following", passed through rather
    /// than interpreted. No conditions is every row: that is what the action
    /// looks like the moment it is dragged into a shortcut, and an empty result
    /// there reads as a broken action rather than an unfinished one.
    static func rows<Row>(_ rows: [Row],
                          passing tests: [(Row) -> Bool],
                          all: Bool) -> [Row] {
        guard !tests.isEmpty else { return rows }
        return rows.filter { row in
            all ? tests.allSatisfy { $0(row) } : tests.contains { $0(row) }
        }
    }

    /// What a Find action can be sorted by, in the two terms both lists share.
    enum Order: Sendable {
        /// Alphabetical, as a shelf is.
        case title
        /// When it was last written to — the order everything else in this app
        /// already puts these lists in.
        case edited
    }

    static func screenplays(_ rows: [WidgetProject],
                            sortedBy order: Order,
                            ascending: Bool) -> [WidgetProject] {
        // A screenplay the server never dated sorts as the oldest thing there
        // is rather than being dropped — the rule `ordered` follows, and the
        // same one, because a Find action and the widget disagreeing about
        // where an untouched draft belongs would be nobody's idea of an
        // ordering.
        sorted(rows, by: order, ascending: ascending,
               title: \.title, edited: { $0.lastEdited ?? .distantPast })
    }

    static func documents(_ rows: [WidgetDocument],
                          sortedBy order: Order,
                          ascending: Bool) -> [WidgetDocument] {
        sorted(rows, by: order, ascending: ascending,
               title: \.title, edited: \.updatedAt)
    }

    /// Ties break on the other term, so a Find action returns the same list
    /// twice running. Swift's sort promises nothing about equal elements, and a
    /// shortcut that quietly reshuffles its own results is a bug nobody can
    /// reproduce.
    private static func sorted<Row>(_ rows: [Row],
                                    by order: Order,
                                    ascending: Bool,
                                    title: KeyPath<Row, String>,
                                    edited: (Row) -> Date) -> [Row] {
        rows.sorted { lhs, rhs in
            let byTitle = lhs[keyPath: title].localizedCaseInsensitiveCompare(rhs[keyPath: title])
            switch order {
            case .title:
                if byTitle != .orderedSame {
                    return ascending == (byTitle == .orderedAscending)
                }
                return edited(lhs) > edited(rhs)
            case .edited:
                let left = edited(lhs), right = edited(rhs)
                if left != right { return ascending ? left < right : left > right }
                return byTitle == .orderedAscending
            }
        }
    }
}
