//
//  SongBlock.swift
//  scripty
//
//  One line of a lyric.
//
//  A song is stored as ordered blocks on the server, the way a screenplay is —
//  which is what lets a line be reordered, highlighted, versioned and scoped to
//  an edition. This client used to edit songs as one lump of text through the
//  document endpoint, so none of that was reachable.
//

import Foundation

struct SongBlock: Decodable, Identifiable, Hashable, HALResource {
    let id: Int
    var documentId: Int?
    var projectId: Int?
    var order: Int?
    var content: String?
    var highlight: String?
    let links: HALLinks?

    private enum CodingKeys: String, CodingKey {
        case id, documentId, projectId, order, content, highlight
        case links = "_links"
    }

    var text: String { content ?? "" }

    var isEditable: Bool { hasLink(.update) }

    var tint: BlockHighlight? { BlockHighlight(serverValue: highlight) }
}

/// A new line. `content` may be blank — a writer usually makes the line before
/// they have the words for it.
struct CreateSongBlockCommand: Encodable {
    var content: String
}

struct EditSongBlockCommand: Encodable {
    var content: String
}

/// Absolute 1-based position, matching what the collection reports.
struct MoveSongBlockCommand: Encodable {
    var position: Int
}

/// A blank or unknown colour clears the tint, as on the server.
struct SetSongBlockHighlightCommand: Encodable {
    var highlight: String?
}
