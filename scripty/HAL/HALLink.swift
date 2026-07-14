//
//  HALLink.swift
//  scripty
//
//  HAL hypermedia link types. The client never hardcodes endpoint paths;
//  it follows these links starting from the API root.
//

import Foundation

/// A single HAL link object (`{"href": "..."}`).
struct HALLink: Codable, Hashable, Sendable {
    let href: String
    var templated: Bool?

    init(href: String, templated: Bool? = nil) {
        self.href = href
        self.templated = templated
    }

    /// Server hrefs are absolute in practice; resolve relative ones defensively.
    func url(relativeTo base: URL) -> URL? {
        URL(string: href, relativeTo: base)?.absoluteURL
    }

    /// A copy of this link with the given query parameters added or replaced.
    func addingQuery(_ items: [String: String]) -> HALLink {
        guard var components = URLComponents(string: href) else { return self }
        var query = components.queryItems ?? []
        for (name, value) in items.sorted(by: { $0.key < $1.key }) {
            query.removeAll { $0.name == name }
            query.append(URLQueryItem(name: name, value: value))
        }
        components.queryItems = query
        return HALLink(href: components.string ?? href, templated: templated)
    }
}

/// The `_links` object of a HAL resource.
/// Tolerates both single-object and array rel values (Spring emits single objects).
struct HALLinks: Hashable, Sendable {
    private var storage: [String: HALLink]

    init(_ storage: [String: HALLink] = [:]) {
        self.storage = storage
    }

    subscript(rel: Rel) -> HALLink? {
        storage[rel.rawValue]
    }

    var isEmpty: Bool { storage.isEmpty }

    func contains(_ rel: Rel) -> Bool {
        storage[rel.rawValue] != nil
    }
}

extension HALLinks: Decodable {
    private enum Value: Decodable {
        case single(HALLink)
        case many([HALLink])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let link = try? container.decode(HALLink.self) {
                self = .single(link)
            } else {
                self = .many(try container.decode([HALLink].self))
            }
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: Value].self)
        var links: [String: HALLink] = [:]
        for (rel, value) in raw {
            switch value {
            case .single(let link):
                links[rel] = link
            case .many(let list):
                links[rel] = list.first
            }
        }
        storage = links
    }
}

/// A resource that carries HAL `_links`. UI affordances are driven by link
/// presence: no `update` link means no edit button.
protocol HALResource {
    var links: HALLinks? { get }
}

extension HALResource {
    func link(_ rel: Rel) -> HALLink? {
        links?[rel]
    }

    func hasLink(_ rel: Rel) -> Bool {
        link(rel) != nil
    }
}
