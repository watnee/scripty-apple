//
//  ProjectsWidgetData.swift
//  Shared between the scripty app and the ProjectsWidget extension
//
//  The handful of screenplays the Home Screen widget draws, and the shared
//  container both sides reach them through. This is the whole of what the two
//  targets agree on: the app writes a snapshot whenever the project list
//  loads, and the extension only ever reads one.
//
//  Deliberately free of the network and the Keychain. A widget that signed in
//  for itself would be a second copy of the HAL client to keep honest — and it
//  has nothing to show that the app has not already fetched, since the sidebar
//  loads the whole list on every launch.
//
//  Also deliberately separate from OfflineStore. That cache holds the server's
//  own HAL payloads so the app can decode a whole collection back; this holds
//  five fields per row, is capped at a handful of entries, and is read by a
//  process that must draw in milliseconds and cannot decode HAL at all.
//
//  Nothing here imports the app's `Project`: the extension would have to
//  compile HALLink and HALResource with it, for the sake of fields it never
//  draws. ProjectsWidgetPublisher does the narrowing on the app's side.
//

import Foundation

/// One row of the widget: a screenplay, and just enough about it to draw the
/// row and to open the right one when it is tapped.
struct WidgetProject: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    /// Already resolved through `Project.displayTitle`, so the extension never
    /// has to know that a project can be titled in two places or in neither.
    let title: String
    /// The two lines of context the sidebar row also shows. Optional because
    /// the server omits them until someone fills the title page in.
    let writers: String?
    let version: String?
    /// Nil for a screenplay the server has never dated — a project made and not
    /// yet touched. It sorts last rather than being dropped; see `ordered`.
    let lastEdited: Date?
    /// The writer's starred screenplay, drawn with the same star the sidebar
    /// uses. At most one project in a snapshot has this.
    let isDefault: Bool

    init(id: Int, title: String, writers: String? = nil, version: String? = nil,
         lastEdited: Date? = nil, isDefault: Bool = false) {
        self.id = id
        self.title = title
        self.writers = writers
        self.version = version
        self.lastEdited = lastEdited
        self.isDefault = isDefault
    }
}

/// What the app last published, and when it did.
///
/// `savedAt` is not used to age the rows out — a snapshot is cleared when it
/// stops being true (signing out) rather than expiring on a timer, because a
/// list of your own screenplays does not become wrong by sitting still.
struct ProjectsSnapshot: Codable, Sendable {
    var projects: [WidgetProject]
    var savedAt: Date

    init(projects: [WidgetProject] = [], savedAt: Date = .distantPast) {
        self.projects = projects
        self.savedAt = savedAt
    }

    var isEmpty: Bool { projects.isEmpty }
}

// MARK: - The shared container

enum ProjectsWidgetStore {
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
    /// substituted into Info.plist at build time; a simulator or unsigned build
    /// has no team, and gets nil rather than a stray leading dot.
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
    static let widgetKind = "ProjectsWidget"

    /// How many rows are kept.
    ///
    /// Sized for the second reader rather than the first. The largest widget
    /// family draws six, and eight was once ample for it — but this snapshot is
    /// also the whole of what Siri and Spotlight can name (see scripty/Intents),
    /// and there a cap is not a shorter list, it is "no such screenplay" for a
    /// screenplay that plainly exists. Thirty-two is past any working writer's
    /// shelf; the widget takes its six off the top as before.
    static let limit = 32

    private static let fileName = "projects-widget.json"

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
    /// readable in the file — all three mean the same thing to the widget, which
    /// is that it has nothing to draw.
    static func load() -> ProjectsSnapshot {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else {
            return ProjectsSnapshot()
        }
        return decode(data)
    }

