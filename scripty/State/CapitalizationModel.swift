//
//  CapitalizationModel.swift
//  scripty
//
//  Loads and edits the user's auto-capitalization preferences.
//
//  Shared rather than one per script: the preference belongs to the writer,
//  not the screenplay, and every open editor has to agree about whether it is
//  typing scene headings in capitals. Loaded once per session from the link
//  the API root advertises; a server that does not offer it leaves the
//  defaults in place and shows no settings entry.
//

import Foundation
import Observation

@Observable @MainActor
final class CapitalizationModel {
    /// Optimistic until the server answers, and the historic behaviour if it
    /// never does — an element must not start lowercase and jump to capitals
    /// when a request lands mid-sentence.
    private(set) var preferences: CapitalizationPreferences = .all
    private(set) var isLoaded = false
    var errorMessage: String?

    private let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    /// True when the server advertised the preferences resource at all.
    var isAvailable: Bool { app.apiRoot?.hasLink(.capitalizationPreferences) ?? false }

    /// True when it also offered a way to change them — a reader gets the
    /// values applied but no switches to flip.
    var canEdit: Bool { preferences.hasLink(.update) }

    func load() async {
        guard !isLoaded, let link = app.apiRoot?.link(.capitalizationPreferences) else { return }
        do {
            preferences = try await app.client.fetch(CapitalizationPreferences.self, from: link)
            isLoaded = true
            errorMessage = nil
        } catch {
            // Non-fatal: the defaults are the historic behaviour, so a failure
            // here costs the writer their preference, not their script.
            errorMessage = error.localizedDescription
        }
    }

    /// Flip one element type. Shows the new state immediately and rolls back if
    /// the server refuses — a switch that stays where it was put and silently
    /// means the opposite is worse than one that visibly springs back.
    func setCapitalization(_ type: BlockType, to value: Bool) async {
        guard let link = preferences.link(.update) else { return }
        let previous = preferences
        preferences = preferences.setting(type, to: value)
        do {
            preferences = try await app.client.fetch(
                CapitalizationPreferences.self, from: link, method: "POST",
                body: CapitalizationUpdate(type, value))
            errorMessage = nil
        } catch {
            preferences = previous
            app.handle(error)
            errorMessage = error.localizedDescription
        }
    }
}
