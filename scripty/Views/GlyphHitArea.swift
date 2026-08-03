//
//  GlyphHitArea.swift
//  scripty
//
//  Making a small glyph big enough to hit, without making it look bigger.
//
//  A 32pt icon button is well under the 44pt Apple asks for, and the workspace
//  section headers are the worst case for it: undo, redo and the reorder menu
//  sit in a row immediately beside a full-width button that expands the whole
//  document, so a miss does not do nothing — it collapses what the writer was
//  looking at.
//
//  The fix was already written twice, inline, in `PageNavigatorBar` and
//  `BlockMarkers`: pad the label so the tappable area grows, take the padding
//  back with negative outer padding so nothing moves. This is the third and
//  fourth use, so it lives in one place.
//

import SwiftUI

extension View {
    /// Grows this label's tappable area by `x` and `y` on each side.
    ///
    /// Pair with `.glyphHitInset(x:y:)` on the control itself, or the bar
    /// really does get bigger.
    func glyphHitArea(x: CGFloat = 4, y: CGFloat = 6) -> some View {
        self.padding(.horizontal, x)
            .padding(.vertical, y)
            .contentShape(Rectangle())
    }

    /// Gives back the room `glyphHitArea(x:y:)` claimed, so the control draws
    /// exactly where it did before while staying easier to hit.
    func glyphHitInset(x: CGFloat = 4, y: CGFloat = 6) -> some View {
        self.padding(.horizontal, -x)
            .padding(.vertical, -y)
    }
}
