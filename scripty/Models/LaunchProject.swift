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
    /// The demo opens whatever comes first instead, which is the sample
    /// screenplay: the demo exists to show the editor, and its projects live in
    /// memory with no star ever set on them.
    static func opened(in projects: [Project], isDemo: Bool) -> Project? {
        isDemo ? projects.first : Project.starred(in: projects)
    }
}
