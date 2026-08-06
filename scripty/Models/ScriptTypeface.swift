//
//  ScriptTypeface.swift
//  scripty
//
//  How a `ScriptFont` turns into type on the screen.
//
//  The three faces the editor offers used to be resolved separately by every
//  view that drew a block, and they disagreed: the page view asked for Courier
//  New, the editor rows for the system monospace, and neither is the face the
//  web app names. Courier Prime now travels in the bundle (see `UIAppFonts` in
//  Info.plist) so there is one answer, and it is the right one — which matters
//  because a screenplay page is measured in characters, not points.
//

import SwiftUI
// Guarded because `Tests/run.sh` compiles this file for the Mac, where the
// names and ratios above are all the print suite wants — the UIKit resolver
// below is the app's, and UIKit is not there to import.
#if canImport(UIKit)
import UIKit
#endif

extension ScriptFont {
    /// The face the app ships set in: Courier is the screenplay convention and
    /// Courier Prime is the Courier the web stylesheet asks for first.
    ///
    /// This is the *shipped* default, not the one in force — a writer can name
    /// another in Editor Preferences, and what a block with no font of its own
    /// is drawn in is `PresentationSettings.font(for:)`. This stays the value
    /// that setting starts at, and the answer anywhere there is no writer to
    /// have chosen: a widget, a test, a renderer handed no preference.
    static let `default`: ScriptFont = .courierPrime

    /// The PostScript name to ask the font system for. Courier Prime ships in
    /// the bundle; the other two are faces iOS already has. Naming the regular
    /// face is enough — bold and italic are resolved within the family by the
    /// trait matching each view already does.
    var postScriptName: String {
        switch self {
        case .courierPrime: return "CourierPrime"
        case .arial: return "Helvetica"
        case .timesNewRoman: return "TimesNewRomanPSMT"
        }
    }

    /// The line box this face renders at, as a multiple of the type size, with
    /// a little slack on top of the measured figure.
    ///
    /// A screenplay line is set solid — leading equal to the type size — but a
    /// font occupies its own natural line box, so type has to be sized *down*
    /// by that ratio for a rendered line to fill exactly one page line. Courier
    /// Prime is drawn nearly solid already (1.008), where Courier New needs
    /// 1.133 and the two proportional faces about as much; that is the whole
    /// reason a page set in it comes out at a true ten characters to the inch
    /// instead of the eight-and-change Courier New was giving.
    ///
    /// Erring high is the safe direction twice over: the line box stays inside
    /// the budget the paginator charged the row, and the slightly narrower
    /// glyphs wrap no later than the paginator assumed, so nothing is clipped.
    var naturalLeading: CGFloat {
        switch self {
        case .courierPrime: return 1.025
        case .arial, .timesNewRoman: return 1.15
        }
    }
}

#if canImport(UIKit)
extension ScriptFont {
    /// The face as UIKit wants it, with whatever traits the element asks for.
    ///
    /// Every writing surface in the app draws through this one resolver — the
    /// screenplay rows, a song's lyric lines and the note editor — which is
    /// what keeps a lyric looking like the script it belongs to rather than
    /// like a different app. A face the device cannot find falls back to the
    /// system monospace and never to the proportional default: whatever else
    /// goes wrong, the columns stay columns.
    @MainActor
    func uiFont(size: CGFloat, traits: UIFontDescriptor.SymbolicTraits = []) -> UIFont {
        let key = FontKey(family: self, size: size, traits: traits.rawValue)
        if let cached = Self.fontCache[key] { return cached }

        let base = UIFont(name: postScriptName, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)

        let resolved = base.fontDescriptor.withSymbolicTraits(traits)
            .map { UIFont(descriptor: $0, size: size) } ?? base
        Self.fontCache[key] = resolved
        return resolved
    }

    /// The type one screenplay element is set in: its own face at the size the
    /// surface is drawn at, carrying the element type's own emphasis — a scene
    /// heading's weight, a parenthetical's italics — folded in with whatever
    /// the writer asked for on top.
    ///
    /// Shared by the three continuous surfaces: the text views the writer types
    /// into, the rows of a locked script, and the reading surface. A face
    /// resolved two ways is a face with two sets of metrics, and text that
    /// measures differently wraps differently — which moves every line below it.
    /// One resolver, one wrap, one place on the page.
    ///
    /// Emphasis is carried as symbolic traits rather than as a weight because a
    /// `UITextView` sets its whole content in one font: semibold is not
    /// available to the surface the writer types into, so it is not available to
    /// the two that have to agree with it either.
    ///
    /// The face is the block's own where the server gave it one and the writer's
    /// chosen default where it did not — never the shipped `.default`, which
    /// would leave a script reset to Times drawing every unstyled element in
    /// Courier. Read here rather than passed in, so the three surfaces cannot
    /// disagree about it; each of them calls this from a SwiftUI body, which is
    /// what registers the observation that redraws them when the setting moves.
    @MainActor
    static func element(_ block: Block, size: CGFloat) -> UIFont {
        var traits: UIFontDescriptor.SymbolicTraits = []
        switch block.blockType {
        case .scene, .shot, .section: traits.insert(.traitBold)
        case .parenthetical, .lyrics, .synopsis: traits.insert(.traitItalic)
        default: break
        }
        if block.textBold ?? false { traits.insert(.traitBold) }
        if block.textItalic ?? false { traits.insert(.traitItalic) }

        return PresentationSettings.shared.font(for: block.font)
            .uiFont(size: size, traits: traits)
    }

