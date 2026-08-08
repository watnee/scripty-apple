//
//  OfflineBlockQueue.swift
//  scripty
//
//  The outbox for elements written while offline. Editing an existing element
//  offline was already covered — the live text is held and retried — but
//  *creating* one needs somewhere to record an element the server has never
//  seen, in an order that still makes sense once several of them chain off
//  each other. This is that record, and it is on disk, so closing the app on
//  a train does not throw the scene away.
//
//  Mirrors the web client's outbox, minus the three bugs its implementation
//  documents:
//
//  1. The web keeps its temp-id → real-id map in memory for the duration of
//     one sync run, so a run that dies half way strands every create anchored
//     to one that had already landed. Here the map is persisted next to the
//     queue and consulted on every replay, so a half-finished run resumes.
//  2. The web's queue blocks at the head on an op that can never succeed (the
//     anchor was deleted by a collaborator, say). Here a create that fails
//     *permanently* is dropped alone — its dependents are re-anchored to
//     whatever it hung off — and the rest of the queue drains.
//  3. Neither implementation can be perfectly idempotent without a server-side
//     client token: a create whose response is lost in flight may be replayed
//     and duplicate. The window is one request wide and the mapping is
//     recorded the instant a response lands. Documented, not pretended away.
//

import Foundation

/// One element written while the server was out of reach, waiting to be sent.
///
/// `anchorId` is the element it belongs below, and may itself be a `tempId`
/// that has not been created yet — writing three lines offline chains them.
/// `Anchor.end` covers the append case, where the new element goes after
/// whatever the script ends with rather than below a particular line.
struct PendingBlockCreate: Codable, Equatable {
    /// Negative, and unique within the project. Server ids are positive, so
    /// the sign alone tells a local element from a real one everywhere else.
    let tempId: Int
    /// The element this one sits below, or `PendingBlockCreate.appendAnchor`
    /// to mean "at the end of the script".
    var anchorId: Int
    /// The screenplay element type. A lyric line has no types — a song is
    /// lines, not scenes and dialogue — so the song queue stores `""` here and
    /// `nil` in `personId`, and its replay never reads either. Kept rather than
    /// made optional so one queue serves both and the file format stays one
    /// thing.
    var type: String
    /// The words as they stood at the last keystroke. Updated in place while
    /// the writer types, so the queue always holds the newest version — the
    /// same last-write-wins rule the text auto-save follows.
    var content: String
    var personId: Int?
    var createdAt: Date

    /// The anchor value meaning "append", used when there is no element to
    /// hang the new one below (the toolbar +, or a script whose last line is
    /// itself still pending).
    static let appendAnchor = 0

    var isAppend: Bool { anchorId == Self.appendAnchor }
}

/// Per-account, per-project outbox files under Application Support. Not
/// observable on purpose, exactly like `UnsavedDraftStore`: `ScriptModel`'s
/// own `blocks` array stays the presentation truth and this only makes it
/// durable.
@MainActor
final class OfflineBlockQueue {
    /// What one project's file holds. The map outlives the queue entries it
    /// came from: an element created offline keeps its temp identity in any
    /// anchor still queued behind it, so the mapping has to survive the entry
    /// being sent and removed.
    private struct Stored: Codable {
        var pending: [PendingBlockCreate] = []
        var idMap: [String: Int] = [:]
    }

    private let root: URL
    private var cache: [Int: Stored] = [:]

    /// Entries older than this are dropped on read. A month-old pending create
    /// anchored to a script that has moved on is more likely to confuse than
    /// to help, and it matches the draft store's horizon.
    private static let horizon: TimeInterval = 30 * 24 * 60 * 60

