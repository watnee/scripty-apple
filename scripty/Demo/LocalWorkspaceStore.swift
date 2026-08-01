//
//  LocalWorkspaceStore.swift
//  scripty
//
//  Where the signed-out session's work lives between launches.
//
//  A device with no account writes into `DemoBackend`, which is an in-process
//  stand-in for the API rather than a cache of it: there is no server copy of
//  any of it, and nothing else on the device holds a second one. That makes
//  this file the writer's only copy — the opposite of `OfflineStore`, where
//  every byte is a replaceable snapshot of something the server already has.
//  Losing a project here loses the project.
//
//  So the whole backend is written out as one document rather than a file per
//  resource. Its stores point at each other by id — a block's project, a
//  version's blocks, a trashed project's people — and a half-written set of
//  files would be a workspace whose ids no longer line up. One atomic write is
//  the only shape in which "what the session holds" is either entirely the
//  previous state or entirely the new one.
//
//  Not in the App Group. The widgets are given their rows by the publishers,
//  which write their own small snapshots; nothing outside the app needs to read
//  a whole workspace, and the extensions have no business holding one.
//

import Foundation

/// The signed-out workspace on disk: one document, read at launch and rewritten
/// after anything that changes it.
///
/// `nonisolated` because `DemoBackend` is an actor and calls straight into it —
/// the file work belongs to whichever thread the request is being served on,
/// not to the main one.
nonisolated struct LocalWorkspaceStore: Sendable {
    private let url: URL

    /// `directory` is injectable so the checks can point a store at a temporary
    /// path instead of the real Application Support one.
    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "scripty", isDirectory: true)
            .appendingPathComponent("LocalWorkspace", isDirectory: true)
        url = base.appendingPathComponent("workspace.json")
    }

    /// Atomic, so a crash mid-write leaves the previous workspace intact rather
    /// than a truncated one. Failures are swallowed: a device that cannot write
    /// Application Support is beyond helping here, and refusing to serve the
    /// request would take the session down with the disk.
    func save(_ data: Data) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func load() -> Data? {
        try? Data(contentsOf: url)
    }

    /// Thrown away wholesale when the work it held has been taken somewhere
    /// better — uploaded into an account on sign-in — so the next signed-out
    /// session starts clean rather than on a second copy of it.
    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
