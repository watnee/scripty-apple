//
//  TrashModel.swift
//  scripty
//
//  Reading a list of set-aside things and acting on what is in it. One model
//  serves the element trash, the screenplay trash and the document archive,
//  because the shape is the same: a list where each item can be put back or
//  taken further away, reached from a link the owning collection advertised.
//
//  Which two rels those are is the one thing that differs. A trash restores and
//  purges; the archive unarchives, and its second action is the ordinary soft
//  delete — an archived song decided against for good should not have to come
//  back off the shelf first. So the rels are given at construction rather than
//  assumed, and everything below reads them.
//
//  Every action answers with the refreshed collection, so the list never has to
//  guess what happened.
//

import Foundation
import Observation

@Observable
@MainActor
final class TrashModel<Item: Decodable & Identifiable & HALResource> where Item.ID == Int {
    private let app: AppModel
    private let source: HALLink
    /// The way back — `restore` in a trash, `unarchive` on the shelf.
    private let restoreRel: Rel
    /// The way further away — `purge` in a trash, `delete` from the archive,
    /// which is the ordinary trip to the trash rather than the end of one.
    private let removeRel: Rel
    /// How that second action is sent. A purge is a DELETE on the item; the
    /// archive's delete is advertised as one too, so this is the same either
    /// way — named rather than hard-coded so a collection that spells it
    /// differently is one argument away.
    private let removeMethod: String

    private(set) var items: [Item] = []
    private(set) var links = HALLinks()
    private(set) var isLoading = false
    private(set) var isWorking = false
    var errorMessage: String?

    var isEmpty: Bool { items.isEmpty }

    /// Offered only when there is something to empty.
    var canEmpty: Bool { links.contains(.emptyTrash) }

    init(app: AppModel,
         source: HALLink,
         restoreRel: Rel = .restore,
         removeRel: Rel = .purge,
         removeMethod: String = "DELETE") {
        self.app = app
        self.source = source
        self.restoreRel = restoreRel
        self.removeRel = removeRel
        self.removeMethod = removeMethod
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

    func canRestore(_ item: Item) -> Bool { item.hasLink(restoreRel) }
    func canPurge(_ item: Item) -> Bool { item.hasLink(removeRel) }

    @discardableResult
    func restore(_ item: Item) async -> Bool {
        await act(item.link(restoreRel), method: "POST")
    }

    @discardableResult
    func purge(_ item: Item) async -> Bool {
        await act(item.link(removeRel), method: removeMethod)
    }

    /// Destroys everything in the trash. There is nothing after this.
    @discardableResult
    func emptyTrash() async -> Bool {
        await act(links[.emptyTrash], method: "DELETE")
    }

    private func act(_ link: HALLink?, method: String) async -> Bool {
        guard let link, !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            let collection: HALCollection<Item> = try await app.client.fetch(
                from: link, method: method)
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
