//
//  DocumentsRequest.swift
//  scripty
//
//  What something outside the screenplay asked the Songs & Notes screen to
//  show. Three things can ask: the toolbar button (songs, no document), the
//  Home Screen's Songs/Notes quick actions (one list, no document), and a
//  Home Screen widget row (the list a named song or note is on, and that
//  document open).
//
//  One value rather than a pair of optionals threaded side by side, because
//  the two halves only ever mean anything together — a document id with no
//  list to find it on, or a list opened on a document from the other one,
//  are both states nothing should be able to express.
//

import Foundation

struct DocumentsRequest: Equatable, Sendable {
    /// Which of the two lists — songs or notes — the sheet opens on.
    var type: DocumentType

    /// A particular song or note to open straight into, if the request named
    /// one. Nil opens the list itself, which is what every route but a widget
    /// row does.
    ///
    /// Honoured only when the loaded list actually holds it: a widget row
    /// naming a song since deleted still opens the list, which is where its
    /// writer was heading anyway.
    var documentId: Int?

    init(type: DocumentType, documentId: Int? = nil) {
        self.type = type
        self.documentId = documentId
    }
}
