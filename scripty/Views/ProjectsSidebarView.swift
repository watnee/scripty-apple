//
//  ProjectsSidebarView.swift
//  scripty
//

import SwiftUI

struct ProjectsSidebarView: View {
    let app: AppModel
    let model: ProjectListModel
    @Binding var selection: Project?

    @State private var showingCreate = false
    @State private var renamingProject: Project?
    @State private var showingPasskeys = false

    var body: some View {
        List(selection: $selection) {
            if app.isDemo {
                DemoBanner()
            }
            ForEach(model.projects) { project in
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
                        "No Projects",
                        systemImage: "film",
                        description: Text("Create a project to start writing."))
                }
            }
        }
        .navigationTitle("Projects")
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
                Menu {
                    if !app.isDemo {
                        Button {
                            showingPasskeys = true
                        } label: {
                            Label("Passkeys", systemImage: "person.badge.key")
                        }
                    }
                    Button(role: .destructive) {
                        app.signOut()
                    } label: {
                        Label(app.isDemo ? "Exit Demo" : "Sign Out",
                              systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    Label("Account", systemImage: "person.crop.circle")
                }
            }
        }
        .sheet(isPresented: $showingPasskeys) {
            PasskeysView(app: app)
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
                    Text(lastEdited, format: .relative(presentation: .named))
                }
                if let teams = project.teams, !teams.isEmpty {
                    Text("·")
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
