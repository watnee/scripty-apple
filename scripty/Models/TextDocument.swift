//
//  TextDocument.swift
//  scripty
//
//  A project text document — a song (lyrics) or a note (draft). Mirrors the
//  web app's Songs / Notes. The list form carries a `preview`; fetching a
//  single document fills in the full `content`. UI affordances (edit, delete,
//  insert, share) are gated on link presence, like every other resource.
//

import Foundation

enum DocumentType: String, Codable, Sendable, CaseIterable {
    case song = "SONG"
    case notes = "NOTES"
    case other = "OTHER"

    var label: String {
        switch self {
        case .song: return "Song"
        case .notes: return "Notes"
        case .other: return "Other"
        }
    }

    /// Plural heading used in the segmented picker.
    var listLabel: String {
        switch self {
        case .song: return "Songs"
        case .notes, .other: return "Notes"
        }
    }
}

struct TextDocument: Decodable, Identifiable, Hashable, HALResource {
    let id: Int
    var projectId: Int?
    var projectTitle: String?
    var title: String?
    var documentType: String?
    var documentTypeLabel: String?
    var content: String?
    var preview: String?
    var sortOrder: Int?
    var createdAt: Date?
    var updatedAt: Date?
    /// When this was put aside, or nil for anything in the list.
    ///
    /// The archive opens its documents in place — that is what makes it an
    /// archive rather than a bin — so an editor can be holding one, and nothing
    /// else on screen would say so. The list never carries this: the server
    /// omits it for everything the list holds.
    var archivedAt: Date?
    let links: HALLinks?

    private enum CodingKeys: String, CodingKey {
        case id, projectId, projectTitle, title, documentType, documentTypeLabel
        case content, preview, sortOrder, createdAt, updatedAt, archivedAt
        case links = "_links"
    }

    /// Whether this document is in the archive rather than the list.
    ///
    /// Read from the stamp rather than from the `unarchive` link, because the
    /// two answer different questions: the link says whether *this* reader may
    /// bring it back, and this says what they are looking at. A view-only
    /// collaborator gets no link and should still be told.
    var isArchived: Bool { archivedAt != nil }

    var displayTitle: String {
        let name = title ?? ""
        return name.isEmpty ? "Untitled \(kind.label)" : name
    }

    /// Falls back to SONG — matches the server default for a new document.
    var kind: DocumentType {
        documentType.flatMap { DocumentType(rawValue: $0.uppercased()) } ?? .song
    }
}

extension Array where Element == TextDocument {
    /// The most recently edited first, at most `limit` of them.
    ///
    /// One definition of "recent" for the two places that offer a shortcut
    /// straight to a song — the script's Songs menu and the head of the songs
    /// list — so the same handful appears in both, in the same order.
    ///
    /// A document the server never dated is left out rather than sorted as
    /// ancient: it has nothing to be recent about, and a `distantPast` stand-in
    /// would fill a shortcut slot with the row least likely to be wanted.
    func mostRecentlyEdited(limit: Int) -> [TextDocument] {
        guard limit > 0 else { return [] }
        return compactMap { document in document.updatedAt.map { (document, $0) } }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.displayTitle
                    .localizedCaseInsensitiveCompare(rhs.0.displayTitle) == .orderedAscending
            }
            .prefix(limit)
            .map(\.0)
    }

    /// The same list with `document` moved `delta` places among these rows, or
    /// nil when it is not here or already at the end it is being sent to.
    ///
    /// The one-slot move the web's drag handle answers its arrow keys with: a
    /// way to arrange a list without a pointer, which is also the only way on
    /// touch, where a handle cannot be dragged at all.
    func moving(_ document: TextDocument, by delta: Int) -> [TextDocument]? {
        guard let at = firstIndex(where: { $0.id == document.id }) else { return nil }
        let to = at + delta
        guard to >= 0, to < count else { return nil }
        var moved = self
        moved.insert(moved.remove(at: at), at: to)
        return moved
    }

    /// Puts a rearranged view of this list back into it, so the whole list can
    /// be saved after a move made against a searched-down or re-sorted view of
    /// it.
    ///
    /// `rearranged` is the rows that were on screen, in their new order. They
    /// fill the slots those rows already held here, in turn, which leaves every
    /// row the search hid exactly where it was — the same bargain the web
    /// strikes when it drags a card past cards that are `hidden`. Anything in
    /// `rearranged` that is not here is ignored, so a stale row cannot smuggle
    /// itself into the saved order.
    func merging(shown rearranged: [TextDocument]) -> [TextDocument] {
        let here = Set(map(\.id))
        var incoming = rearranged.filter { here.contains($0.id) }[...]
        let onScreen = Set(incoming.map(\.id))
        return map { row in
            onScreen.contains(row.id) ? (incoming.popFirst() ?? row) : row
        }
    }
}

/// New song/note. `documentType` is the raw server value ("SONG" / "NOTES").
struct CreateDocumentCommand: Encodable {
    var projectId: Int
    var title: String
    var documentType: String
    var content: String
}

/// Editing an existing document. Server keeps `type` fixed to what it stored.
struct EditDocumentCommand: Encodable {
    var projectId: Int
    var title: String
    var documentType: String
    var content: String
}

/// A project's songs & notes in their new order, by id. The server reassigns
/// sort order to match, so only the ids being moved need to be sent.
struct ReorderDocumentsCommand: Encodable {
    var orderedIds: [Int]
}

/// The songs to move to the trash in one call. Songs only, as on the web: the
/// server skips any id that is not a song of this project.
struct BulkDeleteDocumentsCommand: Encodable {
    var ids: [Int]
}

/// Switch a document between song and note. The server takes the raw type
/// ("SONG" / "NOTES") and normalizes anything else to NOTES.
struct ChangeDocumentTypeCommand: Encodable {
    var type: String
}

/// Insert a document's content into the screenplay as blocks.
/// Omitting `afterBlockId` appends after the last block; `asType` overrides
/// the default Fountain type (LYRICS for songs).
struct InsertDocumentCommand: Encodable {
    var afterBlockId: Int?
    var asType: String?
}

struct ShareEmailCommand: Encodable {
    var email: String
}

/// Several songs in one message. The server skips anything in `ids` that is
/// not a song of this project, so it answers with what actually went.
struct BulkShareEmailCommand: Encodable {
    var ids: [Int]
    var email: String
}

/// What the server sent, and to whom.
struct BulkShareResult: Decodable {
    var shared: Int?
    var titles: [String]?
    var email: String?
}

/// Result of an insert-into-script call.
struct InsertResult: Decodable {
    var inserted: Int?
    var projectId: Int?
    var firstBlockId: Int?
}
