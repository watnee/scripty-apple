//
//  ProjectVersion.swift
//  scripty
//
//  A saved snapshot of a screenplay. The server has kept version history over
//  REST all along — this is the client finally reading it.
//
//  Snapshots are taken automatically as the script changes and can also be
//  named by hand; `autoSave` tells the two apart, which matters because a
//  history that lists a hundred automatic saves the same way as the four the
//  writer deliberately marked is not much of a history.
//

import Foundation

struct ProjectVersion: Decodable, Identifiable, Hashable, HALResource {
    let id: Int
    var label: String?
    var createdAt: Date?
    var autoSave: Bool?
    var sceneCount: Int?
    var blockCount: Int?
    var characterCount: Int?
    var changeSummary: VersionChangeSummary?
    let links: HALLinks?

    private enum CodingKeys: String, CodingKey {
        case id, label, createdAt, autoSave, sceneCount, blockCount, characterCount
        case changeSummary
        case links = "_links"
    }

    var isAutoSave: Bool { autoSave ?? false }

    var displayLabel: String {
        let trimmed = (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return isAutoSave ? "Autosave" : "Version"
    }

    /// "12 scenes · 240 elements · 6 characters", skipping anything the server
    /// did not report.
    var sizeSummary: String {
        var parts: [String] = []
        if let scenes = sceneCount {
            parts.append("\(scenes) " + (scenes == 1 ? "scene" : "scenes"))
        }
        if let blocks = blockCount {
            parts.append("\(blocks) " + (blocks == 1 ? "element" : "elements"))
        }
        if let characters = characterCount, characters > 0 {
            parts.append("\(characters) " + (characters == 1 ? "character" : "characters"))
        }
        return parts.joined(separator: " · ")
    }

    static func == (lhs: ProjectVersion, rhs: ProjectVersion) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// What changed since the previous snapshot. The server works this out when it
/// saves, so the client never diffs anything itself.
struct VersionChangeSummary: Decodable, Hashable {
    var blocksAdded: Int?
    var blocksRemoved: Int?
    var blocksEdited: Int?
    var scenesAdded: Int?
    var scenesRemoved: Int?
    var scenesRenamed: Int?
    var charactersAdded: Int?
    var charactersRemoved: Int?
    var projectMetadataChanged: Bool?
    /// A few human-readable lines the server already phrased.
    var details: [String]?

    /// Compact counts for the row: "+12 −3 ~5".
    var tallies: [(symbol: String, count: Int)] {
        var result: [(String, Int)] = []
        let added = (blocksAdded ?? 0) + (scenesAdded ?? 0) + (charactersAdded ?? 0)
        let removed = (blocksRemoved ?? 0) + (scenesRemoved ?? 0) + (charactersRemoved ?? 0)
        let edited = (blocksEdited ?? 0) + (scenesRenamed ?? 0)
        if added > 0 { result.append(("+", added)) }
        if removed > 0 { result.append(("−", removed)) }
        if edited > 0 { result.append(("~", edited)) }
        return result
    }

    var isEmpty: Bool {
        tallies.isEmpty && !(projectMetadataChanged ?? false) && (details ?? []).isEmpty
    }
}

/// Naming a snapshot is optional; the server falls back to "Version".
struct CreateVersionCommand: Encodable {
    var label: String?
}