    /// Resolved fonts, kept between updates.
    ///
    /// Every keystroke invalidates the observed editing state, so SwiftUI
    /// re-runs the update for each visible row — and building a `UIFont` from
    /// a descriptor is not free. A whole script only ever uses a handful of
    /// (family, size, traits) combinations, so they are worth holding onto:
    /// the work collapses to a dictionary lookup after the first row of each
    /// kind. Bounded by the type-size control having a fixed set of steps.
    @MainActor private static var fontCache: [FontKey: UIFont] = [:]

    private struct FontKey: Hashable {
        let family: ScriptFont
        let size: CGFloat
        /// `SymbolicTraits` is an OptionSet and so isn't Hashable on its own.
        let traits: UInt32
    }
}

/// Type for the prose surfaces: a note, and a song's lyrics in both of the
/// places they are written — the line-per-block editor and the plain one.
///
/// They used to answer for themselves and disagreed three ways: the note
/// editor asked for the system monospace, a lyric line for the proportional
/// system face at 17pt, and the screenplay for Courier Prime at 16 — so a
/// writer moving between a scene, its song and the notes about it met three
/// different typefaces. The web app sets all three in Courier Prime; so does
/// this now.
enum ProseFont {
    /// The base point size at 100%, shared with `EditableBlockRow` so a lyric
    /// and the scene it sits under are set at the same size.
    ///
    /// Twenty, because eighteen was small to write in for an hour at a stretch
    /// and the A+ control is a thing a writer has to find. This is what the app
    /// is set in before anyone touches that control, so it is worth it being a
    /// size to work in rather than the smallest one that reads.
    ///
    /// The number is only half of the answer, though: it travels with
    /// `ScriptRowChrome.printedMeasure`, because a measure is a count of
    /// characters before it is a width. Six inches of screenplay is sixty
    /// characters and Courier Prime advances 0.6em, so sixty of them want
    /// `0.6 × baseSize × 60` points of column — 711 at this size, as 640 was at
    /// eighteen. Move one of the two without the other and the writing column
    /// stops breaking its lines where paper does: set at 16 against the 640
    /// column the script held sixty-six characters to the line and ran on past
    /// the page, and set at 20 against that same column it would hold
    /// fifty-three and break well short of it. They are one setting in two
    /// numbers. Rounding the pair so the column wraps a character early rather
    /// than a character late is the safe direction here, for the reason
    /// `naturalLeading` errs high.
    ///
    /// Every continuous surface reads this — the writing column, the reader,
    /// both song editors and the note editor — so it is the one number that
    /// says how big the app's prose is drawn. The page view is deliberately not
    /// among them: a sheet is geometry, and `ScreenplayFont.sheet` sizes type
    /// to the line it has to fit, which is why growing this leaves the page
    /// count, the preview and the exported PDF exactly where they were.
    static let baseSize: CGFloat = 20

    /// `baseSize` at the writer's chosen scale, then scaled again by the
    /// system's Dynamic Type setting — prose has no page geometry to protect
    /// and so no Courier-fidelity excuse to ignore either.
    ///
    /// In the default face, which is the writer's to choose. Lyrics and notes
    /// have no font of their own to override it with — nothing in either
    /// editor sets one — so for them the setting is simply the face they are
    /// written in, and a script reset to Times brings its songs and notes with
    /// it rather than leaving them in Courier.
    ///
    /// `face` is a parameter, and a required one, because the text views that
    /// draw prose are UIKit representables: resolving the setting inside
    /// `updateUIView` reads it outside any body, so nothing would redraw an
    /// editor left open behind the settings sheet. Asking for the face here
    /// makes each of them read it where their parent builds its body instead.
    @MainActor
    static func editor(scale: Double, face: ScriptFont) -> UIFont {
        UIFontMetrics(forTextStyle: .body)
            .scaledFont(for: face.uiFont(size: baseSize * scale))
    }
}
#endif

/// Type for a page-accurate sheet, where one rendered line has to occupy one
/// line of paper and no more.
enum ScreenplayFont {
    /// `family`, sized so a line of it fills exactly one `lineHeight` of the
    /// page. Fixed rather than scaled: a sheet is geometry, and every row on it
    /// is clipped to the line budget the paginator charged — letting Dynamic
    /// Type grow the type would push text out of its own page, not enlarge it.
    static func sheet(_ family: ScriptFont, lineHeight: CGFloat) -> Font {
        .custom(family.postScriptName, fixedSize: lineHeight / family.naturalLeading)
    }
}
