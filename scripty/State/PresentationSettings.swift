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
            // Clamp by re-assigning only when it actually changes something.
            // `@Observable` rewrites these into computed properties, so a
            // `didSet` that writes back to itself unconditionally re-enters
            // forever rather than settling — the write-back has to be the
            // exception, and the re-entry then does the storing.
            let clamped = min(Self.maxTextSize, max(Self.minTextSize, textSize))
            if clamped != textSize {
                textSize = clamped
                return
            }
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

    // MARK: - Type size in points

    /// The same setting said the way a writer says it. A screenplay is set in
    /// 12pt, so the percentage above and a point size are one number in two
    /// units — and points are the unit anyone who has opened a word processor
    /// reaches for. Nothing new is stored: this reads and writes `textSize`,
    /// which keeps the web app's key and its `⌘+` / `⌘−` stepping intact.
    ///
    /// Like the percentage, it is how big the script is *drawn* — in the
    /// editor, the page view and the reader. Printing and PDF export stay at
    /// the standard 12pt, because a page that paginates differently from
    /// everyone else's is not a screenplay any more.
    ///
    /// Rounded to a tenth of a point, which is what makes the presets
    /// round-trip: 14pt is 116.67% of 12, stored as the whole 117%, and 117%
    /// of 12 comes back as 14.04.
    var fontSizePt: Double {
        get { ((ScreenplayLayout.fontSizePt * textScale) * 10).rounded() / 10 }
        set { textSize = Self.textSize(forFontSizePt: newValue) }
    }

    /// The sizes the menu offers: the familiar ones, then every other point up
    /// to the ceiling. 13pt and 15pt are reachable by typing a number, but
    /// listing them would make the menu a ruler rather than a choice.
    static let fontSizePresets: [Double] = [10, 11, 12, 14, 16, 18, 20, 24]

    /// The range the scale can express, in points. The floor is 9.6 — 80% of
    /// 12 — and rounding it up rather than down keeps every size the writer can
    /// ask for a size the writer can be given back.
    static var minFontSizePt: Double {
        (ScreenplayLayout.fontSizePt * Double(minTextSize) / 100).rounded(.up)
    }

    static var maxFontSizePt: Double {
        (ScreenplayLayout.fontSizePt * Double(maxTextSize) / 100).rounded(.down)
    }

    /// What a point size works out to as a stored percentage. Out-of-range
    /// sizes are pulled to the nearest end rather than refused: someone typing
    /// 72 into the size field wants the biggest type there is.
    static func textSize(forFontSizePt points: Double) -> Int {
        let clamped = min(maxFontSizePt, max(minFontSizePt, points))
        return Int((clamped / ScreenplayLayout.fontSizePt * 100).rounded())
    }

    /// How a size is written on a chip or in a menu — "12", not "12.0", since
    /// whole points are the ordinary case and a trailing zero reads as noise.
    static func fontSizeLabel(_ points: Double) -> String {
        points == points.rounded()
            ? String(Int(points))
            : String(format: "%.1f", points)
    }

    var fontSizeLabel: String { Self.fontSizeLabel(fontSizePt) }

    /// Whether the script is currently set in this size, for the checkmark
    /// beside a preset. Compared with a tenth of a point's slack because both
    /// sides came through a percentage.
    func isSetIn(fontSizePt points: Double) -> Bool {
        abs(fontSizePt - points) < 0.05
    }

    // MARK: - Typeface

    /// The face an element is set in when it carries no font of its own, which
    /// is most of them: a block only records a font once someone picks one from
    /// the Format menu, and that menu's "Default" is what puts it back here.
    ///
    /// Courier Prime until the writer says otherwise — the screenplay
    /// convention, and the face the web stylesheet asks for first, so a script
    /// that has never met this setting reads the same in both clients.
    ///
    /// A device preference like the type size above it, and for the same
    /// reason: it is how the script is *drawn*, not what any block stores. It
    /// has no counterpart in the web app, so unlike its neighbours the key is
    /// ours rather than one of theirs. What a block itself says still wins —
    /// this only answers for the ones that say nothing.
    var defaultFont: ScriptFont {
        didSet {
            guard defaultFont != oldValue else { return }
            defaults.set(defaultFont.rawValue, forKey: Key.defaultFont)
        }
    }

    /// The face a block is drawn in: its own where it names one, the writer's
    /// default where it does not. Every surface that sets type resolves through
    /// here — editor rows, page sheets, the reader and the offline print — so
    /// one setting answers for all of them at once, and reading it from a
    /// SwiftUI `body` is what redraws them when it changes.
    func font(for serverValue: String?) -> ScriptFont {
        ScriptFont(serverValue: serverValue) ?? defaultFont
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

    /// Collapses the script to its scenes, sections and synopses so the shape
    /// of the story can be rearranged without the scenes' contents in the way.
    ///
    /// Distinct from the outline *panel*, which lists the same elements to
    /// navigate by. This is the editor itself, narrowed: what is left is still
    /// typed into, retyped and reordered in place — and everything that makes
    /// a *new* element while it is on stays inside `BlockType.outlineTypes`,
    /// or the writing would go somewhere the writer cannot see.
    ///
    /// Turning it on leaves page view, as it does in the browser — paper sheets
    /// full of gaps where the scenes used to be are nobody's idea of an outline.
    var isOutlineMode: Bool {
        didSet {
            guard isOutlineMode != oldValue else { return }
            defaults.set(isOutlineMode ? "1" : "0", forKey: Key.outlineMode)
            if isOutlineMode { isPageView = false }
        }
    }

    /// Shows the running word count and page estimate under the script.
    ///
    /// Stored as the web stores it — the key names the *hidden* state, and an
    /// unset key means hidden — so a writer who has never asked for the readout
    /// gets a clean page in both clients.
    var showsWordCount: Bool {
        didSet {
            guard showsWordCount != oldValue else { return }
            defaults.set(!showsWordCount, forKey: Key.wordCountHidden)
        }
    }

    /// Whether the keyboard marks misspellings while typing into an element.
    ///
    /// On by default, as it is in the browser. Screenplays are full of names
    /// and shouted sluglines that no dictionary knows, so this is the one view
    /// preference a writer is likely to want off for good.
    var isSpellcheckEnabled: Bool {
        didSet {
            guard isSpellcheckEnabled != oldValue else { return }
            defaults.set(isSpellcheckEnabled, forKey: Key.spellcheck)
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
            // See the note on `textSize` — the clamp must not write back
            // unconditionally.
            let clamped = min(Self.maxZoom, max(Self.minZoom, pageZoom))
            if clamped != pageZoom {
                pageZoom = clamped
                return
            }
            guard pageZoom != oldValue else { return }
            persistZoom()
        }
    }

    /// Fit-to-width: the sheet is sized to the space it has rather than to a
    /// percentage. Like the web app this shares the zoom key, storing the
    /// literal "fit" where a number would otherwise go.
    var isPageZoomFit: Bool {
        didSet {
            guard isPageZoomFit != oldValue else { return }
            persistZoom()
        }
    }

    /// What fit currently works out to. The page view measures it and reports
    /// it back — the sheet's unzoomed width depends on the window, full-width
    /// mode and the paper size, so it cannot be computed from settings alone.
    /// Not persisted: it is a fact about this window, not a preference.
    var fitZoom = defaultZoom {
        didSet {
            // See the note on `textSize`.
            let clamped = min(Self.maxZoom, max(Self.minZoom, fitZoom))
            guard clamped != fitZoom else { return }
            fitZoom = clamped
        }
    }

    /// The zoom actually in force, which is what the navigator shows.
    var effectiveZoom: Int { isPageZoomFit ? fitZoom : pageZoom }

    var zoomScale: Double { Double(effectiveZoom) / 100.0 }
    var canZoomIn: Bool { effectiveZoom < Self.maxZoom }
    var canZoomOut: Bool { effectiveZoom > Self.minZoom }

    /// Stepping away from fit starts from whatever fit resolved to, so the
    /// first press nudges the size on screen rather than jumping back to 100%.
    func zoomIn() { stepZoom(by: Self.zoomStep) }
    func zoomOut() { stepZoom(by: -Self.zoomStep) }

    private func stepZoom(by delta: Int) {
        let from = effectiveZoom
        isPageZoomFit = false
        pageZoom = from + delta
    }

    func resetZoom() {
        isPageZoomFit = false
        pageZoom = Self.defaultZoom
    }

    /// A second press on an active Fit returns to 100%, matching the web.
    func toggleFitZoom() {
        if isPageZoomFit {
            resetZoom()
        } else {
            isPageZoomFit = true
        }
    }

    private func persistZoom() {
        if isPageZoomFit {
            defaults.set(Key.fitValue, forKey: Key.pageZoom)
        } else {
            defaults.set(pageZoom, forKey: Key.pageZoom)
        }
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
        static let fullWidth = "scripty-screenplay-full-width"
        static let pageZoom = "scripty-page-zoom"
        /// What the zoom key holds when fit-to-width is on — the web's spelling.
        static let fitValue = "fit"
        static let pageSetup = "scripty-page-setup"
        /// Ours alone — the web app has no default-font setting to borrow a
        /// key from — but spelled its way, so it sits with the rest.
        static let defaultFont = "scripty-default-font"
        /// Stored as "1"/"0" rather than a boolean — the web's spelling.
        static let outlineMode = "scripty-outline-mode"
        /// Names the hidden state, not the shown one — the web's spelling.
        static let wordCountHidden = "scripty-word-count-hidden"
        /// Unprefixed in the web app too.
        static let spellcheck = "spellcheck"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // `object(forKey:)` distinguishes "never set" from "set to zero", so a
        // first run gets the documented defaults rather than a 0% type size.
        let storedTextSize = defaults.object(forKey: Key.textSize) as? Int
        textSize = min(Self.maxTextSize,
                       max(Self.minTextSize, storedTextSize ?? Self.defaultTextSize))

        // The zoom key holds either a percentage or the literal "fit"; an
        // unreadable value means neither, so it falls back to 100%.
        isPageZoomFit = defaults.string(forKey: Key.pageZoom) == Key.fitValue
        let storedZoom = defaults.object(forKey: Key.pageZoom) as? Int
        pageZoom = min(Self.maxZoom, max(Self.minZoom, storedZoom ?? Self.defaultZoom))

        // Hidden unless the key says otherwise, matching the web's
        // `getItem(...) !== 'false'`; spellcheck is the other way round.
        let hidden = defaults.object(forKey: Key.wordCountHidden) as? Bool ?? true
        showsWordCount = !hidden
        isSpellcheckEnabled = defaults.object(forKey: Key.spellcheck) as? Bool ?? true

        // The web writes "1" and reads anything else as off, so an old boolean
        // or a missing key both mean the whole script is showing.
        isOutlineMode = defaults.string(forKey: Key.outlineMode) == "1"

        // A name nothing recognises — a face dropped from a later build, or a
        // key someone edited — is no font at all, and the shipped default is
        // the honest answer then rather than a script drawn in nothing.
        defaultFont = ScriptFont(serverValue: defaults.string(forKey: Key.defaultFont))
            ?? .default

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
