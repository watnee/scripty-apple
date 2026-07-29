//
//  BookmarksWidgetPublisher.swift
//  scripty
//
//  Where the app meets its Bookmarks widget: it turns the flagged elements of
//  the script on screen into the handful of rows the widget draws, and tells
//  WidgetKit when they have changed.
//
//  The shape of this file is WidgetPublisher.swift's, for the same reasons. The
//  pure half — merging, ordering, the URLs — lives next door in
//  Shared/BookmarksWidgetData.swift, which the extension compiles too and
//  Tests/BookmarksWidget checks without a simulator. Only the part that talks
//  to WidgetKit is here.
//

import Foundation
import SwiftUI
import WidgetKit

enum BookmarksWidgetPublisher {
    /// Republishes one screenplay's bookmarks from the elements on screen.
    ///
    /// Called wherever the blocks settle rather than from the bookmark toggle,
    /// so that every path which changes what the rows say is covered by one
    /// call site: flagging and unflagging, but also editing a flagged line,
    /// deleting one, undoing any of that, and the sync poll bringing in a
    /// collaborator's change.
    ///
    /// The demo publishes nothing, exactly as the other two widgets do not. Its
    /// script lives in memory for as long as the app is running, so a row
    /// quoting it is a row that could only ever fail to open — and it would sit
    /// on the Home Screen long after the demo was over, since nothing but this
    /// app can take it back down.
    ///
    /// An unflagged script still publishes: an empty list for this project is
    /// how the last bookmark coming off it takes its row away.
    static func publish(_ blocks: [Block], project: Project, isDemo: Bool,
                        at now: Date = .now) {
        guard !isDemo else { return }
        let rows = blocks.filter(\.isBookmarked).map { block in
            WidgetBookmark(blockId: block.id,
                           projectId: project.id,
                           projectTitle: project.displayTitle,
                           // The same clip the outline sidebar puts on a line,
                           // including the "(Untitled)" an empty element reads
                           // as — a flagged blank line is rare but it should
                           // not draw as a blank row.
                           preview: ScriptOutline.preview(block.content ?? ""),
                           elementLabel: block.blockType.label,
                           // A block the server has not ordered sorts to the
                           // top of its screenplay's run rather than being
                           // dropped; nothing about it is wrong, and the
                           // widget would rather show it than not.
                           order: block.order ?? 0,
                           markedAt: now)
        }
        guard BookmarksWidgetStore.publish(rows, forProject: project.id, at: now) else { return }
        WidgetCenter.shared.reloadTimelines(ofKind: BookmarksWidgetStore.widgetKind)
    }

    /// Empties the widget. Signing out goes through here, and it matters more
    /// for this widget than for the other two: its rows are not titles but the
    /// script itself, readable off the Home Screen by whoever picks the phone
    /// up next.
    static func clear() {
        BookmarksWidgetStore.clear()
        WidgetCenter.shared.reloadTimelines(ofKind: BookmarksWidgetStore.widgetKind)
    }
}

extension View {
    /// Hands over the element a tapped Bookmarks row asked for, once.
    ///
    /// `initial` is what catches the tap that opened this screenplay — that was
    /// decided before the script view existed — while the change itself catches
    /// a tap for the screenplay already on screen. The request is written back
    /// to nil either way, so it cannot fire again on a later rebuild.
    ///
    /// A named modifier taking a plain function rather than the `onChange`
    /// written inline where it is used: `ScriptView`'s body is long enough that
    /// adding one more closure to the chain put it past the compiler's
    /// type-checking budget once already ("unable to type-check this expression
    /// in reasonable time"), and the fix that worked was moving the closure out
    /// into a function of its own.
    func openingBookmark(_ request: Binding<Int?>,
                         perform: @escaping (Int) -> Void) -> some View {
        onChange(of: request.wrappedValue, initial: true) { _, blockId in
            guard let blockId else { return }
            request.wrappedValue = nil
            perform(blockId)
        }
    }
}
