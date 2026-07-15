//
//  ThemeSetting.swift
//  scripty
//
//  Mirrors the web user menu's Theme control (Light / Dark / System). The
//  choice is a pure client-side appearance preference — persisted locally and
//  applied app-wide via `preferredColorScheme` — so it works signed out of a
//  server and in demo mode alike.
//

import SwiftUI

enum ThemeSetting: String, CaseIterable, Identifiable, Sendable {
    case light
    case dark
    case system

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "System"
        }
    }

    var symbol: String {
        switch self {
        case .light: return "sun.max"
        case .dark: return "moon"
        case .system: return "circle.lefthalf.filled"
        }
    }

    /// The scheme to force, or `nil` for "follow the system" — the value fed to
    /// `.preferredColorScheme`.
    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }
}
