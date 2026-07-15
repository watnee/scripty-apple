//
//  Block.swift
//  scripty
//

import Foundation

/// One screenplay element (a Fountain block): scene heading, action,
/// dialogue, transition, etc. Ordered by `order` within a project.
struct Block: Decodable, Identifiable, Hashable, HALResource {
    let id: Int
    var projectId: Int?
    var order: Int?
    var content: String?
    var type: String?
    var personId: Int?
    var personName: String?
    var bookmarked: Bool?
    var pinned: Bool?
    var scene: Bool?
    var tags: String?
    var textAlign: String?
    var font: String?
    var textBold: Bool?
    var textItalic: Bool?
    var textUnderline: Bool?
    let links: HALLinks?

    private enum CodingKeys: String, CodingKey {
        case id, projectId, order, content, type, personId, personName
        case bookmarked, pinned, scene, tags, textAlign, font
        case textBold, textItalic, textUnderline
        case links = "_links"
    }

    /// Unknown server types fall back to `.action` for rendering.
    var blockType: BlockType {
        BlockType(rawValue: type ?? "") ?? .action
    }

    var isBookmarked: Bool { bookmarked ?? false }
    var isPinned: Bool { pinned ?? false }

    /// True when the server advertises any mutation link for this block.
    var isEditable: Bool { hasLink(.update) }
}

/// Fountain screenplay element types (mirrors Block.java on the server).
enum BlockType: String, CaseIterable, Identifiable {
    case scene = "SCENE"
    case action = "ACTION"
    case text = "TEXT"
    case character = "CHARACTER"
    case dialogue = "DIALOGUE"
    case dualDialogue = "DUAL_DIALOGUE"
    case parenthetical = "PARENTHETICAL"
    case transition = "TRANSITION"
    case shot = "SHOT"
    case lyrics = "LYRICS"
    case centered = "CENTERED"
    case section = "SECTION"
    case synopsis = "SYNOPSIS"
    case note = "NOTE"
    case pageBreak = "PAGE_BREAK"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .scene: return "Scene"
        case .action: return "Action"
        case .text: return "Text"
        case .character: return "Character"
        case .dialogue: return "Dialogue"
        case .dualDialogue: return "Dual Dialogue"
        case .parenthetical: return "Parenthetical"
        case .transition: return "Transition"
        case .shot: return "Shot"
        case .lyrics: return "Lyrics"
        case .centered: return "Centered"
        case .section: return "Section"
        case .synopsis: return "Synopsis"
        case .note: return "Note"
        case .pageBreak: return "Page Break"
        }
    }

    /// Character cues carry the speaker name as their content.
    var isCharacterCue: Bool {
        self == .character || self == .dualDialogue
    }

    /// The type a brand-new element gets when you press Return after this one.
    /// After a character cue you're writing dialogue; otherwise action.
    /// Mirrors `nextTypeAfter` in the web editor's fountain-power.js.
    var followingType: BlockType {
        isCharacterCue ? .dialogue : .action
    }

    /// Classic Final-Draft-style Tab order (mirrors `TAB_CYCLE`).
    static let tabCycle: [BlockType] =
        [.scene, .action, .character, .parenthetical, .dialogue, .transition, .shot]

    /// Less-common types map onto the logical cycle before advancing
    /// (mirrors `TAB_CYCLE_ENTRY`).
    private var tabCycleEntry: BlockType {
        switch self {
        case .text, .centered, .note: return .action
        case .lyrics: return .dialogue
        case .dualDialogue: return .character
        case .section, .synopsis, .pageBreak: return .scene
        default: return self
        }
    }

    /// The next (or previous) type when the writer presses Tab / Shift-Tab.
    func cyclingType(backward: Bool) -> BlockType {
        let cycle = BlockType.tabCycle
        let entry = tabCycleEntry
        let index = cycle.firstIndex(of: entry) ?? cycle.firstIndex(of: .action)!
        let step = backward ? -1 : 1
        let next = (index + step + cycle.count) % cycle.count
        return cycle[next]
    }
}

struct CreateBlockCommand: Encodable {
    var content: String
    var personId: Int?
    var projectId: Int
    var type: String
}

/// The API does not allow changing a block's type after a plain PUT.
struct EditBlockCommand: Encodable {
    var content: String
    var personId: Int?
    var tags: String?
}

/// Insert a new element directly beneath an existing block (rel `createBelow`).
/// The web editor uses this when Return splits a line: `content` is the text
/// that lands in the new element.
struct CreateBelowCommand: Encodable {
    var content: String
    var personId: Int?
    var type: String
}

/// Retype a block in place (rel `setType`) — the REST counterpart of the web
/// editor's element-type bar. Content/personId/tags are preserved when omitted.
struct SetTypeCommand: Encodable {
    var type: String
    var content: String?
    var personId: Int?
    var tags: String?
}
