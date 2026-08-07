//
//  SongsNotesWidgetData.swift
//  Shared between the scripty app and the SongsNotesWidget extension
//
//  The handful of songs and notes the Home Screen widgets draw, and the shared
//  container both sides reach it through. This is the whole of what the two
//  targets agree on: the app writes a snapshot whenever a project's documents
//  load, and the extension only ever reads one.
//
//  One snapshot, two widgets. Songs and Notes are separate entries in the
//  gallery — placed, sized and torn off independently — but they are two views
//  of the same file, because the app has both halves of a project in hand at
//  the same moment and writing them twice would only be two ways to disagree.
//
//  Deliberately free of the network and the Keychain. A widget that signed in
//  for itself would be a second copy of the HAL client to keep honest — and it
//  has nothing to show that the app has not already fetched, since a document
//  only reaches the widget by way of a screen that opened it.
//
//  Also deliberately separate from OfflineStore. That cache holds the server's
//  own HAL payloads so the app can decode a whole script back; this holds four
//  fields per row, is capped at a couple of dozen entries, and is read by a
//  process that must draw in milliseconds and cannot decode HAL at all.
//

import Foundation

/// One row of the widget: a song or a note, and just enough about it to draw
/// the row and to open the right screen when it is tapped.
nonisolated struct WidgetDocument: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let projectId: Int
    let projectTitle: String
    let title: String
    /// Which of the two lists — and so which of the two widgets — it belongs
    /// to. A Bool rather than the app's `DocumentType` so the extension does
    /// not have to compile the models; `WidgetDocumentKind` reads it back.
    let isSong: Bool
    let updatedAt: Date

    init(id: Int, projectId: Int, projectTitle: String,
         title: String, isSong: Bool, updatedAt: Date) {
        self.id = id
        self.projectId = projectId
        self.projectTitle = projectTitle
        self.title = title
        self.isSong = isSong
        self.updatedAt = updatedAt
    }
}

/// Which of the two widgets a row belongs to.
///
/// A widget's whole identity, as far as the shared half is concerned: the rows
/// it draws and the `kind` string WidgetKit knows it by. Presentation — what it
/// is called in the gallery, which symbol and tint it draws — lives in the
/// extension, which is the only target that can say any of it.
nonisolated enum WidgetDocumentKind: String, CaseIterable, Hashable, Sendable {
    case song
    case note

    /// Matches the `kind` each widget declares, so `WidgetCenter` can be told
    /// to reload one of them by name.
    ///
    /// These replaced the single `SongsNotesWidget` kind the two were one
    /// widget under. A tile already placed under that kind has nothing left in
    /// the bundle to draw it and is dropped by the system; WidgetKit offers no
    /// way to rename a kind, and there was no honest way around that.
    var widgetKind: String {
        switch self {
        case .song: "SongsWidget"
        case .note: "NotesWidget"
        }
    }

    /// Whether a row belongs to this half.
    func contains(_ document: WidgetDocument) -> Bool {
        document.isSong == (self == .song)
    }
}

/// What the app last published, and when it did.
///
/// `savedAt` is the widget's answer to "is this worth showing at all" — a
/// snapshot from an account that signed out months ago is cleared rather than
/// aged out, so in practice it is only ever used to say how fresh the rows are.
nonisolated struct SongsNotesSnapshot: Codable, Sendable {
    var documents: [WidgetDocument]
    var savedAt: Date

    init(documents: [WidgetDocument] = [], savedAt: Date = .distantPast) {
        self.documents = documents
        self.savedAt = savedAt
    }

    /// The half of the snapshot one widget draws, in the order it was stored.
    func documents(_ kind: WidgetDocumentKind) -> [WidgetDocument] {
        documents.filter(kind.contains)
    }
}

// MARK: - The shared container

