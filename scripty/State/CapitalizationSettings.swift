//
//  CapitalizationSettings.swift
//  scripty
//
//  Per-element auto-capitalization: whether scene headings, character cues,
//  transitions and shots are typed in ALL CAPS. The web app's counterpart is
//  auto-caps-toggle.js.
//
//  Unlike the presentation settings next door, this one is stored on the
//  server. Exports (PDF/DOCX/EPUB/FDX/Fountain) bake the case into the file, so
//  the server has to know the writer's choice; a device-only toggle would make
//  the export disagree with the editor. UserDefaults is kept only as an
//  optimistic mirror — under the web's own localStorage key — so the editor
//  renders correctly before the fetch lands, exactly as the web does.
//

import Foundation
import Observation

@Observable
@MainActor
final class CapitalizationSettings {
    /// Shared because the editor reads it per line while the settings sheet
    /// writes it — the same reason `PresentationSettings` is shared.
    static let shared = CapitalizationSettings()

    /// All four on is the historic behavior, and the default the server falls
    /// back to, so a fresh account reads the same as it always did.
    private(set) var enabled: [CapitalizedElement: Bool] =
        Dictionary(uniqueKeysWithValues: CapitalizedElement.allCases.map { ($0, true) })

    /// Present only once the root advertised the preference and it loaded; the
    /// settings entry is gated on it so the toggles never post to nowhere.
    private(set) var updateLink: HALLink?

    /// The web's localStorage key, reused so the intent is traceable and a
    /// writer moving between the clients on the same device sees no jump.
    private let cacheKey = "scripty-auto-caps"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let cached = readCache() { enabled = cached }
    }

    func isOn(_ element: CapitalizedElement) -> Bool { enabled[element] ?? true }

    /// Whether the given element type is typed in caps. Dual dialogue is a
    /// character cue, so it follows the character toggle; anything without a
    /// matching preference is never forced to caps.
    func isOn(forBlockType type: BlockType) -> Bool {
        guard let element = Self.element(for: type) else { return false }
        return isOn(element)
    }

    /// The case a rendered element should show: the per-type uppercase the
    /// web performs with a CSS `text-transform`, applied only where the
    /// preference is on. The read-only surfaces (Page View, the reader, locked
    /// rows) call this instead of forcing `.uppercased()`, so a toggled-off
    /// element reads in its typed case there the way it already does in the
    /// editor — the editor bakes the case as you type, these views cannot, so
    /// they transform on display instead. Read from a SwiftUI `body` so
    /// flipping a toggle redraws every visible line.
    func displayCased(_ content: String, forBlockType type: BlockType) -> String {
        isOn(forBlockType: type) ? content.uppercased() : content
    }

    static func element(for type: BlockType) -> CapitalizedElement? {
        switch type {
        case .scene: return .scene
        case .character, .dualDialogue: return .character
        case .transition: return .transition
        case .shot: return .shot
        default: return nil
        }
    }

    /// Reads the stored preference from the link the root advertised. Failures
    /// are quiet: the cache (or the all-on default) is already showing, and a
    /// preference that would not load is not worth an alert on the projects list.
    func load(using client: APIClient, from link: HALLink) async {
        do {
            let prefs: CapitalizationPreferences = try await client.fetch(from: link)
            apply(prefs.values)
            updateLink = prefs.link(.update) ?? prefs.link(.selfRel) ?? link
            writeCache()
        } catch {
            // Keep whatever the cache gave us; leave updateLink nil so the sheet
            // stays hidden rather than offering a control that cannot persist.
        }
    }

    /// Flips one element and persists just that field — a partial POST, so two
    /// quick toggles never race to overwrite each other's other fields. Reverts
    /// on failure so the editor never disagrees with what the server stored.
    func set(_ element: CapitalizedElement, on: Bool, using client: APIClient) async {
        guard let link = updateLink else { return }
        let previous = enabled[element] ?? true
        guard previous != on else { return }
        enabled[element] = on
        writeCache()
        do {
            let prefs: CapitalizationPreferences = try await client.fetch(
                from: link, method: "POST",
                body: CapitalizationPreferences.Update(element: element, on: on))
            apply(prefs.values)
            writeCache()
        } catch {
            enabled[element] = previous
            writeCache()
        }
    }

    /// Signing out returns to the all-on default and drops the link, so the next
    /// account starts clean rather than inheriting the last one's toggles.
    func reset() {
        enabled = Dictionary(uniqueKeysWithValues: CapitalizedElement.allCases.map { ($0, true) })
        updateLink = nil
        defaults.removeObject(forKey: cacheKey)
    }

    // MARK: - Storage

    private func apply(_ values: [CapitalizedElement: Bool]) {
        for element in CapitalizedElement.allCases {
            if let value = values[element] { enabled[element] = value }
        }
    }

    private func writeCache() {
        let raw = Dictionary(uniqueKeysWithValues: enabled.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONSerialization.data(withJSONObject: raw) {
            defaults.set(data, forKey: cacheKey)
        }
    }

    private func readCache() -> [CapitalizedElement: Bool]? {
        guard let data = defaults.data(forKey: cacheKey),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Bool]
        else { return nil }
        var result: [CapitalizedElement: Bool] = [:]
        for element in CapitalizedElement.allCases {
            if let value = raw[element.rawValue] { result[element] = value }
        }
        return result.isEmpty ? nil : result
    }
}
