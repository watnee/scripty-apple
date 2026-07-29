//
//  ProjectsSidebarView.swift
//  scripty
//

import SwiftUI
import UniformTypeIdentifiers

/// Mirrors the web project list's sort control ("Last edited" / "Name A–Z"),
/// plus the reverse the users list already offers. Raw values back an
/// @AppStorage so the choice sticks, like the web app's sessionStorage-persisted
/// `<select>` — and the two original raw values are unchanged, so a writer who
/// picked one before this case existed keeps it.
enum ProjectSort: String, CaseIterable, Identifiable {
    case lastEdited
    case oldestEdited
    case title
    case titleDescending

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lastEdited: "Last edited"
        case .oldestEdited: "Least recently edited"
        case .title: "Name A–Z"
        case .titleDescending: "Name Z–A"
        }
    }

    var systemImage: String {
        switch self {
        case .lastEdited, .oldestEdited: "clock"
        case .title, .titleDescending: "textformat"
        }
    }
}

struct ProjectsSidebarView: View {
    let app: AppModel
    let model: ProjectListModel
    /// The open screenplay's id. An id rather than the project itself because a
    /// selection matched on the whole value does not survive a refresh — see
    /// `ContentView`.
    @Binding var selection: Int?

    @State private var showingCreate = false
    @State private var showingImporter = false
    /// Presented by link rather than by flag, so the sheet cannot open before
    /// the server has said where the trash is.
    @State private var trashLink: HALLink?
    @State private var renamingProject: Project?
    /// The project whose team assignment is being edited — the per-project
    /// production-teams picker, distinct from the global `teamsLink` above.
    @State private var assigningTeamsProject: Project?
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

    /// Client-side search + sort. The search scans the whole row (title, project
    /// name, writers, version, teams — see `Project.searchHaystackLowercased`)
    /// rather than the web's title-only filter, and every term has to match, so
    /// "jane draft" narrows instead of widening.
    private var displayedProjects: [Project] {
        let terms = searchText.lowercased().split(separator: " ").map(String.init)
        let filtered = terms.isEmpty
            ? model.projects
            : model.projects.filter { project in
                let haystack = project.searchHaystackLowercased
                return terms.allSatisfy { haystack.contains($0) }
            }
        return filtered.sorted { lhs, rhs in
            switch sortMode {
            case .lastEdited, .oldestEdited:
                let l = lhs.lastEdited ?? .distantPast
                let r = rhs.lastEdited ?? .distantPast
                if l != r { return sortMode == .lastEdited ? l > r : l < r }
                return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
            case .title:
                return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
            case .titleDescending:
                return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedDescending
            }
        }
    }

    /// Web header subtitle: a screenplay count, or a tagline when empty. While a
    /// search is narrowing the list it says so — a bare "12 screenplays" over
    /// three visible rows reads as a list that has lost something.
    private var countSubtitle: String {
        let total = model.projects.count
        guard total > 0 else { return "Your screenplays live here." }
        let shown = displayedProjects.count
        guard shown == total else { return "\(shown) of \(total) screenplays" }
        return total == 1 ? "1 screenplay" : "\(total) screenplays"
    }

