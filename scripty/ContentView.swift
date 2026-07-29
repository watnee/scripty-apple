//
//  ContentView.swift
//  scripty
//
//  Main shell: projects sidebar plus the screenplay detail pane.
//  Collapses to a stack on iPhone automatically.
//
//  Also the one place that can answer anything the Home Screen asks for — a
//  long-press menu entry or a tapped row on either widget — since answering one
//  means choosing a project, and this is where the list of them lives. The
//  menu's own recents and the Screenplays widget's rows are republished from
//  here for the same reason.
//

import SwiftUI

struct ContentView: View {
    let app: AppModel

    @State private var projectList: ProjectListModel
    @State private var selectedProject: Project?
    /// Set by a Songs or Notes quick action, or by a tapped widget row, and
    /// cleared by the script view once it has opened that list. Held here
    /// rather than passed at creation because tapping Songs for the screenplay
    /// already on screen changes no project, so there is no rebuild to carry an
    /// initial value in on.
    @State private var openingDocuments: DocumentsRequest?

    private let quickActions = QuickActions.shared

    init(app: AppModel) {
        self.app = app
        _projectList = State(initialValue: ProjectListModel(app: app))
    }

    var body: some View {
        NavigationSplitView {
            ProjectsSidebarView(app: app, model: projectList, selection: $selectedProject)
        } detail: {
            if let project = selectedProject {
                ScriptView(app: app, project: project, openingDocuments: $openingDocuments)
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
            // the same position.
            performQuickAction()
            openWidgetDestination()
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
        .onChange(of: projectList.projects) { _, projects in
            quickActions.publishRecents(projects, isDemo: app.isDemo)
            ProjectsWidgetPublisher.publish(projects, isDemo: app.isDemo)
        }
        // A load landing is the other moment an action can become answerable:
        // one taken while the list was still in flight has been sitting here
        // waiting for exactly this.
        .onChange(of: projectList.isLoading) { _, _ in
            performQuickAction()
            openWidgetDestination()
        }
        .onChange(of: quickActions.pending) { _, _ in performQuickAction() }
        // The app was already running when the widget row was tapped, so the
        // list is in hand and the only thing that changed is the request.
        .onChange(of: app.pendingWidgetDestination) { _, _ in openWidgetDestination() }
    }

    /// Opens the screenplay a launch opens on its own — the starred project, or
    /// the demo's sample script — leaving the detail pane empty when there is
    /// none. Runs once, from the load this view's own `task` performs: a writer
    /// who has since gone back to the list is not dragged forward again by a
    /// later refresh.
    ///
    /// A pending quick action outranks it. That tap named where to go, and
    /// opening the star first would only show a screenplay nobody asked for
    /// long enough to be replaced.
    private func openLaunchProject() {
        guard selectedProject == nil, quickActions.pending == nil else { return }
        selectedProject = LaunchProject.opened(in: projectList.projects, isDemo: app.isDemo)
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
        guard let project = action.project(in: projectList.projects) else { return }
        selectedProject = project
        openingDocuments = action.documentType.map { DocumentsRequest(type: $0) }
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
        selectedProject = project
        openingDocuments = DocumentsRequest(type: destination.isSong ? .song : .notes,
                                            documentId: destination.documentId)
    }
}
