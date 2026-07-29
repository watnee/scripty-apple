//
//  IntentSession.swift
//  scripty
//
//  The preamble every intent that does real work shares: wait for the launch
//  to decide whether there is a session, find the screenplay, and hand back a
//  model to write through.
//
//  All of this runs in the app's own process. Every intent here is
//  `openAppWhenRun`, which is not a presentation choice but the whole reason
//  the feature needs no new entitlements: an intent running out of process
//  would have neither the credentials (the keychain item has no access group)
//  nor a route to the network. In the app, `APIClient` and the Keychain are
//  simply already there. That is also why nothing below ever leaves the main
//  actor — `APIClient` is not Sendable, and hopping off would need an
//  isolation story that does not exist.
//
//  Note what this file does *not* do: queue anything. `OfflineStore` is a read
//  cache and `APIClient.offlineCheck` fails fast, so a capture attempted with
//  no signal is reported and dropped. A durable outbox for one intent would be
//  a second sync model to keep honest, and the app has no first one.
//

import AppIntents
import Foundation

@MainActor
enum IntentSession {
    /// Waits out the launch, then insists there is somebody signed in.
    ///
    /// An intent can be dispatched into a process that has only just started —
    /// running the intent is often what started it — so `.loading` is the
    /// ordinary first answer rather than a failure. `awaitReady` is what turns
    /// it into a real one.
    static func requireSignedIn(_ app: AppModel) async throws {
        switch await app.awaitReady() {
        case .signedIn: return
        case .signedOut: throw IntentError.signedOut
        case .loading: throw IntentError.stillStarting
        }
    }

    /// The screenplay an intent is about, with its links — which is what makes
    /// it usable, and what the picker's `ProjectEntity` does not carry.
    ///
    /// Loads a project list of its own rather than reaching for the one on
    /// screen: on a cold launch there is no screen yet, and a list owned by the
    /// intent has a lifetime the intent controls.
    ///
    /// A nil entity means the writer named no screenplay — a spoken "new note"
    /// with nothing after it — and lands the same place the Home Screen's own
    /// Songs and Notes entries land: the starred draft, else the one edited
    /// last. A named screenplay that the list does not hold is an error rather
    /// than a fallback: writing into a different draft than the one asked for
    /// is worse than not writing at all.
    static func project(_ entity: ProjectEntity?, in app: AppModel) async throws -> Project {
        let list = ProjectListModel(app: app)
        await list.refresh()
        if let entity {
            guard let named = list.projects.first(where: { $0.id == entity.id }) else {
                throw IntentError.noSuchProject(entity.title)
            }
            return named
        }
        guard let preferred = QuickAction.preferredProject(in: list.projects) else {
            throw IntentError.noProjects
        }
        return preferred
    }

    /// A model to write this screenplay through. Nothing is preloaded: the
    /// create affordances fall back to the project's own links, so a capture
    /// costs one request rather than a load and then a request.
    static func script(for project: Project, in app: AppModel) -> ScriptModel {
        ScriptModel(app: app, project: project)
    }

    /// Turns "the model reported an error" back into something Siri can say.
    ///
    /// The models swallow their errors into `errorMessage` because a screen is
    /// normally there to show it. An intent has no screen, so the message has
    /// to be carried out as a thrown error instead — and where there is none,
    /// the affordance was simply missing, which for a shared project means
    /// read-only access.
    static func failure(_ model: ScriptModel) -> IntentError {
        .refused(model.errorMessage)
    }
}

/// What an intent tells the writer when it cannot do what was asked.
///
/// `CustomLocalizedStringResourceConvertible` is what makes these show up as
/// sentences in Siri and in the Shortcuts app rather than as a debug
/// description of a Swift error.
enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case signedOut
    case stillStarting
    case noProjects
    case noSuchProject(String)
    case noSuchSong(String)
    case refused(String?)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .signedOut:
            "Sign in to Scripty first."
        case .stillStarting:
            "Scripty is still starting up. Try again in a moment."
        case .noProjects:
            "There are no screenplays to add this to yet."
        case .noSuchProject(let title):
            "Couldn't find a screenplay called \(title)."
        case .noSuchSong(let title):
            "Couldn't find a song called \(title)."
        case .refused(let message):
            // The server's own words where there are any — "you're offline"
            // and "that project is read-only" are both worth hearing verbatim.
            "\(message ?? "Scripty couldn't save that.")"
        }
    }
}
