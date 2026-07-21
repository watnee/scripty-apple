//
//  Actor.swift
//  scripty
//

import Foundation

/// An actor available for casting. Listing requires the casting permission
/// (the server answers 403 otherwise; the UI degrades gracefully).
struct ScriptyActor: Decodable, Identifiable, Hashable, HALResource {
    let id: Int
    var first: String?
    var last: String?
    var phone: String?
    var email: String?
    var hasHeadshot: Bool?
    var projectIds: [Int]?
    /// The characters this actor auditions for, when the list was fetched scoped
    /// to a project. Nil (and so absent) on an unscoped actor, since auditions
    /// only mean something within a project. An empty array means "auditions for
    /// no one", which is distinct from nil.
    var auditionCharacterIds: [Int]?
    let links: HALLinks?

    private enum CodingKeys: String, CodingKey {
        case id, first, last, phone, email, hasHeadshot, projectIds, auditionCharacterIds
        case links = "_links"
    }

    /// Whether the server offered to set this actor's auditions — advertised only
    /// on a project-scoped actor for a user who may manage casting.
    var canSetAuditions: Bool { hasLink(.setAuditions) }

    var displayName: String {
        let value = [first, last].compactMap { $0 }.joined(separator: " ")
        return value.isEmpty ? "Unnamed" : value
    }

    /// Email preferred, phone as the fallback — what a casting list shows
    /// under the name.
    var contactLine: String? {
        let value = [email, phone]
            .compactMap { $0 }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return value.isEmpty ? nil : value.joined(separator: " · ")
    }
}

/// `projectIds` associates the new actor with the projects they can be cast
/// in; the server replaces the whole set on every write.
struct CreateActorCommand: Encodable {
    var first: String
    var last: String
    var phone: String?
    var email: String?
    var projectIds: [Int]
}

struct EditActorCommand: Encodable {
    var first: String
    var last: String
    var phone: String?
    var email: String?
    var projectIds: [Int]
}

/// The characters an actor auditions for in a project, replaced wholesale. An
/// empty list clears them; the list is always sent so "audition for no one" is
/// expressible.
struct SetAuditionsCommand: Encodable {
    var characterIds: [Int]
}
