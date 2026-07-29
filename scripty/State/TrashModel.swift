//
//  TrashModel.swift
//  scripty
//
//  Reading a trash and acting on what is in it. One model serves both the
//  element trash and the screenplay trash, because the shape is the same:
//  a list where each item can be restored or destroyed, reached from a link
//  the owning collection advertised.
//
//  Every action answers with the refreshed trash, so the list never has to
//  guess what happened.
//

import Foundation
import Observation

@Observable
@MainActor
final class TrashModel<Item: Decodable & Identifiable & HALResource> where Item.ID == Int {
    private let app: AppModel
    private let source: HALLink

    private(set) var items: [Item] = []
    private(set) var links = HALLinks()
    private(set) var isLoading = false
    private(set) var isWorking = false
    var errorMessage: String?

    var isEmpty: Bool { items.isEmpty }

    /// Offered only when there is something to empty.
    var canEmpty: Bool { links.contains(.emptyTrash) }

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

    func canRestore(_ item: Item) -> Bool { item.hasLink(.restore) }
    func canPurge(_ item: Item) -> Bool { item.hasLink(.purge) }

    @discardableResult
    func restore(_ item: Item) async -> Bool {
        await act(item.link(.restore), method: "POST")
    }

    @discardableResult
    func purge(_ item: Item) async -> Bool {
        await act(item.link(.purge), method: "DELETE")
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
