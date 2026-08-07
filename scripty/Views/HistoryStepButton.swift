//
//  HistoryStepButton.swift
//  scripty
//
//  Undo and redo in a toolbar, where a hold does the thing a tap cannot.
//
//  A step back is almost never one step. A writer who has typed a paragraph into
//  the wrong element, or a verse into the wrong song, wants the last half-dozen
//  changes gone — and a control that gives exactly one of them per press turns
//  that into six taps in the same square centimetre, each one a fresh chance to
//  miss and hit whatever is beside it. Every keyboard in the world answers a held
//  key by repeating it, and that is the gesture this borrows: press for one step,
//  hold to keep going.
//
//  Where the bar draws only one half of the pair, the hold has a better use and
//  takes it. A `held` alternative turns the gesture into the other way to reach
//  the other direction: hold, and once the press has outlasted a tap the control
//  changes under the finger to say so — Undo becomes Redo — and lifting takes
//  that step instead. Both are the same press read two ways, so a control has one
//  or the other and never both: the editors that draw Undo and Redo side by side
//  keep the repeat, where a lyric retyped a line at a time makes it worth having,
//  and the screenplay's lone Undo, whose Redo is a trip into the "…", spends the
//  hold on reaching it.
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

/// The other half of the pair, where the bar has no room to draw it: what a hold
/// on this control turns it into, and what lifting the finger then does.
struct HistoryStepAlternative {
    /// What the control calls itself once the hold has revealed this — "Redo",
    /// on the one control that has an alternative.
    let title: LocalizedStringKey
    let systemImage: String

    /// Whether this direction has anything in it, asked at the moment the hold
    /// comes good. Nothing to redo means nothing to reveal: the control stays
    /// as it was and the press ends as the tap it started out as, rather than
    /// changing into something that would do nothing.
    let isOffered: () -> Bool

    let step: () async -> Void

    /// What VoiceOver is told about the hold. Given here rather than built from
    /// `title`, which would be a sentence stitched together out of fragments and
    /// so a sentence in one language only.
    let hint: LocalizedStringKey
}

