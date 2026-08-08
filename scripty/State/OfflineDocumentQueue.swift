//
//  OfflineDocumentQueue.swift
//  scripty
//
//  The outbox for whole songs and notes written while offline.
//
//  Editing a document that exists was already covered — the words are held in
//  `UnsavedDocumentStore` and pushed by the reconnect sweep — but *creating*
//  one had nowhere to go, and said so: a document the server has never seen has
//  no copy for a held draft to be measured against, so the create path
//  deliberately held nothing. The words lived in the editor sheet's `@State`
//  and in no other place on earth. Closing the sheet asked the writer to
//  confirm they were throwing away a song; the app being killed did not ask.
//
//  This is that missing record. A song started in a tunnel goes on disk at the
//  first debounce, appears in the songs list under a negative id like any other
//  song, can be typed into, closed, reopened and relaunched — and becomes a
//  real document the moment there is a connection.
//
//  Simpler than `OfflineBlockQueue` in the one way that matters: documents do
//  not anchor to each other, so there is no chain to keep in order and no
//  cascade when one is refused. It keeps the same temp-id map, and for the same
//  reason — an editor open on a document that has just been created has to be
//  able to find out what the server called it.
//

import Foundation

/// One song or note written while the server was out of reach, waiting to be
/// sent.
struct PendingDocumentCreate: Codable, Equatable {
    /// Negative, and unique within the project. Server ids are positive, so the
    /// sign alone tells a local document from a real one everywhere else.
    let tempId: Int
    /// The words as they stood at the last keystroke. Updated in place while
    /// the writer types, so the queue always holds the newest version — the
    /// same last-write-wins rule the document auto-save follows.
    var title: String
    var content: String
    /// The raw server value ("SONG" / "NOTES"), as `CreateDocumentCommand`
    /// takes it.
    var type: String
    var createdAt: Date
}

/// Per-account, per-project outbox files under Application Support. Not
/// observable on purpose, like every other store here: `ScriptModel`'s
/// `documents` array stays the presentation truth and this only makes it
/// durable.
@MainActor
final class OfflineDocumentQueue {
    /// What one project's file holds. The map outlives the entries it came
    /// from: an editor left open on a document created offline needs to know
    /// what the server called it, and so does the record of which document was
    /// last open.
    private struct Stored: Codable {
        var pending: [PendingDocumentCreate] = []
        var idMap: [String: Int] = [:]
    }

    private let root: URL
    private var cache: [Int: Stored] = [:]

    /// Entries older than this are dropped on read — the same horizon every
    /// other offline store keeps.
    private static let horizon: TimeInterval = 30 * 24 * 60 * 60

    /// `scope` identifies whose work this is (server + account), so two
    /// accounts on one device can never replay each other's writing.
    /// `directory` is injectable for tests; the default sits beside the drafts,
    /// the pending elements and the cached copies.
    init(scope: String, directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "scripty", isDirectory: true)
            .appendingPathComponent("PendingDocuments", isDirectory: true)
        root = base.appendingPathComponent(Self.scopeKey(scope), isDirectory: true)
    }

    /// Escaped rather than hashed, the same spelling the other stores use.
    private static func scopeKey(_ scope: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return scope.addingPercentEncoding(withAllowedCharacters: allowed) ?? scope
    }

    private func fileURL(projectId: Int) -> URL {
        root.appendingPathComponent("project-\(projectId).json")
    }

    private func stored(projectId: Int) -> Stored {
        if let cached = cache[projectId] { return cached }
        var loaded = Stored()
        if let data = try? Data(contentsOf: fileURL(projectId: projectId)),
           let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            let oldest = Date(timeIntervalSinceNow: -Self.horizon)
            loaded.pending = decoded.pending.filter { $0.createdAt > oldest }
            loaded.idMap = decoded.idMap
        }
        cache[projectId] = loaded
        return loaded
    }

    // MARK: - Reading

    /// The queue in the order it was written, which is the order it is sent in
    /// — so a list of songs written on one journey comes out in the order the
    /// writer made them rather than shuffled by a dictionary.
    func pending(projectId: Int) -> [PendingDocumentCreate] {
        stored(projectId: projectId).pending
    }

    func pending(tempId: Int, projectId: Int) -> PendingDocumentCreate? {
        stored(projectId: projectId).pending.first { $0.tempId == tempId }
    }

    func hasPending(projectId: Int) -> Bool {
        !stored(projectId: projectId).pending.isEmpty
    }

    /// The real id a temp id turned into, once its create landed.
    func realId(for tempId: Int, projectId: Int) -> Int? {
        stored(projectId: projectId).idMap[String(tempId)]
    }

    /// The next temp id for this project: one below the lowest already spoken
    /// for, counting both the queue and the mappings, so an id is never reused
    /// while anything still refers to it.
    func nextTempId(projectId: Int) -> Int {
        let s = stored(projectId: projectId)
        let used = s.pending.map(\.tempId) + s.idMap.keys.compactMap { Int($0) }
        return (used.min() ?? 0) - 1
    }

    // MARK: - Writing

    func enqueue(_ entry: PendingDocumentCreate, projectId: Int) {
        var s = stored(projectId: projectId)
        s.pending.append(entry)
        commit(s, projectId: projectId)
    }

    /// Keep the queued words in step with what the writer has typed since.
    func update(tempId: Int, title: String, content: String, projectId: Int) {
        var s = stored(projectId: projectId)
        guard let index = s.pending.firstIndex(where: { $0.tempId == tempId }),
              s.pending[index].title != title || s.pending[index].content != content
        else { return }
        s.pending[index].title = title
        s.pending[index].content = content
        commit(s, projectId: projectId)
    }

    /// Record what the server called the document, and drop the entry. Both
    /// halves are one write: a crash between them would strand an editor
    /// looking for an id that is no longer either pending or mapped.
    func resolve(tempId: Int, realId: Int, projectId: Int) {
        var s = stored(projectId: projectId)
        s.idMap[String(tempId)] = realId
        s.pending.removeAll { $0.tempId == tempId }
        commit(s, projectId: projectId)
    }

    /// Give up on an entry — the writer deleted it before it was ever sent, or
    /// the server refused it.
    func drop(tempId: Int, projectId: Int) {
        var s = stored(projectId: projectId)
        guard s.pending.contains(where: { $0.tempId == tempId }) else { return }
        s.pending.removeAll { $0.tempId == tempId }
        s.idMap.removeValue(forKey: String(tempId))
        commit(s, projectId: projectId)
    }

    func removeAll(projectId: Int) {
        cache[projectId] = Stored()
        try? FileManager.default.removeItem(at: fileURL(projectId: projectId))
    }

    private func commit(_ s: Stored, projectId: Int) {
        cache[projectId] = s
        let url = fileURL(projectId: projectId)
        if s.pending.isEmpty && s.idMap.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        // Swallowed like every other store's: a device that cannot write
        // Application Support is beyond helping, and the in-memory copy still
        // covers this session.
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
