//
//  ContentView.swift
//  scripty
//
//  Main shell: projects sidebar plus the screenplay detail pane.
//  Collapses to a stack on iPhone automatically.
//
//  Also the one place that can answer a Home Screen quick action, since
//  answering one means choosing a project, and this is where the list of them
//  lives. A tapped widget row arrives by the same route — see
//  ProjectWidgetLink in scriptyApp — and the menu's own recents and the
//  widget's rows are both republished from here for the same reason.
//

import SwiftUI

struct ContentView: View {
    let app: AppModel

    @State private var projectList: ProjectListModel
    @State private var selectedProject: Project?
    /// Set by a Songs or Notes quick action, and cleared by the script view
    /// once it has opened that list. Held here rather than passed at creation
    /// because tapping Songs for the screenplay already on screen changes no
    /// project, so there is no rebuild to carry an initial value in on.
    @State private var openingDocuments: DocumentType?

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
            // The demo exists to show the screenplay, so open the sample
            // script rather than parking on the empty detail pane.
            if app.isDemo, selectedProject == nil {
                selectedProject = projectList.projects.first
            }
            // A cold launch from the Home Screen menu lands here: the action was
            // taken before this view existed, so nothing has changed since to
            // announce it.
            performQuickAction()
        }
        // What the menu offers, and what the Home Screen widget draws, is
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
        .onChange(of: projectList.isLoading) { _, _ in performQuickAction() }
        .onChange(of: quickActions.pending) { _, _ in performQuickAction() }
    }

    /// Opens what the Home Screen asked for, if anything — a long-press menu
    /// entry or a tapped widget row, which arrive as the same kind of request.
    ///
    /// The action is dropped whether or not it found a project. An entry naming
    /// a screenplay since deleted, or a Songs tap by an account with no
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
        openingDocuments = action.documentType
    }
}
