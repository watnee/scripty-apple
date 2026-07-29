//
//  CommentsModel.swift
//  scripty
//
//  The comment thread on one screenplay element.
//
//  Loaded on demand rather than with the script: most elements have no
//  comments, and fetching a thread per block would cost a request each for
//  nothing.
//

import Foundation
import Observation

@Observable
@MainActor
final class CommentsModel {
    private let app: AppModel
    private let source: HALLink

    private(set) var comments: [BlockComment] = []
    private(set) var links = HALLinks()
    private(set) var isLoading = false
    private(set) var isWorking = false
    var errorMessage: String?

    /// Commenting needs only read access, so this is offered more widely than
    /// the editing affordances are.
    var canComment: Bool { links.contains(.addComment) }

    var isEmpty: Bool { comments.isEmpty }

    init(app: AppModel, source: HALLink) {
        self.app = app
        self.source = source
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let collection: HALCollection<BlockComment> = try await app.client.fetch(from: source)
            adopt(collection)
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    @discardableResult
    func add(_ body: String) async -> Bool {
        guard let link = links[.addComment] else { return false }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return await act(link, method: "POST", body: AddCommentCommand(body: trimmed))
    }

    @discardableResult
    func delete(_ comment: BlockComment) async -> Bool {
        guard let link = comment.link(.delete) else { return false }
        return await act(link, method: "DELETE")
    }

    private func act(_ link: HALLink, method: String, body: (any Encodable)? = nil) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            let collection: HALCollection<BlockComment> = try await app.client.fetch(
                from: link, method: method, body: body)
            adopt(collection)
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    private func adopt(_ collection: HALCollection<BlockComment>) {
        // Oldest first: a thread reads as a conversation.
        comments = collection.items.sorted {
            ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
        }
        links = collection.links
    }

    private func report(_ error: Error) {
        // Nothing cancelled is ever shown — see `isCancelledRequest`.
        guard !error.isCancelledRequest else { return }
        app.handle(error)
        errorMessage = error.localizedDescription
    }
}
