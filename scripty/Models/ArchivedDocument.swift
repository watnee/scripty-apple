//
//  ArchivedDocument.swift
//  scripty
//
//  A song or note put aside — the archive's row, and deliberately not the
//  trash's.
//
//  The two look alike and mean different things. A trashed document is on a
//  countdown: it carries a `purgesAt`, and the way back is called "restore"
//  because something was taken away. An archived one carries only the date it
//  was shelved. Nothing expires it, it is still whole and still openable, and
//  the way back is one tap that needs no warning attached.
//
//  Songs and notes share this screen for the same reason they share the trash:
//  the server keeps one archive per project and tells the two apart by
//  `documentType`, which is the badge the row draws.
//

import Foundation

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

    /// The kind, for the places that need to say "song" or "note" rather than
    /// draw the server's own label. Falls back the way `TextDocument` does.
    var kind: DocumentType {
        documentType.flatMap { DocumentType(rawValue: $0.uppercased()) } ?? .song
    }

    /// The same fallback the lists draw, so a document that was never named
    /// reads here exactly as it did on the shelf it came from.
    var displayTitle: String {
        let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled \(kind.label)" : trimmed
    }

    static func == (lhs: ArchivedDocument, rhs: ArchivedDocument) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
