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
    /// Whether this is the current user's default project (server key `default`).
    var isDefault: Bool?
    let links: HALLinks?

    private enum CodingKeys: String, CodingKey {
        case id, title, screenplayTitle, writers, contactInfo, screenplayVersion, lastEdited, teams
        case isDefault = "default"
        case links = "_links"
    }

    var displayTitle: String {
        let name = screenplayTitle ?? title ?? ""
        return name.isEmpty ? "Untitled Project" : name
    }

    /// Everything the sidebar's search box matches against. The web list filters
    /// on the title alone, but its row shows only the title; this row also shows
    /// the writers, the draft version and the teams, so a search that ignored
    /// them would skip past text the writer can see — the same whole-row scan
    /// the users list does.
    var searchHaystackLowercased: String {
        var parts = [displayTitle]
        // `title` is the project name, which `displayTitle` hides whenever a
        // screenplay title is set — so a writer searching for the name they
        // filed it under still finds it.
        parts.append(contentsOf: [title, writers, screenplayVersion].compactMap { $0 })
        parts.append(contentsOf: teams ?? [])
        return parts.joined(separator: " ").lowercased()
    }
}

struct CreateProjectCommand: Encodable {
    var title: String
    var teamIds: [Int] = []
}

/// Omitting `teamIds` leaves team assignments untouched on the server, so a
/// plain rename never disturbs them and reassigning teams never touches the
/// title. The title-page fields are likewise left alone when nil, so a rename
/// does not wipe the front matter and vice versa.
struct EditProjectCommand: Encodable {
    var title: String
    var screenplayTitle: String?
    var writers: String?
    var contactInfo: String?
    var screenplayVersion: String?
    var teamIds: [Int]?
}

/// One team the project could belong to, and whether it does now — a row in the
/// `projectTeams` collection. The picker ticks the assigned ones and sends the
/// ticked ids back through the project's `update` affordance (`teamIds`).
struct ProjectTeamOption: Decodable, Identifiable, Hashable {
    let id: Int
    var name: String
    var assigned: Bool
}
