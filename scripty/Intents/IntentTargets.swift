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

enum IntentTargets {

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
    /// Three tiers rather than a similarity score. Dictation gives back a whole
    /// title when it heard one, so an exact match is the common case and has to
    /// win outright — a screenplay called *Wake* must not lose to *Wakefield*
    /// merely because *Wakefield* was edited more recently. Below that, a
    /// leading match beats one buried in the middle, which is how a person
    /// shortens a title they are about to say.
    private static func rank(_ needle: String, in name: String) -> Int? {
        if name == needle { return 0 }
        if name.hasPrefix(needle) { return 1 }
        if name.contains(needle) { return 2 }
        return nil
    }

    /// Case and accents folded, ends trimmed. Siri hands over what it heard, not
    /// what was typed when the screenplay was named: *the révolution* and *The
    /// Revolution* are one title being asked for twice.
    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
