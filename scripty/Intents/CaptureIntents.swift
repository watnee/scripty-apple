//
//  CaptureIntents.swift
//  scripty
//
//  The four intents that write something: a note, a song, a line of lyric, a
//  line of script.
//
//  Unlike the open intents next door, these do the work rather than parking a
//  request — an intent that only opened a composer would leave the writer
//  retyping what they had just dictated. So each one waits out the launch,
//  finds the screenplay, sends one request, and then parks a destination so
//  the app lands on what it just made. The app is coming to the front either
//  way; it may as well arrive somewhere useful.
//
//  Every one of them rides a HAL affordance the app already uses from its own
//  screens. Nothing here needed a new rel, and nothing here should grow one:
//  an intent that could do something the app itself cannot is a second idea of
//  what the product is.
//

import AppIntents
import Foundation

// MARK: - New note, new song

/// The two document intents differ only in which half they write to, so the
/// work is written once and each intent says which it is.
@MainActor
private func createDocument(_ type: DocumentType,
                            title: String?,
                            content: String?,
                            in entity: ProjectEntity?,
                            using app: AppModel) async throws -> (Project, TextDocument) {
    try await IntentSession.requireSignedIn(app)
    let project = try await IntentSession.project(entity, in: app)
    let model = IntentSession.script(for: project, in: app)
    // An untitled capture is normal: "add a note" with the words dictated
    // after it names nothing. The server fills in its own title, and the app
    // draws `displayTitle` for anything it leaves blank.
    let named = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let created = await model.createDocument(title: named,
                                                   content: content ?? "",
                                                   type: type) else {
        throw IntentSession.failure(model)
    }
    // Land on it. The same pending destination a tapped widget row uses, so
    // there is one path into the Songs & Notes screen rather than two.
    app.pendingWidgetDestination = WidgetDestination(projectId: project.id,
                                                     documentId: created.id,
                                                     isSong: type == .song)
    return (project, created)
}

struct NewNoteIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "New Note" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Adds a note to a screenplay.", categoryName: "Songs & Notes")
    }
    nonisolated static var openAppWhenRun: Bool { true }

    @Parameter(title: "Title")
    var noteTitle: String?

    @Parameter(title: "Note", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String?

    @Parameter(title: "Screenplay")
    var project: ProjectEntity?

    nonisolated static var parameterSummary: some ParameterSummary {
        Summary("Add note \(\.$noteTitle) to \(\.$project)") {
            \.$text
        }
    }

    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<ProjectEntity> {
        let (target, _) = try await createDocument(.notes, title: noteTitle, content: text,
                                                   in: project, using: app)
        return .result(value: ProjectEntity(WidgetProject(id: target.id,
                                                          title: target.displayTitle)),
                       dialog: "Added a note to \(target.displayTitle).")
    }
}

struct NewSongIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "New Song" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Adds a song to a screenplay.", categoryName: "Songs & Notes")
    }
    nonisolated static var openAppWhenRun: Bool { true }

    @Parameter(title: "Title")
    var songTitle: String?

    @Parameter(title: "Lyrics", inputOptions: String.IntentInputOptions(multiline: true))
    var lyrics: String?

    @Parameter(title: "Screenplay")
    var project: ProjectEntity?

    nonisolated static var parameterSummary: some ParameterSummary {
        Summary("Add song \(\.$songTitle) to \(\.$project)") {
            \.$lyrics
        }
    }

    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<ProjectEntity> {
        let (target, _) = try await createDocument(.song, title: songTitle, content: lyrics,
                                                   in: project, using: app)
        return .result(value: ProjectEntity(WidgetProject(id: target.id,
                                                          title: target.displayTitle)),
                       dialog: "Added a song to \(target.displayTitle).")
    }
}

// MARK: - A line of lyric

