//
//  SongsNotesWidget.swift
//  SongsNotesWidget
//
//  The songs and notes a writer has been working on, on the Home Screen — as
//  two widgets, Songs and Notes, placed and sized independently.
//
//  One extension vending two widgets rather than two extensions: they share
//  their rows, their timeline and every line of their drawing, and differ only
//  in which half of the snapshot they read. A second extension would be a
//  second copy of all of that, kept in step by hand, to gain nothing a
//  `WidgetBundle` does not already give.
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

struct DocumentsEntry: TimelineEntry {
    let date: Date
    /// Which widget this entry is for. Carried rather than inferred from the
    /// rows, so an empty Notes widget still knows to say "notes".
    let kind: WidgetDocumentKind
    /// This widget's half of the snapshot, newest first.
    let documents: [WidgetDocument]
}

struct DocumentsProvider: TimelineProvider {
    let kind: WidgetDocumentKind

    /// What the gallery and the redacted placeholder draw. Made up on purpose:
    /// the placeholder is shown before the widget has been added, when reading
    /// a real writer's titles would be showing them to whoever is browsing the
    /// gallery.
    private var sample: [WidgetDocument] {
        let now = Date.now
        switch kind {
        case .song:
            return [
                WidgetDocument(id: 1, projectId: 1, projectTitle: "Wide Awake",
                               title: "Opening Number", isSong: true,
                               updatedAt: now.addingTimeInterval(-2 * 3600)),
                WidgetDocument(id: 2, projectId: 2, projectTitle: "Nightfall",
                               title: "Reprise", isSong: true,
                               updatedAt: now.addingTimeInterval(-26 * 3600)),
                WidgetDocument(id: 3, projectId: 1, projectTitle: "Wide Awake",
                               title: "Finale", isSong: true,
                               updatedAt: now.addingTimeInterval(-3 * 86_400)),
                WidgetDocument(id: 4, projectId: 2, projectTitle: "Nightfall",
                               title: "The Long Way Round", isSong: true,
                               updatedAt: now.addingTimeInterval(-5 * 86_400)),
            ]
        case .note:
            return [
                WidgetDocument(id: 5, projectId: 1, projectTitle: "Wide Awake",
                               title: "Act Two beats", isSong: false,
                               updatedAt: now.addingTimeInterval(-2 * 3600)),
                WidgetDocument(id: 6, projectId: 2, projectTitle: "Nightfall",
                               title: "Casting thoughts", isSong: false,
                               updatedAt: now.addingTimeInterval(-26 * 3600)),
                WidgetDocument(id: 7, projectId: 1, projectTitle: "Wide Awake",
                               title: "Notes from the read-through", isSong: false,
                               updatedAt: now.addingTimeInterval(-3 * 86_400)),
                WidgetDocument(id: 8, projectId: 2, projectTitle: "Nightfall",
                               title: "Research", isSong: false,
                               updatedAt: now.addingTimeInterval(-5 * 86_400)),
            ]
        }
    }

    private var stored: [WidgetDocument] {
        SongsNotesWidgetStore.load().documents(kind)
    }

    private func entry(_ documents: [WidgetDocument]) -> DocumentsEntry {
        DocumentsEntry(date: .now, kind: kind, documents: documents)
    }

    func placeholder(in context: Context) -> DocumentsEntry {
        entry(sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (DocumentsEntry) -> Void) {
        // The gallery still draws made-up songs. This is the line that keeps a
        // stranger browsing the widget gallery from reading the writer's
        // titles, and it is the easiest thing to lose in a rewrite.
        completion(entry(context.isPreview ? sample : stored))
    }

    /// One entry, and no schedule worth the name.
    ///
    /// The rows only change when the app changes them, and the app reloads the
    /// widget whose half changed, by name, when it does. The hourly refresh is
    /// a backstop for the case that reload never arrives — an app removed, or a
    /// write that landed while the widget was unloaded — not the mechanism.
    func getTimeline(in context: Context, completion: @escaping (Timeline<DocumentsEntry>) -> Void) {
        completion(Timeline(entries: [entry(stored)],
                            policy: .after(.now.addingTimeInterval(3600))))
    }
}

// MARK: - Widgets

/// The shape both widgets share, written once so they cannot drift apart in
/// what they support — only in what they are called and which rows they draw.
private func documentsWidget(for kind: WidgetDocumentKind) -> some WidgetConfiguration {
    StaticConfiguration(kind: kind.widgetKind, provider: DocumentsProvider(kind: kind)) { entry in
        DocumentsWidgetView(entry: entry)
            .containerBackground(.fill.tertiary, for: .widget)
    }
    .configurationDisplayName(kind.displayName)
    .description(kind.galleryDescription)
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
}

struct SongsWidget: Widget {
    var body: some WidgetConfiguration { documentsWidget(for: .song) }
}

struct NotesWidget: Widget {
    var body: some WidgetConfiguration { documentsWidget(for: .note) }
}

@main
struct SongsNotesWidgetBundle: WidgetBundle {
    var body: some Widget {
        SongsWidget()
        NotesWidget()
        // The Control Center tiles ride in this bundle rather than an extension
        // of their own — see ScriptyControls.swift for why.
        SongsControl()
        NewNoteControl()
        NewSongControl()
        ScreenplayControl()
    }
}

// MARK: - What each one is called and looks like

/// The half of a widget's identity that only the extension can say. The rows
/// and the `kind` string live in the shared file, which has no SwiftUI to say
/// any of this with.
extension WidgetDocumentKind {
    var displayName: String {
        switch self {
        case .song: "Songs"
        case .note: "Notes"
        }
    }

