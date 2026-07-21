//
//  CharactersView.swift
//  scripty
//

import SwiftUI

struct CharactersView: View {
    let model: ScriptModel

    @Environment(\.dismiss) private var dismiss
    @State private var editingPerson: Person?
    @State private var showingCreate = false
    @State private var showingActors = false
    /// Owns the project's cast so both the Casting screen and the per-character
    /// picker read the same list. Hidden entirely when the server doesn't
    /// advertise actors or answers 403 for them.
    @State private var casting: CastingModel

    init(model: ScriptModel) {
        self.model = model
        _casting = State(initialValue: CastingModel(app: model.app, project: model.project))
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.characters) { person in
                    Button {
                        if person.hasLink(.update) {
                            editingPerson = person
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(person.displayName)
                                .font(.headline)
                            HStack(spacing: 6) {
                                if let fullName = person.fullName, fullName != person.name {
                                    Text(fullName)
                                }
                                if let actorName = castName(for: person) {
                                    Text("· played by \(actorName)")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                    .swipeActions(edge: .trailing) {
                        if person.hasLink(.delete) {
                            Button(role: .destructive) {
                                Task { await model.deleteCharacter(person) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .overlay {
                if model.characters.isEmpty {
                    ContentUnavailableView(
                        "No Characters",
                        systemImage: "person.2",
                        description: Text("Add characters to link them to dialogue."))
                }
            }
            .navigationTitle("Characters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if casting.isAvailable {
                        Button {
                            showingActors = true
                        } label: {
                            Label("Casting", systemImage: "person.crop.rectangle.stack")
                        }
                    }
                    Button {
                        showingCreate = true
                    } label: {
                        Label("New Character", systemImage: "plus")
                    }
                }
            }
            .task { await casting.loadIfNeeded() }
            .sheet(isPresented: $showingCreate) {
                CharacterEditorSheet(model: model, casting: casting, person: nil)
            }
            .sheet(item: $editingPerson) { person in
                CharacterEditorSheet(model: model, casting: casting, person: person)
            }
            .sheet(isPresented: $showingActors) {
                ActorsView(casting: casting, characters: model.characters)
            }
        }
    }

    /// Prefer the name the server sent with the character; fall back to the
    /// loaded cast so a just-changed assignment shows before the next reload.
    private func castName(for person: Person) -> String? {
        person.actorName ?? casting.actor(id: person.actorId)?.displayName
    }
}

private struct CharacterEditorSheet: View {
    let model: ScriptModel
    let casting: CastingModel
    let person: Person?   // nil = create

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var fullName: String
    /// nil = "Not cast".
    @State private var actorId: Int?
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(model: ScriptModel, casting: CastingModel, person: Person?) {
        self.model = model
        self.casting = casting
        self.person = person
        _name = State(initialValue: person?.name ?? "")
        _fullName = State(initialValue: person?.fullName ?? "")
        _actorId = State(initialValue: person?.actorId)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !fullName.trimmingCharacters(in: .whitespaces).isEmpty
            && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name (as written in script)", text: $name)
                TextField("Full name", text: $fullName)
                if casting.isAvailable {
                    Picker("Cast", selection: $actorId) {
                        Text("Not cast").tag(Int?.none)
                        ForEach(casting.actors) { actor in
                            Text(actor.displayName).tag(Int?.some(actor.id))
                        }
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(person == nil ? "New Character" : "Edit Character")
            .navigationBarTitleDisplayMode(.inline)
            .task { await casting.loadIfNeeded() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                            .disabled(!canSave)
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        errorMessage = nil
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedFullName = fullName.trimmingCharacters(in: .whitespaces)
        Task {
            // A nil actorId clears the casting; when the section is unavailable
            // we pass the existing assignment straight back through.
            let cast = casting.isAvailable ? actorId : person?.actorId
            let succeeded: Bool
            if let person {
                succeeded = await model.updateCharacter(person, name: trimmedName,
                                                        fullName: trimmedFullName, actorId: cast)
            } else {
                succeeded = await model.createCharacter(name: trimmedName,
                                                        fullName: trimmedFullName, actorId: cast)
            }
            isSaving = false
            if succeeded {
                dismiss()
            } else {
                errorMessage = model.errorMessage
            }
        }
    }
}
