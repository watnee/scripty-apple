//
//  UnsavedDraftStore.swift
//  scripty
//
//  Keeps unsaved block text on disk, so the banner's promise — "your work is
//  kept on this device and will be saved when the connection returns" — still
//  holds across a relaunch. ScriptModel writes a draft whenever a commit
//  fails, removes it when a save lands, and re-adopts whatever is left the
//  next time the script loads.
//

import Foundation

/// One block's unsaved words, with enough context to know later whether they
/// are still the newest thing anyone wrote.
struct UnsavedDraft: Codable, Equatable {
    let blockId: Int
    var text: String
    /// What the server had when the save failed. On restore, a server that no
    /// longer matches means someone edited elsewhere in the meantime — pushing
    /// the draft would clobber their newer words, so it is dropped instead.
    var baseText: String?
    var savedAt: Date
}

/// Per-account, per-project draft files under Application Support. Not
/// observable on purpose: nothing draws from this directly — ScriptModel's
/// own `liveText`/`unsavedBlockIds` stay the presentation truth.
@MainActor
final class UnsavedDraftStore {
    private let root: URL
    /// Files already read this session, so the retry loop's repeated saves
    /// don't re-read the disk on every tick.
    private var cache: [Int: [Int: UnsavedDraft]] = [:]

    /// Drafts older than this are dropped on read. The real staleness gate is
    /// `baseText` at restore time; this only stops the directory collecting
    /// abandoned projects forever.
    private static let horizon: TimeInterval = 30 * 24 * 60 * 60

    /// `scope` identifies whose drafts these are (server + account), so two
    /// accounts on one device can never see or replay each other's words.
    /// `directory` is injectable for tests; the default lives in Application
    /// Support next to the app's other files.
    ///
    /// `folder` separates one kind of draft from another: screenplay drafts
    /// key files by project id, song drafts by document id, and the two id
    /// spaces have nothing to do with each other — under one folder a song
    /// could silently shadow a screenplay's file.
    init(scope: String, directory: URL? = nil, folder: String = "Drafts") {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "scripty", isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)
        root = base.appendingPathComponent(Self.scopeKey(scope), isDirectory: true)
    }

    /// Scopes are server-host + username, which can carry characters a file
    /// name can't. Escaped rather than hashed so the directory stays readable.
    private static func scopeKey(_ scope: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return scope.addingPercentEncoding(withAllowedCharacters: allowed) ?? scope
    }

    private func fileURL(projectId: Int) -> URL {
        root.appendingPathComponent("project-\(projectId).json")
    }

    func drafts(projectId: Int) -> [Int: UnsavedDraft] {
        if let cached = cache[projectId] { return cached }
        var loaded: [Int: UnsavedDraft] = [:]
        if let data = try? Data(contentsOf: fileURL(projectId: projectId)),
           let stored = try? JSONDecoder().decode([UnsavedDraft].self, from: data) {
            let oldest = Date(timeIntervalSinceNow: -Self.horizon)
            for draft in stored where draft.savedAt > oldest {
                loaded[draft.blockId] = draft
            }
        }
        cache[projectId] = loaded
        return loaded
    }

    func save(_ draft: UnsavedDraft, projectId: Int) {
        var current = drafts(projectId: projectId)
        guard current[draft.blockId] != draft else { return }
        current[draft.blockId] = draft
        cache[projectId] = current
        persist(current, projectId: projectId)
    }

    func remove(blockId: Int, projectId: Int) {
        var current = drafts(projectId: projectId)
        guard current.removeValue(forKey: blockId) != nil else { return }
        cache[projectId] = current
        persist(current, projectId: projectId)
    }

    func removeAll(projectId: Int) {
        cache[projectId] = [:]
        try? FileManager.default.removeItem(at: fileURL(projectId: projectId))
    }

    private func persist(_ drafts: [Int: UnsavedDraft], projectId: Int) {
        let url = fileURL(projectId: projectId)
        if drafts.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        // Failures are swallowed: a device that can't write Application
        // Support is beyond helping, and the in-memory copy still covers the
        // session. Sorted so the file is stable for a given set of drafts.
        let ordered = drafts.values.sorted { $0.blockId < $1.blockId }
        guard let data = try? JSONEncoder().encode(ordered) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
