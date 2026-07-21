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
    var textSize: Int {
        didSet {
            textSize = min(Self.maxTextSize, max(Self.minTextSize, textSize))
            guard textSize != oldValue else { return }
            defaults.set(textSize, forKey: Key.textSize)
        }
    }

    /// Multiplier the views apply to their base point sizes.
    var textScale: Double { Double(textSize) / 100.0 }

    var canIncreaseTextSize: Bool { textSize < Self.maxTextSize }
    var canDecreaseTextSize: Bool { textSize > Self.minTextSize }

    func increaseTextSize() { textSize += Self.textSizeStep }
    func decreaseTextSize() { textSize -= Self.textSizeStep }
    func resetTextSize() { textSize = Self.defaultTextSize }

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

    /// Lets the text column run the whole width of the window instead of
    /// holding to the printed six-inch measure. Off by default, because the
    /// measure is what makes a script look like a script — but a landscape iPad
    /// is much wider than a page, and someone reformatting rather than writing
    /// would rather use the room.
    var isFullWidth: Bool {
        didSet {
            guard isFullWidth != oldValue else { return }
            defaults.set(isFullWidth, forKey: Key.fullWidth)
        }
    }

    // MARK: - Zoom

    static let defaultZoom = 100
    static let minZoom = 50
    static let maxZoom = 200
    static let zoomStep = 10

    /// Scales the sheet in page view without changing the type size relative
    /// to the page — the sheet and its contents zoom together.
    var pageZoom: Int {
        didSet {
            pageZoom = min(Self.maxZoom, max(Self.minZoom, pageZoom))
            guard pageZoom != oldValue else { return }
            defaults.set(pageZoom, forKey: Key.pageZoom)
        }
    }

    var zoomScale: Double { Double(pageZoom) / 100.0 }
    var canZoomIn: Bool { pageZoom < Self.maxZoom }
    var canZoomOut: Bool { pageZoom > Self.minZoom }

    func zoomIn() { pageZoom += Self.zoomStep }
    func zoomOut() { pageZoom -= Self.zoomStep }
    func resetZoom() { pageZoom = Self.defaultZoom }

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
        static let fullWidth = "scripty-screenplay-full-width"
        static let pageZoom = "scripty-page-zoom"
        static let pageSetup = "scripty-page-setup"
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
        isFullWidth = defaults.bool(forKey: Key.fullWidth)

        if let data = defaults.data(forKey: Key.pageSetup),
           let decoded = try? JSONDecoder().decode(PageSetup.self, from: data) {
            pageSetup = decoded
        } else {
            pageSetup = .default
        }
    }
}
