//
//  ContentView.swift
//  scripty
//
//  Main shell: projects sidebar plus the screenplay detail pane.
//  Collapses to a stack on iPhone automatically.
//
//  Also the one place that can answer anything the Home Screen asks for — a
//  long-press menu entry or a tapped row on any of the three widgets — since
//  answering one means choosing a project, and this is where the list of them
//  lives. The menu's own recents and the Screenplays widget's rows are
//  republished from here for the same reason.
//

import SwiftUI

struct ContentView: View {
    let app: AppModel

    @State private var projectList: ProjectListModel
    /// Which screenplay is open, held as an id rather than as the project.
    ///
    /// A `List` matches its selection against the row tags by equality, so a
    /// selection carrying the whole value is dropped the moment a refresh
    /// returns a project differing in any field — and `lastEdited` moves as
    /// soon as the writer types. The list then writes nil back through this
    /// binding, the detail pane goes with it, and the script load still in
    /// flight dies as a cancelled request the writer sees as "couldn't reach
    /// the server". The id is the part of a project that does not drift.
    @State private var selectedProjectId: Int?
    /// Set by a Songs or Notes quick action, or by a tapped widget row, and
    /// cleared by the script view once it has opened that list. Held here
    /// rather than passed at creation because tapping Songs for the screenplay
    /// already on screen changes no project, so there is no rebuild to carry an
    /// initial value in on.
    @State private var openingDocuments: DocumentsRequest?
    /// The element a tapped Bookmarks row asked for, cleared by the script view
    /// once it has scrolled there. Held here for the reason above: tapping a
    /// bookmark in the screenplay already on screen changes no project, so
    /// there is no rebuild to carry an initial value in on.
    @State private var openingBookmark: Int?
    /// Whether the reopen-what-was-open pass has had its turn. Until it has,
    /// nothing is written back: a selection that is nil only because the list
    /// is still loading must not be mistaken for one the writer cleared.
    @State private var hasRestoredSelection = false

    private let quickActions = QuickActions.shared
    /// Which screenplay to come back to. The screens *above* it are the script
    /// view's half of the same question — see `openEditors`, which is told the
    /// project so it knows whose screens it is holding.
    private let lastOpened = LastOpenedProject()
    /// Where the writer was when they last put the app down. This view owns the
    /// project half of that record; the script view owns the screens above it.
    private let openEditors = OpenEditorState.shared

    /// Watched only to refresh the menu on the way out — see the handler below.
    @Environment(\.scenePhase) private var scenePhase

    init(app: AppModel) {
        self.app = app
        _projectList = State(initialValue: ProjectListModel(app: app))
    }

    /// The selected screenplay as the list currently holds it. Resolved on each
    /// read rather than stored, so a rename or a re-sort lands in the open
    /// script instead of pointing it at a stale copy.
    private var selectedProject: Project? {
        projectList.projects.first { $0.id == selectedProjectId }
    }

