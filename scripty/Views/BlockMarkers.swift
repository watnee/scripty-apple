//
//  BlockMarkers.swift
//  scripty
//
//  The marks that hang beside a screenplay element: the pin and the bookmark
//  the writer put on the line, and the number of comments other people left on
//  it.
//
//  Shared by the read-only and the editable row so a marked line looks the same
//  whichever is drawn, and kept in the margin *beside* the text column rather
//  than over it — a page's right margin is where revision marks have always
//  gone, and text running underneath a badge is text nobody can read.
//

import SwiftUI

/// "3 comments on this line", as a bubble and a number. Draws nothing at all
/// when the count is zero, which is most elements — and is also what a server
/// that never offered the count looks like, so the row degrades to how it
/// looked before.
///
/// Deliberately not tinted like the pin and bookmark: those are marks the
/// writer put on the line themselves, while this is other people's.
struct CommentCountBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Label("\(count)", systemImage: "bubble.left.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
        }
    }

    /// How the badge reads aloud, or nil when there is nothing to say. Rows
    /// hide the badges from VoiceOver and fold them into the row's own label
    /// instead, so a screen reader hears one element per line rather than
    /// several.
    static func spokenLabel(_ count: Int) -> String? {
        switch count {
        case ..<1: return nil
        case 1: return "1 comment"
        default: return "\(count) comments"
        }
    }
}

/// One element's marks, stacked down the margin.
///
/// Stacked rather than strung out in a row because the margin is narrow: a
/// column of small marks fits a phone's gutter, where pin + bookmark + a
/// two-digit comment count side by side does not.
struct BlockMarkerBadges: View {
    let block: Block
    /// How many comments sit on this element; zero draws no bubble.
    var commentCount: Int = 0
    /// Opens the thread. Nil where there is nowhere to open it from — the
    /// bulk-action preview strip, an element the server offered no thread on —
    /// and then the bubble is a badge rather than a button.
    var onComment: (() -> Void)?

    @Environment(\.scriptRowChrome) private var chrome

    /// The width the marks lay out in.
    static let width: CGFloat = 34
    /// That, plus the gap between a mark and the text it annotates — the room
    /// a row leaves for them beside its column.
    static let gutter: CGFloat = width + 8

    private var showsPin: Bool { block.isPinned && chrome.showsPins }
    private var showsBookmark: Bool { block.isBookmarked && chrome.showsBookmarks }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // The writer's own marks share one tint; the comment badge brings
            // its own, since it is other people's. Both are spoken already as
            // part of the row's label, so a screen reader hears one element per
            // line rather than three.
            if showsPin {
                Image(systemName: "pin.fill")
                    .foregroundStyle(.orange)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityHidden(true)
            }
            if showsBookmark {
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(.orange)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityHidden(true)
            }
            comments
        }
        .font(.caption2)
        .frame(width: Self.width, alignment: .leading)
        // Marking a line is a small act with no other confirmation, so the mark
        // arrives with a little movement rather than simply being there.
        .animation(.snappy, value: showsPin)
        .animation(.snappy, value: showsBookmark)
        .animation(.snappy, value: commentCount)
    }

    /// The comment bubble, as a button wherever there is a thread to open.
    ///
    /// This is the only *tap* route to a thread on a line the writer cannot
    /// edit — a locked script, or a reader's copy — where there is no context
    /// menu to reach for.
    @ViewBuilder
    private var comments: some View {
        if commentCount > 0 {
            if let onComment {
                Button(action: onComment) {
                    CommentCountBadge(count: commentCount)
                        // A caption-sized bubble is a 12pt target; the padding
                        // grows it to a thumb's worth and is then taken back
                        // out of the layout, so nothing moves.
                        .padding(11)
                        .contentShape(Rectangle())
                        .padding(-11)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Comments")
                .accessibilityValue("\(commentCount)")
            } else {
                CommentCountBadge(count: commentCount)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Leaves a row room beside its text column for the marks, and hangs them in
/// it.
///
/// The room is the chrome's business rather than the row's: only the script
/// page knows how wide the window is and whether the element labels are already
/// claiming the other margin.
private struct BlockMarkerGutter: ViewModifier {
    let block: Block
    let commentCount: Int
    /// How far down the marks start — the row's own top padding, so a mark
    /// lines up with the first line of the element instead of floating in the
    /// space a scene heading leaves above itself.
    let topInset: CGFloat
    let onComment: (() -> Void)?

    @Environment(\.scriptRowChrome) private var chrome

    func body(content: Content) -> some View {
        content
            .padding(.leading, chrome.leadingGutter)
            .padding(.trailing, chrome.trailingGutter)
            .overlay(alignment: .topTrailing) {
                BlockMarkerBadges(block: block,
                                  commentCount: commentCount,
                                  onComment: onComment)
                    .padding(.top, topInset)
            }
    }
}

extension View {
    /// Hangs this element's marks in the margin beside it.
    func blockMarkers(_ block: Block,
                      commentCount: Int = 0,
                      topInset: CGFloat = 0,
                      onComment: (() -> Void)? = nil) -> some View {
        modifier(BlockMarkerGutter(block: block,
                                   commentCount: commentCount,
                                   topInset: topInset,
                                   onComment: onComment))
    }
}
