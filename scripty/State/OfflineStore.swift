//
//  OfflineStore.swift
//  scripty
//
//  The last good copy of what the server said, kept on disk so a launch or a
//  load without a connection still has a script to show. Mirrors the web
//  client's offline store: any project opened while online is cached
//  implicitly, the newest few are kept, and old copies age out. The payloads
//  are the server's own HAL responses, byte for byte — reading one back goes
//  through the same decoding as the network response did, so a cached script
//  carries the same links and affordances the live one advertised.
//
//  Deliberately separate from UnsavedDraftStore: a draft is the writer's only
//  copy of unsaved words and must never be lost, while everything here is a
//  replaceable copy of what the server already has. Evicting a cached project
//  costs nothing but the ability to read it offline.
//

import Foundation

/// One saved payload and when it was saved, so the screen showing it can say
/// how old the copy is.
struct OfflineSnapshot {
    let data: Data
    let savedAt: Date
}

@MainActor
final class OfflineStore {
    /// What a payload is a snapshot of. Not a generic URL cache on purpose:
    /// each kind is one file with one well-known name, and only the reads
    /// that opt in are ever cached.
    enum Kind {
        case root
        case projects
        case blocks(projectId: Int)
        case characters(projectId: Int)
        case documents(projectId: Int)
        /// One song's lyric lines (the default edition only, like `blocks`).
        /// Lives inside the project's directory, so pruning the project takes
        /// its songs with it.
        case songBlocks(projectId: Int, documentId: Int)
        /// One document's full text — a note, or a song the server keeps as
        /// prose rather than lines. The list carries only a preview, so
        /// without this a note opened offline is a blank page over a page of
        /// writing, and typing into it would eventually send the blank.
        case document(projectId: Int, documentId: Int)
    }

    private let root: URL

    /// The web store's retention numbers: the newest dozen projects, held for
    /// a month. Past either bound a copy is more likely stale than useful.
    private static let maxProjects = 12
    private static let horizon: TimeInterval = 30 * 24 * 60 * 60

    /// `scope` identifies whose copies these are (server + account), so two
    /// accounts on one device can never read each other's scripts. Same
    /// convention as UnsavedDraftStore; `directory` is injectable for tests.
    init(scope: String, directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "scripty", isDirectory: true)
            .appendingPathComponent("Offline", isDirectory: true)
        root = base.appendingPathComponent(Self.scopeKey(scope), isDirectory: true)
    }

    /// Escaped rather than hashed so the directory stays readable — the same
    /// spelling UnsavedDraftStore uses, so one account's two stores sit under
    /// matching names.
    private static func scopeKey(_ scope: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return scope.addingPercentEncoding(withAllowedCharacters: allowed) ?? scope
    }

    private func fileURL(_ kind: Kind) -> URL {
        switch kind {
        case .root:
            return root.appendingPathComponent("root.json")
        case .projects:
            return root.appendingPathComponent("projects.json")
        case .blocks(let id):
            return projectDirectory(id).appendingPathComponent("blocks.json")
        case .characters(let id):
            return projectDirectory(id).appendingPathComponent("characters.json")
        case .documents(let id):
            return projectDirectory(id).appendingPathComponent("documents.json")
        case .songBlocks(let projectId, let documentId):
            return projectDirectory(projectId).appendingPathComponent("song-\(documentId).json")
        case .document(let projectId, let documentId):
            return projectDirectory(projectId).appendingPathComponent("document-\(documentId).json")
        }
    }

    private func projectDirectory(_ id: Int) -> URL {
        root.appendingPathComponent("project-\(id)", isDirectory: true)
    }

    /// Failures are swallowed, as in UnsavedDraftStore: a device that cannot
    /// write Application Support is beyond helping, and the live session
    /// carries on regardless — only the offline copy is missing.
    func save(_ data: Data, _ kind: Kind) {
        let url = fileURL(kind)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// The saved payload, however old. No age gate on the way out: a
    /// months-old copy of the writer's own script is still better than an
    /// empty screen, and the screen showing it says when it was saved.
    func load(_ kind: Kind) -> OfflineSnapshot? {
        let url = fileURL(kind)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let savedAt = attributes?[.modificationDate] as? Date ?? .now
        return OfflineSnapshot(data: data, savedAt: savedAt)
    }

    /// Drop the oldest project copies past the retention bounds. Called after
    /// a project's blocks are cached; `keptId` (the project just saved) is
    /// never evicted, whatever its position.
    ///
    /// Eviction never loses work: unsaved words live in UnsavedDraftStore,
    /// which nothing here touches — an evicted project just can't be *read*
    /// offline until it is opened online once more.
    func prune(keeping keptId: Int) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return }
        let dated: [(url: URL, savedAt: Date)] = entries
            .filter { $0.lastPathComponent.hasPrefix("project-") }
            .map { url in
                let blocks = url.appendingPathComponent("blocks.json")
                let attributes = try? fm.attributesOfItem(atPath: blocks.path)
                return (url, attributes?[.modificationDate] as? Date ?? .distantPast)
            }
            .sorted { $0.savedAt > $1.savedAt }
        let oldest = Date(timeIntervalSinceNow: -Self.horizon)
        for (index, entry) in dated.enumerated()
        where entry.url.lastPathComponent != "project-\(keptId)" {
            if index >= Self.maxProjects || entry.savedAt < oldest {
                try? fm.removeItem(at: entry.url)
            }
        }
    }
}
