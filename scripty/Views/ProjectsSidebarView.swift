//
//  ProjectsSidebarView.swift
//  scripty
//

import SwiftUI
import UniformTypeIdentifiers

/// Mirrors the web project list's sort control ("Last edited" / "Name A–Z").
/// Raw values back an @AppStorage so the choice sticks, like the web app's
/// sessionStorage-persisted `<select>`.
enum ProjectSort: String, CaseIterable, Identifiable {
    case lastEdited
    case title

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lastEdited: "Last edited"
        case .title: "Name A–Z"
        }
    }

    var systemImage: String {
        switch self {
        case .lastEdited: "clock"
        case .title: "textformat"
        }
    }
}

struct ProjectsSidebarView: View {
    let app: AppModel
    let model: ProjectListModel
    @Binding var selection: Project?

    @State private var showingCreate = false
    @State private var showingImporter = false
    /// Presented by link rather than by flag, so the sheet cannot open before
    /// the server has said where the trash is.
    @State private var trashLink: HALLink?
    @State private var renamingProject: Project?
    /// The API root's `teams` link, present only for a user who may manage
    /// them. Held so the sheet opens from the link, not a bare flag.
    @State private var teamsLink: HALLink?
    /// The API root's `users` link — advertised only to an admin, same as teams.
    @State private var usersLink: HALLink?
    /// The API root's `account` link — your own account, so it is offered to
    /// anyone signed in rather than only an admin.
    @State private var accountLink: HALLink?
    @State private var showingPreferences = false
    /// The finished projects archive, waiting for the system share sheet.
    @State private var exportedProjects: ExportedProjects?
    @State private var isExportingProjects = false
    @State private var searchText = ""
    @AppStorage("projectListSort") private var sortMode = ProjectSort.lastEdited
    /// The projects ticked in edit mode, by id — the web list's checkbox
    /// column, which is there to narrow the archive to a few screenplays.
    /// Edit mode is held here rather than left to the environment so leaving it
    /// can drop the ticks along with the bar that acts on them.
    @State private var exportSelection = Set<Int>()
    @State private var editMode: EditMode = .inactive

    /// Light or dark, for the whole app rather than this list.
    private let appearance = AppearanceSettings.shared

    private var appearanceBinding: Binding<AppearanceSettings.Appearance> {
        Binding(get: { appearance.appearance }, set: { appearance.appearance = $0 })
    }

    /// Its own property rather than inline in the toolbar: the toolbar builder
    /// is already long enough that adding a Picker to it defeats the type
    /// checker outright.
    private var appearancePicker: some View {
        Picker(selection: appearanceBinding) {
            ForEach(AppearanceSettings.Appearance.allCases) { choice in
                Label(choice.label, systemImage: choice.systemImage).tag(choice)
            }
        } label: {
            Label("Appearance", systemImage: appearance.appearance.systemImage)
        }
        .pickerStyle(.menu)
    }

