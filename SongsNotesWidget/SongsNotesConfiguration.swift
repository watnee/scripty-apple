//
//  SongsNotesConfiguration.swift
//  SongsNotesWidget
//
//  What "Edit Widget" offers on the Songs & Notes tile.
//
//  One setting: which half of the list to draw. The widget draws what the app
//  published and cannot fetch anything of its own, so this filters rather than
//  asks for anything new — and the store keeps two dozen rows rather than one
//  so that a widget set to one half still has six to draw.
//
//  There is deliberately no screenplay picker here. The app writes this
//  snapshot only for the project whose script has been opened, so a tile pinned
//  to any other screenplay would be permanently empty with no honest way to say
//  why.
//
//  Lives in the extension rather than in Shared: the app has no use for it, and
//  a file in Shared has to be spelled out twice in project.pbxproj.
//

import AppIntents
import WidgetKit

enum DocumentKindAppEnum: String, AppEnum {
    /// What the widget drew before it could be configured, and still the
    /// default — songs and notes interleaved by date.
    case both
    case songs
    case notes

    nonisolated static var typeDisplayRepresentation: TypeDisplayRepresentation { "Kind" }

    nonisolated static var caseDisplayRepresentations: [DocumentKindAppEnum: DisplayRepresentation] {
        [.both: DisplayRepresentation(title: "Songs & notes",
                                      subtitle: "Everything, newest first"),
         .songs: DisplayRepresentation(title: "Songs"),
         .notes: DisplayRepresentation(title: "Notes")]
    }

    var includesSongs: Bool { self != .notes }
    var includesNotes: Bool { self != .songs }
}

struct SongsNotesWidgetConfigurationIntent: WidgetConfigurationIntent {
    nonisolated static var title: LocalizedStringResource { "Songs & Notes" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Choose whether to show songs, notes, or both.")
    }

    /// The default has to reproduce exactly what the widget drew before there
    /// was anything to configure. iOS keeps an already-placed widget across the
    /// change to `AppIntentConfiguration` and instantiates this with its
    /// defaults, so anything but `.both` here would silently empty half of
    /// every widget already on a Home Screen during an app update.
    @Parameter(title: "Show", default: .both)
    var kind: DocumentKindAppEnum

    nonisolated static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$kind)")
    }
}
