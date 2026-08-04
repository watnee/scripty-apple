//
//  ProjectLinks.swift
//  scripty
//
//  Which screenplay on this device is which screenplay in an account.
//
//  A writer with no account writes into the local workspace. Signing in and
//  keeping that work puts a copy in the account — and from that moment there
//  are two of everything, which is only bearable if the app knows the two are
//  the same screenplay. That is all a link is: a local id, an account, and the
//  id the account files it under.
//
//  What it buys is the thing the writer asked for. Signing out goes back to
//  their screenplay rather than to a stale ghost of it; signing in again
//  carries on in it rather than offering to make a third copy; and the words
//  written in either place end up in both. Without the link every crossing is
//  a fork, and the copies drift until neither is the one they mean.
//
//  Kept in UserDefaults beside the other device-wide records
//  (`LastOpenedProject`, `OpenEditorState`) and stamped with the account for
//  the same reason those are: a local session and a fresh account both number
//  their screenplays from 1, so an id alone names nothing. Small, and there is
//  one per screenplay a writer chose to keep — a handful, not a table.
//

import Foundation

/// One screenplay, in the local workspace and in an account.
struct ProjectLink: Codable, Hashable, Sendable {
    /// Its id in `DemoBackend` — the copy on this device.
    var localId: Int
    /// Whose account holds the other copy, spelled as `AppModel.workspaceScope`
    /// spells it: server plus user, so two accounts on one device stay apart.
    var scope: String
    /// Its id in that account.
    var remoteId: Int

    /// What the account's copy said `lastEdited` was when the two were last in
    /// step.
    ///
    /// This is the whole of the app's answer to "has anyone else written in it
    /// since?". A date that has moved means the account's copy changed
    /// somewhere else — a browser, another device — and the local one must not
    /// simply be pushed over it. Nil means the question has never been asked,
    /// which reads the same as "yes, be careful".
    var syncedRemoteEdited: Date?
}

@MainActor
struct ProjectLinkStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Every link this device holds, whatever account it belongs to.
    var all: [ProjectLink] {
        guard let data = defaults.data(forKey: Self.key),
              let links = try? JSONDecoder().decode([ProjectLink].self, from: data) else { return [] }
        return links
    }

    /// The links belonging to one account.
    func links(in scope: String) -> [ProjectLink] {
        all.filter { $0.scope == scope }
    }

    func link(local localId: Int, in scope: String) -> ProjectLink? {
        all.first { $0.localId == localId && $0.scope == scope }
    }

    /// Which screenplay in this account a local one is, if the account has it.
    func remoteId(forLocal localId: Int, in scope: String) -> Int? {
        link(local: localId, in: scope)?.remoteId
    }

    /// The way back: which screenplay on this device an account's one is.
    func localId(forRemote remoteId: Int, in scope: String) -> Int? {
        all.first { $0.remoteId == remoteId && $0.scope == scope }?.localId
    }

    /// Whether any account at all has been given a copy of this local
    /// screenplay — which is what makes keeping it again a second copy rather
    /// than a first.
    func isLinkedAnywhere(local localId: Int) -> Bool {
        all.contains { $0.localId == localId }
    }

    /// Records a link, replacing whatever this device knew about either end of
    /// it. Both ends are cleared and not just the local one: a screenplay
    /// deleted and re-kept can land on an id the account has since reused, and
    /// two links naming the same remote id would make one of them a lie.
    func record(_ link: ProjectLink) {
        var links = all.filter {
            $0.scope != link.scope || ($0.localId != link.localId && $0.remoteId != link.remoteId)
        }
        links.append(link)
        save(links)
    }

    /// Forgets one link — the account no longer has this screenplay, or no
    /// longer means this one by it.
    func forget(local localId: Int, in scope: String) {
        save(all.filter { !($0.localId == localId && $0.scope == scope) })
    }

    private func save(_ links: [ProjectLink]) {
        guard let data = try? JSONEncoder().encode(links) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private static let key = "scripty-project-links"
}
