//
//  Account.swift
//  scripty
//
//  The signed-in user's own account (`GET /api/account`) — the "me" resource
//  behind the user menu. Distinct from `User` (the admin-only directory view):
//  every authenticated user can read this. Admin-only rels (`users`, `teams`)
//  and the `changePassword` rel are advertised only when available, so the
//  menu gates those affordances on link presence, not on a decoded flag.
//

import Foundation

struct Account: Decodable, HALResource {
    var username: String?
    var firstName: String?
    var lastName: String?
    var admin: Bool

    let links: HALLinks?

    private enum CodingKeys: String, CodingKey {
        case username, firstName, lastName, admin
        case links = "_links"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        firstName = try container.decodeIfPresent(String.self, forKey: .firstName)
        lastName = try container.decodeIfPresent(String.self, forKey: .lastName)
        admin = try container.decodeIfPresent(Bool.self, forKey: .admin) ?? false
        links = try container.decodeIfPresent(HALLinks.self, forKey: .links)
    }

    /// Best available human name: full name, then either name, then username.
    var displayName: String {
        let full = [firstName, lastName]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !full.isEmpty { return full }
        if let username, !username.isEmpty { return username }
        return "Account"
    }
}

/// Body for `PUT /api/account/password`. The server enforces the strength
/// policy and that the current password is correct; the client only enforces
/// the new/confirm match locally before sending.
struct ChangePasswordCommand: Encodable {
    var currentPassword: String
    var newPassword: String
}