    var body: some View {
        NavigationSplitView {
            ProjectsSidebarView(app: app, model: projectList, selection: $selectedProjectId)
        } detail: {
            if let project = selectedProject {
                ScriptView(app: app, project: project,
                           openingDocuments: $openingDocuments,
                           openingBookmark: $openingBookmark,
                           onProjectChanged: adoptRenamedProject)
                    .id(project.id)
            } else {
                ContentUnavailableView(
                    "Select a Project",
                    systemImage: "film",
                    description: Text("Choose a screenplay from the sidebar, or create a new one."))
            }
        }
        .task {
            await projectList.refresh()
            openLaunchProject()
            // A cold launch from the Home Screen menu lands here: the action was
            // taken before this view existed, so nothing has changed since to
            // announce it. A widget row tapped on a cold launch is in exactly
            // the same position. It runs after the open above so a menu tap
            // wins: the writer naming a screenplay outranks the one they left.

            performQuickAction()
            openWidgetDestination()
            openBookmarkDestination()
        }
        // What the menu offers, and what the Screenplays widget draws, is
        // whatever the list last held.
        //
        // Deliberately not `initial`: the list starts empty and is only filled
        // by the load above, so publishing the initial value would take every
        // screenplay off the widget on each launch — and leave it off, on a
        // device that then turns out to be offline. An account whose projects
        // really are all gone still publishes, because that is a change from
        // what the list held.
        // Where the writer is, kept as they go. A project deselected on iPad
        // records nothing rather than the last one, since an empty detail pane
        // is a place too — and it is the one they left the app in.
        .onChange(of: selectedProject) { _, project in
            guard !app.isDemo else { return }
            openEditors.rememberProject(project?.id)
        }
        .onChange(of: projectList.projects) { _, projects in
            quickActions.publishRecents(projects, isDemo: app.isDemo)
            ProjectsWidgetPublisher.publish(projects, isDemo: app.isDemo)
        }
        // Opening a screenplay is the other thing that makes it recent, and the
        // only one the menu can hear about while the app is running: an edit
        // moves the server's date, but nothing here would learn that until the
        // sidebar next reloads. The demo is left out for the same reason its
        // projects are never named — it has no screenplays to come back to.
        .onChange(of: selectedProject) { _, project in
            guard !app.isDemo, let project else { return }
            quickActions.noteOpened(project)
            quickActions.publishRecents(projectList.projects, isDemo: app.isDemo)
        }
        // Leaving is the moment before the menu is next read, and the entries
        // say things like "Edited yesterday" that are only true as of when they
        // were written. Rebuilding here settles them against the clock the
        // writer is about to long-press under — a session that ran past midnight
        // otherwise leaves the menu insisting all of it happened today.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            quickActions.publishRecents(projectList.projects, isDemo: app.isDemo)
        }
        // A load landing is the other moment an action can become answerable:
        // one taken while the list was still in flight has been sitting here
        // waiting for exactly this.
        .onChange(of: projectList.isLoading) { _, _ in
            performQuickAction()
            openWidgetDestination()
            openBookmarkDestination()
        }
        .onChange(of: quickActions.pending) { _, _ in performQuickAction() }
        // The app was already running when the widget row was tapped, so the
        // list is in hand and the only thing that changed is the request.
        .onChange(of: app.pendingWidgetDestination) { _, _ in openWidgetDestination() }
        .onChange(of: app.pendingBookmarkDestination) { _, _ in openBookmarkDestination() }
        // Where the app was left, kept as it changes rather than on the way
        // out: a screenplay open when the app is killed should be the one that
        // comes back. The demo is excluded — its sample project is chosen for
        // it every run, and letting it overwrite the writer's own choice would
        // mean a look at the demo lost their place.
        .onChange(of: selectedProject) { _, project in
            guard hasRestoredSelection, !app.isDemo else { return }
            lastOpened.remember(project?.id)
        }
    }

    /// Opens the screenplay a launch opens on its own, leaving the detail pane
    /// empty when there is none. Runs once, from the load this view's own
    /// `task` performs: a writer who has since gone back to the list is not
    /// dragged forward again by a later refresh.
    ///
    /// Where the writer was beats where they usually start. The screenplay the
    /// app was last left in comes back first, so a relaunch carries on — and
    /// `ScriptView` then does the same again inside the script, scrolling to
    /// the element they were on. The starred project is the fallback, for a
    /// first run, for a device that was left on the projects list, and for a
    /// remembered screenplay since deleted or belonging to an account that has
    /// signed out: that id is simply not in the list that came back.
    ///
    /// A pending quick action outranks all of it. That tap named where to go,
    /// and opening anything else first would only show a screenplay nobody
    /// asked for long enough to be replaced.
    private func openLaunchProject() {
        defer { hasRestoredSelection = true }
        guard selectedProjectId == nil, quickActions.pending == nil else { return }
        let remembered = app.isDemo ? nil : lastOpened.projectId
            .flatMap { id in projectList.projects.first { $0.id == id } }
        selectedProjectId = (remembered ?? LaunchProject.opened(in: projectList.projects,
                                                                isDemo: app.isDemo))?.id
    }

    /// Takes on a project the screenplay screen renamed or re-imported.
    ///
    /// The sidebar holds its own copy of the resource, so a name changed from
    /// the title page leaves the row behind it reading the old one. Reloading
    /// the list is the whole job — the selection is an id, so it survives the
    /// swap — and it is also what brings back the row's other facts (last
    /// edited, teams) that the save's own answer does not carry.
    private func adoptRenamedProject(_ updated: Project) async {
        await projectList.refresh()
    }

    /// Opens what the Home Screen menu asked for, if anything.
    ///
    /// The action is dropped whether or not it found a project. A menu entry
    /// naming a screenplay since deleted, or a Songs tap by an account with no
    /// projects, has nowhere to go — and leaving it pending would only mean it
    /// fired later, at whatever the list happened to hold by then.
    private func performQuickAction() {
        // Wait for the list rather than deciding against a half-loaded one:
        // "no such project" and "no projects yet" look the same mid-flight, and
        // only one of them is worth giving up over.
        guard !projectList.isLoading, let action = quickActions.pending else { return }
        quickActions.pending = nil
        guard let project = action.project(in: projectList.projects,
                                           openedAt: quickActions.openedAt) else { return }
        selectedProjectId = project.id
        openingDocuments = action.documentType.map {
            DocumentsRequest(type: $0, creating: action.isCreating)
        }
    }

    /// Opens the song or note a widget row was tapped for.
    ///
    /// Named projects only, unlike a Songs quick action: the row said which
    /// screenplay it drew, so falling back to the starred one would open a
    /// stranger's list rather than the song that was tapped. A row naming a
    /// project since deleted is dropped, on the same reasoning as a stale
    /// Home Screen entry — and for the same reason it is dropped whether or
    /// not it found anything, so it cannot fire again later against whatever
    /// the list happens to hold by then.
    private func openWidgetDestination() {
        guard !projectList.isLoading, let destination = app.pendingWidgetDestination else { return }
        app.pendingWidgetDestination = nil
        guard let project = projectList.projects.first(where: { $0.id == destination.projectId })
        else { return }
        selectedProjectId = project.id
        openingDocuments = DocumentsRequest(type: destination.isSong ? .song : .notes,
                                            documentId: destination.documentId)
    }

    /// Opens the screenplay a tapped Bookmarks row named, and passes the
    /// element on for the script view to scroll to.
    ///
    /// Named projects only, and dropped whether or not it found one, for the
    /// reasons above. The element is handed on unchecked: this view has the
    /// project list, not the script, so whether that line still exists is a
    /// question only the script view can answer — and its answer is to open the
    /// screenplay at the top, which is where the tap was heading anyway.
    private func openBookmarkDestination() {
        guard !projectList.isLoading, let destination = app.pendingBookmarkDestination else {
            return
        }
        app.pendingBookmarkDestination = nil
        guard let project = projectList.projects.first(where: { $0.id == destination.projectId })
        else { return }
        selectedProject = project
        openingBookmark = destination.blockId
    }
}