/// One half of an undo pair: a toolbar control that takes a step when tapped, and
/// whose hold either keeps taking them or offers the other half.
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

    /// What a hold offers instead of a run of steps. `nil` — every editor that
    /// draws both halves — keeps the repeat, which is the whole point of the
    /// gesture where the other direction is already one tap away.
    var held: HistoryStepAlternative? = nil

    /// One step. Async because the screenplay's and the lyric's are — they ask
    /// the server — and the note's, which is not, loses nothing by being awaited.
    let step: () async -> Void

    @State private var stepper = HistoryStepper()
    @State private var isPressed = false

    /// Whether a hold has swapped this control for its alternative. Only ever
    /// true where there is one, and only while the finger is still down.
    @State private var isRevealed = false

    /// What the control is offering at this moment: its own direction, or the
    /// one a hold has revealed under the finger.
    private var showing: HistoryStepAlternative {
        guard isRevealed, let held else {
            return HistoryStepAlternative(title: title,
                                          systemImage: systemImage,
                                          isOffered: isOffered,
                                          step: step,
                                          hint: holdHint)
        }
        return held
    }

    /// What the hold does, which is not the same question as what the control is
    /// showing: a control with an alternative says so before the hold as well as
    /// during it, since a gesture nobody is told about is a gesture nobody makes.
    private var holdHint: LocalizedStringKey {
        held?.hint ?? "Touch and hold to keep going"
    }

    var body: some View {
        let showing = showing
        let offered = showing.isOffered()
        Label(showing.title, systemImage: showing.systemImage)
            // What a bar button item would have drawn for itself: the ordinary
            // glyph colour, the greyed one where there is nothing to take back,
            // and the dip under the finger that says a press landed.
            .foregroundStyle(offered ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .opacity(isPressed ? 0.4 : 1)
            // A glyph is a few points of ink in a 44pt hit area, and a gesture
            // only the ink answered would read as a broken control.
            //
            // The frame is asked for rather than assumed: UIKit grows a real bar
            // button to 44pt, and a hosted view — which this is, being no button
            // — is laid out at the size of its ink, about 20pt square.
            // `contentShape` makes the frame there answer touches and cannot
            // make it bigger, so without this the control draws right, greys
            // right, works when pressed dead centre, and drops the presses that
            // land in the gap beside the glyph. A hold makes that worse, not
            // better: it asks the finger to stay put on a target half the size
            // it looks.
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
            .hoverEffect(.highlight)
            // A drag of no distance, rather than a long press, because a long
            // press *ends* the moment it succeeds: it says when a hold began and
            // nothing about when it stopped, and a repeat needs the release.
            // This reports both, and the tap as well — a press that ends before
            // the hold has started is what a tap is.
            .gesture(press, isEnabled: offered)
            // The swap says itself, in the way a control changing under a
            // stationary finger cannot: a hold is felt before it is seen, and
            // the writer holding this one is looking at the words they are
            // taking back rather than at the bar. Only on the way in — coming
            // back is the finger's own doing and needs no announcement.
            .sensoryFeedback(trigger: isRevealed) { _, revealed in
                revealed ? .impact(weight: .light) : nil
            }
            // Everything a `Button` would have told VoiceOver, said by hand. The
            // hold is named as a hint rather than left to be discovered: it is
            // reachable there — a double tap held down passes the press through —
            // but nothing on screen says so.
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(holdHint)
            .accessibilityAction { stepper.take(step) }
            // And where the hold leads somewhere rather than repeating, it is a
            // named action as well as a hint. A hold *is* reachable with
            // VoiceOver on, but it asks for a double tap held at exactly the
            // right rhythm to reach a control that then changes silently; the
            // rotor asks for the thing by name.
            .accessibilityActions {
                if let held, held.isOffered() {
                    Button(held.title) { stepper.take(held.step) }
                }
            }
            .disabled(!offered)
            // A press ends when the finger lifts, and a gesture the system takes
            // away — the sheet dismissed mid-hold, the bar rebuilt under it —
            // may never say so at all. Nothing here would be left running for
            // long (a run stops at the bottom of its stack whatever happens),
            // but it would be running after the screen it belongs to had gone.
            .onDisappear {
                stepper.endHold(taking: nil)
                isPressed = false
                isRevealed = false
            }
    }

    private var press: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                isPressed = true
                if let held {
                    stepper.beginHold {
                        // Asked here rather than when the press began: a hold
                        // lasts half a second, and this is the answer at the end
                        // of it. Nothing to redo reveals nothing, and the press
                        // stays the tap it was.
                        guard held.isOffered() else { return }
                        isRevealed = true
                    }
                } else {
                    stepper.beginHold(step, while: isOffered)
                }
            }
            .onEnded(pressEnded)
    }

    /// The finger lifted. A press that wandered off the control on its way up is
    /// one taken back, the way a button treats one — but only as far as the tap
    /// goes. Steps a hold has already taken stand: they happened while the finger
    /// was where it meant to be.
    ///
    /// Which is also the way out of a revealed hold, and the reason it is worth
    /// having: a writer who holds Undo, watches it turn into Redo and decides
    /// against it slides off the control and lifts, and nothing has happened. A
    /// hold that fired the moment it came good would have taken the step before
    /// they had read what it said.
    private func pressEnded(_ drag: DragGesture.Value) {
        isPressed = false
        let strayed = abs(drag.translation.width) > 24
            || abs(drag.translation.height) > 24
        // What lifting takes: the revealed half where a hold has swapped the
        // control, and this control's own step every other time. A repeat has
        // already taken everything it is going to — `endHold` knows a run
        // happened and drops this — so the two never both land.
        let tap: (() async -> Void)? = isRevealed ? held?.step : step
        isRevealed = false
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

    /// The finger went down on a control whose hold offers the other half rather
    /// than repeating this one. The same wait — a hold is a hold wherever it is,
    /// and a writer who has learnt the length of one on this bar has learnt it
    /// for both — and then the control is told to change under the finger.
    ///
    /// Nothing is taken here. A press that comes good is still a press in
    /// progress: what it does is decided when the finger lifts, which is what
    /// leaves room to change your mind. So `walked` stays false and the release
    /// takes the one step it was handed.
    ///
    /// Called again on every movement of the press, like its sibling, so the
    /// guard is what keeps one press to one wait.
    func beginHold(revealing reveal: @escaping () -> Void) {
        guard hold == nil else { return }
        walked = false
        hold = Task {
            try? await Task.sleep(for: Self.holdDelay)
            guard !Task.isCancelled else { return }
            reveal()
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
