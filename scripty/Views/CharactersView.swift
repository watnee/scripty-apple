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
                                if let actorName = person.actorName {
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
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingCreate = true
                    } label: {
                        Label("New Character", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingCreate) {
                CharacterEditorSheet(model: model, person: nil)
            }
            .sheet(item: $editingPerson) { person in
                CharacterEditorSheet(model: model, person: person)
            }
        }
    }
}

private struct CharacterEditorSheet: View {
    let model: ScriptModel
    let person: Person?   // nil = create

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var fullName: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(model: ScriptModel, person: Person?) {
        self.model = model
        self.person = person
        _name = State(initialValue: person?.name ?? "")
        _fullName = State(initialValue: person?.fullName ?? "")
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
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(person == nil ? "New Character" : "Edit Character")
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
            let succeeded: Bool
            if let person {
                succeeded = await model.updateCharacter(person, name: trimmedName, fullName: trimmedFullName)
            } else {
                succeeded = await model.createCharacter(name: trimmedName, fullName: trimmedFullName)
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
