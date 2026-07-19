//
//  ScriptEdition.swift
//  scripty
//
//  A named variant of a screenplay: a shooting draft, a table read, a
//  production revision.
//
//  The API has taken an `editionId` on blocks, imports and version history all
//  along, but nothing said which ids existed — in the web app it comes from the
//  session, so the parameter worked there and nowhere else. Reading this
//  collection is what makes it usable from here.
//

import Foundation

struct ScriptEdition: Decodable, Identifiable, Hashable, HALResource {
    let id: Int
    var name: String?
    /// The edition opened when a request does not name one.
    var isDefault: Bool?
    /// The edition view-only readers see. Independent of the default: a writer
    /// can work in a draft while readers stay on the last published cut.
    var isPublished: Bool?
    var lastEdited: Date?
    var blockCount: Int?
    let links: HALLinks?

    private enum CodingKeys: String, CodingKey {
        case id, name, blockCount, lastEdited
        case isDefault = "default"
        case isPublished = "published"
        case links = "_links"
    }

    var displayName: String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Edition" : trimmed
    }

    var isTheDefault: Bool { isDefault ?? false }
    var isThePublished: Bool { isPublished ?? false }

    var sizeSummary: String {
        guard let count = blockCount else { return "" }
        return "\(count) " + (count == 1 ? "element" : "elements")
    }
}

/// Creating an edition may copy the script from an existing one — how a
/// revision starts life as a duplicate of the draft it revises. Omitting the
/// source makes an empty edition.
struct CreateEditionCommand: Encodable {
    var name: String
    var copyFromEditionId: Int?
}

struct RenameEditionCommand: Encodable {
    var name: String
}
