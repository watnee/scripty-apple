//
//  Person.swift
//  scripty
//

import Foundation

/// A character in a screenplay, optionally cast to an actor.
struct Person: Decodable, Identifiable, Hashable, HALResource {
    let id: Int
    var name: String?
    var fullName: String?
    var projectId: Int?
    var projectTitle: String?
    var actorId: Int?
    var actorName: String?
    let links: HALLinks?

    private enum CodingKeys: String, CodingKey {
        case id, name, fullName, projectId, projectTitle, actorId, actorName
        case links = "_links"
    }

    var displayName: String {
        let value = name ?? fullName ?? ""
        return value.isEmpty ? "Unnamed" : value
    }
}

struct CreatePersonCommand: Encodable {
    var name: String
    var fullName: String
    var actorId: Int?
    var projectId: Int
}

struct EditPersonCommand: Encodable {
    var name: String
    var fullName: String
    var actorId: Int?
    var projectId: Int?
}
