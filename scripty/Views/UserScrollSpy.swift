//
//  UserScrollSpy.swift
//  scripty
//
//  Reports the scrolling a person is doing with their finger — and only that.
//  Hide-on-scroll chrome has to know the difference: a programmatic jump (an
//  outline tap, a restored reading position) travels the same distance a flick
//  does, and the offset shifts when a bar the listener hides changes the safe
//  area. Reacting to either would fold the bars away under someone who never
//  scrolled, or argue with the very layout change the listener just made.
//

import SwiftUI

extension View {
    /// Calls `action` for every scroll the user drives by gesture, with how far
    /// this event moved and how far the viewport now sits below the content's
    /// top. Applied to the ScrollView itself, like the scroll modifiers it is
    /// built from.
    ///
    /// Filtered down to gestures three ways: programmatic scrolls report the
    /// `.animating` phase and are dropped; content short enough not to scroll
    /// is dropped, so a rubber-band stretch on an empty page cannot read as
    /// travel; and events past the bottom edge are dropped, so the bounce back
    /// from an over-scroll does not read as scrolling up.
    func onUserScroll(
        _ action: @escaping (_ delta: CGFloat, _ fromTop: CGFloat) -> Void
    ) -> some View {
        modifier(UserScrollSpy(action: action))
    }
}

private struct UserScrollSpy: ViewModifier {
    let action: (CGFloat, CGFloat) -> Void

    /// Whether the current motion belongs to a finger or to the momentum it
    /// left behind. `.animating` — a scrollTo — is deliberately not in the set.
    @State private var isUserDriven = false

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, phase in
                isUserDriven = phase == .tracking || phase == .interacting
                    || phase == .decelerating
            }
            .onScrollGeometryChange(for: Probe.self) { geometry in
                Probe(geometry)
            } action: { old, new in
                // Both ends of the event must be on legitimate ground: the
                // event that crosses back from an over-scroll is the spring
                // settling, not a finger, and it moves the whole stretch of
                // the bounce in one step.
                guard isUserDriven, new.canScroll,
                      !new.beyondBottom, !old.beyondBottom else { return }
                action(new.offset - old.offset, new.offset + new.topInset)
            }
    }

    /// What one geometry event looked like, in the terms the filter cares
    /// about. The raw offset and the inset are kept separate rather than
    /// pre-added: hiding a bar changes the inset without any scrolling, and a
    /// pre-added sum would hand that shift to the listener as a flick.
    private struct Probe: Equatable {
        var offset: CGFloat
        var topInset: CGFloat
        var canScroll: Bool
        var beyondBottom: Bool

        init(_ geometry: ScrollGeometry) {
            offset = geometry.contentOffset.y
            topInset = geometry.contentInsets.top
            let insets = geometry.contentInsets.top + geometry.contentInsets.bottom
            canScroll = geometry.contentSize.height + insets
                > geometry.containerSize.height + 1
            beyondBottom = offset > geometry.contentSize.height
                + geometry.contentInsets.bottom - geometry.containerSize.height
        }
    }
}
