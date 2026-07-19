//
//  ProjectActivity.swift
//  scripty
//
//  What has been happening to a screenplay.
//
//  The summary is phrased by the server when the event is recorded, so it is
//  rendered rather than reassembled from the action type here — a client that
//  built its own sentences would drift from the web app's wording for the same
//  event. `actionType` is still carried so entries can be grouped and iconed
//  without reading the prose.
//

import Foundation

struct ProjectActivity: Decodable, Identifiable, Hashable, HALResource {
    let id: Int
    var actorDisplayName: String?
    var actionType: String?
    var summary: String?
    var createdAt: Date?
    let links: HALLinks?

    private enum CodingKeys: String, CodingKey {
        case id, actorDisplayName, actionType, summary, createdAt
        case links = "_links"
    }

    var displayActor: String {
        let trimmed = (actorDisplayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Someone" : trimmed
    }

    var displaySummary: String {
        let trimmed = (summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "made a change" : trimmed
    }

    /// A rough icon for the kind of event. Unknown types get a neutral mark
    /// rather than nothing, since the server may record kinds this build has
    /// never heard of.
    var systemImage: String {
        switch (actionType ?? "").uppercased() {
        case let type where type.contains("DELETE"): return "trash"
        case let type where type.contains("RESTORE"): return "arrow.uturn.backward"
        case let type where type.contains("IMPORT"): return "square.and.arrow.down"
        case let type where type.contains("EXPORT"): return "square.and.arrow.up"
        case let type where type.contains("COMMENT"): return "bubble.left"
        case let type where type.contains("VERSION"): return "clock.arrow.circlepath"
        case let type where type.contains("CAST") || type.contains("ACTOR"): return "person.2"
        case let type where type.contains("CREATE"): return "plus.circle"
        default: return "pencil"
        }
    }

    static func == (lhs: ProjectActivity, rhs: ProjectActivity) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
