//
//  Archive.swift
//  scripty
//
//  A song or note the writer has put aside on purpose.
//
//  Kept apart from the types in Trash.swift rather than folded in with a flag,
//  because the two differ in exactly the field that matters: a trashed document
//  carries a purge date and this does not. Nothing expires out of the archive,
//  so there is no date to render and none to read as a deadline.
//

import Foundation

/// An archived song or note.
struct ArchivedDocument: Decodable, Identifiable, Hashable, HALResource {
    let id: Int
    var title: String?
    var documentType: String?
    var documentTypeLabel: String?
    var preview: String?
    var archivedAt: Date?
    let links: HALLinks?

    private enum CodingKeys: String, CodingKey {
        case id, title, documentType, documentTypeLabel, preview, archivedAt
        case links = "_links"
    }

    var displayTitle: String {
        let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    /// The archive holds songs and notes together, told apart by this — the same
    /// shape `TextDocument.kind` reads, so a row can badge them the same way.
    var kind: DocumentType { DocumentType(rawValue: (documentType ?? "").uppercased()) ?? .song }

    static func == (lhs: ArchivedDocument, rhs: ArchivedDocument) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// An archived screenplay.
///
/// Carries what the project list carries rather than what the trash carries:
/// an archived project is one you might still be reading, not one you are
/// deciding whether to recover, so `lastEdited` and the teams earn their place
/// beside `archivedAt`. As with the document above there is no purge date,
/// because there is none to have.
struct ArchivedProject: Decodable, Identifiable, Hashable, HALResource {
    let id: Int
    var title: String?
    var lastEdited: Date?
    var archivedAt: Date?
    var teams: [String]?
    let links: HALLinks?

    private enum CodingKeys: String, CodingKey {
        case id, title, lastEdited, archivedAt, teams
        case links = "_links"
    }

    var displayTitle: String {
        let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Screenplay" : trimmed
    }

    static func == (lhs: ArchivedProject, rhs: ArchivedProject) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Archiving several documents at once, from a selection in the list.
struct BulkArchiveDocumentsCommand: Encodable {
    let ids: [Int]
}
