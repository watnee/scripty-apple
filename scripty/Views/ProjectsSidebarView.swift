//
//  ProjectsSidebarView.swift
//  scripty
//

import SwiftUI

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
    @State private var renamingProject: Project?
    @State private var searchText = ""
    @AppStorage("projectListSort") private var sortMode = ProjectSort.lastEdited

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

    var body: some View {
        List(selection: $selection) {
            if app.isDemo {
                DemoBanner()
            }
            ForEach(displayedProjects) { project in
                ProjectRow(project: project)
                    .tag(project)
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingCreate = true
                } label: {
                    Label("New Project", systemImage: "plus")
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
            ToolbarItem(placement: .secondaryAction) {
                Button(role: .destructive) {
                    app.signOut()
                } label: {
                    Label(app.isDemo ? "Exit Demo" : "Sign Out",
                          systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(project.displayTitle)
                .font(.headline)
                .lineLimit(1)
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
        .padding(.vertical, 2)
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
