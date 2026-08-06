//
//  TextDocumentFolder.swift
//  scripty
//
//  A folder: the name a writer files some of a project's songs or notes under.
//  Mirrors the web app's folder chips above the Songs / Notes lists.
//
//  Flat, and belonging to one list rather than to the project — "Act One" under
//  Songs and "Act One" under Notes are two folders, and neither list is ever
//  handed the other's. A folder carries no documents: each `TextDocument` says
//  which folder it is in, so the list is the one place the arrangement lives.
//
//  Affordances are gated on links, like every other resource here: rename and
//  remove appear only where the server advertised them.
//

import Foundation

struct TextDocumentFolder: Decodable, Identifiable, Hashable, HALResource {
    let id: Int
    var projectId: Int?
    /// The raw server value ("SONG" / "NOTES") for the list this belongs to.
    var documentType: String?
    var name: String?
    /// How many of the list's documents are filed here, as the server counted
    /// them. Only used for a heading's count — what is *in* a folder is decided
    /// from the documents themselves, so a stale number can never hide a row.
    var documentCount: Int?
    var createdAt: Date?
    var updatedAt: Date?
    let links: HALLinks?

    private enum CodingKeys: String, CodingKey {
        case id, projectId, documentType, name, documentCount, createdAt, updatedAt
        case links = "_links"
    }

    /// Never empty: the server refuses a blank name, so this only stands in for
    /// a folder from a server that stopped sending one.
    var displayName: String {
        let value = name ?? ""
        return value.isEmpty ? "Untitled Folder" : value
    }

    /// Which list this folder belongs to, defaulting to songs as the document
    /// itself does.
    var kind: DocumentType {
        documentType.flatMap { DocumentType(rawValue: $0.uppercased()) } ?? .song
    }

    var canRename: Bool { hasLink(.renameFolder) }
    var canDelete: Bool { hasLink(.deleteFolder) }
}

extension Array where Element == TextDocumentFolder {
    /// This list's folders, in the order a heading should show them.
    ///
    /// The server already sorts by name and the app keeps that: a folder has no
    /// arrangement of the writer's own to preserve, and a list of names sorted
    /// by name is the least surprising thing when the name is all it shows.
    func forList(_ kind: DocumentType) -> [TextDocumentFolder] {
        filter { folder in
            kind == .song ? folder.kind == .song : folder.kind != .song
        }
    }
}

/// Making a folder, and renaming one. The server takes the same one field
/// either way, and answers both with the refreshed folder collection.
struct FolderNameCommand: Encodable {
    var name: String
}

/// Filing one document. A nil `folderId` is what takes it out of its folder —
/// there is no separate unfile call, because a document in no folder is the
/// ordinary state rather than a special one.
///
/// Encoded explicitly rather than through the synthesised `Encodable`, which
/// would drop a nil field entirely and leave the server reading "leave it
/// alone" where "take it out" was meant.
struct MoveToFolderCommand: Encodable {
    var folderId: Int?

    private enum CodingKeys: String, CodingKey {
        case folderId
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(folderId, forKey: .folderId)
    }
}

/// Filing the ticked rows. Same nil-means-unfile rule, and the same reason for
/// spelling the encoding out.
struct BulkMoveToFolderCommand: Encodable {
    var ids: [Int]
    var folderId: Int?

    private enum CodingKeys: String, CodingKey {
        case ids, folderId
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ids, forKey: .ids)
        try container.encode(folderId, forKey: .folderId)
    }
}
