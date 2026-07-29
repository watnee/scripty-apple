//
//  ScriptModel+Casting.swift
//  scripty
//
//  Character writes that also set the casting. The base model's character
//  methods preserve whatever actor was already assigned; these take the
//  assignment as an argument so the editor can change it — a nil actorId
//  clears the casting.
//

import Foundation

extension ScriptModel {
    @discardableResult
    func createCharacter(name: String, fullName: String, actorId: Int?) async -> Bool {
        guard let link = charactersLinks[.selfRel] ?? project.link(.characters) else { return false }
        do {
            let _: Person = try await app.client.fetch(
                from: link, method: "POST",
                body: CreatePersonCommand(name: name, fullName: fullName,
                                          actorId: actorId, projectId: project.id))
            await loadCharacters()
            errorMessage = nil
            return true
        } catch {
            reportCasting(error)
            return false
        }
    }

    @discardableResult
    func updateCharacter(_ person: Person, name: String, fullName: String, actorId: Int?) async -> Bool {
        guard let link = person.link(.update) else { return false }
        do {
            let _: Person = try await app.client.fetch(
                from: link, method: "PUT",
                body: EditPersonCommand(name: name, fullName: fullName,
                                        actorId: actorId, projectId: person.projectId))
            await loadCharacters()
            await loadBlocks()   // dialogue rows show personName
            errorMessage = nil
            return true
        } catch {
            reportCasting(error)
            return false
        }
    }

    /// The base model's `report` is private; this is the same routing.
    private func reportCasting(_ error: Error) {
        // Nothing cancelled is ever shown — see `isCancelledRequest`.
        guard !error.isCancelledRequest else { return }
        app.handle(error)
        errorMessage = error.localizedDescription
    }
}
