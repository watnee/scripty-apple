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

    /// A line written while the server was out of reach, standing in for the
    /// one the reconnect will make. Server ids are positive, so the sign alone
    /// tells a local line from a real one everywhere else — the same rule
    /// `Block.isLocal` follows.
    var isLocal: Bool { id < 0 }

    /// True when the writer may type into this line. A local line advertises no
    /// links at all — there is nothing on the server to link to — so it would
    /// otherwise come out read-only, which is precisely the line the writer is
    /// in the middle of writing.
    var isEditable: Bool { hasLink(.update) || isLocal }

    var tint: BlockHighlight? { BlockHighlight(serverValue: highlight) }
}

extension SongBlock {
    /// The on-screen stand-in for a line created while offline.
    ///
    /// `order` is the anchor's, which only matters until a load re-sorts — and
    /// a load replaces the collection wholesale and re-inserts the pending
    /// lines by position anyway. Declared in an extension so the memberwise
    /// initialiser survives.
    static func local(tempId: Int, documentId: Int?, projectId: Int?,
                      order: Int?, content: String) -> SongBlock {
        SongBlock(id: tempId, documentId: documentId, projectId: projectId,
                  order: order, content: content, highlight: nil, links: nil)
    }
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
