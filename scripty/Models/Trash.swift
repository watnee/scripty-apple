//
//  Trash.swift
//  scripty
//
//  Things that were deleted and can still be got back.
//
//  Deleting has always been a soft delete on the server; the client just had no
//  way to read the trash, so every delete looked final from the iPad and was
//  reversible from the browser. `purgeAt` matters as much as the item itself —
//  recovery has a deadline, and a list that cannot say when is asking the
//  writer to guess.
//

import Foundation

/// A screenplay element in the trash.
struct DeletedBlock: Decodable, Identifiable, Hashable, HALResource {
    let id: Int
    var preview: String?
    var empty: Bool?
    var typeLabel: String?
    var editionName: String?
    var deletedByName: String?
    var deletedAt: Date?
    var purgeAt: Date?
    let links: HALLinks?

    private enum CodingKeys: String, CodingKey {
        case id, preview, empty, typeLabel, editionName, deletedByName
        case deletedAt, purgeAt
        case links = "_links"
    }

    /// An element deleted while still blank has no preview to show.
    var isEmptyElement: Bool { empty ?? false }

    var displayPreview: String {
        let trimmed = (preview ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Empty element" : trimmed
    }

    static func == (lhs: DeletedBlock, rhs: DeletedBlock) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A song or note in the trash.
struct DeletedDocument: Decodable, Identifiable, Hashable, HALResource {
    let id: Int
    var title: String?
    var documentType: String?
    var documentTypeLabel: String?
    var preview: String?
    var deletedAt: Date?
    var purgesAt: Date?
    let links: HALLinks?

    private enum CodingKeys: String, CodingKey {
        case id, title, documentType, documentTypeLabel, preview
        case deletedAt, purgesAt
        case links = "_links"
    }

    var displayTitle: String {
        let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    static func == (lhs: DeletedDocument, rhs: DeletedDocument) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A whole screenplay in the trash.
struct TrashedProject: Decodable, Identifiable, Hashable, HALResource {
    let id: Int
    var title: String?
    var deletedAt: Date?
    let links: HALLinks?

    private enum CodingKeys: String, CodingKey {
        case id, title, deletedAt
        case links = "_links"
    }

    var displayTitle: String {
        let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Screenplay" : trimmed
    }

    static func == (lhs: TrashedProject, rhs: TrashedProject) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
