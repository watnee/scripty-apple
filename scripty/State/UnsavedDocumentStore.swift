//
//  UnsavedDocumentStore.swift
//  scripty
//
//  Keeps a note's (or a prose song's) unsaved title and content on disk, the
//  way UnsavedDraftStore keeps a block's unsaved text: written when a document
//  save cannot get out, removed when one lands, drained by the reconnect
//  sweep — with the sheet open or long closed. Before this, those words lived
//  in the editor sheet's own @State and went down with the app.
//
//  A separate type rather than a third folder of UnsavedDraftStore because the
//  shape differs: a document draft is a title *and* a body, and the staleness
//  gate on restore has to check both.
//

import Foundation

/// One document's unsaved words, with enough context to know later whether
/// they are still the newest thing anyone wrote.
struct UnsavedDocumentDraft: Codable, Equatable {
    let documentId: Int
    var title: String
    var content: String
    /// What the server had when the save failed. On restore or drain, a server
    /// that no longer matches means someone edited elsewhere in the meantime —
    /// pushing the draft would clobber their newer words, so it is dropped
    /// instead. Nil means "no evidence", which restores rather than drops: the
    /// words are the writer's own and silence is the worse failure.
    var baseTitle: String?
    var baseContent: String?
    var savedAt: Date
}

/// Per-account, per-project draft files under Application Support. Not
/// observable on purpose, like the other stores: ScriptModel's
/// `heldDocumentIds` stays the presentation truth and this only makes it
/// durable.
@MainActor
final class UnsavedDocumentStore {
    private let root: URL
    private var cache: [Int: [Int: UnsavedDocumentDraft]] = [:]

    /// Drafts older than this are dropped on read — the same horizon every
    /// other offline store keeps.
    private static let horizon: TimeInterval = 30 * 24 * 60 * 60

    /// `scope` identifies whose drafts these are (server + account), so two
    /// accounts on one device can never see or replay each other's words.
    /// `directory` is injectable for tests.
    init(scope: String, directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "scripty", isDirectory: true)
            .appendingPathComponent("NoteDrafts", isDirectory: true)
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

    func drafts(projectId: Int) -> [Int: UnsavedDocumentDraft] {
        if let cached = cache[projectId] { return cached }
        var loaded: [Int: UnsavedDocumentDraft] = [:]
        if let data = try? Data(contentsOf: fileURL(projectId: projectId)),
           let stored = try? JSONDecoder().decode([UnsavedDocumentDraft].self, from: data) {
            let oldest = Date(timeIntervalSinceNow: -Self.horizon)
            for draft in stored where draft.savedAt > oldest {
                loaded[draft.documentId] = draft
            }
        }
        cache[projectId] = loaded
        return loaded
    }

    func draft(documentId: Int, projectId: Int) -> UnsavedDocumentDraft? {
        drafts(projectId: projectId)[documentId]
    }

    func hasPending(projectId: Int) -> Bool {
        !drafts(projectId: projectId).isEmpty
    }

    func save(_ draft: UnsavedDocumentDraft, projectId: Int) {
        var current = drafts(projectId: projectId)
        guard current[draft.documentId] != draft else { return }
        current[draft.documentId] = draft
        cache[projectId] = current
        persist(current, projectId: projectId)
    }

    func remove(documentId: Int, projectId: Int) {
        var current = drafts(projectId: projectId)
        guard current.removeValue(forKey: documentId) != nil else { return }
        cache[projectId] = current
        persist(current, projectId: projectId)
    }

    func removeAll(projectId: Int) {
        cache[projectId] = [:]
        try? FileManager.default.removeItem(at: fileURL(projectId: projectId))
    }

    private func persist(_ drafts: [Int: UnsavedDocumentDraft], projectId: Int) {
        let url = fileURL(projectId: projectId)
        if drafts.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        // Failures are swallowed, like every store beside this one: a device
        // that can't write Application Support is beyond helping, and the
        // in-memory copy still covers the session.
        let ordered = drafts.values.sorted { $0.documentId < $1.documentId }
        guard let data = try? JSONEncoder().encode(ordered) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
