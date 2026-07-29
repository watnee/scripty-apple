//
//  ShortcutLink.swift
//  scripty
//
//  Every `scripty://` link that names a screen, and the one reader that turns
//  one back into something the app can do.
//
//  The app already had three of these — a widget row, a tapped screenplay, the
//  demo — each parsed at its own branch of `onOpenURL`. The App Intents next
//  door needed a fourth and a fifth ("my songs", "my notes"), which is one more
//  than a pile of branches is worth: gathered here, the four hosts are a
//  vocabulary rather than a sequence of special cases, and a writer building a
//  Shortcut by hand can use exactly the same links Siri does.
//
//  Deliberately free of AppIntents and UIKit, and answering in `QuickAction` —
//  the app's existing word for "open this, once there is a project list to open
//  it against". A link that arrives before there is one is parked, exactly as a
//  long-press menu entry is, and by the same machinery.
//
//  The one link not here is the widget's own `scripty://document?…`, which stays
//  in Shared/SongsNotesWidgetData.swift: the extension compiles that file and
//  must be able to write the link without compiling the app's models with it.
//

import Foundation

enum ShortcutLink {
    static let scheme = "scripty"

    /// The hosts, which are the whole of the vocabulary. `document` belongs to
    /// `WidgetLink` and is listed only so this file is the place to read the set
    /// off; nothing here parses it.
    private enum Host {
        static let songs = "songs"
        static let notes = "notes"
        static let demo = "demo"
    }

    /// The link that asks for what a long-press menu entry asks for.
    ///
    /// A screenplay defers to `ProjectWidgetLink` rather than spelling the same
    /// URL a second way — the Screenplays widget has been handing that exact
    /// link to the app since before any of this existed, and two spellings of
    /// one route is how the two quietly stop agreeing.
    static func url(for action: QuickAction) -> URL {
        switch action {
        case .songs: return url(host: Host.songs)
        case .notes: return url(host: Host.notes)
        case .project(let id): return ProjectWidgetLink.url(projectId: id)
        }
    }

    /// The project list itself, with no screenplay named.
    static var screenplaysURL: URL { ProjectWidgetLink.listURL }

    /// The offline demo.
    static var demoURL: URL { url(host: Host.demo) }

    /// Whether a link is the demo's. A path as well as a host because
    /// `scripty:///demo` and `scripty://demo` are both things people write, and
    /// a Shortcut that quietly does nothing is a poor way to find out which one
    /// this app meant.
    static func isDemo(_ url: URL) -> Bool {
        guard url.scheme == scheme else { return false }
        return url.host() == Host.demo || url.path == "/\(Host.demo)"
    }

    /// Reads a link back, or nil for one that names no screen this understands —
    /// the demo link and a recovery email's both arrive at the same door.
    ///
    /// Songs and Notes name no screenplay on purpose. They mean what the menu's
    /// two fixed entries mean, which is "in whichever screenplay is mine", and
    /// that question is only answerable against the loaded list — so it is left
    /// to `QuickAction.project(in:)` to answer, in the one place it is already
    /// answered.
    static func action(in url: URL) -> QuickAction? {
        guard url.scheme == scheme else { return nil }
        switch url.host() {
        case Host.songs: return .songs
        case Host.notes: return .notes
        default: return ProjectWidgetLink.projectId(in: url).map { .project(id: $0) }
        }
    }

    private static func url(host: String) -> URL {
        // Two fixed words, so this cannot fail — but neither a widget nor an
        // intent is a place to trap.
        URL(string: "\(scheme)://\(host)") ?? URL(fileURLWithPath: "/")
    }
}
