//
//  ProjectsWidget.swift
//  ProjectsWidget
//
//  The screenplays a writer has been working on, on the Home Screen.
//
//  Everything drawn here comes out of the App Group snapshot the app writes
//  (see Shared/ProjectsWidgetData.swift). The extension never signs in and
//  never touches the network, so it has nothing to fail at: it either has a
//  snapshot to draw or it invites the writer to open the app.
//
//  Tapping a row hands a `scripty://project?id=…` URL back to the app, which
//  selects that screenplay — the same place tapping its row in the sidebar and
//  the Home Screen menu's recent entries both land.
//

import SwiftUI
import WidgetKit

// MARK: - Timeline

struct ProjectsEntry: TimelineEntry {
    let date: Date
    let snapshot: ProjectsSnapshot
}

struct ProjectsProvider: AppIntentTimelineProvider {
    /// What the gallery and the redacted placeholder draw. Made up on purpose:
    /// the placeholder is shown before the widget has been added, when reading
    /// a real writer's titles would be showing them to whoever is browsing the
    /// gallery.
    private var sample: ProjectsSnapshot {
        let now = Date.now
        return ProjectsSnapshot(projects: [
            WidgetProject(id: 1, title: "Wide Awake", writers: "A. Marlowe",
                          version: "Second Draft",
                          lastEdited: now.addingTimeInterval(-2 * 3600), isDefault: true),
            WidgetProject(id: 2, title: "Nightfall", writers: "A. Marlowe, J. Reed",
                          version: "Revised Pages",
                          lastEdited: now.addingTimeInterval(-26 * 3600)),
            WidgetProject(id: 3, title: "The Longest Winter", writers: "A. Marlowe",
                          version: "First Draft",
                          lastEdited: now.addingTimeInterval(-4 * 86_400)),
            WidgetProject(id: 4, title: "Salt Flats", writers: "J. Reed",
                          lastEdited: now.addingTimeInterval(-9 * 86_400)),
        ], savedAt: now)
    }

    func placeholder(in context: Context) -> ProjectsEntry {
        ProjectsEntry(date: .now, snapshot: sample)
    }

    func snapshot(for configuration: ProjectsWidgetConfigurationIntent,
                  in context: Context) async -> ProjectsEntry {
        // The gallery still draws made-up screenplays. This is the line that
        // keeps a stranger browsing the widget gallery from reading the
        // writer's titles, and it is the easiest thing to lose in a rewrite.
        let stored = context.isPreview ? sample : ProjectsWidgetStore.load()
        return ProjectsEntry(date: .now, snapshot: configured(stored, by: configuration))
    }

    /// One entry, and no schedule worth the name.
    ///
    /// The rows only change when the app changes them, and the app reloads this
    /// widget by name when it does. The hourly refresh is a backstop for the
    /// case that reload never arrives — an app removed, or a write that landed
    /// while the widget was unloaded — not the mechanism.
    ///
    /// It does earn its keep even when nothing changes, though: the rows carry
    /// relative dates, and "2 hours ago" is only redrawn when the timeline is.
    func timeline(for configuration: ProjectsWidgetConfigurationIntent,
                  in context: Context) async -> Timeline<ProjectsEntry> {
        let stored = ProjectsWidgetStore.load()
        let entry = ProjectsEntry(date: .now, snapshot: configured(stored, by: configuration))
        return Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(3600)))
    }

    /// The configuration applied, still as a snapshot.
    ///
    /// Reordering here rather than in the view keeps the drawing exactly as
    /// dumb as it was before there was anything to configure — `isEmpty` and
    /// the family's own row count both still work off the entry, unchanged —
    /// and puts the choice in a pure function the tests can reach.
    private func configured(_ snapshot: ProjectsSnapshot,
                            by configuration: ProjectsWidgetConfigurationIntent) -> ProjectsSnapshot {
        ProjectsSnapshot(projects: snapshot.rows(starredFirst: configuration.scope == .starredFirst,
                                                 limit: ProjectsWidgetStore.limit),
                         savedAt: snapshot.savedAt)
    }
}

// MARK: - Widget

