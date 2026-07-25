//
//  User.swift
//  scripty
//
//  An account on the server. Managing users is an admin task, which is why the
//  API root only advertises the `users` rel to an admin — the same gate the web
//  app puts behind ROLE_ADMIN. A deployment or account without that rel sees no
//  user-management UI at all, rather than a screen that 403s.
//
//  The resource carries the account's identity and its role flags; what an admin
//  may do with one travels as links (`update`, `delete`), not as computed rules.
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
    var viewCasting: Bool?
    var developer: Bool?
    var enabled: Bool?
    /// Which projects this account can reach, and why. Present only on the
    /// single-user resource the `self` link returns (the profile), not on the
    /// list items — so it is nil until a profile is fetched. Admin-diagnostic,
    /// mirroring the web profile page's access breakdown.
    var projectAccess: [UserProjectAccess]?
    let links: HALLinks?

    private enum CodingKeys: String, CodingKey {
        case id, username, firstName, lastName, team, admin, producer, director,
             writer, actor, crew, directorOfPhotography, castingDirector,
             viewCasting, developer, enabled, projectAccess
        case links = "_links"
    }

    var displayName: String {
        let value = [firstName, lastName].compactMap { $0 }.joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? (username ?? "Unnamed") : value
    }

    /// The account's granted roles, in the order the web app lists them, for the
    /// one-line summary under a name. An admin outranks everything, so it stands
    /// alone.
    var roleSummary: String {
        if admin == true { return "Admin" }
        let roles: [(Bool?, String)] = [
            (director, "Director"), (producer, "Producer"), (writer, "Writer"),
            (actor, "Actor"), (crew, "Crew"),
            (directorOfPhotography, "DoP"), (castingDirector, "Casting"),
            (viewCasting, "View Casting"), (developer, "Developer"),
        ]
        let granted = roles.filter { $0.0 == true }.map(\.1)
        return granted.isEmpty ? "No roles" : granted.joined(separator: " · ")
    }

    var canUpdate: Bool { hasLink(.update) }
    /// Delete is offered as a link only when the server allows it — an admin
    /// cannot remove their own account, so that row simply carries no `delete`.
    var canDelete: Bool { hasLink(.delete) }
}

/// One project an account can reach, and why — a row of the profile's access
/// breakdown. The server computes every field (whether it is view-only or
/// editable, and the reason: a privileged role, a team, or an open project),
/// so the client only displays them. Present only on a fetched profile.
struct UserProjectAccess: Decodable, Identifiable, Hashable {
    let projectId: Int
    var projectName: String?
    var canEdit: Bool?
    var permissionLabel: String?
    var accessReason: String?

    var id: Int { projectId }
}

/// A new account. The server hashes `password`; the role flags default to false
/// when omitted, so only the granted ones need sending — but the form sends the
/// full set so a cleared box genuinely clears the role.
struct CreateUserCommand: Encodable {
    var username: String
    var password: String
    var firstName: String
    var lastName: String
    var team: String?
    var admin: Bool
    var director: Bool
    var producer: Bool
    var writer: Bool
    var actor: Bool
    var crew: Bool
    var directorOfPhotography: Bool
    var castingDirector: Bool
    var viewCasting: Bool
    var developer: Bool
}

/// An edit to an existing account. A blank `password` means "leave it unchanged"
/// — the server reads a blank one as null rather than trying to validate it — so
/// it is omitted from the body entirely when the admin did not type a new one.
struct EditUserCommand: Encodable {
    var username: String
    var password: String?
    var firstName: String
    var lastName: String
    var team: String?
    var admin: Bool
    var director: Bool
    var producer: Bool
    var writer: Bool
    var actor: Bool
    var crew: Bool
    var directorOfPhotography: Bool
    var castingDirector: Bool
    var viewCasting: Bool
    var developer: Bool
}
