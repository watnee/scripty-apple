//
//  ArchiveModel.swift
//  scripty
//
//  Reading a project's archive and acting on what is in it.
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
final class ArchiveModel {
    private let app: AppModel
    private let source: HALLink

    private(set) var items: [ArchivedDocument] = []
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
            let collection: HALCollection<ArchivedDocument> = try await app.client.fetch(from: source)
            adopt(collection)
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    func canUnarchive(_ item: ArchivedDocument) -> Bool { item.hasLink(.unarchive) }

    /// Deleting from here is the ordinary soft delete: it lands in the trash and
    /// stays restorable, so it needs no confirmation of its own.
    func canDelete(_ item: ArchivedDocument) -> Bool { item.hasLink(.delete) }

    @discardableResult
    func unarchive(_ item: ArchivedDocument) async -> Bool {
        await act(item.link(.unarchive), method: "POST")
    }

    @discardableResult
    func delete(_ item: ArchivedDocument) async -> Bool {
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

    /// The full document behind an archived row, for opening it in the editor.
    /// An archived song is still whole, which is the point of the archive.
    func document(for item: ArchivedDocument) async -> TextDocument? {
        guard let link = item.link(.document) else { return nil }
        do {
            let document: TextDocument = try await app.client.fetch(from: link)
            errorMessage = nil
            return document
        } catch {
            report(error)
            return nil
        }
    }

    private func act(_ link: HALLink?, method: String) async -> Bool {
        guard let link, !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            let collection: HALCollection<ArchivedDocument> = try await app.client.fetch(
                from: link, method: method)
            adopt(collection)
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    private func adopt(_ collection: HALCollection<ArchivedDocument>) {
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
