//
//  PresentationSettings.swift
//  scripty
//
//  How the script is presented rather than what it says: page view, focus
//  mode, type size, zoom and page setup. These are the iPad counterparts of
//  the web app's localStorage-backed view preferences, and they use the same
//  keys and the same defaults so a writer moving between the two finds the
//  script looking the way they left it.
//
//  Deliberately a device preference, not a server one — the web app never
//  syncs these either, and a phone wants a different type size than a desk.
//

import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class PresentationSettings {
    /// Shared because every surface — editor, page view, reader — reads the
    /// same type size and page setup.
    static let shared = PresentationSettings()

    // MARK: - Type size

    static let defaultTextSize = 100
    static let minTextSize = 80
    static let maxTextSize = 200
    static let textSizeStep = 10

    /// Percentage, 80–200 in steps of ten.
    ///
    /// The range is enforced by the mutators below and by `init`, *not* by
    /// this `didSet`. Assigning to a property inside its own `didSet` recurses
    /// under `@Observable` — the generated setter re-enters the observer — and
    /// the clamp that used to live here ran until the stack ran out. Pressing
    /// Bigger or Smaller crashed the app outright.
    private(set) var textSize: Int {
        didSet {
            guard textSize != oldValue else { return }
            defaults.set(textSize, forKey: Key.textSize)
        }
    }

    /// Multiplier the views apply to their base point sizes.
    var textScale: Double { Double(textSize) / 100.0 }

    var canIncreaseTextSize: Bool { textSize < Self.maxTextSize }
    var canDecreaseTextSize: Bool { textSize > Self.minTextSize }

    func increaseTextSize() { setTextSize(textSize + Self.textSizeStep) }
    func decreaseTextSize() { setTextSize(textSize - Self.textSizeStep) }
    func resetTextSize() { setTextSize(Self.defaultTextSize) }

    /// The one way in, so the bounds are applied exactly once per change.
    private func setTextSize(_ value: Int) {
        textSize = min(Self.maxTextSize, max(Self.minTextSize, value))
    }

    // MARK: - Modes

    /// Renders the script as discrete paper sheets instead of one column.
    var isPageView: Bool {
        didSet {
            guard isPageView != oldValue else { return }
            defaults.set(isPageView, forKey: Key.pageView)
        }
    }

    /// Hides everything but the writing surface.
    var isFocusMode: Bool {
        didSet {
            guard isFocusMode != oldValue else { return }
            defaults.set(isFocusMode, forKey: Key.focusMode)
        }
    }

    /// Shows a running word count while writing.
    var showsWordCount: Bool {
        didSet {
            guard showsWordCount != oldValue else { return }
            defaults.set(showsWordCount, forKey: Key.wordCount)
        }
    }

    /// Names each element's type down the margin.
    var showsElementLabels: Bool {
        didSet {
            guard showsElementLabels != oldValue else { return }
            defaults.set(showsElementLabels, forKey: Key.elementLabels)
        }
    }

    // MARK: - Appearance

    /// Light, dark, or whatever the device is doing.
    ///
    /// A device-wide setting like the rest of this class, and stored under the
    /// web app's key so a writer who picked dark there finds it dark here.
    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark

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

        /// Nil means "follow the device", which is what SwiftUI wants.
        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    var appearance: Appearance {
        didSet {
            guard appearance != oldValue else { return }
            defaults.set(appearance.rawValue, forKey: Key.appearance)
        }
    }

    // MARK: - Zoom

    static let defaultZoom = 100
    static let minZoom = 50
    static let maxZoom = 200
    static let zoomStep = 10

    /// Scales the sheet in page view without changing the type size relative
    /// to the page — the sheet and its contents zoom together.
    ///
    /// Clamped by its mutators rather than by `didSet`, for the same reason
    /// `textSize` is.
    private(set) var pageZoom: Int {
        didSet {
            guard pageZoom != oldValue else { return }
            defaults.set(pageZoom, forKey: Key.pageZoom)
        }
    }

    var zoomScale: Double { Double(pageZoom) / 100.0 }
    var canZoomIn: Bool { pageZoom < Self.maxZoom }
    var canZoomOut: Bool { pageZoom > Self.minZoom }

    func zoomIn() { setPageZoom(pageZoom + Self.zoomStep) }
    func zoomOut() { setPageZoom(pageZoom - Self.zoomStep) }
    func resetZoom() { setPageZoom(Self.defaultZoom) }

    private func setPageZoom(_ value: Int) {
        pageZoom = min(Self.maxZoom, max(Self.minZoom, value))
    }

    // MARK: - Page setup

    var pageSetup: PageSetup {
        didSet {
            guard pageSetup != oldValue else { return }
            if let data = try? JSONEncoder().encode(pageSetup) {
                defaults.set(data, forKey: Key.pageSetup)
            }
        }
    }

    func resetPageSetup() { pageSetup = .default }

    // MARK: - Storage

    /// The web app's localStorage keys, reused so the intent is traceable.
    private enum Key {
        static let textSize = "scripty-text-size"
        static let pageView = "scripty-page-view-mode"
        static let focusMode = "scripty-focus-mode"
        static let pageZoom = "scripty-page-zoom"
        static let pageSetup = "scripty-page-setup"
        static let wordCount = "scripty-word-count"
        static let elementLabels = "scripty-element-labels"
        static let appearance = "scripty-theme"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // `object(forKey:)` distinguishes "never set" from "set to zero", so a
        // first run gets the documented defaults rather than a 0% type size.
        let storedTextSize = defaults.object(forKey: Key.textSize) as? Int
        textSize = min(Self.maxTextSize,
                       max(Self.minTextSize, storedTextSize ?? Self.defaultTextSize))

        let storedZoom = defaults.object(forKey: Key.pageZoom) as? Int
        pageZoom = min(Self.maxZoom, max(Self.minZoom, storedZoom ?? Self.defaultZoom))

        isPageView = defaults.bool(forKey: Key.pageView)
        isFocusMode = defaults.bool(forKey: Key.focusMode)
        showsWordCount = defaults.bool(forKey: Key.wordCount)
        showsElementLabels = defaults.bool(forKey: Key.elementLabels)
        appearance = (defaults.string(forKey: Key.appearance)
            .flatMap(Appearance.init(rawValue:))) ?? .system

        if let data = defaults.data(forKey: Key.pageSetup),
           let decoded = try? JSONDecoder().decode(PageSetup.self, from: data) {
            pageSetup = decoded
        } else {
            pageSetup = .default
        }
    }
}
