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

/// Result of an insert-into-script call.
struct InsertResult: Decodable {
    var inserted: Int?
    var projectId: Int?
    var firstBlockId: Int?
}
