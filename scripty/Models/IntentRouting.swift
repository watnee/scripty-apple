//
//  IntentRouting.swift
//  scripty
//
//  What a Control Center button, and anything else that hands the app a bare
//  `scripty://` route, is actually asking for.
//
//  One function, and it exists so that `scriptyApp.onOpenURL` stays a list of
//  one-liners. The mapping is where a Control Center tile silently opens the
//  wrong half of the screen, and a mapping buried in a view's closure can only
//  be checked by pressing the button on a device.
//
//  Deliberately free of UIKit and of AppIntents, like QuickAction next door —
//  the routes arrive by URL precisely so that nothing outside the app has to
//  compile an intent, and this file is the last stop before the app's own
//  vocabulary takes over. QuickActions.swift is where the two meet.
//

import Foundation

enum IntentRouting {
    /// The action a route asks for, in the form the app already knows how to
    /// park and drain.
    ///
    /// Every route lands on `QuickAction` rather than on a second pending kind
    /// of its own. That machinery already waits for a project list, settles on
    /// a screenplay, opens it and drops the request on sign-out — all four of
    /// which a control needs and none of which is worth building twice.
    static func action(for route: ScriptyLink.Route) -> QuickAction {
        switch route {
        case .songs: .songs
        case .notes: .notes
        case .screenplay: .preferredProject
        // No project id: a control is a fixed tile, and which screenplay it
        // means is a question only the loaded list can answer.
        case .compose(let isSong): .compose(projectId: nil, type: isSong ? .song : .notes)
        }
    }
}