    /// Two menus rather than one overflow pile. Every entry used to be a
    /// `.secondaryAction`, which iOS collapses into a single "…" holding
    /// everything from Import to Sign Out — one undifferentiated list mixing
    /// what you do to this list with what you do to your account. Sorting them
    /// into a list menu and an account menu also lifts the ceiling that shaped
    /// the old code: `ToolbarContentBuilder` takes ten items and fails the
    /// eleventh as a baffling "extra argument in call", whereas each menu here
    /// is one item holding as many entries as it likes.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if editMode.isEditing {
            // Nothing but leaving: the list under it is answering a different
            // question, and New/Import/Account all belong to the other one.
            ToolbarItem(placement: .primaryAction) {
                Button("Done") { editMode = .inactive }
            }
        } else {
            // No "+" here: creating a project is already offered, named, by the
            // bar under the list, which is on screen whenever this toolbar is.
            // A glyph saying the same thing in the far corner is one control
            // too many, and reads as a second, different action.
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    listMenu
                } label: {
                    Label("Project List Options", systemImage: "ellipsis.circle")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    accountMenu
                } label: {
                    Label("Account", systemImage: "person.crop.circle")
                }
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

    /// What you can do to the list itself: bring screenplays in, take them out,
    /// order them, and reach the ones you deleted.
    @ViewBuilder
    private var listMenu: some View {
        Section {
            if model.canImport {
                Button {
                    showingImporter = true
                } label: {
                    Label("Import Project", systemImage: "square.and.arrow.down")
                }
            }
            // The whole list as one re-importable archive — what the web list's
            // Download button sends. Exporting is a read, so it needs no more
            // than the projects the server already showed us.
            if model.canExportAll {
                Button {
                    download()
                } label: {
                    Label("Export All Projects", systemImage: "square.and.arrow.up.on.square")
                }
                .disabled(isExportingProjects)
                // Worth entering only where there is an archive to narrow, and
                // only with more than one screenplay to choose between.
                if model.projects.count > 1 {
                    Button {
                        editMode = .active
                    } label: {
                        Label("Select Projects…", systemImage: "checkmark.circle")
                    }
                }
            }
        }
        if let trash = model.collectionLinks[.trash] {
            Section {
                Button {
                    trashLink = trash
                } label: {
                    Label("Recently Deleted", systemImage: "trash")
                }
            }
        }
        Section("Sort By") {
            Picker("Sort", selection: $sortMode) {
                ForEach(ProjectSort.allCases) { mode in
                    Label(mode.label, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.inline)
        }
    }

    /// Who you are and how the app looks — the web app's user dropdown, which
    /// is where all of these live there too.
    @ViewBuilder
    private var accountMenu: some View {
        Section {
            // Your own account: password and passkeys. Advertised to anyone
            // signed in, unlike the admin-only entries below.
            if let account = app.apiRoot?.link(.account) {
                Button {
                    accountLink = account
                } label: {
                    Label("Account", systemImage: "person.badge.key")
                }
            }
            // Editor preferences (auto-capitalization) — advertised on the root
            // only for a signed-in account, since they are stored per user.
            if app.apiRoot?.hasLink(.capitalizationPreferences) == true {
                Button {
                    showingPreferences = true
                } label: {
                    Label("Editor Preferences", systemImage: "textformat")
                }
            }
        }
        Section {
            // Only for a user the server lets manage teams — the root advertises
            // the rel to no one else.
            if let teams = app.apiRoot?.link(.teams) {
                Button {
                    teamsLink = teams
                } label: {
                    Label("Teams", systemImage: "person.3")
                }
            }
            // Admin-only, same gate as teams: the root advertises `users` to no
            // one else.
            if let users = app.apiRoot?.link(.users) {
                Button {
                    usersLink = users
                } label: {
                    Label("Users", systemImage: "person.crop.circle")
                }
            }
        }
        Section {
            // Nothing gates appearance: it is a choice about this device, so
            // there is no link to ask about. Help sits alongside it for the same
            // reason, and because that is where the web app's account menu keeps
            // its two help entries.
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
        }
        Section {
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
        // The same actions as the swipe, plus the ones that have no swipe slot.
        // A swipe is invisible until you try it and has no equivalent under a
        // pointer at all, so on iPad and Mac the row's actions were effectively
        // unreachable; a long press or right-click reaches them everywhere.
        .contextMenu { projectMenu(for: project) }
        .swipeActions(edge: .trailing) {
            // Affordances are driven by the links the server returned.
            if project.hasLink(.delete) {
                Button(role: .destructive) {
                    Task {
                        if selection == project.id { selection = nil }
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
            // Only an editor is offered the picker — the server advertises
            // `projectTeams` on that gate, so a reader's row shows nothing here.
            if project.hasLink(.projectTeams) {
                Button {
                    assigningTeamsProject = project
                } label: {
                    Label("Teams", systemImage: "person.2")
                }
                .tint(.indigo)
            }
        }
    }

    /// Every action a single row offers, gated exactly as the swipe actions are
    /// — on the links the server returned for that project.
    @ViewBuilder
    private func projectMenu(for project: Project) -> some View {
        Section {
            if project.hasLink(.update) {
                Button {
                    renamingProject = project
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            }
            if project.hasLink(.toggleDefault) {
                Button {
                    Task { await model.toggleDefault(project) }
                } label: {
                    Label(project.isDefault ?? false ? "Remove as Default" : "Set as Default",
                          systemImage: project.isDefault ?? false ? "star.slash" : "star")
                }
            }
            // Only an editor is offered the picker — the server advertises
            // `projectTeams` on that gate, so a reader's row shows nothing here.
            if project.hasLink(.projectTeams) {
                Button {
                    assigningTeamsProject = project
                } label: {
                    Label("Teams…", systemImage: "person.2")
                }
            }
        }
        // One screenplay's own archive, without the detour through edit mode and
        // a single tick — the ids query the bundle export already accepts.
        if model.canExportAll {
            Section {
                Button {
                    download(ids: [project.id], named: project.displayTitle)
                } label: {
                    Label("Export Screenplay", systemImage: "square.and.arrow.up")
                }
                .disabled(isExportingProjects)
            }
        }
        if project.hasLink(.delete) {
            Section {
                Button(role: .destructive) {
                    Task {
                        if selection == project.id { selection = nil }
                        await model.delete(project)
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    /// The selection in list order, so a bundle of several reads in the order
    /// the list was showing rather than the order rows happened to be tapped.
    private var selectedProjects: [Project] {
        displayedProjects.filter { exportSelection.contains($0.id) }
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
                        projectRow(for: project).tag(project.id)
                    }
                }
            }
        }
        .onChange(of: editMode) { _, mode in
            if !mode.isEditing { exportSelection.removeAll() }
        }
        .overlay {
            if model.projects.isEmpty {
                if model.isLoading {
                    ProgressView()
                } else {
                    // The one thing to do from here is the one thing the empty
                    // state should offer, so the sentence and the button that
                    // answers it sit together.
                    ContentUnavailableView {
                        Label("No projects yet", systemImage: "film")
                    } description: {
                        Text("Create your first screenplay to get started.")
                    } actions: {
                        Button {
                            showingCreate = true
                        } label: {
                            Label("New Project", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } else if displayedProjects.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .navigationTitle("Projects")
        .navigationSubtitle(countSubtitle)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search projects")
        .refreshable { await model.refresh() }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                offlineFooter
                newProjectBar
            }
        }
        // The connection is back — trade the offline copy for the real list.
        .onChange(of: app.connectivity.isOnline) { _, online in
            guard online else { return }
            Task { await model.refresh() }
        }
        .toolbar { toolbar }
        // Outside the toolbar, not inside: an environment value only reaches
        // the subtree below the modifier that sets it, so a binding installed
        // under the toolbar would leave the rows reading an edit mode nobody
        // is setting.
        .environment(\.editMode, $editMode)
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
                guard let created = await model.createProject(title: title) else { return false }
                // Naming a screenplay is the writer asking to start writing it,
                // so open it rather than leaving them to find the new row.
                selection = created.id
                return true
            }
        }
        .sheet(item: $renamingProject) { project in
            ProjectTitleSheet(title: project.title ?? "", heading: "Rename Project") { title in
                await model.rename(project, to: title)
            }
        }
        .sheet(item: $assigningTeamsProject) { project in
            ProjectTeamsSheet(model: model, project: project)
        }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.json],
                      allowsMultipleSelection: false) { result in
            if case let .failure(error) = result {
                model.errorMessage = error.localizedDescription
                return
            }
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

    /// The primary action, and now the only standing one: the toolbar's "+" was
    /// a glyph whose meaning you have to already know, sitting in the corner
    /// furthest from the thumb, saying exactly what this says. This names the
    /// action, stays put as the list scrolls, and is the only place it appears
    /// once the empty state stops being shown — which is from the writer's very
    /// first screenplay onwards.
    ///
    /// Drawn here rather than as a `.bottomBar` toolbar item, which is where it
    /// started: a bar item built from a `Label` shows the glyph and drops the
    /// title even under `.titleAndIcon`, and inside the iPad's sidebar column a
    /// prominent one loses its fill and leaves white text on a white bar. An
    /// inset is drawn by SwiftUI rather than bridged into a `UIBarButtonItem`,
    /// so neither happens, and it stacks with the offline footer instead of
    /// competing with it for the same edge.
    ///
    /// Edit mode hides it: that list is answering which screenplays to export,
    /// and starting a new one is not an answer to it. It is deliberately *not*
    /// also hidden behind an empty list, even though the empty state offers the
    /// same button: a bottom inset that starts out empty is never installed at
    /// all, so gating on the list having loaded leaves the bar missing for the
    /// rest of the session.
    @ViewBuilder
    private var newProjectBar: some View {
        if !editMode.isEditing {
            Button {
                showingCreate = true
            } label: {
                Label("New Project", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            // No background of its own: the host mounts it with `.safeAreaBar`,
            // so the button is already floating on Liquid Glass, and a `.bar`
            // fill under it draws a second, flatter surface on top of that one.
        }
    }

    /// Says the list on screen is the copy saved on this device, and how old
    /// it is — an out-of-date list should not look current. Only shown when
    /// the fallback actually happened, not merely because the radio is off.
    @ViewBuilder
    private var offlineFooter: some View {
        if let savedAt = model.offlineCopySavedAt {
            HStack(spacing: 6) {
                Image(systemName: "wifi.slash")
                    .font(.caption)
                Text("Offline — projects saved "
                     + savedAt.formatted(.relative(presentation: .named)))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Offline. Showing the projects saved on this device "
                                + savedAt.formatted(.relative(presentation: .named)) + ".")
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
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

    /// Blank-safe reads of the title-page fields: the server omits nulls but
    /// happily stores an empty string, and a row must not sprout a line for one.
    private func present(_ field: String?) -> String? {
        guard let value = field?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private var writers: String? { present(project.writers) }
    private var version: String? { present(project.screenplayVersion) }
    private var teams: [String] { (project.teams ?? []).compactMap(present) }

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
                // One VoiceOver stop for the whole description rather than four
                // — but only over the text, so the star stays its own control.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityDescription)
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
                    badge("Default")
                }
            }
            // Who wrote it — the title page's own second line, and the one
            // field that tells two drafts of a shared premise apart.
            if let writers {
                Text(writers)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
                if let version {
                    if project.lastEdited != nil {
                        Text("·")
                    }
                    Text(version)
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            // Teams were a comma list sharing the date's line, which read as
            // more dates. As capsules they read as what they are — labels the
            // project carries — and they stay on one line: a project on five
            // teams should not make a row three times the height of its
            // neighbours.
            if !teams.isEmpty {
                HStack(spacing: 4) {
                    ForEach(teams.prefix(2), id: \.self) { team in
                        badge(team, tinted: false)
                    }
                    if teams.count > 2 {
                        badge("+\(teams.count - 2)", tinted: false)
                    }
                }
                .lineLimit(1)
            }
        }
    }

    /// The Default pill and the team pills, which differ only in colour: the
    /// tinted one is a state the writer set, the grey ones are facts about
    /// who the project is shared with.
    private func badge(_ text: String, tinted: Bool = true) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tinted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tinted ? AnyShapeStyle(.tint.opacity(0.15))
                               : AnyShapeStyle(.quaternary),
                        in: Capsule())
            .lineLimit(1)
    }

    /// Spelled out rather than combined from the labels above, because the
    /// visible row leans on layout ("·", capsules) that reads as nothing aloud,
    /// and because the truncated "+3" would be announced as literally that.
    private var accessibilityDescription: String {
        var parts = [project.displayTitle]
        if isDefault { parts.append("Default project") }
        if let writers { parts.append("Written by \(writers)") }
        if let version { parts.append(version) }
        if let lastEdited = project.lastEdited {
            parts.append("Edited " + lastEdited.formatted(.relative(presentation: .named)))
        }
        if !teams.isEmpty {
            parts.append((teams.count == 1 ? "Team: " : "Teams: ") + teams.joined(separator: ", "))
        }
        return parts.joined(separator: ". ")
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

/// The per-project team assignment: the web production page's "Teams"
/// checkboxes. Lists every team the writer could assign the project to (from
/// `projectTeams`), ticks the ones it belongs to now, and saves the ticked ids
/// back through the project's `update` affordance.
///
/// Saving with nothing ticked is allowed on purpose: unlike an actor, which is
/// only reachable through a project's cast, a project with no teams is still
/// reached from the writer's own list, so leaving it teamless is a real choice
/// (it just cannot take collaborators until a team is added).
private struct ProjectTeamsSheet: View {
    let model: ProjectListModel
    let project: Project

    @Environment(\.dismiss) private var dismiss
    @State private var options: [ProjectTeamOption] = []
    @State private var selected: Set<Int> = []
    @State private var isLoading = true
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if options.isEmpty {
                    Section {
                        Text("No teams yet.")
                        Text("Create a team from the sidebar's Teams screen to share this screenplay with collaborators.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(options) { option in
                            Toggle(option.name, isOn: binding(for: option.id))
                        }
                    } header: {
                        Text("Teams")
                    } footer: {
                        Text("This screenplay appears in casting and sharing for each selected team.")
                    }
                }
            }
            .navigationTitle("Teams")
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
                            .disabled(isLoading)
                    }
                }
            }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func binding(for id: Int) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { isOn in
                if isOn { selected.insert(id) } else { selected.remove(id) }
            }
        )
    }

    private func load() async {
        let loaded = await model.loadProjectTeams(project) ?? []
        options = loaded
        selected = Set(loaded.filter(\.assigned).map(\.id))
        isLoading = false
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            let succeeded = await model.updateProjectTeams(project, teamIds: selected.sorted())
            isSaving = false
            if succeeded { dismiss() }
        }
    }
}