struct ProjectsWidget: Widget {
    var body: some WidgetConfiguration {
        // The kind is unchanged on purpose: iOS finds an already-placed widget
        // by that string, and swapping StaticConfiguration for this one under
        // the same kind is the supported way to let existing widgets keep their
        // place and simply gain an "Edit Widget" entry.
        AppIntentConfiguration(kind: ProjectsWidgetStore.widgetKind,
                               intent: ProjectsWidgetConfigurationIntent.self,
                               provider: ProjectsProvider()) { entry in
            ProjectsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Screenplays")
        .description("The screenplays you have been working on. Tap one to open it.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}

@main
struct ProjectsWidgetBundle: WidgetBundle {
    var body: some Widget {
        ProjectsWidget()
    }
}

// MARK: - Drawing

struct ProjectsWidgetView: View {
    let entry: ProjectsEntry

    @Environment(\.widgetFamily) private var family

    /// How many rows each family has room for. Small shows one because the
    /// whole tile is a single tap target — a list of rows there would look
    /// tappable and all lead to the same place.
    private var rowLimit: Int {
        switch family {
        case .systemSmall: 1
        case .systemMedium: 3
        case .systemLarge: 6
        default: 1
        }
    }

    private var projects: [WidgetProject] {
        Array(entry.snapshot.projects.prefix(rowLimit))
    }

    var body: some View {
        if entry.snapshot.isEmpty {
            emptyState
        } else if family == .accessoryRectangular {
            accessory
        } else {
            list
        }
    }

    // MARK: Home Screen

    private var list: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 8) {
            header
            ForEach(projects) { project in
                // Small has no room for per-row links and is one tap target
                // anyway (`.widgetURL` below), so the row is drawn plain there.
                if family == .systemSmall {
                    ProjectRow(project: project, isRoomy: false)
                } else {
                    Link(destination: ProjectWidgetLink.url(for: project)) {
                        ProjectRow(project: project, isRoomy: family == .systemLarge)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Only the small family needs this — the others link per row — but the
        // whole-tile link is also what a tap on a large widget's empty space
        // lands on, and it should go somewhere sensible rather than nowhere.
        .widgetURL(projects.first.map(ProjectWidgetLink.url(for:)))
    }

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: "film")
                .font(.caption2)
            Text("Screenplays")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.secondary)
    }

    // MARK: Lock Screen

    /// One line of title and one of context, in the monochrome the accessory
    /// families render in — no colour, no star, nothing that only reads at full
    /// size.
    @ViewBuilder
    private var accessory: some View {
        if let project = entry.snapshot.projects.first {
            VStack(alignment: .leading, spacing: 2) {
                Text("Screenplay")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(project.title)
                    .font(.headline)
                    .lineLimit(1)
                if let lastEdited = project.lastEdited {
                    Text(lastEdited, format: .relative(presentation: .numeric))
                        .font(.caption)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(ProjectWidgetLink.url(for: project))
        }
    }

    // MARK: Nothing to show

    /// Reached before the app has loaded a project list even once, by an
    /// account with no screenplays yet, and after signing out. All three are
    /// states a fresh widget is legitimately in, so it says what to do rather
    /// than looking broken.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            if family != .accessoryRectangular {
                header
            }
            Text("No screenplays yet")
                .font(family == .systemSmall ? .caption : .subheadline)
                .fontWeight(.medium)
            Text("Open Scripty to start one.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(ProjectWidgetLink.listURL)
    }
}

/// One screenplay: what it is called, whether it is the starred one, and when
/// it was last touched.
private struct ProjectRow: View {
    let project: WidgetProject
    /// Whether there is room for the second line of context. Only the large
    /// family has it; the others would push the writers off the edge or steal a
    /// row from the screenplay below.
    let isRoomy: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: project.isDefault ? "star.fill" : "film")
                .font(.caption2)
                .foregroundStyle(project.isDefault ? .yellow : .secondary)
                .frame(width: 12)
                // The star is the only thing on the row that is not read out by
                // its own text, and "starred" is what it means here — not the
                // rating it usually is.
                .accessibilityLabel(project.isDefault ? "Default screenplay" : "Screenplay")
            VStack(alignment: .leading, spacing: 1) {
                Text(project.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                if let lastEdited = project.lastEdited {
                    // The relative date is drawn by the system rather than baked
                    // into the entry, so "2 hours ago" keeps counting without
                    // the timeline being rebuilt for it.
                    Text(lastEdited, format: .relative(presentation: .numeric))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if isRoomy, let context = context {
                    Text(context)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// The writers and the draft version, whichever of the two the title page
    /// has — nil when it has neither, so the row does not leave a blank line
    /// where a screenplay nobody has filled in yet would be.
    private var context: String? {
        let parts = [project.writers, project.version]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Previews

#Preview("Medium", as: .systemMedium) {
    ProjectsWidget()
} timeline: {
    ProjectsEntry(date: .now, snapshot: ProjectsSnapshot(projects: [
        WidgetProject(id: 1, title: "Wide Awake", writers: "A. Marlowe",
                      version: "Second Draft",
                      lastEdited: .now.addingTimeInterval(-2 * 3600), isDefault: true),
        WidgetProject(id: 2, title: "Nightfall", writers: "A. Marlowe, J. Reed",
                      lastEdited: .now.addingTimeInterval(-26 * 3600)),
        WidgetProject(id: 3, title: "The Longest Winter",
                      lastEdited: .now.addingTimeInterval(-4 * 86_400)),
    ], savedAt: .now))
    ProjectsEntry(date: .now, snapshot: ProjectsSnapshot())
}
