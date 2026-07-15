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

    /// The element created when Enter is pressed inside this one, mirroring
    /// `nextTypeAfter` in the web editor: a cue is followed by dialogue,
    /// everything else by action.
    var followingType: BlockType {
        isCharacterCue ? .dialogue : .action
    }

    /// The order the element-type bar's Tab key cycles through, matching
    /// `TAB_CYCLE` in the web editor.
    static let tabCycle: [BlockType] = [
        .scene, .action, .character, .parenthetical, .dialogue, .transition, .shot,
    ]

    /// The next type when Tab (or Shift-Tab) cycles from this one. Types
    /// outside the cycle re-enter it at `.action`.
    func cycled(backward: Bool) -> BlockType {
        let cycle = Self.tabCycle
        let start = cycle.firstIndex(of: self) ?? cycle.firstIndex(of: .action) ?? 0
        let next = backward
            ? (start - 1 + cycle.count) % cycle.count
            : (start + 1) % cycle.count
        return cycle[next]
    }
}

struct CreateBlockCommand: Encodable {
    var content: String
    var personId: Int?
    var projectId: Int
    var type: String
}

/// Edit a block's content, linked character, and tags in place.
/// (Element type is changed through `SetTypeCommand`, not here.)
struct EditBlockCommand: Encodable {
    var content: String
    var personId: Int?
    var tags: String?
}

/// Insert a new element directly below an anchor block — the Enter key in
/// the web editor. Content is the text carried into the new element.
struct CreateBelowCommand: Encodable {
    var content: String
    var personId: Int?
    var type: String
}

/// Retype a block in place — the element-type bar in the web editor.
/// Content/personId are sent so the retype can reinterpret them (e.g. a
/// character cue's name, or clearing a cue's text when it becomes dialogue).
struct SetTypeCommand: Encodable {
    var type: String
    var content: String?
    var personId: Int?
    var tags: String?
}