    /// Failures are swallowed, as in OfflineStore: nothing here is anyone's only
    /// copy of anything, and a device that cannot write its own app group
    /// container is beyond helping by a widget.
    static func save(_ snapshot: ProjectsSnapshot) {
        guard let fileURL, let data = encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Takes the widget's rows away entirely. Signing out goes through here: the
    /// next person to pick up the phone should not be able to read the last
    /// writer's screenplay titles off the Home Screen.
    static func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: Publishing

    /// The rows a list of projects becomes, most recently edited first, capped
    /// at `limit`.
    ///
    /// The starred project is *not* floated to the top. The star answers "which
    /// screenplay is mine", which is the question the Home Screen menu's Songs
    /// entry asks; this widget asks "what have I been working on", and a writer
    /// who has spent the week in a different draft should see that draft first.
    /// The star is drawn on its row instead, wherever the row lands.
    ///
    /// A project the server gave no edit date is kept rather than filtered out —
    /// it sorts last, but an account whose only screenplay has never been
    /// touched should still find it here rather than an empty widget. Ties break
    /// on title so the widget is not reshuffled by a sort that never promised to
    /// be stable.
    ///
    /// Pure, and separate from the file above, so the ordering can be checked
    /// without an app group container to write into.
    static func ordered(_ projects: [WidgetProject], limit: Int = limit) -> [WidgetProject] {
        let sorted = projects.sorted { lhs, rhs in
            let left = lhs.lastEdited ?? .distantPast
            let right = rhs.lastEdited ?? .distantPast
            if left != right { return left > right }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        return Array(sorted.prefix(max(0, limit)))
    }

    /// Writes the ordered list, reporting whether it differs from what was
    /// already stored.
    ///
    /// The answer is what decides whether to spend a `WidgetCenter` reload: the
    /// project list is refreshed after every rename, star, import and delete,
    /// and most of those refreshes change nothing the widget draws.
    ///
    /// The whole list is replaced rather than merged, unlike the app's other
    /// caches — the sidebar always holds every project the account can see, so
    /// a screenplay missing from `projects` is a screenplay that is gone.
    @discardableResult
    static func publish(_ projects: [WidgetProject], at now: Date = .now) -> Bool {
        let existing = load()
        let ordered = ordered(projects)
        guard ordered != existing.projects else { return false }
        save(ProjectsSnapshot(projects: ordered, savedAt: now))
        return true
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
    static func encode(_ snapshot: ProjectsSnapshot) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(snapshot)
    }

    static func decode(_ data: Data) -> ProjectsSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ProjectsSnapshot.self, from: data)) ?? ProjectsSnapshot()
    }
}

// MARK: - What a tap means

/// The `scripty://` URLs the widget hands back to the app.
///
/// A URL rather than an App Intent because the widget is asking for a screen,
/// not for work to be done: opening a screenplay needs the signed-in session
/// and the loaded project list that only the app has.
enum ProjectWidgetLink {
    static let scheme = "scripty"
    static let host = "project"

    private static let idKey = "id"

    static func url(for project: WidgetProject) -> URL {
        url(projectId: project.id)
    }

    static func url(projectId: Int) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: idKey, value: String(projectId))]
        // Built here from one integer and two fixed words, so this cannot fail
        // — but a widget is not a place to trap.
        return components.url ?? URL(string: "\(scheme)://\(host)")!
    }

    /// The whole widget's own link, for a tap that landed on no row: the app's
    /// project list, with nothing selected.
    static var listURL: URL {
        URL(string: "\(scheme)://\(host)")!
    }

    /// Reads a project id back, or nil for any other `scripty://` URL — the demo
    /// link and the password reset link both arrive at the same door.
    ///
    /// A host of `project` with no id is the list link above, which asks for no
    /// particular screenplay and so answers nil here too: the app has nothing to
    /// do about it beyond coming to the front, which it is already doing.
    static func projectId(in url: URL) -> Int? {
        guard url.scheme == scheme, url.host() == host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        return components.queryItems?
            .first { $0.name == idKey }?
            .value
            .flatMap(Int.init)
    }
}
