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
    /// Which screenplay is open, by id rather than by value.
    ///
    /// A `Project` is a snapshot of a resource that keeps changing under it —
    /// every save bumps `lastEdited`, starring one flips `default` — and a
    /// selection held as the whole value goes stale the moment any of that
    /// happens: the sidebar stops highlighting the row it is showing, and on a
    /// phone the split view reads the change as picking a different screenplay
    /// and re-pushes the detail, throwing away a loaded script to load the same
    /// one again. The id is the part that actually says which project this is.
    @State private var selectedProjectId: Project.ID?
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

    /// The chosen project as the list currently describes it. Derived rather
    /// than stored, so a refreshed list is a refreshed selection.
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
            // The demo exists to show the screenplay, so open the sample
            // script rather than parking on the empty detail pane.
            if app.isDemo, selectedProjectId == nil {
                selectedProjectId = projectList.projects.first?.id
            }
            // A cold launch from the Home Screen menu lands here: the action was
            // taken before this view existed, so nothing has changed since to
            // announce it.
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
        guard let project = action.project(in: projectList.projects) else { return }
        selectedProjectId = project.id
        openingDocuments = action.documentType
    }
}
