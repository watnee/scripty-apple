//
//  WidgetPublisher.swift
//  scripty
//
//  Where the app meets its Home Screen widget: it turns a project's documents
//  into the handful of rows the widget draws, and tells WidgetKit when they
//  have changed.
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
    /// Republishes one project's half of the widget.
    ///
    /// Called wherever a project's documents settle rather than from the load
    /// itself, so that every path that changes them — creating, renaming,
    /// deleting, importing, restoring from the trash — is covered by the one
    /// call site watching the list.
    ///
    /// The demo publishes nothing, exactly as the Home Screen menu's recents
    /// do not. Its songs live in memory for as long as the app is running, so
    /// a row naming one is a row that could only ever fail to open — and it
    /// would sit on the Home Screen long after the demo was over, since
    /// nothing but this app can take it back down.
    static func publish(_ documents: [TextDocument], project: Project, isDemo: Bool) {
        guard !isDemo else { return }
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
        guard SongsNotesWidgetStore.publish(rows, forProject: project.id) else { return }
        WidgetCenter.shared.reloadTimelines(ofKind: SongsNotesWidgetStore.widgetKind)
    }

    /// Empties the widget. Signing out goes through here: the next person to
    /// pick up the phone should not be able to read the last writer's song
    /// titles off the Home Screen.
    static func clear() {
        SongsNotesWidgetStore.clear()
        WidgetCenter.shared.reloadTimelines(ofKind: SongsNotesWidgetStore.widgetKind)
    }
}

extension View {
    /// Republishes the widget whenever this project's songs and notes change.
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
            WidgetPublisher.publish(documents, project: model.project, isDemo: model.app.isDemo)
        }
    }
}