    /// `scope` identifies whose work this is (server + account), so two
    /// accounts on one device can never replay each other's writing.
    /// `directory` is injectable for tests; the default sits beside the
    /// drafts and the cached copies.
    ///
    /// `folder` separates one kind of queue from another, exactly as
    /// `UnsavedDraftStore`'s does: the screenplay files by project id, a lyric
    /// by document id, and the two id spaces have nothing to do with each
    /// other — under one folder a song's queue would silently shadow a
    /// screenplay's.
    init(scope: String, directory: URL? = nil, folder: String = "PendingBlocks") {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "scripty", isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)
        root = base.appendingPathComponent(Self.scopeKey(scope), isDirectory: true)
    }

    /// Escaped rather than hashed, the same spelling the other two stores use.
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

    /// The queue in the order it was written, which is the only order it can
    /// safely be replayed in: a later entry may be anchored to an earlier one.
    func pending(projectId: Int) -> [PendingBlockCreate] {
        stored(projectId: projectId).pending
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

    func enqueue(_ entry: PendingBlockCreate, projectId: Int) {
        var s = stored(projectId: projectId)
        s.pending.append(entry)
        commit(s, projectId: projectId)
    }

    /// Keep the queued words in step with what the writer has typed since.
    func updateContent(tempId: Int, to content: String, projectId: Int) {
        var s = stored(projectId: projectId)
        guard let index = s.pending.firstIndex(where: { $0.tempId == tempId }),
              s.pending[index].content != content else { return }
        s.pending[index].content = content
        commit(s, projectId: projectId)
    }

    /// Keep the queued type in step with a retype the writer made before the
    /// element ever reached the server.
    func updateType(tempId: Int, to type: String, projectId: Int) {
        var s = stored(projectId: projectId)
        guard let index = s.pending.firstIndex(where: { $0.tempId == tempId }),
              s.pending[index].type != type else { return }
        s.pending[index].type = type
        commit(s, projectId: projectId)
    }

    /// Record what the server called the element, and drop the entry. Both
    /// halves are one write: a crash between them is what strands dependents.
    func resolve(tempId: Int, realId: Int, projectId: Int) {
        var s = stored(projectId: projectId)
        s.idMap[String(tempId)] = realId
        s.pending.removeAll { $0.tempId == tempId }
        commit(s, projectId: projectId)
    }

    /// Give up on an entry and on everything anchored to it, however deep the
    /// chain runs — sending a create whose anchor will never exist just fails
    /// forever at the head of the queue.
    ///
    /// Returns every temp id dropped, so the caller can take the elements off
    /// the screen too.
    @discardableResult
    func drop(tempId: Int, projectId: Int) -> [Int] {
        var s = stored(projectId: projectId)
        var doomed: Set<Int> = [tempId]
        // The queue is in creation order, so one forward pass catches a chain
        // of any length: a dependent is always behind what it hangs off.
        for entry in s.pending where doomed.contains(entry.anchorId) {
            doomed.insert(entry.tempId)
        }
        s.pending.removeAll { doomed.contains($0.tempId) }
        for id in doomed { s.idMap.removeValue(forKey: String(id)) }
        commit(s, projectId: projectId)
        return doomed.sorted(by: >)
    }

    /// Give up on one entry without taking its dependents with it: anything
    /// anchored to the refused element is re-anchored to whatever the refused
    /// one hung off, so the rest of a chain still lands where it was written —
    /// one line short instead of gone.
    ///
    /// This is for a create the *server* refused. The cascade in `drop` is for
    /// a deliberate delete, where the writer removing an element means to take
    /// its chain along; a refusal earns only its own removal.
    func dropSingle(tempId: Int, projectId: Int) {
        var s = stored(projectId: projectId)
        guard let index = s.pending.firstIndex(where: { $0.tempId == tempId }) else { return }
        let removed = s.pending.remove(at: index)
        for i in s.pending.indices where s.pending[i].anchorId == tempId {
            s.pending[i].anchorId = removed.anchorId
        }
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
        // Swallowed like the draft store's: a device that cannot write
        // Application Support is beyond helping, and the in-memory copy still
        // covers this session.
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
