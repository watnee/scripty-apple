//
//  LaunchProject.swift
//  scripty
//
//  Which screenplay the app opens by itself, once the project list has loaded
//  and the writer has not asked for anything in particular.
//
//  This is the web app's landing behaviour: signing in there lands on
//  `/project/show?id=<default>` when the writer has starred a project, and on
//  the project list when they have not. The star is what a writer with one
//  screenplay in progress sets so the app stops asking, and the client that
//  ignored it would make them tap past the same list every launch.
//
//  Only the star opens a project. The Home Screen menu falls back to the most
//  recently edited one (`QuickAction.preferredProject`), but that fallback
//  answers a tap the writer just made; a launch has no such request behind it,
//  and guessing would take an account that never starred anything and drop it
//  into a screenplay it never asked for — on iPhone, where the list and the
//  script are the same column, past the list entirely.
//
//  Deliberately free of SwiftUI so the choice can be checked without a
//  simulator; ContentView is where it is acted on.
//

import Foundation

enum LaunchProject {
    /// The project to open on its own, or nil to leave the writer on the list.
    ///
    /// The rule is the same signed out: a device with no account keeps its
    /// workspace between launches, stars included, so honouring the star there
    /// is honouring a choice the writer actually made.
    ///
    /// `isEphemeralDemo` is the one exception — the screenshot runs, which are
    /// reseeded every launch with no star ever set on anything. Those open
    /// whatever comes first, which is the sample screenplay: the demo exists to
    /// show the editor, not the projects list.
    static func opened(in projects: [Project], isEphemeralDemo: Bool) -> Project? {
        isEphemeralDemo ? projects.first : Project.starred(in: projects)
    }
}
