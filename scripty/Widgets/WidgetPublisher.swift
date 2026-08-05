//
//  WidgetPublisher.swift
//  scripty
//
//  Where the app meets its Songs and Notes widgets: it turns a project's
//  documents into the handful of rows they draw, and tells WidgetKit which of
//  the two has changed.
//
//  The shape of this file is QuickActions.swift's, for the same reasons. The
//  pure half — merging, ordering, the URLs — lives next door in
//  Shared/SongsNotesWidgetData.swift, which the extension compiles too and
//  Tests/SongsNotesWidget checks without a simulator. Only the part that talks
//  to WidgetKit is here.
//

import Foundation
import SwiftUI
import WidgetKit

enum WidgetPublisher {
    /// Republishes one project's rows on both widgets.
    ///
    /// Called wherever a project's documents settle rather than from the load
    /// itself, so that every path that changes them — creating, renaming,
    /// deleting, importing, restoring from the trash — is covered by the one
    /// call site watching the list.
    ///
    /// A signed-out device publishes like any other: its workspace is kept on
    /// disk, so a row naming one of its songs opens that song tomorrow just as
    /// it does now.
    ///
    /// Only the throwaway demo publishes nothing, exactly as the Home Screen
    /// menu's recents do not. Its songs live in memory for as long as the app
    /// is running, so a row naming one is a row that could only ever fail to
    /// open — and it would sit on the Home Screen long after the demo was over,
    /// since nothing but this app can take it back down.
    static func publish(_ documents: [TextDocument], project: Project,
                        isEphemeralDemo: Bool) {
        guard !isEphemeralDemo else { return }
        let rows = documents.compactMap { document -> WidgetDocument? in
            // A document the server never dated is left out rather than sorted
            // as ancient — the same rule `mostRecentlyEdited` follows, and for
            // the same reason: this widget is a "what have I been working on"
            // list, and a row with nothing to be recent about would take a
            // slot from one that has.
            guard let updatedAt = document.updatedAt else { return nil }
            return WidgetDocument(id: document.id,
                                  projectId: project.id,
                                  projectTitle: project.displayTitle,
                                  title: document.displayTitle,
                                  isSong: document.kind == .song,
                                  updatedAt: updatedAt)
        }
        // What was stored a moment ago, so the songs and notes that have since
        // left can be taken out of Spotlight by name.
        let before = SongsNotesWidgetStore.load().documents
        // Only the widget whose rows actually changed is reloaded. Reloads are
        // rationed by the system, and an afternoon spent on the songs leaves
        // the Notes widget drawing exactly what it already drew.
        //
        // Nothing changed is also nothing to donate, and that is the common
        // case: the documents are loaded on every visit to the script, and most
        // visits leave them exactly as they were.
        let changed = SongsNotesWidgetStore.publish(rows, forProject: project.id)
        guard !changed.isEmpty else { return }
        for kind in changed {
            WidgetCenter.shared.reloadTimelines(ofKind: kind.widgetKind)
        }
        // Read back rather than recomputed: the store merges this project's
        // rows into every other project's and trims each half on the way in, so
        // Spotlight should be told what is actually stored and not this file's
        // second guess at it.
        //
        // Donated after the reload rather than instead of it. The two are not
        // alternatives — a widget draws six rows of one project, Spotlight
        // answers for every row of every project this device has opened — and
        // until this existed the app indexed screenplays only, while the help
        // told writers their songs and notes were searchable too.
        let stored = SongsNotesWidgetStore.load().documents
        let gone = before.map(\.id).filter { id in !stored.contains { $0.id == id } }
        SpotlightIndex.replace(stored.map(DocumentEntity.init), removing: gone)
    }

    /// Empties both widgets. Signing out goes through here: the next person to
    /// pick up the phone should not be able to read the last writer's song
    /// titles off the Home Screen — nor, since the same titles are donated to
    /// Spotlight, out of a search field.
    ///
    /// `SpotlightIndex.clear()` takes the whole index rather than this half of
    /// it, and so does the screenplays publisher's own `clear()`. They are only
    /// ever called together, at sign-out, so the second is a no-op; the point of
    /// calling it here anyway is that neither publisher is left depending on the
    /// other having run first to keep a promise it makes on its own.
    static func clear() {
        SongsNotesWidgetStore.clear()
        for kind in SongsNotesWidgetStore.widgetKinds {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
        SpotlightIndex.clear()
    }
}

extension View {
    /// Republishes both widgets whenever this project's songs and notes change.
    ///
    /// A named modifier rather than the `onChange` written inline where it is
    /// used: `ScriptView`'s body is long enough that adding one more closure to
    /// the chain put it past the compiler's type-checking budget ("unable to
    /// type-check this expression in reasonable time"). Moving the closure into
    /// a function of its own is what brings it back — the call site is then a
    /// single method with one concrete argument.
    ///
    /// Deliberately not `initial`: the list starts empty and is only filled by
    /// the load, so publishing the initial value would take the project off the
    /// widget every time its script was opened — and leave it off, on a device
    /// that then turns out to be offline. A project whose documents really are
    /// all gone still publishes, because that is a change from what it held.
    func publishingSongsAndNotes(from model: ScriptModel) -> some View {
        onChange(of: model.documents) { _, documents in
            WidgetPublisher.publish(documents, project: model.project,
                                    isEphemeralDemo: model.app.isEphemeralDemo)
        }
    }
}
