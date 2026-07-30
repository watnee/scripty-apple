//
//  ScrollThumb.swift
//  scripty
//
//  The scroll bar as Word's iOS app draws it: a thin thumb that fades in
//  against the right edge while the script moves and fades away once it
//  stops — and, unlike the system indicator it replaces, one you can grab.
//  A feature-length script is a few hundred screens tall, and the system bar
//  only reports that crossing; the thumb turns it into a handle, so the whole
//  script rides under one drag.
//

import SwiftUI

extension View {
    /// Replaces the system scroll indicator with a draggable thumb. Applied
    /// to the ScrollView itself, like the scroll modifiers it is built from.
    func draggableScrollThumb() -> some View {
        modifier(ScrollThumb())
    }
}

private struct ScrollThumb: ViewModifier {
    /// The scroll view's latest report of where it is and how much there is.
    @State private var probe = Probe()
    /// The handle back into the scroll view — dragging the thumb drives the
    /// content through it. Left unset otherwise, so merely being bound never
    /// moves anything.
    @State private var position = ScrollPosition()
    @State private var isVisible = false
    @State private var isDragging = false
    /// Where the thumb stood when the finger landed on it; the drag is
    /// measured from here rather than integrated step by step, so a slow
    /// drag cannot accumulate rounding drift.
    @State private var dragStartProgress: CGFloat = 0
    /// The pending fade-out. Cancelled by any new movement, so the thumb
    /// stays up exactly as long as the scrolling does.
    @State private var hideTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .scrollIndicators(.hidden)
            .scrollPosition($position)
            .onScrollGeometryChange(for: Probe.self) { Probe($0) } action: { old, new in
                probe = new
                guard new.canScroll else {
                    // Content that fits has nothing to indicate — and a
                    // rubber-band stretch on it must not flash the thumb.
                    hide(after: 0)
                    return
                }
                // Only genuine travel wakes the thumb: a bar folding away
                // changes the insets without any scrolling, and reacting to
                // that would flash the thumb at a writer who never moved.
                if new.offset != old.offset, new.insetsMatch(old) {
                    show()
                }
            }
            .overlay(alignment: .trailing) { track }
            .onDisappear { hideTask?.cancel() }
    }

    /// The strip the thumb rides in. It spans the safe area — the same region
    /// the scroll geometry's insets carve out of the container — so the
    /// thumb's track and the content's travel measure the same journey.
    private var track: some View {
        GeometryReader { proxy in
            let trackHeight = proxy.size.height
            let thumbHeight = thumbHeight(in: trackHeight)
            if probe.canScroll, isVisible || isDragging {
                thumb(height: thumbHeight)
                    .offset(y: probe.progress * max(0, trackHeight - thumbHeight))
                    .gesture(drag(trackHeight: trackHeight, thumbHeight: thumbHeight))
                    .transition(.opacity)
            }
        }
        .frame(width: Self.grabWidth)
        .padding(.vertical, 4)
        // The thumb duplicates scrolling, which VoiceOver already does with a
        // three-finger swipe — the system indicator it replaces is invisible
        // to VoiceOver for the same reason.
        .accessibilityHidden(true)
    }

    private func thumb(height: CGFloat) -> some View {
        Capsule()
            .fill(.secondary)
            .opacity(isDragging ? 0.9 : 0.55)
            // Swelling under the finger is the thumb saying "caught": the
            // difference between dragging the script and flicking past it.
            .frame(width: isDragging ? 7 : 4)
            .frame(width: Self.grabWidth, height: height, alignment: .trailing)
            // The visible sliver is far too thin to hit, so the whole grab
            // strip beside it takes the touch — the capsule's frame, not the
            // track's, so taps along the empty edge still reach the script.
            .contentShape(.rect)
            .padding(.trailing, 3)
            .animation(.easeOut(duration: 0.15), value: isDragging)
    }

    /// Wide enough to catch a thumb-tip; the visible capsule keeps to a
    /// sliver of it.
    private static let grabWidth: CGFloat = 24

    /// Proportional like the system bar — the thumb's share of the track is
    /// the viewport's share of the script — but never shrunk past a graspable
    /// size on a script hundreds of screens tall.
    private func thumbHeight(in trackHeight: CGFloat) -> CGFloat {
        let proportional = trackHeight * probe.visibleFraction
        return min(trackHeight, max(44, proportional))
    }

    private func drag(trackHeight: CGFloat, thumbHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    dragStartProgress = probe.progress
                }
                let usable = trackHeight - thumbHeight
                guard usable > 0 else { return }
                let progress = min(max(
                    dragStartProgress + value.translation.height / usable, 0), 1)
                // The track maps onto the whole scrollable span, so the far
                // end of the drag is the far end of the script. Converted
                // back from "distance below the top" to the offset's own
                // terms, which start above zero by the top inset.
                position.scrollTo(y: progress * probe.range - probe.topInset)
            }
            .onEnded { _ in
                isDragging = false
                hide(after: Self.linger)
            }
    }

    /// How long the thumb outlives the last movement before fading.
    private static let linger: TimeInterval = 0.9

    private func show() {
        hideTask?.cancel()
        if !isVisible {
            withAnimation(.easeOut(duration: 0.12)) { isVisible = true }
        }
        hide(after: Self.linger)
    }

    private func hide(after delay: TimeInterval) {
        hideTask?.cancel()
        hideTask = Task {
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled, !isDragging else { return }
            withAnimation(.easeOut(duration: 0.35)) { isVisible = false }
        }
    }

    /// One geometry event, in the terms the thumb cares about. The offset and
    /// the insets are kept separate for the same reason UserScrollSpy keeps
    /// them: a bar hiding shifts the insets without any scrolling, and the
    /// show-filter needs to tell the two apart.
    private struct Probe: Equatable {
        var offset: CGFloat = 0
        var topInset: CGFloat = 0
        var bottomInset: CGFloat = 0
        var contentHeight: CGFloat = 0
        var containerHeight: CGFloat = 0

        init() {}

        init(_ geometry: ScrollGeometry) {
            offset = geometry.contentOffset.y
            topInset = geometry.contentInsets.top
            bottomInset = geometry.contentInsets.bottom
            contentHeight = geometry.contentSize.height
            containerHeight = geometry.containerSize.height
        }

        /// The full scrollable span: how far the offset travels between the
        /// top rest position and the bottom one.
        var range: CGFloat {
            contentHeight + topInset + bottomInset - containerHeight
        }

        var canScroll: Bool { range > 1 }

        /// How far down the journey the viewport sits, clamped so an
        /// over-scroll bounce pins the thumb to the end rather than pushing
        /// it off the track.
        var progress: CGFloat {
            min(max((offset + topInset) / max(range, 1), 0), 1)
        }

        /// The viewport's share of everything there is to see.
        var visibleFraction: CGFloat {
            containerHeight / max(contentHeight + topInset + bottomInset, 1)
        }

        func insetsMatch(_ other: Probe) -> Bool {
            topInset == other.topInset && bottomInset == other.bottomInset
        }
    }
}
