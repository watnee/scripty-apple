//
//  BookmarksWidgetData.swift
//  Shared between the scripty app and the BookmarksWidget extension
//
//  The elements a writer flagged, and the shared container both sides reach
//  them through. This is the whole of what the two targets agree on: the app
//  writes a snapshot whenever a script's blocks settle, and the extension only
//  ever reads one.
//
//  Deliberately free of the network and the Keychain, like the other two
//  widgets. A widget that signed in for itself would be a second copy of the
//  HAL client to keep honest — and it has nothing to show that the app has not
//  already fetched, since a bookmark only reaches the widget by way of a script
//  that was opened.
//
//  Nothing here imports the app's `Block`: the extension would have to compile
//  HALResource and BlockType with it, for the sake of a preview string and a
//  label. BookmarksWidgetPublisher does the narrowing on the app's side, which
//  is also where `ScriptOutline.preview` already lives.
//

import Foundation

/// One row of the widget: a flagged element, and just enough about it to draw
/// the row and to scroll to the right line when it is tapped.
nonisolated struct WidgetBookmark: Codable, Hashable, Identifiable, Sendable {
    /// The block id — what the app scrolls to, and unique across projects
    /// because the server hands elements one sequence.
    let blockId: Int
    let projectId: Int
    let projectTitle: String
    /// The element's text, already clipped by `ScriptOutline.preview`, so the
    /// extension never has to know how the outline sidebar shortens a line —
    /// or that an empty element reads as "(Untitled)" rather than a blank row.
    let preview: String
    /// What kind of element it is, in the words the element bar uses ("Scene",
    /// "Dialogue"). A String rather than the app's `BlockType` so the extension
    /// does not compile the models for a caption; nil is not expected, but a
    /// row that lost its label is still worth drawing.
    let elementLabel: String?
    /// Where the element sits in the script. Kept so the rows of one screenplay
    /// read in the order they were written rather than in the order the filter
    /// happened to visit them; see `ordered`.
    let order: Int
    /// When this screenplay's bookmarks last *changed* — the same instant for
    /// every row of one script, and left alone by a publish that found nothing
    /// different (see `publish`).
    ///
    /// The server dates neither the block nor the flag, so there is no "when
    /// was this bookmarked" to sort on. This is the honest substitute, and it
    /// answers a question worth asking: which screenplay was most recently
    /// marked up. Reopening an old draft and reading it does not push a script
    /// you flagged this morning down the widget.
    let markedAt: Date

    var id: Int { blockId }

    init(blockId: Int, projectId: Int, projectTitle: String, preview: String,
         elementLabel: String? = nil, order: Int, markedAt: Date) {
        self.blockId = blockId
        self.projectId = projectId
        self.projectTitle = projectTitle
        self.preview = preview
        self.elementLabel = elementLabel
        self.order = order
        self.markedAt = markedAt
    }
}

/// What the app last published, and when it did.
///
/// `savedAt` is not used to age the rows out — a snapshot is cleared when it
/// stops being true (signing out) rather than expiring on a timer, because a
/// line you flagged does not become unflagged by sitting still.
nonisolated struct BookmarksSnapshot: Codable, Sendable {
    var bookmarks: [WidgetBookmark]
    var savedAt: Date

    init(bookmarks: [WidgetBookmark] = [], savedAt: Date = .distantPast) {
        self.bookmarks = bookmarks
        self.savedAt = savedAt
    }

    var isEmpty: Bool { bookmarks.isEmpty }
}

// MARK: - The shared container

