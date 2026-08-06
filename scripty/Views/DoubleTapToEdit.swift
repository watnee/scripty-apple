//
//  DoubleTapToEdit.swift
//  scripty
//
//  Double tap words that are only being shown, and start writing in them.
//
//  Every writing surface here has two postures. A song or a note opens up to be
//  read, with Edit in the corner; a screenplay or a lyric can be locked, and
//  says so in a banner or by losing its editing bars. Until now those controls
//  were the only ways across. Pages and Word both take a double tap on the text
//  itself as the same instruction, and a writer who learned it there tries it
//  here first — so a tap that did nothing was this app saying no to a gesture it
//  had simply never been taught.
//
//  Two halves, because the surfaces are built two ways. A locked screenplay
//  element is drawn as SwiftUI text, so there the gesture is a view modifier. A
//  lyric line and a note body stay UITextViews with `isEditable` off, and a
//  gesture recogniser is the only thing that sees a tap those swallow — it also
//  knows where among the words the finger landed, so the caret can go there
//  rather than at the end of the line.
//
//  Never a way past the server's answer. Each caller offers this only where the
//  words were already theirs to change and it is this device's own posture — a
//  reading view, or the local lock — standing in the way. A reader taps twice on
//  a script they were given to read and nothing happens, which is the truth.
//

import SwiftUI
import UIKit

extension View {
    /// A double tap here starts writing. Nil where there is nothing to start —
    /// the words are editable already, or were never this writer's to change —
    /// and then no gesture is attached at all.
    func doubleTapToEdit(_ startWriting: (() -> Void)?) -> some View {
        modifier(DoubleTapToEditGestureModifier(startWriting: startWriting))
    }
}

private struct DoubleTapToEditGestureModifier: ViewModifier {
    let startWriting: (() -> Void)?

    func body(content: Content) -> some View {
        if let startWriting {
            content
                // A screenplay row is mostly air — a character cue is one word
                // in the middle of a six-inch column — and a gesture only the
                // glyphs themselves answered would read as a broken one.
                .contentShape(Rectangle())
                // Simultaneous rather than `onTapGesture`, because the reading
                // surfaces enable text selection: a plain tap gesture would be
                // held up behind the selection's own, and on those screens the
                // second tap would go nowhere.
                .simultaneousGesture(TapGesture(count: 2).onEnded(startWriting))
                // VoiceOver spends its own double tap on activating whatever is
                // under the finger, so this gesture cannot be reached that way
                // at all. The same door, named, among the element's actions.
                .accessibilityAction(named: "Edit", startWriting)
        } else {
            content
        }
    }
}

extension String {
    /// A UTF-16 `offset` into these words as a count of Characters — the count
    /// a text view reports its own selection in, turned into the count the
    /// caret requests that survive a mode change are kept in.
    ///
    /// Clamped rather than trusted: the offset was measured against the words a
    /// reader was showing, and a save landing in between can leave it past the
    /// end of the line it named.
    func characterOffset(utf16 offset: Int) -> Int {
        let bounded = max(0, min(offset, (self as NSString).length))
        guard let index = Range(NSRange(location: 0, length: bounded), in: self)?.upperBound
        else { return count }
        return distance(from: startIndex, to: index)
    }
}

/// The same gesture for a UITextView that has been put down to be read.
///
/// Held by the representable's coordinator, which owns the view it is attached
/// to. The recogniser is added once and enabled only while the text view is not
/// editable, so it is never in the way of ordinary typing.
@MainActor
final class DoubleTapToEditGesture: NSObject, UIGestureRecognizerDelegate {
    /// What the host does when the writer asks for the keyboard: leave the
    /// reading view, or take the lock off.
    ///
    /// Handed where among the words the finger landed, in UTF-16, because only
    /// this object knows that and the host may be the one that has to act on
    /// it. Two cases, and they need different things:
    ///
    /// * **The lock.** The words stay in the same text view and it flips to
    ///   editable, so the caret is placed below and the host can ignore the
    ///   offset entirely.
    /// * **A reading view.** The words on screen are a *different* view from
    ///   the one about to take the caret — the reader is torn down and the
    ///   writing surface built in its place — so the placing below has nothing
    ///   left to place into, and the offset is the only way the tap survives
    ///   the handoff. Hosts carry it across; see `ScriptView`'s
    ///   `pendingWriteTarget` for the same trick a line at a time.
    var startWriting: ((Int) -> Void)?

    private weak var textView: UITextView?
    private var recognizer: UITapGestureRecognizer?

    /// Attaches the gesture, once. Called from `makeUIView`, where the text view
    /// is made; calling it again on the same object is a no-op, so a coordinator
    /// that outlives a rebuilt view cannot stack recognisers up.
    func attach(to textView: UITextView) {
        guard recognizer == nil else { return }
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        tap.numberOfTapsRequired = 2
        tap.delegate = self
        textView.addGestureRecognizer(tap)
        self.textView = textView
        recognizer = tap
    }

    /// Whether there is currently anywhere for the gesture to take the writer.
    /// Disabled rather than detached: the answer flips with a lock or a mode,
    /// both of which change several times in a sitting, and adding and removing
    /// a recogniser mid-touch is how a tap gets lost.
    func setOffered(_ offered: Bool) {
        recognizer?.isEnabled = offered
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        // Read straight from the text view rather than from a flag of our own:
        // it is the thing that will refuse the caret, so it is the thing worth
        // asking. A tap that arrives just as editing is turned on elsewhere has
        // nothing to do.
        guard let textView, !textView.isEditable, let startWriting else { return }
        let offset = utf16Offset(of: gesture.location(in: textView), in: textView)
        startWriting(offset)
        // Only reaches anything where this same view is the one that takes the
        // caret — the lock. Where the host swapped the surface underneath us it
        // gives up after its attempts and the host's own handoff is what puts
        // the caret in the words.
        placeCaret(at: offset, attemptsLeft: 3)
    }

    /// The host answers by turning editing on, which is a SwiftUI state change:
    /// the text view is still read-only in this turn of the run loop and would
    /// refuse both the caret and first responder. So the caret follows a turn
    /// behind — and tries a couple more times if it has to, because when the
    /// update lands is SwiftUI's business rather than something to be timed.
    private func placeCaret(at offset: Int, attemptsLeft: Int) {
        guard attemptsLeft > 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let textView else { return }
            guard textView.isEditable else {
                placeCaret(at: offset, attemptsLeft: attemptsLeft - 1)
                return
            }
            if !textView.isFirstResponder { textView.becomeFirstResponder() }
            let length = (textView.text as NSString?)?.length ?? 0
            textView.selectedRange = NSRange(location: min(offset, length), length: 0)
        }
    }

    /// Where among the words the finger landed, in UTF-16 — the count a text
    /// view's own selection is in, and the only count this file needs.
    private func utf16Offset(of point: CGPoint, in textView: UITextView) -> Int {
        guard let position = textView.closestPosition(to: point) else {
            return (textView.text as NSString?)?.length ?? 0
        }
        return textView.offset(from: textView.beginningOfDocument, to: position)
    }

    /// UIKit's own double tap selects the word under the finger, and a
    /// recogniser made to wait behind that one would never fire at all. Both
    /// run: the caret placed above lands a turn later and is what remains.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
