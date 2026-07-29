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

    private let quickActions = QuickActions.shared
    /// Where the writer was when they last put the app down. This view owns the
    /// project half of that record; the script view owns the screens above it.
    private let openEditors = OpenEditorState.shared

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
            } else {
                reopenRememberedProject()
            }
            // A cold launch from the Home Screen menu lands here: the action was
            // taken before this view existed, so nothing has changed since to
            // announce it. After the restore rather than before, because tapping
            // a menu entry is someone saying where they want to go now, which
            // outranks where they happened to be last time.
            performQuickAction()
        }
        // Where the writer is, kept as they go. A project deselected on iPad
        // records nothing rather than the last one, since an empty detail pane
        // is a place too — and it is the one they left the app in.
        .onChange(of: selectedProject) { _, project in
            guard !app.isDemo else { return }
            openEditors.rememberProject(project?.id)
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

    /// Reopens the project the app was last left in.
    ///
    /// Only ever on the way in, and only onto an empty selection, so a project
    /// chosen since — by a quick action, or by hand while the list was still
    /// loading — is not overruled by where the writer was yesterday. An id
    /// belonging to a screenplay since deleted, or to another account, is simply
    /// not among the projects, and the list opens as it always did.
    ///
    /// The demo neither reads this record nor writes one: it opens the sample
    /// script by its own rule just below, and a five-minute walkthrough must not
    /// leave its place sitting on top of where the writer's real work was.
    private func reopenRememberedProject() {
        guard selectedProject == nil,
              let id = openEditors.rememberedProjectId,
              let project = projectList.projects.first(where: { $0.id == id }) else { return }
        selectedProject = project
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
