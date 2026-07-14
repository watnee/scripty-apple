//
//  APIRoot.swift
//  scripty
//

import Foundation

/// The links-only resource returned by `GET /api`.
/// Entry rels: projects, actors, users, teams.
struct APIRoot: Decodable, HALResource {
    let links: HALLinks?

    private enum CodingKeys: String, CodingKey {
        case links = "_links"
    }
}
