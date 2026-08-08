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
}

struct TextDocument: Decodable, Identifiable, Hashable, HALResource {
    let id: Int
    /// What this song or note is, as against where it happens to be kept.
    ///
    /// The same song can exist in an account and on a device that was signed
    /// out when it was written; the two number their documents separately and
    /// always will, so `id` cannot say they are the same song and this can. It
    /// is what the app matches on across a sign-in or a sign-out — see
    /// `AppModel.carryOpenDocument`.
    ///
    /// Optional: a server older than the field simply does not send it, and
    /// nothing here fails for the want of it — the crossing just does not
    /// reopen the song it would otherwise have reopened.
    var uid: String?
    var projectId: Int?
    var projectTitle: String?
    var title: String?
    var documentType: String?
    var documentTypeLabel: String?
    /// The folder this is filed under, or nil for an unfiled one.
    ///
    /// Unfiled is not a lesser state — a project with no folders has every
    /// document here, and the list reads exactly as it always has.
    var folderId: Int?
    /// That folder's name, so a document fetched on its own can say where it
    /// lives without also fetching the folder list.
    var folderName: String?
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
        case id, uid, projectId, projectTitle, title, documentType, documentTypeLabel
        case folderId, folderName
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

    /// A song or note written while the server was out of reach, standing in
    /// for the document the reconnect will make. Server ids are positive, so
    /// the sign alone tells a local document from a real one everywhere else —
    /// the rule `Block.isLocal` and `SongBlock.isLocal` already follow.
    var isLocal: Bool { id < 0 }

    var displayTitle: String {
        let name = title ?? ""
        return name.isEmpty ? "Untitled \(kind.label)" : name
    }

    /// Falls back to SONG — matches the server default for a new document.
    var kind: DocumentType {
        documentType.flatMap { DocumentType(rawValue: $0.uppercased()) } ?? .song
    }
}

extension TextDocument {
    /// The on-screen stand-in for a song or note created while offline.
    ///
    /// No links at all, which is the honest answer: there is nothing on the
    /// server to link to, so every affordance gated on one — rename, archive,
    /// insert into the script, share by email — correctly stays away until the
    /// document exists. Editing is the exception, and it is handled by id
    /// rather than by link (`ScriptModel.saveDocumentOutcome`), because typing
    /// into what you have just written is the whole point.
    ///
    /// `updatedAt` is the last keystroke, so the lists that sort by it put a
    /// song written five minutes ago where the writer expects to find it.
    /// Declared in an extension so the memberwise initialiser survives.
    static func local(tempId: Int, projectId: Int, title: String, content: String,
                      type: DocumentType, updatedAt: Date) -> TextDocument {
        TextDocument(id: tempId, uid: nil, projectId: projectId, projectTitle: nil,
                     title: title, documentType: type.rawValue,
                     documentTypeLabel: type.label, folderId: nil, folderName: nil,
                     content: content, preview: content, sortOrder: nil,
                     createdAt: updatedAt, updatedAt: updatedAt, archivedAt: nil,
                     links: nil)
    }
}

extension Array where Element == TextDocument {
    /// The song or note a remembered record names, by whichever of its two
    /// names still applies here.
    ///
    /// The uid first, because it is the one that survives a crossing: the record
    /// may have been written in a signed-out workspace and be being read in an
    /// account, where the same song is filed under a different number. The id is
    /// the fallback, for a record with no uid — an older build's, or one written
    /// against a server that does not publish them — and for the ordinary case
    /// where nothing has crossed anything and the two agree.
    ///
    /// Nil when neither finds it, which is a song deleted since. Every caller
    /// treats that as "reopen nothing", because the alternative is opening a
    /// song the writer never asked for.
    func rememberedOne(id: Int, uid: String?) -> TextDocument? {
        if let uid, !uid.isEmpty, let matched = first(where: { $0.uid == uid }) { return matched }
        return first { $0.id == id }
    }

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
