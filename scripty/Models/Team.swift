//
//  Team.swift
//  scripty
//
//  A row in the admin-only team list (`GET /api/team`). Reached from the user
//  menu's "Teams" item, shown only when the account advertises the `teams` rel.
//

import Foundation

struct Team: Decodable, Identifiable, Hashable, HALResource {
    let id: Int
    var name: String?
    let links: HALLinks?

    private enum CodingKeys: String, CodingKey {
        case id, name
        case links = "_links"
    }

    var displayName: String {
        let trimmed = name?.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty ? "Team \(id)" : trimmed
    }
}
