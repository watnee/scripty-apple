//
//  BookmarksWidget.swift
//  BookmarksWidget
//
//  The lines a writer flagged, on the Home Screen.
//
//  Everything drawn here comes out of the App Group snapshot the app writes
//  (see Shared/BookmarksWidgetData.swift). The extension never signs in and
//  never touches the network, so it has nothing to fail at: it either has a
//  snapshot to draw or it invites the writer to open the app.
//
//  Tapping a row hands a `scripty://bookmark?project=…&block=…` URL back to the
//  app, which opens that screenplay and scrolls to that element — the same jump
//  the outline sidebar's bookmark list makes from inside the app.
//

import SwiftUI
import WidgetKit

// MARK: - Timeline

struct BookmarksEntry: TimelineEntry {
    let date: Date
    let snapshot: BookmarksSnapshot
}

struct BookmarksProvider: TimelineProvider {
    /// What the gallery and the redacted placeholder draw. Made up on purpose:
    /// the placeholder is shown before the widget has been added, when drawing
    /// a real writer's dialogue would be showing it to whoever is browsing the
    /// gallery.
    private var sample: BookmarksSnapshot {
        let now = Date.now
        return BookmarksSnapshot(bookmarks: [
            WidgetBookmark(blockId: 1, projectId: 1, projectTitle: "Wide Awake",
                           preview: "INT. DINER — NIGHT", elementLabel: "Scene",
                           order: 12, markedAt: now),
            WidgetBookmark(blockId: 2, projectId: 1, projectTitle: "Wide Awake",
                           preview: "You were never going to tell me, were you?",
                           elementLabel: "Dialogue", order: 18, markedAt: now),
            WidgetBookmark(blockId: 3, projectId: 1, projectTitle: "Wide Awake",
                           preview: "She sets the cup down without drinking from it.",
                           elementLabel: "Action", order: 24, markedAt: now),
            WidgetBookmark(blockId: 4, projectId: 2, projectTitle: "Nightfall",
                           preview: "EXT. HIGHWAY — DAWN", elementLabel: "Scene",
                           order: 3, markedAt: now.addingTimeInterval(-86_400)),
        ], savedAt: now)
    }

    func placeholder(in context: Context) -> BookmarksEntry {
        BookmarksEntry(date: .now, snapshot: sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (BookmarksEntry) -> Void) {
        let snapshot = context.isPreview ? sample : BookmarksWidgetStore.load()
        completion(BookmarksEntry(date: .now, snapshot: snapshot))
    }

    /// One entry, and no schedule worth the name.
    ///
    /// The rows only change when the app changes them, and the app reloads this
    /// widget by name when it does. The hourly refresh is a backstop for the
    /// case that reload never arrives — an app removed, or a write that landed
    /// while the widget was unloaded — not the mechanism.
    ///
    /// Unlike the other two widgets, nothing here is a relative date, so the
    /// backstop is all it is: an entry redrawn on the hour looks exactly like
    /// the one it replaced unless the script really did change.
    func getTimeline(in context: Context, completion: @escaping (Timeline<BookmarksEntry>) -> Void) {
        let entry = BookmarksEntry(date: .now, snapshot: BookmarksWidgetStore.load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(3600))))
    }
}

// MARK: - Widget

