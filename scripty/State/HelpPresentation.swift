//
//  HelpPresentation.swift
//  scripty
//
//  Which help screen is open, if any.
//
//  The Mac menu bar can ask for one, and so can the projects sidebar, but a
//  `Commands` body cannot present a sheet — only a view can. So the two routes
//  in share one piece of state and the root view does the presenting, which
//  also means help is reachable from the sign-in screen, where there is no
//  project list to hang a button on.
//
//  Shared rather than owned, for the same reason the appearance setting is:
//  there is one help centre, not one per window.
//

import Foundation
import Observation

@Observable
@MainActor
final class HelpPresentation {
    static let shared = HelpPresentation()

    enum Screen: String, Identifiable, Sendable {
        case help
        case shortcuts

        var id: String { rawValue }
    }

    /// Nil when nothing is open. One at a time: the two screens cover the same
    /// ground from different ends, and stacking them would only bury the first.
    var screen: Screen?
}
