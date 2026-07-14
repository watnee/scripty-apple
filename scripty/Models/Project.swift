//
//  Project.swift
//  scripty
//

import Foundation

/// A screenplay project. The server omits null fields, so everything but
/// `id` is optional.
struct Project: Decodable, Identifiable, Hashable, HALResource {
    let id: Int
    var title: String?
    var screenplayTitle: String?
    var writers: String?
    var contactInfo: String?
    var screenplayVersion: String?
    var lastEdited: Date?
    var teams: [String]?
    let links: HALLinks?

    private enum CodingKeys: String, CodingKey {
        case id, title, screenplayTitle, writers, contactInfo, screenplayVersion, lastEdited, teams
        case links = "_links"
    }

    var displayTitle: String {
        let name = screenplayTitle ?? title ?? ""
        return name.isEmpty ? "Untitled Project" : name
    }
}

struct CreateProjectCommand: Encodable {
    var title: String
    var teamIds: [Int] = []
}

/// Omitting `teamIds` leaves team assignments untouched on the server.
struct EditProjectCommand: Encodable {
    var title: String
}
