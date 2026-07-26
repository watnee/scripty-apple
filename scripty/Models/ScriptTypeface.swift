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
