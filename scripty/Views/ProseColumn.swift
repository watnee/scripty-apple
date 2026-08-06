//
//  ProseColumn.swift
//  scripty
//
//  Where the words of a song or a note sit, and what they are set in — for the
//  writing surfaces and the reading ones alike.
//
//  The counterpart of `ScriptRowChrome`, which does the same job for the
//  screenplay, and it exists for the same reason. Reading and writing are the
//  same document at the same distance: one you can type into and one you
//  cannot, and nothing else. Two surfaces each answering "how far in does the
//  text start, and what size is it" for themselves is what used to make the
//  words move on the way between them — the lyric narrowed and re-centred, the
//  note's headings swelled and its bullets grew dots, and every line of both
//  landed somewhere it had not been a moment earlier.
//
//  So the numbers live here and both sides read them. The type is not a number
//  at all but the editor's own `UIFont`, handed to SwiftUI as it is: a face
//  resolved twice is a face with two sets of metrics, and text that measures
//  differently wraps differently.
//

import SwiftUI
import UIKit

@MainActor
enum ProseColumn {
    /// How far the words start from the edge of the surface.
    ///
    /// Twenty, because that is where a lyric line has always sat: the list's
    /// own sixteen points of row inset plus the four the row keeps for itself.
    /// The plain editor — a new song, and every note — used to start at
    /// sixteen, so the two song editors disagreed about their own left edge.
    static let horizontalPadding: CGFloat = 20

    /// The air above the title, and between it and the first line under it.
    /// A song or a note is headed on both surfaces, in the same face in the
    /// same place; these keep it in the same place vertically too.
    static let titleTopPadding: CGFloat = 8
    static let titleBottomPadding: CGFloat = 16

    /// Slack under the last line, so the end of a document is not flush with
    /// the bottom of the screen. Reading only: the writing surface is a text
    /// view that fills the room it is given and scrolls its own content.
    static let bottomSlack: CGFloat = 24

    /// The words' own width inside a surface `available` points across: what is
    /// left after the margins on either side.
    ///
    /// Handed to the reading surface's text view as a *definite* width rather
    /// than left to `maxWidth: .infinity`. A representable inside a scroll view
    /// is sized from whatever proposal SwiftUI happens to make, and the answer
    /// came out a few points short of the row it stands in for — which is a line
    /// that wraps a word earlier, and every line under it in a different place.
    /// The editable row has no such trouble: a list row is handed a definite
    /// width by UIKit. This is that width, worked out the same way.
    static func columnWidth(in available: CGFloat) -> CGFloat? {
        guard available > horizontalPadding * 2 else { return nil }
        return available - horizontalPadding * 2
    }
}

/// A song or a note, set for reading: the writing surface's own text view with
/// the caret taken out of it.
///
/// UIKit rather than a SwiftUI `Text`, and that is the whole point of it. The
/// two lay text out with different engines, and at the identical width in the
/// identical font SwiftUI breaks a line roughly a word earlier than TextKit
/// does — so a reader built out of `Text` re-wrapped the writer's paragraphs the
/// moment they stopped typing, however carefully the margins were matched. The
/// same engine is the only way the same words break in the same places.
///
/// Not scrollable: it reports its full height to whatever `ScrollView` it is in,
/// exactly as the lyric rows do inside their list. Selectable, so a verse can be
/// copied out of a song being read, and read-only, so it cannot be typed into —
/// which is the only difference between this and the editor it stands in for.
struct ProseText: UIViewRepresentable {
    let text: String
    /// The writer's chosen type size, as a multiple. Passed rather than a point
    /// size so the words resolve their type through `ProseFont`, exactly as the
    /// editors do.
    let textScale: Double
    /// The way back to the keyboard: two taps in the words, as in Pages and
    /// Word. Nil where there is nothing to go back to — a document the server
    /// sent to be read only.
    ///
    /// Handed how far into *this* stretch of words the finger landed, in
    /// UTF-16. A reader is not the view that takes the caret — tapping here
    /// tears this view down and builds the writing surface in its place — so
    /// the offset is the whole of what survives the handoff, and the host is
    /// the one that has to spend it.
    var startWriting: ((Int) -> Void)?

    /// The face the writer chose for everything with no font of its own,
    /// resolved as this view is built rather than inside `updateUIView`: an
    /// observation registered from there belongs to no body, and a document left
    /// open behind the settings sheet would stay in the old face.
    private let defaultFont = PresentationSettings.shared.defaultFont

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.text = text
        view.font = ProseFont.editor(scale: textScale, face: defaultFont)
        // Through the coordinator's copy of the parent: the closure outlives
        // this struct, which SwiftUI rebuilds on every redraw.
        context.coordinator.doubleTap.startWriting = { [weak coordinator = context.coordinator] offset in
            coordinator?.parent?.startWriting?(offset)
        }
        context.coordinator.parent = self
        context.coordinator.doubleTap.attach(to: view)
        context.coordinator.doubleTap.setOffered(startWriting != nil)
        return view
    }

    /// Wrap and grow at the width SwiftUI offers, the way the editable rows do:
    /// a non-scrolling UITextView otherwise reports its longest line's width and
    /// overflows the column.
    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView: UITextView,
                      context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        let fitted = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitted.height))
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
        let font = ProseFont.editor(scale: textScale, face: defaultFont)
        // Only when it really moved — reassigning re-lays-out the whole text.
        if view.font != font { view.font = font }
        context.coordinator.doubleTap.setOffered(startWriting != nil)
    }

    @MainActor
    final class Coordinator {
        /// The double tap that asks for the keyboard on words that have none.
        /// Held here because the recogniser has to outlive the struct.
        let doubleTap = DoubleTapToEditGesture()
        var parent: ProseText?
    }
}
