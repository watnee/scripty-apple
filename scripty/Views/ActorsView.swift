//
//  ActorsView.swift
//  scripty
//
//  The cast list for a project — the iPad counterpart of the web app's
//  Casting screen. Add, edit and remove actors, each row showing the
//  headshot the server holds. Every affordance is gated on the links the
//  server advertised.
//

import SwiftUI

struct ActorsView: View {
    let casting: CastingModel
    /// The project's characters, used to name and pick auditions. Empty when the
    /// caller has none to offer, which also hides the audition affordances.
    var characters: [Person] = []

    @Environment(\.dismiss) private var dismiss
    @State private var editingActor: ScriptyActor?
    @State private var auditioningActor: ScriptyActor?
    @State private var showingCreate = false
    @State private var searchText = ""

    private var shown: [ScriptyActor] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return casting.actors }
        return casting.actors.filter { actor in
            [actor.displayName, actor.email ?? "", actor.phone ?? ""]
                .contains { $0.lowercased().contains(query) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(shown) { actor in
                    row(for: actor)
                }
            }
            .overlay { emptyState }
            .searchable(text: $searchText, prompt: "Search cast")
            .navigationTitle("Casting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .task { await casting.load() }
            .refreshable { await casting.load() }
            .sheet(isPresented: $showingCreate) {
                ActorEditorSheet(casting: casting, actor: nil)
            }
            .sheet(item: $editingActor) { actor in
                ActorEditorSheet(casting: casting, actor: actor)
            }
            .sheet(item: $auditioningActor) { actor in
                AuditionPickerSheet(casting: casting, actor: actor, characters: characters)
            }
            .alert("Casting", isPresented: errorBinding) {
                Button("OK", role: .cancel) { casting.errorMessage = nil }
            } message: {
                Text(casting.errorMessage ?? "")
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for actor: ScriptyActor) -> some View {
        Button {
            if actor.hasLink(.update) {
                editingActor = actor
            }
        } label: {
            HStack(spacing: 12) {
                HeadshotThumbnail(casting: casting, actor: actor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(actor.displayName)
                        .font(.headline)
                    if let contact = actor.contactLine {
                        Text(contact)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let line = auditionLine(for: actor) {
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .foregroundStyle(.primary)
        .swipeActions(edge: .leading) {
            if canAudition(actor) {
                Button {
                    auditioningActor = actor
                } label: {
                    Label("Auditions", systemImage: "theatermasks")
                }
                .tint(.purple)
            }
        }
        .swipeActions(edge: .trailing) {
            if actor.hasLink(.delete) {
                Button(role: .destructive) {
                    Task { await casting.deleteActor(actor) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .contextMenu {
            if canAudition(actor) {
                Button {
                    auditioningActor = actor
                } label: {
                    Label("Auditions…", systemImage: "theatermasks")
                }
            }
        }
    }

    /// The server offers auditions on the actor, and the caller gave us
    /// characters to pick from.
    private func canAudition(_ actor: ScriptyActor) -> Bool {
        actor.canSetAuditions && !characters.isEmpty
    }

    /// "Auditioning for MAYA, DEV" — the character names this actor is trying
    /// out for, or nil when there are none to show.
    private func auditionLine(for actor: ScriptyActor) -> String? {
        let ids = actor.auditionCharacterIds ?? []
        guard !ids.isEmpty else { return nil }
        let names = characters
            .filter { ids.contains($0.id) }
            .map(\.displayName)
        guard !names.isEmpty else { return nil }
        return "Auditioning for " + names.joined(separator: ", ")
    }

    @ViewBuilder
    private var emptyState: some View {
        if shown.isEmpty {
            if casting.isLoading {
                ProgressView()
            } else if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                ContentUnavailableView(
                    "No Actors",
                    systemImage: "person.crop.rectangle.stack",
                    description: Text(casting.canCreate
                        ? "Add an actor to start casting your characters."
                        : "Nobody has been added to this project's cast."))
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }
        if casting.canCreate {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingCreate = true
                } label: {
                    Label("New Actor", systemImage: "plus")
                }
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { casting.errorMessage != nil },
                set: { if !$0 { casting.errorMessage = nil } })
    }
}

/// Picks which characters an actor auditions for. Starts from what they audition
/// for now, and sends the whole set back — the server replaces it wholesale.
private struct AuditionPickerSheet: View {
    let casting: CastingModel
    let actor: ScriptyActor
    let characters: [Person]

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<Int> = []
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            List {
                if characters.isEmpty {
                    Text("This project has no characters to audition for yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(characters) { character in
                    Button {
                        toggle(character.id)
                    } label: {
                        HStack {
                            Text(character.displayName)
                                .foregroundStyle(.primary)
                            Spacer()
                            if selected.contains(character.id) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Auditions")
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
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                Text(actor.displayName)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 4)
            }
            .onAppear { selected = Set(actor.auditionCharacterIds ?? []) }
        }
    }

    private func toggle(_ id: Int) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }

    private func save() {
        isSaving = true
        Task {
            let ok = await casting.setAuditions(actor, characterIds: Array(selected))
            isSaving = false
            if ok { dismiss() }
        }
    }
}

/// A small round headshot, or the silhouette placeholder while it loads or
/// when the actor has no image on file.
struct HeadshotThumbnail: View {
    let casting: CastingModel
    let actor: ScriptyActor
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let data = casting.headshotData(for: actor),
               let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.circle")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .task(id: actor.id) { await casting.loadHeadshot(for: actor) }
    }
}