    /// Client-side search + sort, matching the web list which filters by title
    /// and orders by the chosen mode (with a title tie-break on last-edited).
    private var displayedProjects: [Project] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = query.isEmpty
            ? model.projects
            : model.projects.filter { $0.displayTitle.lowercased().contains(query) }
        return filtered.sorted { lhs, rhs in
            switch sortMode {
            case .lastEdited:
                let l = lhs.lastEdited ?? .distantPast
                let r = rhs.lastEdited ?? .distantPast
                if l != r { return l > r }
                return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
            case .title:
                return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
            }
        }
    }

    /// Web header subtitle: a screenplay count, or a tagline when empty.
    private var countSubtitle: String {
        switch model.projects.count {
        case 0: "Your screenplays live here."
        case 1: "1 screenplay"
        case let n: "\(n) screenplays"
        }
    }

    /// Its own property rather than inline on the list: the toolbar has
    /// grown enough entries that leaving it in `body` puts the whole view
    /// past what the type checker will attempt.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                showingCreate = true
            } label: {
                Label("New Project", systemImage: "plus")
            }
        }
        if model.canImport {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showingImporter = true
                } label: {
                    Label("Import Project", systemImage: "square.and.arrow.down")
                }
            }
        }
        // The whole list as one re-importable archive — what the web list's
        // Download button sends. Exporting is a read, so it needs no more
        // than the projects the server already showed us.
        if model.canExportAll {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    download()
                } label: {
                    Label("Export All Projects", systemImage: "square.and.arrow.up.on.square")
                }
                .disabled(isExportingProjects)
            }
        }
        ToolbarItem(placement: .secondaryAction) {
            Picker("Sort", selection: $sortMode) {
                ForEach(ProjectSort.allCases) { mode in
                    Label(mode.label, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.menu)
        }
        if let trash = model.collectionLinks[.trash] {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    trashLink = trash
                } label: {
                    Label("Recently Deleted", systemImage: "trash")
                }
            }
        }
        // Only for a user the server lets manage teams — the root advertises
        // the rel to no one else.
        if let teams = app.apiRoot?.link(.teams) {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    teamsLink = teams
                } label: {
                    Label("Teams", systemImage: "person.3")
                }
            }
        }
        // Admin-only, same gate as teams: the root advertises `users` to no
        // one else.
        if let users = app.apiRoot?.link(.users) {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    usersLink = users
                } label: {
                    Label("Users", systemImage: "person.crop.circle")
                }
            }
        }
        // Your own account: password and passkeys. Advertised to anyone
        // signed in, unlike the admin-only entries above.
        if let account = app.apiRoot?.link(.account) {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    accountLink = account
                } label: {
                    Label("Account", systemImage: "person.badge.key")
                }
            }
        }
        // Editor preferences (auto-capitalization) — advertised on the root
        // only for a signed-in account, since they are stored per user.
        if app.apiRoot?.hasLink(.capitalizationPreferences) == true {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showingPreferences = true
                } label: {
                    Label("Editor Preferences", systemImage: "textformat")
                }
            }
        }
        // Appearance keeps the account entries company, as it does in the web
        // app's user dropdown. Nothing gates it: it is a choice about this
        // device, so there is no link to ask about. Help sits alongside it for
        // the same reason, and because that is where the web app's account menu
        // keeps its two help entries.
        //
        // Grouped with signing out rather than added as an eleventh item —
        // `ToolbarContentBuilder` takes ten, and the eleventh fails as a
        // baffling "extra argument in call" rather than as anything about
        // toolbars.
        ToolbarItemGroup(placement: .secondaryAction) {
            appearancePicker

            Button {
                HelpPresentation.shared.screen = .help
            } label: {
                Label("Scripty Help", systemImage: "questionmark.circle")
            }

            Button {
                HelpPresentation.shared.screen = .shortcuts
            } label: {
                Label("Keyboard Shortcuts", systemImage: "keyboard")
            }

            Button(role: .destructive) {
                app.signOut()
            } label: {
                Label(app.isDemo ? "Exit Demo" : "Sign Out",
                      systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }

    /// One row, without the tag: what a row is tagged with depends on which
    /// list it is in, and the two lists mean different things by "selected".
    @ViewBuilder
    private func projectRow(for project: Project) -> some View {
        ProjectRow(project: project) {
            Task { await model.toggleDefault(project) }
        }
        .swipeActions(edge: .trailing) {
            // Affordances are driven by the links the server returned.
            if project.hasLink(.delete) {
                Button(role: .destructive) {
                    Task {
                        if selection?.id == project.id { selection = nil }
                        await model.delete(project)
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            if project.hasLink(.update) {
                Button {
                    renamingProject = project
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .tint(.blue)
            }
        }
    }

    /// The selection in list order, so a bundle of several reads in the order
    /// the list was showing rather than the order rows happened to be tapped.
    private var selectedProjects: [Project] {
        displayedProjects.filter { exportSelection.contains($0.id) }
    }

    /// Its own `.toolbar`, not another branch of `toolbar` above: that builder
    /// is already at the ten items `ToolbarContentBuilder` accepts, and the
    /// eleventh fails as a baffling "extra argument in call".
    @ToolbarContentBuilder
    private var selectionToolbar: some ToolbarContent {
        // Worth entering only where there is an archive to narrow, and only
        // with more than one screenplay to choose between.
        if model.canExportAll && model.projects.count > 1 {
            ToolbarItem(placement: .primaryAction) {
                EditButton()
            }
        }
        // Shown once something is ticked — an empty bar under a list nobody is
        // selecting from is noise.
        if editMode.isEditing && !exportSelection.isEmpty {
            ToolbarItem(placement: .bottomBar) {
                Button {
                    exportSelected()
                } label: {
                    Label("Export \(exportSelection.count)", systemImage: "square.and.arrow.up")
                }
                .disabled(isExportingProjects)
            }
        }
    }

    var body: some View {
        // Two lists rather than one, because a sidebar's selection *is* the
        // navigation — tapping a row opens that screenplay. Ticking several to
        // export is a different question with a different answer type, so edit
        // mode swaps in a list that asks it instead of overloading the one
        // binding to mean both.
        Group {
            if editMode.isEditing {
                List(selection: $exportSelection) {
                    ForEach(displayedProjects) { project in
                        projectRow(for: project)
                    }
                }
            } else {
                List(selection: $selection) {
                    if app.isDemo {
                        DemoBanner()
                    }
                    ForEach(displayedProjects) { project in
                        projectRow(for: project).tag(project)
                    }
                }
            }
        }
        .environment(\.editMode, $editMode)
        .onChange(of: editMode) { _, mode in
            if !mode.isEditing { exportSelection.removeAll() }
        }
        .overlay {
            if model.projects.isEmpty {
                if model.isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView(
                        "No projects yet",
                        systemImage: "film",
                        description: Text("Create your first screenplay to get started."))
                }
            } else if displayedProjects.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .navigationTitle("Projects")
        .navigationSubtitle(countSubtitle)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search projects")
        .refreshable { await model.refresh() }
        .toolbar { toolbar }
        .toolbar { selectionToolbar }
        .sheet(isPresented: $showingPreferences) {
            CapitalizationSettingsView(app: app)
        }
        .sheet(item: $trashLink) { link in
            TrashView<TrashedProject, TrashedProjectRow>(
                app: app,
                source: link,
                title: "Recently Deleted",
                emptyMessage: "Screenplays you delete can be restored from here.",
                // A restored screenplay belongs back in the list behind us.
                onChanged: { await model.refresh() }) { project in
                    TrashedProjectRow(project: project)
                }
        }
        .sheet(item: $teamsLink) { link in
            TeamsView(app: app, source: link, projects: model.projects)
        }
        .sheet(item: $usersLink) { link in
            UsersView(app: app, source: link)
        }
        .sheet(item: $accountLink) { link in
            AccountView(app: app, source: link)
        }
        .sheet(item: $exportedProjects) { export in
            ShareSheet(items: [export.url])
        }
        .sheet(isPresented: $showingCreate) {
            ProjectTitleSheet(title: "", heading: "New Project") { title in
                await model.createProject(title: title) != nil
            }
        }
        .sheet(item: $renamingProject) { project in
            ProjectTitleSheet(title: project.title ?? "", heading: "Rename Project") { title in
                await model.rename(project, to: title)
            }
        }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.json],
                      allowsMultipleSelection: false) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            Task {
                // Imported files live outside the sandbox; read them under a
                // security scope, then hand the bytes to the API.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    model.errorMessage = "Couldn't read that file."
                    return
                }
                await model.importProject(data: data, filename: url.lastPathComponent)
            }
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })
    }

    /// The archive narrowed to the ticked screenplays. A single one comes back
    /// as that project's own archive — the server unwraps a selection of one —
    /// so it is named after the project rather than after the bundle.
    private func exportSelected() {
        let chosen = selectedProjects
        guard !chosen.isEmpty else { return }
        let name = chosen.count == 1 ? chosen[0].displayTitle : "Scripty Projects"
        download(ids: chosen.map(\.id), named: name)
    }

    /// The archive can take a moment to build on a busy account, so the button
    /// stays disabled until the file is on disk and the share sheet is up. A
    /// failure has already been reported through the model's error alert.
    private func download(ids: [Int] = [], named name: String = "Scripty Projects") {
        isExportingProjects = true
        Task {
            if let url = await model.exportProjects(ids: ids, named: name) {
                exportedProjects = ExportedProjects(url: url)
                // The bundle is on its way to the share sheet, so the ticks
                // have done their job.
                editMode = .inactive
            }
            isExportingProjects = false
        }
    }
}