/// `nonisolated` for the reason `ProjectsWidgetStore` records: this is read
/// by a timeline provider and by App Intents on their own queues, in a copy
/// of the process woken without a screen, and the app target's MainActor
/// default is not the isolation any of those readers have.
nonisolated enum BookmarksWidgetStore {
    /// The App Group both targets are entitled to, as iOS spells it. Changing
    /// this string means changing all six entitlement files with it: a mismatch
    /// does not fail to build, it just leaves the widget reading an empty
    /// container forever.
    static let appGroup = "group.scripty.scripty"

    /// The same group as macOS spells it — `TEAMID.group.…`.
    ///
    /// Mac Catalyst is the reason this exists at all: the container can only be
    /// opened with the exact identifier the entitlement granted, and the two
    /// platforms grant different strings for the same group. The prefix is
    /// substituted into Info.plist at build time; a build with no team to
    /// substitute gets nil rather than a stray leading dot.
    static var prefixedAppGroup: String? {
        guard let prefix = Bundle.main.object(forInfoDictionaryKey: "TeamIdentifierPrefix")
                as? String,
              !prefix.isEmpty,
              // An unexpanded `$(TeamIdentifierPrefix)` is a build that never
              // had a team to substitute, not a team called that.
              !prefix.hasPrefix("$")
        else { return nil }
        return prefix.hasSuffix(".") ? prefix + appGroup : "\(prefix).\(appGroup)"
    }

    /// Matches the `kind` the widget declares, so `WidgetCenter` can be told to
    /// reload this one by name.
    static let widgetKind = "BookmarksWidget"

    /// How many rows are kept. The largest family draws six, and the spare are
    /// what let a screenplay's bookmarks survive another script being opened
    /// on top of them — the rows are grouped by script, so a stingy cap would
    /// mean only ever seeing the most recent one's.
    static let limit = 12

    private static let fileName = "bookmarks-widget.json"

    /// Nil on a device where the group is not provisioned — which is a real
    /// state, not a bug: a development build signed without the capability
    /// still runs, it simply has no widget. Every call below degrades to a
    /// no-op rather than trapping.
    ///
    /// Both spellings are tried because iOS and macOS grant different ones (see
    /// `prefixedAppGroup`), and asking for the wrong one is not an error — it
    /// just answers nil. Plain first: it is the one that resolves on every iOS
    /// device and simulator, so Catalyst pays the extra call and nothing else
    /// does.
    static var containerURL: URL? {
        let manager = FileManager.default
        if let url = manager.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return url
        }
        guard let prefixed = prefixedAppGroup else { return nil }
        return manager.containerURL(forSecurityApplicationGroupIdentifier: prefixed)
    }

    private static var fileURL: URL? {
        containerURL?.appendingPathComponent(fileName)
    }

    // MARK: Reading and writing

    /// An empty snapshot where there is no container, no file in it, or nothing
    /// readable in the file — all three mean the same thing to the widget,
    /// which is that it has nothing to draw.
    static func load() -> BookmarksSnapshot {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else {
            return BookmarksSnapshot()
        }
        return decode(data)
    }

    /// Failures are swallowed, as in OfflineStore: nothing here is anyone's
    /// only copy of anything, and a device that cannot write its own app group
    /// container is beyond helping by a widget.
    static func save(_ snapshot: BookmarksSnapshot) {
        guard let fileURL, let data = encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Takes the widget's rows away entirely. Signing out goes through here:
    /// the next person to pick up the phone should not be able to read the last
    /// writer's dialogue off the Home Screen — which this widget shows more of
    /// than either of the others, since its rows are the script itself.
    static func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: Publishing

    /// Folds one script's bookmarks into what is already stored, capped at
    /// `limit`.
    ///
    /// The project's previous rows are dropped rather than merged, so an
    /// element unflagged, retyped or deleted since the last publish leaves with
    /// them. Every other project is left alone — the widget spans an account,
    /// but the app only ever has one script's elements in hand at a time.
    ///
    /// The order is by screenplay, most recently marked up first, and within a
    /// screenplay by position in the script. Sorting the whole list by anything
    /// finer would interleave two drafts' lines, which reads as nonsense: these
    /// rows are sentences out of a script, and a run of them only means
    /// anything in the order it was written. Ties on both keys break on the
    /// block id so the widget is not reshuffled by a sort that never promised
    /// to be stable.
    ///
    /// Pure, and separate from the file above, so the ordering can be checked
    /// without an app group container to write into.
    static func merging(_ bookmarks: [WidgetBookmark],
                        forProject projectId: Int,
                        into existing: [WidgetBookmark],
                        limit: Int = limit) -> [WidgetBookmark] {
        let kept = existing.filter { $0.projectId != projectId }
        let combined = kept + bookmarks.filter { $0.projectId == projectId }
        return Array(ordered(combined).prefix(max(0, limit)))
    }

    /// The sort described on `merging`, on its own so it can be checked on its
    /// own.
    static func ordered(_ bookmarks: [WidgetBookmark]) -> [WidgetBookmark] {
        bookmarks.sorted { lhs, rhs in
            if lhs.markedAt != rhs.markedAt { return lhs.markedAt > rhs.markedAt }
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.blockId < rhs.blockId
        }
    }

    /// Writes the merged list, reporting whether it differs from what was
    /// already stored.
    ///
    /// The answer is what decides whether to spend a `WidgetCenter` reload: the
    /// elements land again on every visit to a script, on every sync poll, and
    /// after every edit — and almost none of those change a bookmark.
    ///
    /// The comparison deliberately ignores `markedAt`, which is stamped fresh
    /// on every call and would otherwise make every publish look like a change.
    /// That is also what keeps the stamp meaning "last marked up" rather than
    /// "last looked at": a script whose bookmarks are unchanged is not written
    /// back, so it keeps the stamp it earned and does not shoulder aside the
    /// screenplay the writer actually flagged something in.
    @discardableResult
    static func publish(_ bookmarks: [WidgetBookmark],
                        forProject projectId: Int,
                        at now: Date = .now) -> Bool {
        let existing = load()
        let merged = merging(bookmarks, forProject: projectId, into: existing.bookmarks)
        guard !isSameContent(merged, existing.bookmarks) else { return false }
        save(BookmarksSnapshot(bookmarks: merged, savedAt: now))
        return true
    }

    /// Whether two row lists say the same thing, ignoring the stamps.
    ///
    /// `WidgetBookmark`'s own `==` compares `markedAt` too, which is right for a
    /// value type and wrong for this question: two publishes of an unchanged
    /// script differ only in when they happened.
    static func isSameContent(_ lhs: [WidgetBookmark], _ rhs: [WidgetBookmark]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.blockId == right.blockId
                && left.projectId == right.projectId
                && left.projectTitle == right.projectTitle
                && left.preview == right.preview
                && left.elementLabel == right.elementLabel
                && left.order == right.order
        }
    }

    // MARK: Coding

    /// ISO-8601 both ways, so a snapshot written by one version of the app is
    /// readable by an extension built from another — they ship together, but
    /// only the app is replaced when the widget is already on a Home Screen.
    ///
    /// Separate from the file handling above, and not private, so the pairing
    /// can be checked without a container to write into. It is worth checking:
    /// a date written one way and read another does not fail loudly, it leaves
    /// the widget reading an empty snapshot forever.
    static func encode(_ snapshot: BookmarksSnapshot) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(snapshot)
    }

    static func decode(_ data: Data) -> BookmarksSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(BookmarksSnapshot.self, from: data)) ?? BookmarksSnapshot()
    }
}

