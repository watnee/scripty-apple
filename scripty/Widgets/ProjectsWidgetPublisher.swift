//
//  ProjectsWidgetPublisher.swift
//  scripty
//
//  Where the app meets its Home Screen widget: it turns the project list into
//  the handful of rows the widget draws, and tells WidgetKit when they have
//  changed.
//
//  The shape of this file is QuickActions.swift's, for the same reasons. The
//  pure half — ordering, the URLs — lives next door in
//  Shared/ProjectsWidgetData.swift, which the extension compiles too and
//  Tests/ProjectsWidget checks without a simulator. Only the part that talks to
//  WidgetKit is here.
//

import Foundation
import WidgetKit

enum ProjectsWidgetPublisher {
    /// Republishes the widget from the list the sidebar is showing.
    ///
    /// Called from the one place watching `ProjectListModel.projects` rather
    /// than from the load itself, so that every path that changes the list —
    /// creating, renaming, starring, importing, deleting, restoring from the
    /// trash — is covered without each having to remember to.
    ///
    /// A signed-out device publishes like any other: its workspace is kept on
    /// disk, so a row naming one of its screenplays opens that screenplay
    /// tomorrow just as it does now.
    ///
    /// Only the throwaway demo publishes nothing, exactly as the Home Screen
    /// menu's recents do not. Its projects live in memory for as long as the
    /// app is running, so a row naming one is a row that could only ever fail
    /// to open — and it would sit on the Home Screen long after the demo was
    /// over, since nothing but this app can take it back down.
    ///
    /// An empty list still publishes when it is genuinely empty and not merely
    /// unloaded; see the caller, which does not fire on the initial value.
    static func publish(_ projects: [Project], isEphemeralDemo: Bool) {
        guard !isEphemeralDemo else { return }
        let rows = projects.map { project in
            WidgetProject(id: project.id,
                          title: project.displayTitle,
                          writers: project.writers,
                          version: project.screenplayVersion,
                          lastEdited: project.lastEdited,
                          isDefault: project.isDefault == true)
        }
        // What was on the widget a moment ago, so the screenplays that have
        // since left it can be taken out of Spotlight by name.
        let before = ProjectsWidgetStore.load().projects
        guard ProjectsWidgetStore.publish(rows) else { return }
        WidgetCenter.shared.reloadTimelines(ofKind: ProjectsWidgetStore.widgetKind)
        // Read back rather than recomputed: the store trims and orders on the
        // way in, and Spotlight should be told what is actually stored, not
        // this file's second guess at it.
        let stored = ProjectsWidgetStore.load().projects
        let gone = before.map(\.id).filter { id in !stored.contains { $0.id == id } }
        SpotlightIndex.replace(stored.map(ScreenplayEntity.init), removing: gone)
    }

    /// Empties the widget. Signing out goes through here: the next person to
    /// pick up the phone should not be able to read the last writer's
    /// screenplay titles off the Home Screen — nor, since the same titles are
    /// donated to Spotlight, out of a search field.
    static func clear() {
        ProjectsWidgetStore.clear()
        WidgetCenter.shared.reloadTimelines(ofKind: ProjectsWidgetStore.widgetKind)
        SpotlightIndex.clear()
    }
}
