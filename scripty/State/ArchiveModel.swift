//
//  ArchiveModel.swift
//  scripty
//
//  Reading an archive and acting on what is in it. One model serves the
//  document archive and the screenplay archive, as `TrashModel` serves both
//  trashes: same shape, different scale.
//
//  Shaped like `TrashModel` but deliberately not it: the archive has one way
//  out rather than two, no bulk destroy, and nothing that expires — so a shared
//  generic would be a pile of conditionals over rels only one of them has.
//  What they do share is the rule that matters: every action answers with the
//  refreshed collection, so the list never has to guess what happened.
//

import Foundation
import Observation

@Observable
@MainActor
final class ArchiveModel<Item: Decodable & Identifiable & HALResource> where Item.ID == Int {
    private let app: AppModel
    private let source: HALLink

    private(set) var items: [Item] = []
    private(set) var links = HALLinks()
    private(set) var isLoading = false
    private(set) var isWorking = false
    var errorMessage: String?

    var isEmpty: Bool { items.isEmpty }

    init(app: AppModel, source: HALLink) {
        self.app = app
        self.source = source
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let collection: HALCollection<Item> = try await app.client.fetch(from: source)
            adopt(collection)
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    func canUnarchive(_ item: Item) -> Bool { item.hasLink(.unarchive) }

    /// Whether a selection can be brought back in one call.
    ///
    /// Read from the collection rather than from the rows: the server puts this
    /// on the archive itself, and only when there is something in it — unlike
    /// `archived`, which is advertised empty so a list has somewhere to send its
    /// first document.
    var canBulkUnarchive: Bool { links.contains(.bulkUnarchive) }

    /// Deleting from here is the ordinary soft delete: it lands in the trash and
    /// stays restorable, so it needs no confirmation of its own.
    func canDelete(_ item: Item) -> Bool { item.hasLink(.delete) }

    @discardableResult
    func unarchive(_ item: Item) async -> Bool {
        await act(item.link(.unarchive), method: "POST")
    }

    /// Brings several back at once. Answers with the refreshed archive, as every
    /// action here does, so the sheet never has to work out what left.
    ///
    /// Ids the server skips — something another device brought back while this
    /// sheet was open — simply stay in the reply, which is what makes a stale
    /// selection harmless rather than an error.
    @discardableResult
    func bulkUnarchive(_ ids: [Int]) async -> Bool {
        guard !ids.isEmpty else { return false }
        return await act(links[.bulkUnarchive], method: "POST",
                         body: BulkUnarchiveCommand(ids: ids))
    }

    @discardableResult
    func delete(_ item: Item) async -> Bool {
        // The delete answers with a bare document resource, not the archive, so
        // this drops the row itself and re-reads rather than adopting a reply of
        // the wrong shape.
        guard let link = item.link(.delete), !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await app.client.data(for: link, method: "DELETE")
            items.removeAll { $0.id == item.id }
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// The whole thing behind an archived row, followed by rel — a `TextDocument`
    /// through `document`, say. An archived song is still whole, which is the
    /// point of the archive, and this is how the editor gets at it.
    func resource<T: Decodable>(_ rel: Rel, of item: Item) async -> T? {
        guard let link = item.link(rel) else { return nil }
        do {
            let resource: T = try await app.client.fetch(from: link)
            errorMessage = nil
            return resource
        } catch {
            report(error)
            return nil
        }
    }

    private func act(_ link: HALLink?, method: String,
                     body: (any Encodable)? = nil) async -> Bool {
        guard let link, !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            let collection: HALCollection<Item> = try await app.client.fetch(
                from: link, method: method, body: body)
            adopt(collection)
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    private func adopt(_ collection: HALCollection<Item>) {
        items = collection.items
        links = collection.links
    }

    private func report(_ error: Error) {
        // Nothing cancelled is ever shown — see `isCancelledRequest`.
        guard !error.isCancelledRequest else { return }
        app.handle(error)
        errorMessage = error.localizedDescription
    }
}