// MARK: - What a tap means

/// Where a tapped bookmark row is asking the app to go.
nonisolated struct BookmarkDestination: Equatable, Sendable {
    let projectId: Int
    /// The element to scroll to, or nil where the tap only named a screenplay —
    /// the widget's empty state, and a tap that landed on no row.
    let blockId: Int?
}

/// The `scripty://` URLs the widget hands back to the app.
///
/// A URL rather than an App Intent because the widget is asking for a screen,
/// not for work to be done: reaching a flagged line needs the signed-in
/// session, the loaded project list and the loaded script that only the app
/// has.
nonisolated enum BookmarkWidgetLink {
    static let scheme = "scripty"
    static let host = "bookmark"

    private enum Key {
        static let project = "project"
        static let block = "block"
    }

    static func url(for bookmark: WidgetBookmark) -> URL {
        url(projectId: bookmark.projectId, blockId: bookmark.blockId)
    }

    static func url(projectId: Int, blockId: Int? = nil) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        var items = [URLQueryItem(name: Key.project, value: String(projectId))]
        if let blockId {
            items.append(URLQueryItem(name: Key.block, value: String(blockId)))
        }
        components.queryItems = items
        // Built here from integers and two fixed words, so this cannot fail —
        // but a widget is not a place to trap.
        return components.url ?? URL(string: "\(scheme)://\(host)")!
    }

    /// Reads one back, or nil for any other `scripty://` URL — the other two
    /// widgets' rows, the demo link and the password reset link all arrive at
    /// the same door.
    static func destination(in url: URL) -> BookmarkDestination? {
        guard url.scheme == scheme, url.host() == host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        guard let projectId = value(Key.project).flatMap(Int.init) else { return nil }
        // An id that is present but not a number is a malformed link, not a
        // request for the script's top: dropping it beats scrolling somewhere
        // arbitrary.
        let raw = value(Key.block)
        let blockId = raw.flatMap(Int.init)
        if raw != nil, blockId == nil { return nil }
        return BookmarkDestination(projectId: projectId, blockId: blockId)
    }
}
