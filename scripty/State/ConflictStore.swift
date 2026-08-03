//
//  ConflictStore.swift
//  scripty
//
//  Where a `SyncConflict` waits for the writer. The draft stores beside this
//  one keep words that are *going* to the server; this keeps the ones that
//  cannot go without a decision first.
//
//  Durable for the same reason the drafts are, and more so: a held draft is
//  retried by every sweep, so a lost one costs a delay. A conflict is retried
//  by nobody — it is waiting on a person — so if it does not survive the
//  relaunch, the version it was holding is gone for good.
//

import Foundation

/// Per-account, per-collection conflict files under Application Support. Not
/// observable on purpose, like every store here: the models keep the
/// presentation truth and this only makes it outlive the session.
@MainActor
final class ConflictStore {
    private let root: URL
    private var cache: [Int: [String: SyncConflict]] = [:]

    /// Conflicts older than this are dropped on read. Far longer than the
    /// drafts' horizon would justify on its own — 30 days is what the other
    /// stores keep — but the same number, because the words inside are the
    /// same words and a writer who comes back to a project after a month
    /// should find the same story everywhere.
    private static let horizon: TimeInterval = 30 * 24 * 60 * 60

    /// `scope` identifies whose conflicts these are (server + account), so two
    /// accounts on one device can never see each other's words. `folder`
    /// separates the screenplay's conflicts (keyed by project id) from the
    /// lyric editor's (keyed by document id), which are different id spaces —
    /// under one folder a song would silently shadow a screenplay's file.
    /// `directory` is injectable for tests.
    init(scope: String, directory: URL? = nil, folder: String = "Conflicts") {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "scripty", isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)
        root = base.appendingPathComponent(Self.scopeKey(scope), isDirectory: true)
    }

    /// Escaped rather than hashed, the same spelling the other stores use.
    private static func scopeKey(_ scope: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return scope.addingPercentEncoding(withAllowedCharacters: allowed) ?? scope
    }

    private func fileURL(collectionId: Int) -> URL {
        root.appendingPathComponent("collection-\(collectionId).json")
    }

    /// Oldest first: the order they happened in is the order they read in, and
    /// a list that reshuffles as rows are resolved is a list nobody trusts.
    func conflicts(collectionId: Int) -> [SyncConflict] {
        stored(collectionId: collectionId).values.sorted { $0.detectedAt < $1.detectedAt }
    }

    func conflict(id: String, collectionId: Int) -> SyncConflict? {
        stored(collectionId: collectionId)[id]
    }

    func hasPending(collectionId: Int) -> Bool {
        !stored(collectionId: collectionId).isEmpty
    }

    /// File a conflict, or bring an existing one for the same subject up to
    /// date.
    ///
    /// A repeat is not a second row: it is the same disagreement seen again,
    /// usually because the sweep ran twice. The newest words win on both sides
    /// — this device's copy has moved on, and so has the server's — but the
    /// *first* `detectedAt` is kept, because when the divergence began is what
    /// the writer is placing in their memory of the day, and a timestamp that
    /// refreshes itself would say "just now" forever.
    func record(_ conflict: SyncConflict, collectionId: Int) {
        var current = stored(collectionId: collectionId)
        var entry = conflict
        if let existing = current[conflict.id] {
            entry.detectedAt = existing.detectedAt
            // Keep the earliest evidence of where the two sides parted; the
            // newer "base" is only ever a later state of one of them.
            entry.base = existing.base ?? conflict.base
        }
        guard current[conflict.id] != entry else { return }
        current[conflict.id] = entry
        cache[collectionId] = current
        persist(current, collectionId: collectionId)
    }

    func remove(id: String, collectionId: Int) {
        var current = stored(collectionId: collectionId)
        guard current.removeValue(forKey: id) != nil else { return }
        cache[collectionId] = current
        persist(current, collectionId: collectionId)
    }

    func removeAll(collectionId: Int) {
        cache[collectionId] = [:]
        try? FileManager.default.removeItem(at: fileURL(collectionId: collectionId))
    }

    private func stored(collectionId: Int) -> [String: SyncConflict] {
        if let cached = cache[collectionId] { return cached }
        var loaded: [String: SyncConflict] = [:]
        if let data = try? Data(contentsOf: fileURL(collectionId: collectionId)),
           let decoded = try? JSONDecoder().decode([SyncConflict].self, from: data) {
            let oldest = Date(timeIntervalSinceNow: -Self.horizon)
            for conflict in decoded where conflict.detectedAt > oldest {
                loaded[conflict.id] = conflict
            }
        }
        cache[collectionId] = loaded
        return loaded
    }

    private func persist(_ conflicts: [String: SyncConflict], collectionId: Int) {
        let url = fileURL(collectionId: collectionId)
        if conflicts.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        // Failures are swallowed, like every store beside this one: a device
        // that cannot write Application Support is beyond helping, and the
        // in-memory copy still covers the session. Sorted so the file is
        // stable for a given set of conflicts.
        let ordered = conflicts.values.sorted { $0.detectedAt < $1.detectedAt }
        guard let data = try? JSONEncoder().encode(ordered) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
