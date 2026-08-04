//
//  SwipeToSelect.swift
//  scripty
//
//  Swipe an element to the left to pick it out — the way into selection mode,
//  and the way to keep picking once you are in it.
//
//  Selecting elements was a toolbar errand: find Select Elements, which on a
//  phone is under the "…", then start ticking. But the writer who wants to
//  retype four lines is already looking at those four lines, and a gesture made
//  on the line itself is a shorter road than one made in the corner of the
//  screen. Mail and Photos both take a sideways drag on a row as "this one", and
//  a writer who learned it there tries it here.
//
//  Sideways rather than along the column, because the column scrolls: a gesture
//  that answered a vertical drag would be fighting the scroll view for every
//  touch. Left rather than either way, because right is already spoken for —
//  see `isLeftwardSwipe`. It fires at the end of the swipe rather than as the
//  threshold is crossed: entering selection mode rebuilds every row on screen,
//  and doing that under a finger that is still moving is a lurch.
//
//  Two halves, for the reason `DoubleTapToEdit` has two: an element being typed
//  into is a `UITextView`, which swallows the touches a SwiftUI gesture would
//  need, and only a recogniser of its own sees them. A locked row and a
//  selection-mode row are SwiftUI, and there a view modifier is enough.
//

import SwiftUI
import UIKit

/// What both halves agree on: how far a swipe has to go and which way, and
/// what the writer feels when it lands.
@MainActor
enum SwipeToSelect {
    /// How far across the row the finger has to travel. Long enough that a
    /// wobble while scrolling is not a selection, short enough to be a flick
    /// rather than a haul — the distance a Mail row travels before its first
    /// action is committed to.
    static let distance: CGFloat = 44

    /// Whether a movement was a swipe to the left rather than a scroll.
    ///
    /// Leftward only, and not as a matter of taste: dragging a screenplay to
    /// the *right* is how iOS goes back, and the navigation stack takes that
    /// touch wherever on the row it starts. A right swipe on an element either
    /// closed the screenplay or, caught halfway and snapped back, did nothing
    /// at all — so this reads only the direction that is free, which is the
    /// one Mail puts its row actions on anyway.
    ///
    /// Twice as far across as along, so a diagonal drag is someone scrolling
    /// with an unsteady thumb and the column keeps the benefit of the doubt.
    static func isLeftwardSwipe(dx: CGFloat, dy: CGFloat) -> Bool {
        dx <= -distance && abs(dx) > abs(dy) * 2
    }

    /// The tick a row makes as it joins the selection. The same feedback the
    /// system gives for any pick-one-of-many, and the only sign the gesture
    /// landed that arrives before the screen redraws.
    static func confirm() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

extension View {
    /// A swipe to the left here picks this element out. Nil where selection
    /// would lead nowhere — a server that offers no bulk action at all — and
    /// then no gesture is attached.
    func swipeToSelect(_ select: (() -> Void)?) -> some View {
        modifier(SwipeToSelectModifier(select: select))
    }
}

private struct SwipeToSelectModifier: ViewModifier {
    let select: (() -> Void)?

    func body(content: Content) -> some View {
        if let select {
            content
                // A screenplay row is mostly air, and a gesture only the glyphs
                // answered would read as a broken one — the same reason the
                // double tap claims the whole row.
                .contentShape(Rectangle())
                // Simultaneous, so the gesture is not held up behind whatever
                // else the row offers: the double tap that starts writing, the
                // long press that picks a row up to reorder it. The distance
                // is what keeps them apart — a tap covers none of it, and a
                // lift for reordering cancels this one outright.
                .simultaneousGesture(
                    DragGesture(minimumDistance: SwipeToSelect.distance)
                        .onEnded { drag in
                            let moved = drag.translation
                            guard SwipeToSelect.isLeftwardSwipe(dx: moved.width,
                                                                dy: moved.height)
                            else { return }
                            SwipeToSelect.confirm()
                            select()
                        })
                // VoiceOver has no swipe to spare — its own gestures are spoken
                // for — so the same door, named, among the element's actions.
                .accessibilityAction(named: "Select Element", select)
        } else {
            content
        }
    }
}

/// The same gesture for the element the writer is typing into.
///
/// Held by `BlockTextView`'s coordinator, which owns the view it is attached
/// to. The recogniser is added once and enabled only while there is a selection
/// to join, so it is never in the way of ordinary typing.
@MainActor
final class SwipeToSelectGesture: NSObject, UIGestureRecognizerDelegate {
    /// Picks this element out. Set by the representable, which knows which
    /// element the view is showing.
    var select: (() -> Void)?

    private var recognizer: UIPanGestureRecognizer?

    /// Attaches the gesture, once — a coordinator that outlives a rebuilt view
    /// cannot stack recognisers up.
    func attach(to view: UIView) {
        guard recognizer == nil else { return }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSwipe))
        pan.delegate = self
        view.addGestureRecognizer(pan)
        recognizer = pan
    }

    /// Whether a swipe currently has anywhere to go. Disabled rather than
    /// detached, for the reason the double tap is: the answer flips with a
    /// script's own affordances, and adding and removing a recogniser mid-touch
    /// is how a gesture gets lost.
    func setOffered(_ offered: Bool) {
        recognizer?.isEnabled = offered
    }

    @objc private func handleSwipe(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended else { return }
        // Measured against the window rather than against the element itself:
        // the column can be scrolling under the finger at the same time — the
        // scroll's pan runs alongside this one — and the row's own coordinates
        // move with it, which would count the scroll as part of the swipe.
        let moved = gesture.translation(in: nil)
        guard SwipeToSelect.isLeftwardSwipe(dx: moved.x, dy: moved.y) else { return }
        SwipeToSelect.confirm()
        select?()
    }

    /// A pan the text view also wants — dragging the caret, dragging a
    /// selection out — is not one to queue behind: a recogniser made to wait
    /// for those to fail would never fire on a line with words in it. Both run,
    /// and the direction test above is what keeps this one from answering a
    /// touch that was meant for the text. The scroll view's own pan is in the
    /// same position, and has to be, or the column would stop scrolling
    /// wherever a finger happened to land on an element.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
