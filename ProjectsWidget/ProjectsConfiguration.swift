//
//  ProjectsConfiguration.swift
//  ProjectsWidget
//
//  What "Edit Widget" offers on the Screenplays tile.
//
//  One setting, and it only reorders. The widget draws what the app published
//  and cannot fetch anything of its own, so every option here has to be a
//  question the stored snapshot can already answer — a picker offering
//  screenplays this device has never loaded would be a picker that produces
//  empty tiles.
//
//  Lives in the extension rather than in Shared: the app has no use for it, and
//  a file in Shared has to be spelled out twice in project.pbxproj.
//

import AppIntents
import WidgetKit

enum ProjectScopeAppEnum: String, AppEnum {
    /// What the widget drew before it could be configured, and still the
    /// default — the snapshot's own order.
    case recentlyEdited
    /// The starred screenplay first, then the rest in that same order.
    case starredFirst

    nonisolated static var typeDisplayRepresentation: TypeDisplayRepresentation { "Order" }

    nonisolated static var caseDisplayRepresentations: [ProjectScopeAppEnum: DisplayRepresentation] {
        [.recentlyEdited: DisplayRepresentation(title: "Recently edited",
                                                subtitle: "Whatever you touched last"),
         .starredFirst: DisplayRepresentation(title: "Starred first",
                                              subtitle: "Your starred screenplay at the top")]
    }
}

struct ProjectsWidgetConfigurationIntent: WidgetConfigurationIntent {
    nonisolated static var title: LocalizedStringResource { "Screenplays" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Choose which screenplay leads the list.")
    }

    /// The default has to reproduce exactly what the widget drew before there
    /// was anything to configure. iOS keeps an already-placed widget across the
    /// change to `AppIntentConfiguration` and instantiates this with its
    /// defaults, so anything but `.recentlyEdited` here would silently
    /// rearrange every widget already on a Home Screen during an app update.
    @Parameter(title: "Order", default: .recentlyEdited)
    var scope: ProjectScopeAppEnum

    nonisolated static var parameterSummary: some ParameterSummary {
        Summary("Show screenplays \(\.$scope)")
    }
}
