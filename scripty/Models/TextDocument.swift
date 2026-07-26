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
    let links: HALLinks?

    private enum CodingKeys: String, CodingKey {
        case id, projectId, projectTitle, title, documentType, documentTypeLabel
        case content, preview, sortOrder, createdAt, updatedAt
        case links = "_links"
    }

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