struct AppendSongLineIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "Add Lyric Line" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Adds a line to the end of a song.", categoryName: "Songs & Notes")
    }
    nonisolated static var openAppWhenRun: Bool { true }

    @Parameter(title: "Line")
    var line: String

    /// The song by name rather than by a picker of its own.
    ///
    /// A song entity would need a snapshot of every project's documents, and
    /// the app only ever writes the one whose screenplay has been opened — so
    /// the picker would be empty for most screenplays with no honest way to say
    /// so. A name is matched against the documents actually loaded here, which
    /// is a list that is always right.
    @Parameter(title: "Song")
    var song: String

    @Parameter(title: "Screenplay")
    var project: ProjectEntity?

    nonisolated static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$line) to \(\.$song) in \(\.$project)")
    }

    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<ProjectEntity> {
        try await IntentSession.requireSignedIn(app)
        let target = try await IntentSession.project(project, in: app)
        let model = IntentSession.script(for: target, in: app)
        await model.loadDocuments()

        let wanted = song.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = model.songs.first(where: {
            $0.displayTitle.localizedCaseInsensitiveCompare(wanted) == .orderedSame
        }) else {
            throw IntentError.noSuchSong(wanted)
        }

        // The list rows carry a preview rather than the lyric, and the lines
        // hang off the full document's own links.
        guard let full = await model.fetchDocument(match) else {
            throw IntentSession.failure(model)
        }
        let lyric = SongBlockModel(app: app, document: full)
        await lyric.load()
        guard await lyric.appendLine(content: line) != nil else {
            throw IntentError.refused(lyric.errorMessage)
        }

        app.pendingWidgetDestination = WidgetDestination(projectId: target.id,
                                                         documentId: match.id,
                                                         isSong: true)
        return .result(value: ProjectEntity(WidgetProject(id: target.id,
                                                          title: target.displayTitle)),
                       dialog: "Added a line to \(match.displayTitle).")
    }
}

// MARK: - A line of script

/// The subset of `BlockType` worth dictating.
///
/// Not all fifteen. A spoken page break is nonsense, a character cue is half of
/// a pair that only means anything with the dialogue under it, and a picker of
/// fifteen entries is harder to use than one of five — the writer who wants the
/// other ten is at a keyboard, where all of them are a keystroke away.
enum ScreenplayElementAppEnum: String, AppEnum {
    case action
    case scene
    case dialogue
    case note
    case lyrics

    nonisolated static var typeDisplayRepresentation: TypeDisplayRepresentation { "Element" }

    nonisolated static var caseDisplayRepresentations: [ScreenplayElementAppEnum: DisplayRepresentation] {
        [.action: "Action",
         .scene: "Scene Heading",
         .dialogue: "Dialogue",
         .note: "Note",
         .lyrics: "Lyrics"]
    }

    var blockType: BlockType {
        switch self {
        case .action: .action
        case .scene: .scene
        case .dialogue: .dialogue
        case .note: .note
        case .lyrics: .lyrics
        }
    }
}

struct NewScreenplayElementIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "Add Screenplay Element" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Adds a line to the end of a screenplay.",
                          categoryName: "Screenplays")
    }
    nonisolated static var openAppWhenRun: Bool { true }

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    @Parameter(title: "Element", default: .action)
    var kind: ScreenplayElementAppEnum

    @Parameter(title: "Screenplay")
    var project: ProjectEntity?

    nonisolated static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$kind) \(\.$text) to \(\.$project)")
    }

    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<ProjectEntity> {
        try await IntentSession.requireSignedIn(app)
        let target = try await IntentSession.project(project, in: app)
        let model = IntentSession.script(for: target, in: app)
        // No person: a dictated cue names nobody, and the server accepts a
        // dialogue element without one — it belongs to whoever spoke last.
        guard await model.createBlock(content: text, type: kind.blockType, personId: nil) else {
            throw IntentSession.failure(model)
        }
        QuickActions.shared.pending = .project(id: target.id)
        return .result(value: ProjectEntity(WidgetProject(id: target.id,
                                                          title: target.displayTitle)),
                       dialog: "Added to \(target.displayTitle).")
    }
}
