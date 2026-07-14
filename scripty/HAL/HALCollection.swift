//
//  HALCollection.swift
//  scripty
//
//  Generic HAL collection decoding. Spring names the `_embedded` key after
//  the DTO class (e.g. "projectResourceList"); decoding key-agnostically
//  keeps the client working if those names change. Empty collections may
//  omit `_embedded` entirely.
//

import Foundation

struct HALCollection<Item: Decodable>: Decodable {
    let items: [Item]
    let links: HALLinks

    private enum CodingKeys: String, CodingKey {
        case embedded = "_embedded"
        case links = "_links"
    }

    init(items: [Item] = [], links: HALLinks = HALLinks()) {
        self.items = items
        self.links = links
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let embedded = try container.decodeIfPresent([String: [Item]].self, forKey: .embedded) ?? [:]
        items = embedded.values.flatMap { $0 }
        links = try container.decodeIfPresent(HALLinks.self, forKey: .links) ?? HALLinks()
    }
}
