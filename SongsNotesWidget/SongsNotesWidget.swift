//
//  SongsNotesWidget.swift
//  SongsNotesWidget
//
//  The songs and notes a writer has been working on, on the Home Screen.
//
//  Everything drawn here comes out of the App Group snapshot the app writes
//  (see Shared/SongsNotesWidgetData.swift). The extension never signs in and
//  never touches the network, so it has nothing to fail at: it either has a
//  snapshot to draw or it invites the writer to open the app.
//
//  Tapping a row hands a `scripty://document?…` URL back to the app, which
//  opens that project's songs & notes on the document named — the same screen
//  the toolbar's Songs button and the Home Screen's Songs quick action reach.
//

import SwiftUI
import WidgetKit

// MARK: - Timeline

struct SongsNotesEntry: TimelineEntry {
    let date: Date
    let snapshot: SongsNotesSnapshot
}

struct SongsNotesProvider: TimelineProvider {
    /// What the gallery and the redacted placeholder draw. Made up on purpose:
    /// the placeholder is shown before the widget has been added, when reading
    /// a real writer's titles would be showing them to whoever is browsing the
    /// gallery.
    private var sample: SongsNotesSnapshot {
        let now = Date.now
        return SongsNotesSnapshot(documents: [
            WidgetDocument(id: 1, projectId: 1, projectTitle: "Wide Awake",
                           title: "Opening Number", isSong: true,
                           updatedAt: now.addingTimeInterval(-2 * 3600)),
            WidgetDocument(id: 2, projectId: 1, projectTitle: "Wide Awake",
                           title: "Act Two beats", isSong: false,
                           updatedAt: now.addingTimeInterval(-26 * 3600)),
            WidgetDocument(id: 3, projectId: 2, projectTitle: "Nightfall",
                           title: "Reprise", isSong: true,
                           updatedAt: now.addingTimeInterval(-3 * 86_400)),
            WidgetDocument(id: 4, projectId: 2, projectTitle: "Nightfall",
                           title: "Casting thoughts", isSong: false,
                           updatedAt: now.addingTimeInterval(-5 * 86_400)),
        ], savedAt: now)
    }

    func placeholder(in context: Context) -> SongsNotesEntry {
        SongsNotesEntry(date: .now, snapshot: sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (SongsNotesEntry) -> Void) {
        let snapshot = context.isPreview ? sample : SongsNotesWidgetStore.load()
        completion(SongsNotesEntry(date: .now, snapshot: snapshot))
    }

    /// One entry, and no schedule worth the name.
    ///
    /// The rows only change when the app changes them, and the app reloads
    /// this widget by name when it does. The hourly refresh is a backstop for
    /// the case that reload never arrives — an app removed, or a write that
    /// landed while the widget was unloaded — not the mechanism.
    func getTimeline(in context: Context, completion: @escaping (Timeline<SongsNotesEntry>) -> Void) {
        let entry = SongsNotesEntry(date: .now, snapshot: SongsNotesWidgetStore.load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(3600))))
    }
}

// MARK: - Widget

struct SongsNotesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SongsNotesWidgetStore.widgetKind,
                            provider: SongsNotesProvider()) { entry in
            SongsNotesWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Songs & Notes")
        .description("The songs and notes you have been working on. Tap one to open it.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}

@main
struct SongsNotesWidgetBundle: WidgetBundle {
    var body: some Widget {
        SongsNotesWidget()
    }
}

// MARK: - Drawing

struct SongsNotesWidgetView: View {
    let entry: SongsNotesEntry

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

    private var documents: [WidgetDocument] {
        Array(entry.snapshot.documents.prefix(rowLimit))
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
            ForEach(documents) { document in
                // Small has no room for per-row links and is one tap target
                // anyway (`.widgetURL` below), so the row is drawn plain there.
                if family == .systemSmall {
                    DocumentRow(document: document, showsProject: true)
                } else {
                    Link(destination: WidgetLink.url(for: document)) {
                        DocumentRow(document: document, showsProject: true)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Only the small family needs this — the others link per row — but the
        // whole-tile link is also what a tap on a large widget's empty space
        // lands on, and it should go somewhere sensible rather than nowhere.
        .widgetURL(documents.first.map(WidgetLink.url(for:)))
    }

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: "music.note.list")
                .font(.caption2)
            Text("Songs & Notes")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.secondary)
    }

    // MARK: Lock Screen

    /// One line of title and one of context, in the monochrome the accessory
    /// families render in — no colour, no project symbol, nothing that only
    /// reads at full size.
    @ViewBuilder
    private var accessory: some View {
        if let document = entry.snapshot.documents.first {
            VStack(alignment: .leading, spacing: 2) {
                Text(document.isSong ? "Song" : "Note")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(document.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(document.projectTitle)
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(WidgetLink.url(for: document))
        }
    }

    // MARK: Nothing to show

    /// Reached before the app has opened a project's songs & notes even once,
    /// and after signing out. Both are states a fresh widget is legitimately
    /// in, so it says what to do rather than looking broken.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            if family != .accessoryRectangular {
                header
            }
            Text("No songs or notes yet")
                .font(family == .systemSmall ? .caption : .subheadline)
                .fontWeight(.medium)
            Text("Open Scripty to see the ones you are working on.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(URL(string: "\(WidgetLink.scheme)://"))
    }
}

/// One song or note: which kind it is, what it is called, and where it lives.
private struct DocumentRow: View {
    let document: WidgetDocument
    let showsProject: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: document.isSong ? "music.note" : "note.text")
                .font(.caption2)
                .foregroundStyle(document.isSong ? .pink : .orange)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(document.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                if showsProject {
                    // The relative date is drawn by the system rather than
                    // baked into the entry, so "2 hours ago" keeps counting
                    // without the timeline being rebuilt for it.
                    Text("\(document.projectTitle) · ")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    + Text(document.updatedAt, format: .relative(presentation: .numeric))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Previews

#Preview("Medium", as: .systemMedium) {
    SongsNotesWidget()
} timeline: {
    SongsNotesEntry(date: .now, snapshot: SongsNotesSnapshot(documents: [
        WidgetDocument(id: 1, projectId: 1, projectTitle: "Wide Awake",
                       title: "Opening Number", isSong: true,
                       updatedAt: .now.addingTimeInterval(-2 * 3600)),
        WidgetDocument(id: 2, projectId: 1, projectTitle: "Wide Awake",
                       title: "Act Two beats", isSong: false,
                       updatedAt: .now.addingTimeInterval(-26 * 3600)),
        WidgetDocument(id: 3, projectId: 2, projectTitle: "Nightfall",
                       title: "Reprise", isSong: true,
                       updatedAt: .now.addingTimeInterval(-3 * 86_400)),
    ], savedAt: .now))
    SongsNotesEntry(date: .now, snapshot: SongsNotesSnapshot())
}