struct BookmarksWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: BookmarksWidgetStore.widgetKind,
                            provider: BookmarksProvider()) { entry in
            BookmarksWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Bookmarks")
        .description("The lines you flagged while writing. Tap one to jump to it.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}

@main
struct BookmarksWidgetBundle: WidgetBundle {
    var body: some Widget {
        BookmarksWidget()
    }
}

// MARK: - Drawing

struct BookmarksWidgetView: View {
    let entry: BookmarksEntry

    @Environment(\.widgetFamily) private var family

    /// How many rows each family has room for. Small shows one because the
    /// whole tile is a single tap target — a list of rows there would look
    /// tappable and all lead to the same place. A bookmark's row is a sentence
    /// out of a script rather than a title, so every family fits fewer of them
    /// than the Screenplays widget does.
    private var rowLimit: Int {
        switch family {
        case .systemSmall: 1
        case .systemMedium: 2
        case .systemLarge: 5
        default: 1
        }
    }

    private var bookmarks: [WidgetBookmark] {
        Array(entry.snapshot.bookmarks.prefix(rowLimit))
    }

    /// The visible rows, each told whether it opens a new screenplay's run.
    ///
    /// The rows arrive grouped by script (see `BookmarksWidgetStore.merging`),
    /// so naming the screenplay once above each run says everything repeating
    /// it on every row would, without spending a line per row to say it.
    ///
    /// The heading is dropped entirely when every visible row belongs to the
    /// same script: at that point it is the widget's subject, not a divider,
    /// and the widget already has a header.
    private var rows: [BookmarkRowItem] {
        let visible = bookmarks
        let isGrouped = Set(visible.map(\.projectId)).count > 1
        return visible.enumerated().map { index, bookmark in
            BookmarkRowItem(
                bookmark: bookmark,
                showsProject: isGrouped
                    && (index == 0 || visible[index - 1].projectId != bookmark.projectId))
        }
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
            ForEach(rows) { row in
                // Small has no room for per-row links and is one tap target
                // anyway (`.widgetURL` below), so the row is drawn plain there.
                if family == .systemSmall {
                    BookmarkRow(item: row, isRoomy: false)
                } else {
                    Link(destination: BookmarkWidgetLink.url(for: row.bookmark)) {
                        BookmarkRow(item: row, isRoomy: family == .systemLarge)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Only the small family needs this — the others link per row — but the
        // whole-tile link is also what a tap on a large widget's empty space
        // lands on, and it should go somewhere sensible rather than nowhere.
        .widgetURL(bookmarks.first.map(BookmarkWidgetLink.url(for:)))
    }

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: "bookmark.fill")
                .font(.caption2)
            Text("Bookmarks")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.secondary)
    }

    // MARK: Lock Screen

    /// One flagged line and the screenplay it came from, in the monochrome the
    /// accessory families render in — no symbol tint, nothing that only reads
    /// at full size.
    @ViewBuilder
    private var accessory: some View {
        if let bookmark = entry.snapshot.bookmarks.first {
            VStack(alignment: .leading, spacing: 2) {
                Text(bookmark.projectTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(bookmark.preview)
                    .font(.headline)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(BookmarkWidgetLink.url(for: bookmark))
        }
    }

    // MARK: Nothing to show

    /// Reached before the app has opened a script even once, by a writer who
    /// has flagged nothing yet, and after signing out. All three are states a
    /// fresh widget is legitimately in, so it says what to do rather than
    /// looking broken.
    ///
    /// The second line is what makes this widget's empty state worth writing:
    /// unlike screenplays and songs, bookmarks are not something an account
    /// simply has — they only exist once someone has flagged a line, and a
    /// writer who has never used the feature would otherwise be left guessing
    /// what the widget wanted from them.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            if family != .accessoryRectangular {
                header
            }
            Text("No bookmarks yet")
                .font(family == .systemSmall ? .caption : .subheadline)
                .fontWeight(.medium)
            Text("Flag a line while writing and it shows up here.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One visible row, and whether it opens a new screenplay's run of them.
private struct BookmarkRowItem: Identifiable {
    let bookmark: WidgetBookmark
    let showsProject: Bool

    var id: Int { bookmark.blockId }
}

/// One flagged element: the screenplay it belongs to where that has changed,
/// the line itself, and what kind of element it is.
private struct BookmarkRow: View {
    let item: BookmarkRowItem
    /// Whether there is room for a second line of the element's text and for
    /// its type. Only the large family has it; the others would push the line
    /// off the edge or steal a row from the bookmark below.
    let isRoomy: Bool

    private var bookmark: WidgetBookmark { item.bookmark }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if item.showsProject {
                Text(bookmark.projectTitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "bookmark.fill")
                    .font(.caption2)
                    .foregroundStyle(.tint)
                    .frame(width: 12)
                    // The symbol is the only thing on the row not read out by
                    // its own text, and every row has one — so it is labelled
                    // once here rather than left to VoiceOver to describe as an
                    // image.
                    .accessibilityLabel("Bookmark")
                VStack(alignment: .leading, spacing: 1) {
                    Text(bookmark.preview)
                        .font(.caption.weight(.medium))
                        .lineLimit(isRoomy ? 2 : 1)
                    if isRoomy, let label = bookmark.elementLabel {
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Previews

#Preview("Medium", as: .systemMedium) {
    BookmarksWidget()
} timeline: {
    BookmarksEntry(date: .now, snapshot: BookmarksSnapshot(bookmarks: [
        WidgetBookmark(blockId: 1, projectId: 1, projectTitle: "Wide Awake",
                       preview: "INT. DINER — NIGHT", elementLabel: "Scene",
                       order: 12, markedAt: .now),
        WidgetBookmark(blockId: 2, projectId: 1, projectTitle: "Wide Awake",
                       preview: "You were never going to tell me, were you?",
                       elementLabel: "Dialogue", order: 18, markedAt: .now),
        WidgetBookmark(blockId: 4, projectId: 2, projectTitle: "Nightfall",
                       preview: "EXT. HIGHWAY — DAWN", elementLabel: "Scene",
                       order: 3, markedAt: .now.addingTimeInterval(-86_400)),
    ], savedAt: .now))
    BookmarksEntry(date: .now, snapshot: BookmarksSnapshot())
}
