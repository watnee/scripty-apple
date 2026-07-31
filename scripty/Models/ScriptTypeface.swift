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
    /// The face a block is set in when the server has not named one, which is
    /// most of them: the web app only records a font once someone picks one.
    /// Courier is the screenplay convention and Courier Prime is the Courier
    /// the web stylesheet asks for first.
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
    static let baseSize: CGFloat = 16

    /// `baseSize` at the writer's chosen scale, then scaled again by the
    /// system's Dynamic Type setting — prose has no page geometry to protect
    /// and so no Courier-fidelity excuse to ignore either.
    @MainActor
    static func editor(scale: Double) -> UIFont {
        UIFontMetrics(forTextStyle: .body)
            .scaledFont(for: ScriptFont.default.uiFont(size: baseSize * scale))
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