    var galleryDescription: String {
        switch self {
        case .song: "The songs you have been working on. Tap one to open it."
        case .note: "The notes you have been keeping. Tap one to open it."
        }
    }

    /// Drawn beside the widget's name in its header. The list symbol, because
    /// the header names the whole widget rather than any one row.
    var headerSymbol: String {
        switch self {
        case .song: "music.note.list"
        case .note: "note.text"
        }
    }

    var rowSymbol: String {
        switch self {
        case .song: "music.note"
        case .note: "note.text"
        }
    }

    /// The app's own colour for this list, so a glance at the Home Screen
    /// tells the two widgets apart before either title is read.
    var tint: Color {
        switch self {
        case .song: .pink
        case .note: .orange
        }
    }

    var emptyTitle: String {
        switch self {
        case .song: "No songs yet"
        case .note: "No notes yet"
        }
    }

    /// What the Lock Screen calls one row, where there is no symbol and no
    /// colour to say it with.
    var rowLabel: String {
        switch self {
        case .song: "Song"
        case .note: "Note"
        }
    }
}

// MARK: - Drawing

struct DocumentsWidgetView: View {
    let entry: DocumentsEntry

    @Environment(\.widgetFamily) private var family

    private var kind: WidgetDocumentKind { entry.kind }

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
        Array(entry.documents.prefix(rowLimit))
    }

    var body: some View {
        if entry.documents.isEmpty {
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
                    DocumentRow(document: document, kind: kind)
                } else {
                    Link(destination: WidgetLink.url(for: document)) {
                        DocumentRow(document: document, kind: kind)
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
            Image(systemName: kind.headerSymbol)
                .font(.caption2)
            Text(kind.displayName)
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
        if let document = entry.documents.first {
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.rowLabel)
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
    ///
    /// Also where a writer who keeps songs but no notes will find the Notes
    /// widget sitting, which is the honest answer for it to give: the app has
    /// looked, and there are none.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            if family != .accessoryRectangular {
                header
            }
            Text(kind.emptyTitle)
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

/// One song or note: what it is called and where it lives.
///
/// Every row on a widget is the same kind as every other, so the symbol says
/// nothing the header has not — it is here as the row's leading edge, the same
/// anchor the lists inside the app draw against.
private struct DocumentRow: View {
    let document: WidgetDocument
    let kind: WidgetDocumentKind

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: kind.rowSymbol)
                .font(.caption2)
                .foregroundStyle(kind.tint)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(document.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                // The relative date is drawn by the system rather than baked
                // into the entry, so "2 hours ago" keeps counting without the
                // timeline being rebuilt for it.
                Text("\(document.projectTitle) · ")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                + Text(document.updatedAt, format: .relative(presentation: .numeric))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Previews

#Preview("Songs", as: .systemMedium) {
    SongsWidget()
} timeline: {
    DocumentsEntry(date: .now, kind: .song, documents: [
        WidgetDocument(id: 1, projectId: 1, projectTitle: "Wide Awake",
                       title: "Opening Number", isSong: true,
                       updatedAt: .now.addingTimeInterval(-2 * 3600)),
        WidgetDocument(id: 2, projectId: 2, projectTitle: "Nightfall",
                       title: "Reprise", isSong: true,
                       updatedAt: .now.addingTimeInterval(-26 * 3600)),
        WidgetDocument(id: 3, projectId: 1, projectTitle: "Wide Awake",
                       title: "Finale", isSong: true,
                       updatedAt: .now.addingTimeInterval(-3 * 86_400)),
    ])
    DocumentsEntry(date: .now, kind: .song, documents: [])
}

#Preview("Notes", as: .systemMedium) {
    NotesWidget()
} timeline: {
    DocumentsEntry(date: .now, kind: .note, documents: [
        WidgetDocument(id: 5, projectId: 1, projectTitle: "Wide Awake",
                       title: "Act Two beats", isSong: false,
                       updatedAt: .now.addingTimeInterval(-2 * 3600)),
        WidgetDocument(id: 6, projectId: 2, projectTitle: "Nightfall",
                       title: "Casting thoughts", isSong: false,
                       updatedAt: .now.addingTimeInterval(-26 * 3600)),
    ])
    DocumentsEntry(date: .now, kind: .note, documents: [])
}
