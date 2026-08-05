//
//  ReadingViewSettings.swift
//  scripty
//
//  Whether a document opens to be read or to be written in.
//
//  Both of the document apps everyone already has on an iPhone open a file for
//  reading first. Pages puts a document into reading view — the document as it
//  is, with no caret — and gives you an Edit button; Word opens in Read Mode
//  and gives you a pencil. Both do it for the same reason, which is that a
//  phone is a device you scroll with your thumb, and a screenplay that is live
//  to the keyboard while you are scrolling through it is a screenplay you will
//  eventually type into by accident.
//
//  So this client opens documents the same way, and copies the two rules that
//  make the behaviour bearable rather than annoying:
//
//  * A document reopens the way you left it. Tap Edit once and that screenplay
//    is a screenplay you write in; it stops asking. Put it back into reading
//    view and it stays there.
//  * There is one switch — "Open in Edit View" — that changes the answer for
//    every document you have never made a choice about. Pages keeps exactly
//    this setting, and lets a per-document choice outrank it, which is why the
//    remembered value is consulted first below.
//
//  A device preference, like everything else about presentation: the same
//  account is read on a phone on a train and written on an iPad at a desk, and
//  only one of those wants a caret waiting. Nothing here reaches the server,
//  and the web app has no counterpart — it is a browser, where a document
//  cannot be scrolled into by accident — so these are this client's own keys
//  rather than borrowed ones.
//

import Foundation
import Observation

@Observable
@MainActor
final class ReadingViewSettings {
    /// Shared: screenplays, songs and notes all ask the same question.
    static let shared = ReadingViewSettings()

    /// A document, as this store keys one. A screenplay is keyed by its
    /// project because that is the identity the rest of the app remembers it
    /// by — the edition, the position and the outline tab are all filed that
    /// way — and songs and notes by their own id.
    enum Document: Hashable, Sendable {
        case screenplay(project: Int)
        case document(id: Int)
        /// Every song in a project on one screen — the all-songs workspace,
        /// which is a surface rather than a document and so has no id of its
        /// own to be filed under. Keyed by project for the reason a screenplay
        /// is: that is the identity everything else about this screen, down to
        /// which songs were left open, is remembered by.
        ///
        /// Deliberately *not* the same key as any song it shows. A song put
        /// into reading view in its own editor has said nothing about how a
        /// screen of every song should come up, and a writer who reaches this
        /// one through a button called "Edit All on One Page" has said the
        /// opposite — see `chosenReadingView`, which is what lets this screen
        /// open to be written in while the documents keep their own rule.
        case songsWorkspace(project: Int)
    }

    /// Whether documents nobody has made a choice about open ready to type in.
    ///
    /// Off, so they open to be read. This is the one default in the app that is
    /// deliberately not the writing-first answer, and the switch exists because
    /// it is also the one default a working writer is most likely to want the
    /// other way round.
    var opensInEditView: Bool {
        didSet {
            guard opensInEditView != oldValue else { return }
            defaults.set(opensInEditView, forKey: Key.opensInEditView)
        }
    }

    /// How this document should open. A choice already made about it wins over
    /// the switch, so turning "Open in Edit View" on affects the documents the
    /// writer has never had an opinion about and leaves the rest alone.
    func opensInReadingView(_ document: Document) -> Bool {
        chosenReadingView(document) ?? !opensInEditView
    }

    /// The choice the writer has actually made about this one, or nil where
    /// they have made none.
    ///
    /// The same answer `opensInReadingView` starts from, without the fallback,
    /// for the one surface that needs a different fallback. A screen reached
    /// by pressing "Edit All on One Page" opens to be written in whatever the
    /// app-wide switch says — the button is the writer saying so — but it
    /// still has to reopen the way they last left it, and "left it in the
    /// editor" and "never touched the mode" are answers this is the only way
    /// to tell apart.
    func chosenReadingView(_ document: Document) -> Bool? {
        defaults.object(forKey: Self.key(for: document)) as? Bool
    }

    /// Records which way this document was last put, which is what makes the
    /// Edit button a one-time cost per document rather than a tax on every
    /// visit. Called only for a change the writer asked for: a document that
    /// drops out of reading view because it turned out to be empty has not
    /// been chosen, and storing that would quietly opt it out of the switch.
    func remember(_ readingView: Bool, for document: Document) {
        defaults.set(readingView, forKey: Self.key(for: document))
    }

    // MARK: - Storage

    private enum Key {
        static let opensInEditView = "scripty-open-in-edit-view"
    }

    /// Kept in the same `scripty-…-<kind>-<id>` family as the per-project view
    /// options next door, so the two read as one set of preferences even though
    /// they are stored by different objects.
    private static func key(for document: Document) -> String {
        switch document {
        case .screenplay(let project): return "scripty-reading-view-project-\(project)"
        case .document(let id): return "scripty-reading-view-document-\(id)"
        case .songsWorkspace(let project): return "scripty-reading-view-songs-workspace-\(project)"
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `bool(forKey:)` is right here for once: an unset key and a stored
        // false mean the same thing, which is "open it to be read".
        opensInEditView = defaults.bool(forKey: Key.opensInEditView)
    }
}
