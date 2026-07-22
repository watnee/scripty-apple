//
//  AppearanceSettings.swift
//  scripty
//
//  Light, dark, or whatever the device is doing. The web app puts this in the
//  account dropdown and keeps it in localStorage under `theme`, so this uses
//  the same key and the same three values.
//
//  A device preference rather than a server one, like everything else about
//  presentation: the same account is read on a bright rehearsal-room iPad and
//  in a dark editing suite, and only one of those wants a dark script.
//
//  Deliberately Foundation-only — the mapping to a SwiftUI `ColorScheme` lives
//  with the view that applies it, which keeps the choice itself testable.
//

import Foundation
import Observation

@Observable
@MainActor
final class AppearanceSettings {
    /// Shared: the choice colours the whole app, not one script.
    static let shared = AppearanceSettings()

    /// The three the web offers, spelled the way it stores them.
    enum Appearance: String, CaseIterable, Identifiable, Sendable {
        case system
        case light
        case dark

        var id: String { rawValue }

        var label: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }

        var systemImage: String {
            switch self {
            case .system: return "circle.lefthalf.filled"
            case .light: return "sun.max"
            case .dark: return "moon"
            }
        }
    }

    var appearance: Appearance {
        didSet {
            guard appearance != oldValue else { return }
            defaults.set(appearance.rawValue, forKey: Key.theme)
        }
    }

    // MARK: - Storage

    /// The web app's key, unprefixed exactly as it is there.
    private enum Key {
        static let theme = "theme"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Anything unrecognised — or nothing at all — means "follow the device",
        // which is what the web's `localStorage.getItem('theme') || 'system'`
        // amounts to.
        let stored = defaults.string(forKey: Key.theme)
        appearance = stored.flatMap(Appearance.init(rawValue:)) ?? .system
    }
}