/// `nonisolated` for the reason `ProjectsWidgetStore` records: this is read
/// by a timeline provider and by App Intents on their own queues, in a copy
/// of the process woken without a screen, and the app target's MainActor
/// default is not the isolation any of those readers have.
nonisolated enum SongsNotesWidgetStore {
    /// The App Group both targets are entitled to, as iOS spells it. Changing
    /// this string means changing all four entitlement files with it: a
    /// mismatch does not fail to build, it just leaves the widget reading an
    /// empty container forever.
    static let appGroup = "group.scripty.scripty"

    /// The same group as macOS spells it — `TEAMID.group.…`.
    ///
    /// Mac Catalyst is the reason this exists at all: the container can only be
    /// opened with the exact identifier the entitlement granted, and the two
    /// platforms grant different strings for the same group. The prefix is
    /// substituted into Info.plist at build time.
    ///
    /// Non-nil more often than the Catalyst framing suggests: a simulator build
    /// signed by a team substitutes the real prefix too, so this answers
    /// `TEAMID.group.…` on iOS as well. That costs nothing, because
    /// `containerURL` only falls back to it when the plain spelling misses —
    /// which on iOS it never does. Nil is for the builds that genuinely have no
    /// team to substitute, where the placeholder comes through unexpanded.
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

    /// Every kind the extension vends, for the times all of them have to be
    /// told at once — signing out, which takes the rows away from both.
    static let widgetKinds = WidgetDocumentKind.allCases.map(\.widgetKind)

    /// How many rows are kept **of each kind**.
    ///
    /// Per kind rather than in total because the two widgets share this one
    /// list but not a single row of it: a week spent writing songs would
    /// otherwise push every note out of the file and leave the Notes widget
    /// empty, with notes it could perfectly well have drawn.
    ///
    /// Sized for the second reader rather than the first. The largest widget
    /// family draws six; the rest of the depth is for Siri, to whom the
    /// snapshot is the whole of what can be named (see scripty/Intents), where
    /// "sorry, no such song" for a song the writer worked on last month is a
    /// quiet failure of exactly the kind a spoken request cannot recover from.
    /// So each half holds a working month's worth and the widget takes its six
    /// off the top. The file is a few fields per row; nothing about this is
    /// expensive.
    static let limit = 24

    private static let fileName = "songs-notes-widget.json"

    /// Nil on a device where the group is not provisioned — which is a real
    /// state, not a bug: a development build signed without the capability
    /// still runs, it simply has no widget. Every call below degrades to a
    /// no-op rather than trapping.
    ///
    /// Both spellings are tried because iOS and macOS grant different ones (see
    /// `prefixedAppGroup`), and asking for the wrong one is not an error — it
    /// just answers nil. Plain first: it is the one that resolves on every iOS
    /// device and simulator, so Catalyst pays the extra call and nothing else
    /// does. Not cached: the answer cannot change within a process, but a
    /// `static let` here would be one more thing to get wrong for no gain at
    /// the handful of calls a widget makes.
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

    static func load() -> SongsNotesSnapshot {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else {
            return SongsNotesSnapshot()
        }
        return (try? decoder.decode(SongsNotesSnapshot.self, from: data)) ?? SongsNotesSnapshot()
    }

    /// Failures are swallowed, as in OfflineStore: nothing here is anyone's
    /// only copy of anything, and a device that cannot write its own app group
    /// container is beyond helping by a widget.
    static func save(_ snapshot: SongsNotesSnapshot) {
        guard let fileURL, let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Takes both widgets' rows away entirely. Signing out goes through here:
    /// the next person to pick up the phone should not be able to read the
    /// last writer's song titles off the Home Screen.
    static func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: Publishing

    /// Folds one project's documents into what is already stored, newest
    /// first, capped at `limit` songs and `limit` notes.
    ///
    /// The project's previous rows are dropped rather than merged, so a song
    /// deleted or renamed since the last publish leaves with them. Every other
    /// project is left alone — the widgets span an account, but the app only
    /// ever has one project's documents in hand at a time.
    ///
    /// Songs and notes come back as one ordered list rather than two, because
    /// storing them apart would only mean sorting them apart as well; each
    /// widget filters out its own half on the way to being drawn.
    ///
    /// Pure, and separate from the file above, so the ordering can be checked
    /// without an app group container to write into.
    static func merging(_ documents: [WidgetDocument],
                        forProject projectId: Int,
                        into existing: [WidgetDocument],
                        limit: Int = limit) -> [WidgetDocument] {
        let kept = existing.filter { $0.projectId != projectId }
        let combined = kept + documents.filter { $0.projectId == projectId }
        let sorted = ordered(combined, limit: combined.count)
        // Each half is capped on its own — see `limit`. Cheap to do twice: the
        // whole list is a few dozen rows.
        let capped = WidgetDocumentKind.allCases.flatMap { kind in
            sorted.filter(kind.contains).prefix(max(0, limit))
        }
        return ordered(capped, limit: capped.count)
    }

    /// Newest first, capped — the one definition of "which of these come first",
    /// shared by the merge above and by the App Intents that offer the same rows
    /// to Siri. Split out so the two cannot drift: a spoken "open my last song"
    /// answering with a different document than the widget draws would look like
    /// a bug in whichever of the two the writer happened to distrust.
    static func ordered(_ documents: [WidgetDocument],
                        limit: Int) -> [WidgetDocument] {
        let sorted = documents.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            // Swift's sort promises nothing about equal elements, so ties break
            // on title rather than letting the widget reshuffle itself between
            // reloads for no visible reason.
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        return Array(sorted.prefix(max(0, limit)))
    }

    /// Writes the merged list, reporting which widgets' rows it changed.
    ///
    /// The answer is what decides which `WidgetCenter` reloads to spend, and
    /// reloads are rationed: loading a project's documents happens on every
    /// visit to the script, most of those visits change nothing at all, and an
    /// afternoon spent on the songs leaves the Notes widget drawing exactly
    /// what it already drew.
    ///
    /// A change that only reorders songs against notes counts as no change,
    /// correctly — neither widget can see the other's rows to be out of order
    /// against.
    @discardableResult
    static func publish(_ documents: [WidgetDocument],
                        forProject projectId: Int,
                        at now: Date = .now) -> Set<WidgetDocumentKind> {
        let existing = load()
        let merged = merging(documents, forProject: projectId, into: existing.documents)
        let changed = WidgetDocumentKind.allCases.filter { kind in
            merged.filter(kind.contains) != existing.documents.filter(kind.contains)
        }
        guard !changed.isEmpty else { return [] }
        save(SongsNotesSnapshot(documents: merged, savedAt: now))
        return Set(changed)
    }

    // MARK: Coding

    /// ISO-8601 both ways, so a snapshot written by one version of the app is
    /// readable by an extension built from another — they ship together, but
    /// only the app is replaced when the widget is already on a Home Screen.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - What a tap means

/// Where a tapped widget row is asking the app to go.
nonisolated struct WidgetDestination: Equatable, Sendable {
    let projectId: Int
    /// The document to open, or nil where the tap only named a project — the
    /// widget's empty state and its header, which open the list rather than
    /// any one song.
    let documentId: Int?
    let isSong: Bool
}

/// The `scripty://` URLs the widget hands back to the app.
///
/// A URL rather than an App Intent because the widget is asking for a screen,
/// not for work to be done: everything a tap leads to needs the signed-in
/// session and the loaded project list that only the app has.
nonisolated enum WidgetLink {
    static let scheme = "scripty"
    static let host = "document"

    private enum Key {
        static let project = "project"
        static let document = "id"
        static let kind = "kind"
    }

    private enum Kind {
        static let song = "song"
        static let notes = "notes"
    }

    static func url(for document: WidgetDocument) -> URL {
        url(projectId: document.projectId, documentId: document.id, isSong: document.isSong)
    }

    /// The whole widget's own link: a project's list, on the given half.
    static func url(projectId: Int, documentId: Int? = nil, isSong: Bool) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        var items = [URLQueryItem(name: Key.project, value: String(projectId)),
                     URLQueryItem(name: Key.kind, value: isSong ? Kind.song : Kind.notes)]
        if let documentId {
            items.append(URLQueryItem(name: Key.document, value: String(documentId)))
        }
        components.queryItems = items
        // The components above are all built here from integers and two fixed
        // words, so this cannot fail — but a widget is not a place to trap.
        return components.url ?? URL(string: "\(scheme)://\(host)")!
    }

    /// Reads one back, or nil for any other `scripty://` URL — the demo link
    /// and the password reset link both arrive at the same door.
    static func destination(in url: URL) -> WidgetDestination? {
        guard url.scheme == scheme, url.host() == host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        guard let projectId = value(Key.project).flatMap(Int.init) else { return nil }
        // An id that is present but not a number is a malformed link, not a
        // request for the list: dropping it beats opening something arbitrary.
        let raw = value(Key.document)
        let documentId = raw.flatMap(Int.init)
        if raw != nil, documentId == nil { return nil }
        return WidgetDestination(projectId: projectId,
                                 documentId: documentId,
                                 isSong: value(Key.kind) != Kind.notes)
    }
}

// MARK: - What a Control Center button means

/// The `scripty://` URLs that name a screen without naming a project.
///
/// `WidgetLink` and `ProjectWidgetLink` next door are built by rows that know
/// exactly which document or screenplay they drew. A Control Center button
/// knows nothing: it is a fixed tile on a Lock Screen, pressed by someone who
/// has a line in their head and no time to pick anything. So these routes name
/// only the screen, and the app settles which project on the far side — the
/// starred screenplay, else the one edited last, which is the answer the Home
/// Screen's own Songs and Notes entries already give.
///
/// A URL rather than a custom App Intent for a reason worth writing down: an
/// intent's *type* has to compile into whatever references it, and an intent
/// that could carry out a capture would have to reach AppModel and the HAL
/// client — neither of which an extension can compile, let alone run. The
/// system's own `OpenURLIntent` carries one of these instead, and the app's
/// existing door in `scriptyApp.onOpenURL` opens it.
nonisolated enum ScriptyLink {
    static let scheme = "scripty"

    /// Where a control is asking the app to go.
    enum Route: Equatable, Sendable {
        /// The songs list of whichever screenplay the app settles on.
        case songs
        /// That same screenplay's notes.
        case notes
        /// A new, empty song or note there, with the composer already open.
        case compose(isSong: Bool)
        /// The screenplay itself.
        case screenplay
    }

    private enum Host {
        static let songs = "songs"
        static let notes = "notes"
        static let compose = "compose"
        static let screenplay = "screenplay"
    }

    private static let kindKey = "kind"

    private enum Kind {
        static let song = "song"
        static let notes = "notes"
    }

    static func url(for route: Route) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        switch route {
        case .songs:
            components.host = Host.songs
        case .notes:
            components.host = Host.notes
        case .screenplay:
            components.host = Host.screenplay
        case .compose(let isSong):
            components.host = Host.compose
            components.queryItems = [URLQueryItem(name: kindKey,
                                                  value: isSong ? Kind.song : Kind.notes)]
        }
        // Built here from fixed words, so this cannot fail — but a control is
        // no better a place to trap than a widget is.
        return components.url ?? URL(string: "\(scheme)://\(Host.screenplay)")!
    }

    /// Reads one back, or nil for any other `scripty://` URL — the demo link,
    /// both widgets' rows and the password reset link all arrive at the same
    /// door, and each of them is somebody else's to answer.
    static func route(in url: URL) -> Route? {
        guard url.scheme == scheme else { return nil }
        switch url.host() {
        case Host.songs: return .songs
        case Host.notes: return .notes
        case Host.screenplay: return .screenplay
        case Host.compose:
            let kind = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first { $0.name == kindKey }?
                .value
            // A kind that is present but is neither word is a malformed link,
            // not a request for a note: dropping it beats opening the composer
            // on the wrong half of the screen.
            switch kind {
            case Kind.song: return .compose(isSong: true)
            case Kind.notes, nil: return .compose(isSong: false)
            default: return nil
            }
        default: return nil
        }
    }
}