/// The downloaded projects archive, identified by where it landed so the share
/// sheet opens only once the file exists.
private struct ExportedProjects: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// Demo mode looks exactly like a real session, so say so plainly: nothing
/// here is talking to a server, and nothing here survives a relaunch.
private struct DemoBanner: View {
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Demo Mode")
                    .font(.subheadline.weight(.semibold))
                Text("A sample screenplay running offline. Edits are discarded when you quit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.clear)
        .selectionDisabled()
        .accessibilityElement(children: .combine)
    }
}

private struct ProjectRow: View {
    let project: Project
    let onToggleDefault: () -> Void

    private var isDefault: Bool { project.isDefault ?? false }

    var body: some View {
        HStack(spacing: 10) {
            // The star mirrors the web list's default-project toggle; the
            // server only advertises `toggleDefault` when it's allowed.
            if project.hasLink(.toggleDefault) {
                Button(action: onToggleDefault) {
                    Image(systemName: isDefault ? "star.fill" : "star")
                        .foregroundStyle(isDefault ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isDefault ? "Remove as default project" : "Set as default project")
            }
            content
        }
        .padding(.vertical, 2)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(project.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                if isDefault {
                    Text("Default")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: Capsule())
                }
            }
            HStack(spacing: 6) {
                if let lastEdited = project.lastEdited {
                    Label {
                        Text(lastEdited, format: .relative(presentation: .named))
                    } icon: {
                        Image(systemName: "clock")
                    }
                    .labelStyle(.titleAndIcon)
                }
                if let teams = project.teams, !teams.isEmpty {
                    if project.lastEdited != nil {
                        Text("·")
                    }
                    Text(teams.joined(separator: ", "))
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// Shared title-entry sheet for creating and renaming projects.
private struct ProjectTitleSheet: View {
    @State var title: String
    let heading: String
    let action: (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                    .focused($focused)
                    .onSubmit { save() }
            }
            .navigationTitle(heading)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isSaving else { return }
        isSaving = true
        Task {
            let succeeded = await action(trimmed)
            isSaving = false
            if succeeded { dismiss() }
        }
    }
}
