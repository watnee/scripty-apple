//
//  ContentView.swift
//  scripty
//
//  Main shell: projects sidebar plus the screenplay detail pane.
//  Collapses to a stack on iPhone automatically.
//
//  Also the one place that can answer a Home Screen quick action, since
//  answering one means choosing a project, and this is where the list of them
//  lives. The menu's own recents are republished from here for the same reason.
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
    /// Whether the reopen-what-was-open pass has had its turn. Until it has,
    /// nothing is written back: a selection that is nil only because the list
    /// is still loading must not be mistaken for one the writer cleared.
    @State private var hasRestoredSelection = false

    private let quickActions = QuickActions.shared
    private let lastOpened = LastOpenedProject()

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
            restoreLastOpenedProject()
            // A cold launch from the Home Screen menu lands here: the action was
            // taken before this view existed, so nothing has changed since to
            // announce it. It runs after the restore so a menu tap wins: the
            // writer naming a screenplay outranks the one they left open.
            performQuickAction()
        }
        // What the menu offers is whatever the list last held.
        .onChange(of: projectList.projects) { _, projects in
            quickActions.publishRecents(projects, isDemo: app.isDemo)
        }
        // A load landing is the other moment an action can become answerable:
        // one taken while the list was still in flight has been sitting here
        // waiting for exactly this.
        .onChange(of: projectList.isLoading) { _, _ in performQuickAction() }
        .onChange(of: quickActions.pending) { _, _ in performQuickAction() }
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

    /// Reopens the screenplay the app was last left in, so a relaunch carries
    /// on where the writer stopped — `ScriptView` then does the same again
    /// inside the script, scrolling to the element they were on.
    ///
    /// Once, on the way in, and only over an empty selection: a demo run has
    /// already picked its sample and a Home Screen action is about to name its
    /// own project. A screenplay since deleted, or one belonging to an account
    /// that has since signed out, is not in the list that came back and is not
    /// found — so the app simply opens on the projects list as it used to.
    private func restoreLastOpenedProject() {
        defer { hasRestoredSelection = true }
        guard !app.isDemo, selectedProject == nil, let id = lastOpened.projectId else { return }
        selectedProject = projectList.projects.first { $0.id == id }
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
        openingDocuments = action.documentType
    }
}
