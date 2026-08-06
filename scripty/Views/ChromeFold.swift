//
//  ChromeFold.swift
//  scripty
//
//  Whether the bars around a document are folded away because the person at it
//  is scrolling down through the words — the reading posture Word's iOS app
//  takes with its ribbon, and for the same reason: on a phone the bars are a
//  real share of the page, and someone scrolling is reading, not reaching for a
//  control. Scrolling back up, or arriving at the top, brings them straight
//  back.
//
//  The rule lives here rather than in the screen that first had it, because a
//  song and a note fold now too. Three screens each with their own thresholds
//  would be three documents that answer a flick of the same length differently
//  — the same divergence `ProseColumn` and `ScriptRowChrome` exist to stop, one
//  layer up. The numbers are the screenplay's, unchanged.
//
//  Never persisted: every visit to a document starts dressed.
//

import SwiftUI

@MainActor
@Observable
final class ChromeFold {
    /// Whether the bars are folded away right now. The screens read this and
    /// nothing else — each decides for itself which of its own bars a fold
    /// takes, since a transport over live audio is not a toolbar.
    private(set) var isHidden = false

    /// How far the current run of scrolling has travelled in one direction.
    /// A change of direction resets it, so folding the bars away — or bringing
    /// them back — takes deliberate travel rather than a jitter of the finger.
    private var run: CGFloat = 0

    /// Takes one gesture-driven scroll event: how far it moved, and how far the
    /// viewport now sits below the top of the content. Fed from `onUserScroll`,
    /// which is what keeps programmatic jumps — an outline tap, a restored
    /// reading position, a line scrolled to for the voice — from folding the
    /// bars away under someone who never scrolled.
    func respond(delta: CGFloat, fromTop: CGFloat) {
        // The top of the document is home: the bars are always dressed there,
        // whichever direction the last gesture moved.
        if fromTop < 32 {
            run = 0
            set(hidden: false)
            return
        }
        guard delta != 0 else { return }
        if (delta > 0) != (run > 0) { run = 0 }
        run += delta
        // Asymmetric on purpose: folding away takes a real pull down, coming
        // back should cost barely more than the thought.
        if run > 60 {
            set(hidden: true)
        } else if run < -20 {
            set(hidden: false)
        }
    }

    /// Brings the bars back for an errand that needs them — a search starting,
    /// a selection beginning. The run is left alone: the finger has not moved,
    /// and the next flick should read as a continuation of the last.
    func show() {
        set(hidden: false)
    }

    private func set(hidden: Bool) {
        guard isHidden != hidden else { return }
        withAnimation(.easeInOut(duration: 0.22)) { isHidden = hidden }
    }
}
