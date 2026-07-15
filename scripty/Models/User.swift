//
//  User.swift
//  scripty
//
//  A row in the admin-only user directory (`GET /api/user`). Reached from the
//  user menu's "Users" item, which is shown only when the account advertises
//  the `users` rel (i.e. the caller is an admin).
//

import Foundation

struct User: Decodable, Identifiable, Hashable, HALResource {
    let id: Int
    var username: String?
    var firstName: String?
    var lastName: String?
    var team: String?
    var admin: Bool?
    var producer: Bool?
    var director: Bool?
    var writer: Bool?
    var actor: Bool?
    var crew: Bool?
    var directorOfPhotography: Bool?
    var castingDirector: Bool?
    var developer: Bool?
    var enabled: Bool?
    let links: HALLinks?

    private enum CodingKeys: String, CodingKey {
        case id, username, firstName, lastName, team
        case admin, producer, director, writer, actor, crew
        case directorOfPhotography, castingDirector, developer, enabled
        case links = "_links"
    }

    var displayName: String {
        let full = [firstName, lastName]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !full.isEmpty { return full }
        return username ?? "User \(id)"
    }

    /// Human labels for the roles this user holds, for a compact summary line.
    var roleLabels: [String] {
        var labels: [String] = []
        if admin == true { labels.append("Admin") }
        if producer == true { labels.append("Producer") }
        if director == true { labels.append("Director") }
        if writer == true { labels.append("Writer") }
        if actor == true { labels.append("Actor") }
        if crew == true { labels.append("Crew") }
        if directorOfPhotography == true { labels.append("DP") }
        if castingDirector == true { labels.append("Casting") }
        if developer == true { labels.append("Developer") }
        return labels
    }
}
