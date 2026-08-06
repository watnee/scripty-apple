//
//  HistoryStepButton.swift
//  scripty
//
//  Undo and redo in a toolbar, where holding one keeps walking.
//
//  A step back is almost never one step. A writer who has typed a paragraph into
//  the wrong element, or a verse into the wrong song, wants the last half-dozen
//  changes gone — and a control that gives exactly one of them per press turns
//  that into six taps in the same square centimetre, each one a fresh chance to
//  miss and hit whatever is beside it. Every keyboard in the world answers a held
//  key by repeating it, and that is the gesture this borrows: press for one step,
//  hold to keep going.
//
//  Not a `Button`, which is the whole reason this file exists, and not a matter
//  of taste. A toolbar item is bridged into the bar UIKit builds, and that
//  bridging is where a hold goes to die: measured on an iPad,
//  `buttonRepeatBehavior(.enabled)` — the platform's own answer to exactly this,
//  which would have been the entire implementation — leaves a six-second hold
//  taking one step, the same as a tap, and a gesture attached to the button
//  (simultaneously, or around it, or on a container holding it) is never
//  delivered at all: the button's action arrives and nothing else does. A
//  toolbar item with no button in it is hosted as an ordinary view, and there
//  every touch arrives. So the press is read from a gesture of this view's own,
//  and everything a button would have given is given back by hand below.
//
//  One step at a time, always. The screenplay's undo is a round trip that ends in
//  the whole script being read back; ten of those in flight together would leave
//  whichever answered last on screen rather than whichever was asked for last. So
//  each step is awaited before the next is asked for, and the hold runs at
//  whatever pace the history can keep up with — a note's own stack as fast as the
//  gap allows, a server's as fast as it answers.
//
//  Stopping takes care of itself: `isOffered` is the same question the button's
//  dimming asks, read again before every step, so the run ends at the bottom of
//  the stack whether or not the finger has lifted.
//

import SwiftUI

/// One half of an undo pair: a toolbar control that takes a step when tapped and
/// keeps taking them while it is held.
///
/// The label is a `Label`, as every other toolbar button here is: the bar decides
/// whether a glyph or a glyph and its name is what fits, and a view that has
/// already made that decision for it draws the wrong thing in half the places it
/// lands.
struct HistoryStepButton: View {
    /// "Undo" or "Redo" — the name in the overflow menu, and what VoiceOver
    /// reads out on the bar.
    let title: LocalizedStringKey
    let systemImage: String

    /// Whether that side of the history has anything in it. Also what ends a
    /// hold: the last step turns this false and the run stops.
    ///
    /// Asked rather than given, and that is the whole reason it is a closure: a
    /// hold outlives the view value that started it, so a `Bool` copied in at the
    /// first touch is the answer from before any of the steps happened — and a
    /// run reading it would walk past the bottom of the stack. The models behind
    /// every caller are classes, so a closure reads what is true now.
    let isOffered: () -> Bool

    /// One step. Async because the screenplay's and the lyric's are — they ask
    /// the server — and the note's, which is not, loses nothing by being awaited.
    let step: () async -> Void

    @State private var stepper = HistoryStepper()
    @State private var isPressed = false

    var body: some View {
        let offered = isOffered()
        Label(title, systemImage: systemImage)
            // What a bar button item would have drawn for itself: the ordinary
            // glyph colour, the greyed one where there is nothing to take back,
            // and the dip under the finger that says a press landed.
            .foregroundStyle(offered ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .opacity(isPressed ? 0.4 : 1)
            // A glyph is a few points of ink in a 44pt hit area, and a gesture
            // only the ink answered would read as a broken control.
            .contentShape(.rect)
            .hoverEffect(.highlight)
            // A drag of no distance, rather than a long press, because a long
            // press *ends* the moment it succeeds: it says when a hold began and
            // nothing about when it stopped, and a repeat needs the release.
            // This reports both, and the tap as well — a press that ends before
            // the hold has started is what a tap is.
            .gesture(press, isEnabled: offered)
            // Everything a `Button` would have told VoiceOver, said by hand. The
            // hold is named as a hint rather than left to be discovered: it is
            // reachable there — a double tap held down passes the press through —
            // but nothing on screen says so.
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Touch and hold to keep going")
            .accessibilityAction { stepper.take(step) }
            .disabled(!offered)
            // A press ends when the finger lifts, and a gesture the system takes
            // away — the sheet dismissed mid-hold, the bar rebuilt under it —
            // may never say so at all. Nothing here would be left running for
            // long (a run stops at the bottom of its stack whatever happens),
            // but it would be running after the screen it belongs to had gone.
            .onDisappear {
                stepper.endHold(taking: nil)
                isPressed = false
            }
    }

    private var press: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                isPressed = true
                stepper.beginHold(step, while: isOffered)
            }
            .onEnded(pressEnded)
    }

    /// The finger lifted. A press that wandered off the control on its way up is
    /// one taken back, the way a button treats one — but only as far as the tap
    /// goes. Steps a hold has already taken stand: they happened while the finger
    /// was where it meant to be.
    private func pressEnded(_ drag: DragGesture.Value) {
        isPressed = false
        let strayed = abs(drag.translation.width) > 24
            || abs(drag.translation.height) > 24
        let tap: (() async -> Void)? = step
        stepper.endHold(taking: strayed ? nil : tap)
    }
}

/// The press behind one control: what turns a hold into a run of steps, and what
/// keeps a tap to exactly one.
///
/// One per control, which is one per direction — undoing and redoing are never in
/// flight together, since walking one way is what fills the other stack.
@MainActor
final class HistoryStepper {
    /// How long a press has to last before it stops being a tap. The system's
    /// own long press, which is what every held control on the device is
    /// measured against.
    private static let holdDelay = Duration.milliseconds(500)

    /// The pause between steps once a run is going. A held key's repeat rate,
    /// near enough — fast enough to feel like rewinding, slow enough that a
    /// finger lifted a moment late has not taken back a paragraph. It is the gap
    /// *after* each step lands rather than instead of one, so a history that
    /// answers slowly sets its own pace.
    private static let repeatGap = Duration.milliseconds(140)

    private var inFlight: Task<Void, Never>?
    private var hold: Task<Void, Never>?

    /// Whether the press that is ending walked the stack — which is what makes
    /// the release a release rather than a tap.
    private var walked = false

    /// One step, from something that is not a press: VoiceOver's activation,
    /// which arrives as an action and never as a touch.
    func take(_ step: @escaping () async -> Void) {
        guard inFlight == nil else { return }
        inFlight = Task {
            await step()
            inFlight = nil
        }
    }

    /// The finger went down. Nothing happens for `holdDelay` — that is what
    /// leaves an ordinary tap alone — and then steps run until it lifts or the
    /// stack empties.
    ///
    /// Called again on every movement of the press, so the guard is what makes it
    /// one run rather than one per wobble.
    func beginHold(_ step: @escaping () async -> Void, while offered: @escaping () -> Bool) {
        guard hold == nil else { return }
        walked = false
        hold = Task {
            try? await Task.sleep(for: Self.holdDelay)
            while !Task.isCancelled, offered() {
                walked = true
                await step()
                try? await Task.sleep(for: Self.repeatGap)
            }
        }
    }

    /// The finger lifted. A press that never became a hold is a tap and takes its
    /// one step here; a press that did takes nothing more, since the run has
    /// already given the writer everything they asked for and one further step
    /// would be the one they did not.
    func endHold(taking step: (() async -> Void)?) {
        hold?.cancel()
        hold = nil
        guard !walked, let step else { return }
        take(step)
    }
}
