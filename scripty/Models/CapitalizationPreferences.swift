//
//  CapitalizationPreferences.swift
//  scripty
//
//  Which element types are typed in capitals, per user.
//
//  Four flags rather than one per element type, matching the server: character
//  and dual dialogue share a flag because they are the same element wearing two
//  layouts, and splitting them would let one script export inconsistently.
//
//  A *server* preference, unlike everything in PresentationSettings. It is not
//  about how the script looks on this device — the exporters bake the case into
//  the PDF, the Word file and the Final Draft file, so a writer who turns scene
//  headings off expects that to hold wherever they open the script.
//

import Foundation

struct CapitalizationPreferences: Decodable, Equatable, HALResource {
    var scene: Bool
    var character: Bool
    var transition: Bool
    var shot: Bool
    let links: HALLinks?

    private enum CodingKeys: String, CodingKey {
        case scene, character, transition, shot
        case links = "_links"
    }

    /// What the server has always done, and what to assume until it answers —
    /// so an element never starts out lowercase and jumps to capitals once a
    /// preference request lands.
    static let all = CapitalizationPreferences(
        scene: true, character: true, transition: true, shot: true, links: nil)

    /// Whether `type` is typed in capitals.
    func applies(to type: BlockType) -> Bool {
        switch type {
        case .scene: return scene
        case .character, .dualDialogue: return character
        case .transition: return transition
        case .shot: return shot
        default: return false
        }
    }

    /// The element types this preference covers, in the order the settings
    /// screen lists them — the order they appear on a page.
    static let coveredTypes: [BlockType] = [.scene, .character, .transition, .shot]

    /// The flag governing `type`, for a settings row.
    func flag(for type: BlockType) -> Bool { applies(to: type) }

    /// A copy with `type`'s flag set.
    func setting(_ type: BlockType, to value: Bool) -> CapitalizationPreferences {
        var copy = self
        switch type {
        case .scene: copy.scene = value
        case .character, .dualDialogue: copy.character = value
        case .transition: copy.transition = value
        case .shot: copy.shot = value
        default: break
        }
        return copy
    }
}

/// A partial update: the server keeps any field left out, so a toggle sends
/// only the one that changed.
struct CapitalizationUpdate: Encodable {
    var scene: Bool?
    var character: Bool?
    var transition: Bool?
    var shot: Bool?

    init(_ type: BlockType, _ value: Bool) {
        switch type {
        case .scene: scene = value
        case .character, .dualDialogue: character = value
        case .transition: transition = value
        case .shot: shot = value
        default: break
        }
    }
}
